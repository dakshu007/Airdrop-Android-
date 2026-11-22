import Foundation
import Network

/// A file the user chose to send.
public struct OutgoingFile: Equatable {
    public let url: URL
    public let name: String
    public let mime: String?
    /// Folders to recreate on the receiver, outermost first (§9.1).
    public let path: [String]
    /// In-memory content (links and text, §9.2); `url` is unused when set.
    public let data: Data?

    public init(url: URL, name: String? = nil, mime: String? = nil, path: [String] = []) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.mime = mime
        self.path = path
        self.data = nil
    }

    private init(text: String, name: String) {
        self.url = URL(fileURLWithPath: "/dev/null")
        self.name = name
        self.mime = "text/plain; charset=utf-8"
        self.path = []
        self.data = Data(text.utf8)
    }

    /// A link or text to hand off; send with `kind: .link` or `.text`.
    public static func text(_ text: String, name: String = "Text") -> OutgoingFile {
        OutgoingFile(text: text, name: name)
    }
}

/// Sender side of one transfer (client role). Create, then `await run()`.
public final class OutgoingTransfer {
    public let id: String
    public let files: [OutgoingFile]
    public let endpoint: NWEndpoint
    public let kind: OfferKind
    /// The capture request this transfer answers (§9.7); the requester accepts it without asking.
    public let requestId: String?
    /// Asks the receiver to delete what it saved after this many seconds (§9.8).
    public let expiresAfter: Int64?
    /// Turbo (§9.10): up to this many connections for a multi-file transfer, 1 (off) to 4.
    /// Used only when the receiver agrees; otherwise the transfer runs on one connection.
    public let turbo: Int

    private let identity: DeviceIdentity
    private let local: LocalInfo
    private let trust: TrustProvider
    private weak var delegate: CrossDropDelegate?
    private let publisher: SnapshotPublisher

    private let lock = NSLock()
    private var cancelled = false
    private var channel: SecureChannel?
    private var pendingDecision: Decision?
    private var offerSent = false
    private let qr: QrPairing?
    /// A Drip Room shared with the receiver (§9.9): pairing proves membership instead of comparing codes.
    private let room: Room?
    /// Bytes the receiver already holds per file, from `transfer.accept` (§9.3).
    private var resumeAt: [Int64: Int64] = [:]
    /// What the receiver granted for Turbo in `transfer.accept` (§9.10).
    private var turboJoin: Turbo.Join?
    private var turboGroup: OutgoingTurbo?
    /// Turbo: receiver-confirmed bytes per file (files arrive out of order).
    private var confirmed: [Int64: Int64] = [:]
    /// The numeric address that answered, once connected (for "last address that worked", §9.5).
    public private(set) var connectedAddress: (host: String, port: UInt16)?
    /// Test hook: called after each data record with the bytes sent so far for the file.
    public var onChunkSent: ((Int64) -> Void)?

    public init(endpoint: NWEndpoint, peerName: String, peerId: String?, peerPlatform: String?,
                files: [OutgoingFile], identity: DeviceIdentity, local: LocalInfo, trust: TrustProvider,
                delegate: CrossDropDelegate?, id: String = UUID().uuidString,
                kind: OfferKind = .files, qr: QrPairing? = nil,
                requestId: String? = nil, expiresAfter: Int64? = nil, room: Room? = nil, turbo: Int = 1) {
        self.id = id
        self.turbo = turbo
        self.endpoint = endpoint
        self.files = files
        self.kind = kind
        self.qr = qr
        self.requestId = requestId
        self.expiresAfter = expiresAfter
        self.room = room
        self.identity = identity
        self.local = local
        self.trust = trust
        self.delegate = delegate
        let states = files.map {
            TransferFileState(name: ($0.path + [$0.name]).joined(separator: "/"), size: 0, mime: $0.mime,
                              sourceURL: $0.data == nil ? $0.url : nil)
        }
        var initial = TransferSnapshot(id: id, direction: .outgoing, peerId: peerId, peerName: peerName,
                                       peerPlatform: peerPlatform, phase: .preparing, files: states)
        initial.kind = kind
        initial.requestId = requestId
        initial.expiresAfter = expiresAfter
        self.publisher = SnapshotPublisher(initial, delegate: delegate)
    }

