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
    /// Bytes the receiver already holds per file, from `transfer.accept` (§9.3).
    private var resumeAt: [Int64: Int64] = [:]
    /// Test hook: called after each data record with the bytes sent so far for the file.
    public var onChunkSent: ((Int64) -> Void)?

    public init(endpoint: NWEndpoint, peerName: String, peerId: String?, peerPlatform: String?,
                files: [OutgoingFile], identity: DeviceIdentity, local: LocalInfo, trust: TrustProvider,
                delegate: CrossDropDelegate?, id: String = UUID().uuidString,
                kind: OfferKind = .files, qr: QrPairing? = nil) {
        self.id = id
        self.endpoint = endpoint
        self.files = files
        self.kind = kind
        self.qr = qr
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
        lock.unlock()
        decision?.resolve(false)
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
                try await pair(secure, peer: peer, sas: handshake.sas)
                paired = true
            }

            let offer = TransferOffer(transferId: id, files: offerFiles, kind: kind)
            try await waitForAcceptance(secure, offer: offer, peer: peer, sas: handshake.sas, alreadyPaired: paired)
            if publisher.current.phase == .rejected { secure.transport.close(); return publisher.current }

            publisher.update(force: true) { $0.phase = .transferring }
            try await stream(secure, offer: offer)
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

    private func pair(_ channel: SecureChannel, peer: PeerInfo, sas: String) async throws {
        publisher.update(force: true) { $0.phase = .pairing }
        try await QrPairingClient.pair(channel: channel, peer: peer, sas: sas, qr: qr, trust: trust,
                                       delegate: delegate,
                                       onDecision: { [weak self] decision in self?.setPending(decision) })
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
        for (index, file) in offer.files.enumerated() {
            try checkCancelled()
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
                continue
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
                let progress = sent
                publisher.update { $0.files[index].bytes = progress }
                onChunkSent?(progress)
            }
        }
    }
}

/// Pairing driven by a scanned QR code (§9.4): the receiver is only accepted if its
/// identity key matches the code, and the code's one-time token lets the receiver
/// skip its prompt. Without a code it is the usual compare-the-numbers pairing.
public enum QrPairingClient {
    static func pair(channel: SecureChannel, peer: PeerInfo, sas: String, qr: QrPairing?, trust: TrustProvider,
                     delegate: CrossDropDelegate?, onDecision: ((Decision) -> Void)?) async throws {
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