    public var snapshot: TransferSnapshot { publisher.current }

    /// Stops the transfer. Safe to call from any thread, at any time.
    public func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let channel = self.channel
        let decision = pendingDecision
        let notify = offerSent
        let group = turboGroup
        lock.unlock()
        decision?.resolve(false)
        group?.cancelSides(transferId: id)
        guard let open = channel else { return }
        Task {
            if notify, open.isEncrypted {
                try? await open.sendControl(WireMessage.make("transfer.cancel", ["transferId": self.id, "reason": "user"]))
            }
            open.transport.close()
        }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func checkCancelled() throws {
        if isCancelled { throw CrossDropError.local(ErrorCode.cancelled) }
    }

    /// Runs to completion and returns the final snapshot.
    @discardableResult
    public func run() async -> TransferSnapshot {
        publisher.update(force: true) { _ in }
        var channel: SecureChannel?
        do {
            if let requestId = requestId, !TransferOffer.isValidTransferId(requestId) {
                throw CrossDropError.local(ErrorCode.internalError, "bad requestId")
            }
            if let seconds = expiresAfter,
               !(ProtocolConstants.minExpiresAfter...ProtocolConstants.maxExpiresAfter).contains(seconds) {
                throw CrossDropError.local(ErrorCode.internalError, "expiresAfter out of range")
            }
            guard (1...ProtocolConstants.maxTurboStreams).contains(turbo) else {
                throw CrossDropError.local(ErrorCode.internalError, "turbo out of range")
            }
            let offerFiles = try prepare()
            try checkCancelled()

            publisher.update { $0.phase = .connecting }
            let transport = NWTransport.connect(to: endpoint)
            let secure = SecureChannel(transport: transport)
            channel = secure
            lock.lock()
            self.channel = secure
            lock.unlock()
            try checkCancelled()
            try await transport.start(timeout: ProtocolConstants.connectTimeout)
            // IPv4 only: a link-local IPv6 address is useless without this Mac's interface scope.
            if case let .hostPort(.ipv4(address), port)? = transport.connection.currentPath?.remoteEndpoint {
                connectedAddress = ("\(address)", port.rawValue)
            }

            let handshake = try await Handshake.runClient(channel: secure, identity: identity, local: local, trust: trust)
            let peer = handshake.peer
            publisher.update { s in
                s.peerId = peer.deviceId
                s.peerName = peer.name
                s.peerPlatform = peer.platform
            }
            try checkCancelled()

            var paired = false
            if trust.trustedIdentityKey(for: peer.deviceId) != peer.identityKey {
                try await pair(secure, peer: peer, sas: handshake.sas, transcriptHash: handshake.transcriptHash, room: room)
                paired = true
            }

            // Turbo (§9.10): ask for extra connections when there is more than one file.
            let parallel: Int? = (turbo >= 2 && kind == .files && offerFiles.count >= 2) ? min(turbo, offerFiles.count) : nil
            let offer = TransferOffer(transferId: id, files: offerFiles, kind: kind,
                                      requestId: requestId, expiresAfter: expiresAfter, parallel: parallel)
            try await waitForAcceptance(secure, offer: offer, peer: peer, sas: handshake.sas, alreadyPaired: paired)
            if publisher.current.phase == .rejected { secure.transport.close(); return publisher.current }

            publisher.update(force: true) { $0.phase = .transferring }
            if let join = turboJoin {
                try await streamTurbo(secure, offer: offer, peer: peer, join: join)
            } else {
                try await stream(secure, offer: offer)
            }
            trust.touch(peer: peer)
            publisher.finish(.completed)
        } catch let error as CrossDropError {
            let effective = isCancelled ? CrossDropError.local(ErrorCode.cancelled) : error
            publisher.finish(effective.isCancellation ? .cancelled : .failed, error: effective)
            if let channel = channel, !isCancelled { await channel.abort(with: error) }
        } catch {
            let wrapped = CrossDropError.local(ErrorCode.internalError, "\(error)")
            publisher.finish(.failed, error: wrapped)
        }
        channel?.transport.close()
        return publisher.current
    }

    /// Reads sizes and hashes every file before connecting (§6.1).
    private func prepare() throws -> [OfferedFile] {
        var result: [OfferedFile] = []
        for (index, file) in files.enumerated() {
            try checkCancelled()
            let hashed: (Int64, String)
            if let data = file.data {
                hashed = (Int64(data.count), Hex.encode(CDCrypto.sha256(data)))
            } else {
                hashed = try Self.hashFile(file.url) { [weak self] in self?.isCancelled ?? true }
            }
            let (size, digest) = hashed
            if kind != .files && size > ProtocolConstants.maxTextPayload {
                throw CrossDropError.local(ErrorCode.fileUnreadable, "text too long")
            }
            result.append(OfferedFile(fileId: Int64(index), name: file.name, size: size, mime: file.mime,
                                      sha256: digest, path: file.path))
            publisher.update { s in
                s.files[index].size = size
                s.files[index].sha256 = digest
            }
        }
        return result
    }

    static func hashFile(_ url: URL, isCancelled: () -> Bool) throws -> (Int64, String) {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw CrossDropError.local(ErrorCode.fileUnreadable)
        }
        defer { try? handle.close() }
        var hash = StreamingHash()
        var size: Int64 = 0
        while true {
            if isCancelled() { throw CrossDropError.local(ErrorCode.cancelled) }
            let chunk: Data
            do {
                chunk = try autoreleasepool { try handle.read(upToCount: 1 << 20) } ?? Data()
            } catch {
                throw CrossDropError.local(ErrorCode.fileUnreadable)
            }
            if chunk.isEmpty { break }
            hash.update(chunk)
            size += Int64(chunk.count)
        }
        return (size, hash.finalizeHex())
    }

    private func pair(_ channel: SecureChannel, peer: PeerInfo, sas: String,
                      transcriptHash: Data = Data(), room: Room? = nil) async throws {
        publisher.update(force: true) { $0.phase = .pairing }
        try await QrPairingClient.pair(channel: channel, peer: peer, sas: sas, qr: qr, trust: trust,
                                       delegate: delegate,
                                       onDecision: { [weak self] decision in self?.setPending(decision) },
                                       transcriptHash: transcriptHash, room: room)
        setPending(nil)
    }

    private func setPending(_ decision: Decision?) {
        lock.lock()
        pendingDecision = decision
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { decision?.resolve(false) }
    }

    private func waitForAcceptance(_ channel: SecureChannel, offer: TransferOffer, peer: PeerInfo,
                                   sas: String, alreadyPaired: Bool) async throws {
        var pairedHere = alreadyPaired
        while true {
            try checkCancelled()
            publisher.update(force: true) { $0.phase = .waitingForAcceptance }
            try await channel.sendControl(offer.toMessage())
            lock.lock()
            offerSent = true
            lock.unlock()
            let reply = try await channel.receiveControl(timeout: ProtocolConstants.humanTimeout + 15)
            switch reply.type {
            case "transfer.accept":
                guard try reply.requireString("transferId") == offer.transferId else {
                    throw CrossDropError.violation(ErrorCode.unexpectedMessage)
                }
                resumeAt = try Self.parseResume(reply, offer: offer)
                turboJoin = try Turbo.parseJoin(reply, requested: offer.parallel)
                return
            case "transfer.reject":
                let reason = reply.string("reason").map { String($0.prefix(64)) } ?? "declined"
                publisher.finish(.rejected, rejectReason: reason)
                return
            case "error":
                let error = reply.peerError()
                if error.code == ErrorCode.pairingRequired && !pairedHere {
                    lock.lock()
                    offerSent = false
                    lock.unlock()
                    try await pair(channel, peer: peer, sas: sas)
                    pairedHere = true
                    continue
                }
                throw error
            case "transfer.cancel":
                throw CrossDropError.peer(ErrorCode.cancelled)
            default:
                throw CrossDropError.violation(ErrorCode.unexpectedMessage)
            }
        }
    }

    /// Validates the receiver's `resume` list (§9.3): known files, 0 < offset < size.
    static func parseResume(_ reply: WireMessage, offer: TransferOffer) throws -> [Int64: Int64] {
        guard let raw = reply.fields["resume"], !(raw is NSNull) else { return [:] }
        let bad = CrossDropError.violation(ErrorCode.badMessage, "bad resume entry")
        guard offer.kind == .files, let list = raw as? [Any], list.count <= offer.files.count else { throw bad }
        var sizes: [Int64: Int64] = [:]
        for file in offer.files { sizes[file.fileId] = file.size }
        var result: [Int64: Int64] = [:]
        for item in list {
            guard let entry = item as? [String: Any],
                  let fileId = JSONValue.int(entry["fileId"]), let offset = JSONValue.int(entry["offset"]),
                  let size = sizes[fileId], offset > 0, offset < size, result[fileId] == nil else { throw bad }
            result[fileId] = offset
        }
        return result
    }

    private func stream(_ channel: SecureChannel, offer: TransferOffer) async throws {
        let publisher = self.publisher
        let reader = Task<Void, Error> {
            while true {
                let message = try await channel.receiveControl(timeout: ProtocolConstants.streamTimeout)
                switch message.type {
                case "transfer.progress":
                    if let fileId = message.int("fileId"), let bytes = message.int("bytes") {
                        let prior = offer.files.prefix(while: { $0.fileId != fileId }).reduce(Int64(0)) { $0 + $1.size }
                        publisher.update { $0.peerConfirmedBytes = prior + bytes }
                    }
                case "transfer.complete":
                    return
                case "transfer.cancel":
                    throw CrossDropError.peer(ErrorCode.cancelled)
                case "error":
                    throw message.peerError()
                default:
                    throw CrossDropError.violation(ErrorCode.unexpectedMessage)
                }
            }
        }

        do {
            try await writeFiles(channel, offer: offer)
        } catch let writeError as CrossDropError {
            if writeError.peerCode != nil || writeError.isCancellation || writeError.code == ErrorCode.fileUnreadable {
                reader.cancel()
                if writeError.code == ErrorCode.fileUnreadable {
                    try? await channel.sendControl(WireMessage.make("transfer.cancel", [
                        "transferId": offer.transferId, "reason": "source_unavailable",
                    ]))
                    channel.transport.close()
                }
                throw writeError
            }
            // Transport failure: the reader usually holds the real reason (e.g. integrity_failed).
            do {
                try await reader.value
            } catch let readError as CrossDropError where readError.fromPeer {
                throw readError
            } catch {}
            throw writeError
        }
        try await reader.value
    }

    private func writeFiles(_ channel: SecureChannel, offer: TransferOffer) async throws {
        for index in offer.files.indices {
            try checkCancelled()
            try await writeFile(channel, offer: offer, index: index, group: nil)
        }
    }

    /// Sends file `index` whole on `channel`: `transfer.start`, then its data records.
    private func writeFile(_ channel: SecureChannel, offer: TransferOffer, index: Int, group: OutgoingTurbo?) async throws {
        let file = offer.files[index]
        let offset = resumeAt[file.fileId] ?? 0
        var start: [String: Any] = ["transferId": offer.transferId, "fileId": file.fileId]
        if offset > 0 { start["offset"] = offset }
        try await channel.sendControl(WireMessage.make("transfer.start", start))
        if let data = files[index].data {
            // Link / text: one small payload from memory.
            var sent = 0
            while sent < data.count {
                let end = min(sent + ProtocolConstants.maxDataBody, data.count)
                try await channel.sendData(data.subdata(in: sent..<end))
                sent = end
            }
            publisher.update { $0.files[index].bytes = Int64(data.count) }
            return
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: files[index].url)
            if offset > 0 { try handle.seek(toOffset: UInt64(offset)) }
        } catch {
            throw CrossDropError.local(ErrorCode.fileUnreadable)
        }
        defer { try? handle.close() }
        var sent: Int64 = offset
        if offset > 0 {
            publisher.update(force: true) { s in
                s.files[index].bytes = offset
                s.resumedBytes += offset
            }
        }
        while sent < file.size {
            try checkCancelled()
            try group?.checkFailed()
            let want = Int(min(Int64(ProtocolConstants.maxDataBody), file.size - sent))
            let chunk: Data
            do {
                chunk = try autoreleasepool { try handle.read(upToCount: want) } ?? Data()
            } catch {
                throw CrossDropError.local(ErrorCode.fileUnreadable)
            }
            // The file changed since it was hashed.
            guard !chunk.isEmpty else { throw CrossDropError.local(ErrorCode.fileUnreadable, "file shrank") }
            try await channel.sendData(chunk)
            sent += Int64(chunk.count)
            group?.keepAlive()
            let progress = sent
            publisher.update { $0.files[index].bytes = progress }
            onChunkSent?(progress)
        }
    }

    // MARK: Turbo (§9.10)

    /// Opens up to `join.max - 1` extra connections to the same receiver. Every connection
    /// takes the next file from a shared queue and sends it whole; `transfer.complete` still
    /// arrives on the main connection. The first failure on any connection ends them all.
    private func streamTurbo(_ main: SecureChannel, offer: TransferOffer, peer: PeerInfo, join: Turbo.Join) async throws {
        let group = OutgoingTurbo(main: main, fileCount: offer.files.count, sideAttempts: join.max - 1)
        lock.lock()
        turboGroup = group
        let alreadyCancelled = cancelled
        lock.unlock()
        defer { group.closeSides() }
        if alreadyCancelled { throw CrossDropError.local(ErrorCode.cancelled) }
        // Extra connections go to the address that answered, so they reach the same device.
        let target = main.transport.connection.currentPath?.remoteEndpoint ?? endpoint
        for _ in 1..<join.max {
            Task { await self.runSide(target, offer: offer, peer: peer, join: join, group: group) }
        }
        let reader = Task { await self.readTurboReplies(main, group: group, isMain: true) }
        let worker = Task { await self.workTurbo(main, offer: offer, group: group, isMain: true) }
        do {
            try await group.wait()
        } catch {
            reader.cancel()
            worker.cancel()
            throw error
        }
    }

    /// One extra connection: handshake, `transfer.join`, then files from the shared queue.
    private func runSide(_ target: NWEndpoint, offer: TransferOffer, peer: PeerInfo, join: Turbo.Join,
                         group: OutgoingTurbo) async {
        let transport = NWTransport.connect(to: target)
        let channel = SecureChannel(transport: transport)
        guard !isCancelled, group.addSide(channel) else {
            transport.close()
            group.settle()
            return
        }
        do {
            try await transport.start(timeout: ProtocolConstants.connectTimeout)
            let handshake = try await Handshake.runClient(channel: channel, identity: identity, local: local, trust: trust)
            // The same device, already trusted: no pairing happens on an extra connection.
            guard handshake.peer.deviceId == peer.deviceId, handshake.peer.identityKey == peer.identityKey,
                  trust.trustedIdentityKey(for: peer.deviceId) == peer.identityKey else {
                throw CrossDropError.local(ErrorCode.peerChangedIdentity, "another device")
            }
            try await channel.sendControl(WireMessage.make("transfer.join", [
                "transferId": offer.transferId, "token": join.token,
            ]))
            let reply = try await channel.receiveControl(timeout: ProtocolConstants.handshakeTimeout)
            guard reply.type == "transfer.joined", reply.string("transferId") == offer.transferId else {
                throw CrossDropError.local(ErrorCode.unexpectedMessage, "join refused")
            }
        } catch {
            // Not joined: its files stay in the queue for the other connections.
            group.removeSide(channel)
            transport.close()
            group.settle()
            return
        }
        let streams = group.joined(channel)
        publisher.update(force: true) { $0.streams = streams }
        group.settle()
        let reader = Task { await self.readTurboReplies(channel, group: group, isMain: false) }
        await workTurbo(channel, offer: offer, group: group, isMain: false)
        await reader.value
    }

    /// Sends files from the shared queue on `channel` until none is left.
    private func workTurbo(_ channel: SecureChannel, offer: TransferOffer, group: OutgoingTurbo, isMain: Bool) async {
        // Give the extra connections a moment to join, so the files spread over all of them.
        if isMain { await group.waitSettled(within: ProtocolConstants.turboJoinWait) }
        do {
            while let index = group.next(for: channel) {
                try checkCancelled()
                try group.checkFailed()
                try await writeFile(channel, offer: offer, index: index, group: group)
                group.fileSent(on: channel)
            }
        } catch let error as CrossDropError {
            if error.code == ErrorCode.fileUnreadable {
                // As on one connection: tell the receiver why, on the main connection.
                try? await group.main.sendControl(WireMessage.make("transfer.cancel", [
                    "transferId": offer.transferId, "reason": "source_unavailable",
                ]))
                group.fail(error)
            } else if error.fromPeer || error.isCancellation || error.peerCode != nil {
                group.fail(error)
            } else {
                // The connection broke in the middle of a file. A reader usually reports what the
                // receiver said first; otherwise the loss itself ends the transfer.
                try? await Task.sleep(nanoseconds: Self.lossGraceNanoseconds)
                group.fail(error)
            }
        } catch {
            group.fail(CrossDropError.local(ErrorCode.internalError, "\(error)"))
        }
    }

    /// Reads the receiver's messages on one Turbo connection: progress, and on the main
    /// connection `transfer.complete`. An idle extra connection that closes loses nothing.
    private func readTurboReplies(_ channel: SecureChannel, group: OutgoingTurbo, isMain: Bool) async {
        do {
            while !group.isEnded {
                let message = try await channel.receiveControl(timeout: ProtocolConstants.streamTimeout)
                switch message.type {
                case "transfer.progress":
                    recordProgress(message)
                    group.keepAlive()
                case "transfer.complete" where isMain:
                    guard try message.requireString("transferId") == id else {
                        throw CrossDropError.violation(ErrorCode.unexpectedMessage)
                    }
                    group.succeed()
                    return
                case "transfer.cancel":
                    throw CrossDropError.peer(ErrorCode.cancelled)
                case "error":
                    throw message.peerError()
                default:
                    throw CrossDropError.violation(ErrorCode.unexpectedMessage)
                }
            }
        } catch let error as CrossDropError {
            if group.isEnded { return }
            if !isMain && !error.fromPeer && error.peerCode == nil {
                // An idle extra connection that closes loses nothing.
                if !group.isBusy(channel) { return }
                // One carrying a file: the receiver usually explains why on the main connection.
                try? await Task.sleep(nanoseconds: Self.lossGraceNanoseconds)
            }
            group.fail(error)
        } catch {
            group.fail(CrossDropError.local(ErrorCode.internalError, "\(error)"))
        }
    }

    /// How long a broken Turbo connection waits for the receiver's reason on the others (§9.10).
    static let lossGraceNanoseconds: UInt64 = 1_000_000_000

    /// Receiver progress for one file; the total is the sum over files (they finish out of order).
    private func recordProgress(_ message: WireMessage) {
        guard message.string("transferId") == id, let fileId = message.int("fileId"),
              let bytes = message.int("bytes") else { return }
        lock.lock()
        confirmed[fileId] = bytes
        let total = confirmed.values.reduce(Int64(0), +)
        lock.unlock()
        publisher.update { $0.peerConfirmedBytes = total }
    }
}

/// Pairing driven by a scanned QR code (§9.4): the receiver is only accepted if its
/// identity key matches the code, and the code's one-time token lets the receiver
/// skip its prompt. Without a code it is the usual compare-the-numbers pairing.
public enum QrPairingClient {
    static func pair(channel: SecureChannel, peer: PeerInfo, sas: String, qr: QrPairing?, trust: TrustProvider,
                     delegate: CrossDropDelegate?, onDecision: ((Decision) -> Void)?,
                     transcriptHash: Data = Data(), room: Room? = nil) async throws {
        if qr == nil, let room = room, room.isActive(), trust.supportsTrustExpiry, !transcriptHash.isEmpty {
            try await RoomPairingClient.pair(channel: channel, peer: peer, sas: sas, transcriptHash: transcriptHash,
                                             room: room, trust: trust, delegate: delegate, onDecision: onDecision)
            return
        }
        guard let qr = qr else {
            try await channel.sendControl(WireMessage.make("pair.request"))
            try await PairingFlow.run(channel: channel, peer: peer, sas: sas, role: .sender, autoConfirm: false,
                                      trust: trust, delegate: delegate, onDecision: onDecision)
            return
        }
        guard peer.fingerprint == qr.fingerprint else {
            throw CrossDropError.violation(ErrorCode.authFailed, "not the device in the QR code")
        }
        try await channel.sendControl(WireMessage.make("pair.request", ["token": qr.token]))
        try await PairingFlow.run(channel: channel, peer: peer, sas: sas, role: .sender, autoConfirm: false,
                                  autoMine: qr.mine, trust: trust, delegate: delegate, onDecision: onDecision)
    }

    /// Connects to the device in a QR code, pairs, and closes. Tries each endpoint in
    /// turn (the code lists every address of the receiver). Returns the paired peer.
    public static func pairOnly(endpoints: [NWEndpoint], qr: QrPairing, identity: DeviceIdentity, local: LocalInfo,
                                trust: TrustProvider, delegate: CrossDropDelegate?) async throws -> PeerInfo {
        var lastError = CrossDropError.local(ErrorCode.unreachable, "no address")
        for endpoint in endpoints {
            let transport = NWTransport.connect(to: endpoint)
            let channel = SecureChannel(transport: transport)
            do {
                try await transport.start(timeout: ProtocolConstants.connectTimeout)
            } catch {
                transport.close()
                lastError = CrossDropError.local(ErrorCode.unreachable, "connect failed")
                continue
            }
            do {
                let handshake = try await Handshake.runClient(channel: channel, identity: identity, local: local, trust: trust)
                try await pair(channel: channel, peer: handshake.peer, sas: handshake.sas, qr: qr, trust: trust,
                               delegate: delegate, onDecision: nil)
                transport.close()
                return handshake.peer
            } catch let error as CrossDropError {
                await channel.abort(with: error)
                throw error
            }
        }
        throw lastError
    }
}

/// Pairing inside a Drip Room (§9.9). The sender proves it holds the room key over this
/// exact handshake; a receiver in the same room answers at once with its own proof, and
/// both store trust that ends with the room. Without that answer (unknown room, wrong
/// key, or an older receiver) it falls back to the normal code comparison.
public enum RoomPairingClient {
    static func pair(channel: SecureChannel, peer: PeerInfo, sas: String, transcriptHash: Data, room: Room,
                     trust: TrustProvider, delegate: CrossDropDelegate?,
                     onDecision: ((Decision) -> Void)?) async throws {
        let proof = room.proof(transcriptHash: transcriptHash).base64EncodedString()
        try await channel.sendControl(WireMessage.make("pair.request", ["room": ["id": room.id, "proof": proof]]))
        // One read of the receiver's first answer; PairingFlow keeps waiting on it if it is slow.
        let answer = Task<WireMessage, Error> {
            try await channel.receiveControl(timeout: ProtocolConstants.humanTimeout + 15)
        }
        // A receiver that accepts the proof answers without a human; anything slower means codes.
        let early = await firstResult(of: answer, within: ProtocolConstants.roomAnswerWait)
        guard let result = early else {
            try await PairingFlow.run(channel: channel, peer: peer, sas: sas, role: .sender, autoConfirm: false,
                                      pendingAnswer: answer, trust: trust, delegate: delegate, onDecision: onDecision)
            return
        }
        let message: WireMessage
        switch result {
        case .success(let value): message = value
        case .failure(let error): throw error
        }
        switch message.type {
        case "pair.confirm":
            guard try message.requireBool("accepted") else { throw CrossDropError.peer(ErrorCode.pairingRejected) }
        case "error":
            throw message.peerError()
        case "transfer.cancel":
            throw CrossDropError.peer(ErrorCode.cancelled)
        default:
            throw CrossDropError.violation(ErrorCode.unexpectedMessage)
        }
        if confirmProofIsValid(message, room: room, transcriptHash: transcriptHash) {
            try await PairingFlow.run(channel: channel, peer: peer, sas: sas, role: .sender, autoConfirm: false,
                                      autoMine: false, autoExpiresAt: room.expiryDate, pendingAnswer: answer,
                                      trust: trust, delegate: delegate, onDecision: onDecision)
        } else {
            // The receiver confirmed without proving the room (it already trusted us): compare codes here.
            try await PairingFlow.run(channel: channel, peer: peer, sas: sas, role: .sender, autoConfirm: false,
                                      pendingAnswer: answer, trust: trust, delegate: delegate, onDecision: onDecision)
        }
    }

    /// The task's outcome if it finishes within `seconds`, otherwise nil (the task keeps
    /// running, and a later `task.value` still gets its result). Not a task group: a group
    /// would wait for its child awaiting `task.value`, which cancellation does not end.
    static func firstResult(of task: Task<WireMessage, Error>, within seconds: TimeInterval) async -> Result<WireMessage, Error>? {
        let outcome = try? await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Result<WireMessage, Error>?, Error>) in
            let box = ContinuationBox(continuation)
            Task {
                do {
                    let value = try await task.value
                    box.resume(returning: .success(value))
                } catch {
                    box.resume(returning: .failure(error))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                box.resume(returning: nil)
            }
        }
        return outcome ?? nil
    }

    static func confirmProofIsValid(_ message: WireMessage, room: Room, transcriptHash: Data) -> Bool {
        guard let entry = message.fields["room"] as? [String: Any],
              let id = entry["id"] as? String, id == room.id,
              let text = entry["proof"] as? String, text.utf8.count <= 128,
              let proof = Data(base64Encoded: text) else { return false }
        return Room.constantTimeEqual(room.confirmProof(transcriptHash: transcriptHash), proof)
    }

    /// Connects to the device that showed a room code, pairs through the room, and closes.
    /// The device must hold the key named by the code's fingerprint. Returns the paired peer.
    public static func pairOnly(invite: RoomInvite, identity: DeviceIdentity, local: LocalInfo,
                                trust: TrustProvider, delegate: CrossDropDelegate?) async throws -> PeerInfo {
        guard trust.supportsTrustExpiry else {
            throw CrossDropError.local(ErrorCode.internalError, "room pairing needs a trust store that can expire trust")
        }
        var lastError = CrossDropError.local(ErrorCode.unreachable, "no address")
        for host in invite.hosts {
            guard let port = NWEndpoint.Port(rawValue: invite.port) else { break }
            let transport = NWTransport.connect(to: .hostPort(host: NWEndpoint.Host(host), port: port))
            let channel = SecureChannel(transport: transport)
            do {
                try await transport.start(timeout: ProtocolConstants.connectTimeout)
            } catch {
                transport.close()
                lastError = CrossDropError.local(ErrorCode.unreachable, "connect failed")
                continue
            }
            do {
                let handshake = try await Handshake.runClient(channel: channel, identity: identity, local: local, trust: trust)
                guard handshake.peer.fingerprint == invite.fingerprint else {
                    throw CrossDropError.violation(ErrorCode.authFailed, "not the device in the room code")
                }
                try await pair(channel: channel, peer: handshake.peer, sas: handshake.sas,
                               transcriptHash: handshake.transcriptHash, room: invite.room, trust: trust,
                               delegate: delegate, onDecision: nil)
                transport.close()
                return handshake.peer
            } catch let error as CrossDropError {
                await channel.abort(with: error)
                throw error
            }
        }
        throw lastError
    }
}
