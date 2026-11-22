import Foundation
import Network

/// Receiver side of one connection (server role).
final class IncomingSession {
    let id = UUID().uuidString
    private let channel: SecureChannel
    private let identity: DeviceIdentity
    private let local: LocalInfo
    private let trust: TrustProvider
    private weak var delegate: CrossDropDelegate?
    private let destination: () -> URL
    private let isReceiving: () -> Bool
    private let privateMode: () -> Bool
    private let pairingTokens: PairingTokens
    private let rooms: Rooms
    private let captureRequests: CaptureRequests
    private let turboRegistry: TurboRegistry
    private let turboEnabled: () -> Bool
    private let activeConnections: () -> Int

    private let lock = NSLock()
    private var publisher: SnapshotPublisher?
    private var pendingDecision: Decision?
    private var userCancelled = false
    /// The Turbo transfer this session owns (main) or joined (extra connection), §9.10.
    private var turbo: IncomingTurbo?

    init(transport: NWTransport, identity: DeviceIdentity, local: LocalInfo, trust: TrustProvider,
         delegate: CrossDropDelegate?, destination: @escaping () -> URL, isReceiving: @escaping () -> Bool,
         privateMode: @escaping () -> Bool = { false }, pairingTokens: PairingTokens = PairingTokens(),
         rooms: Rooms = Rooms(), captureRequests: CaptureRequests = CaptureRequests(),
         turboRegistry: TurboRegistry = TurboRegistry(), turboEnabled: @escaping () -> Bool = { true },
         activeConnections: @escaping () -> Int = { 1 }) {
        self.channel = SecureChannel(transport: transport)
        self.identity = identity
        self.local = local
        self.trust = trust
        self.delegate = delegate
        self.destination = destination
        self.isReceiving = isReceiving
        self.privateMode = privateMode
        self.pairingTokens = pairingTokens
        self.rooms = rooms
        self.captureRequests = captureRequests
        self.turboRegistry = turboRegistry
        self.turboEnabled = turboEnabled
        self.activeConnections = activeConnections
    }

    var transferId: String? {
        currentPublisher?.current.id
    }

    private var currentPublisher: SnapshotPublisher? {
        lock.lock()
        defer { lock.unlock() }
        return publisher
    }

    private var currentTurbo: IncomingTurbo? {
        lock.lock()
        defer { lock.unlock() }
        return turbo
    }

    private func setTurbo(_ group: IncomingTurbo) {
        lock.lock()
        turbo = group
        lock.unlock()
    }

    /// Local user cancels (or declines) whatever is in progress.
    func cancel() {
        lock.lock()
        userCancelled = true
        let decision = pendingDecision
        let group = turbo
        lock.unlock()
        if let decision = decision {
            // Waiting on this user: answering "no" sends the right reply to the peer.
            decision.resolve(false)
            return
        }
        Task {
            if self.channel.isEncrypted, let id = self.transferId {
                // Tell the sender on the main connection first: ending the Turbo group below can
                // wake this session's loop, which then closes the main connection.
                try? await self.channel.sendControl(WireMessage.make("transfer.cancel", [
                    "transferId": id, "reason": "user",
                ]))
            }
            // A Turbo transfer ends on every connection (§9.10).
            group?.fail(CrossDropError.local(ErrorCode.cancelled), origin: self.channel)
            if self.channel.isEncrypted, self.transferId != nil {
                // The sender may still be streaming. Closing now would make TCP send a reset,
                // which can discard our cancel before the sender reads it (it would then report
                // a lost connection). The session loop keeps reading meanwhile; the sender
                // closes as soon as it sees the cancel, which ends the loop.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            self.channel.transport.close()
        }
    }

    /// Closes the connection without notifying the peer (server shutdown).
    func close() {
        lock.lock()
        userCancelled = true
        let decision = pendingDecision
        lock.unlock()
        decision?.cancel()
        channel.transport.close()
    }

    private var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return userCancelled
    }

    func run() async {
        do {
            try await channel.transport.start(timeout: ProtocolConstants.handshakeTimeout)
            if !isReceiving() {
                try? await channel.sendPlaintext(try WireMessage.encode(WireMessage.error(ErrorCode.notReceiving)))
                channel.transport.close()
                return
            }
            let result = try await Handshake.runServer(channel: channel, identity: identity, local: local, trust: trust)
            try await serve(peer: result.peer, sas: result.sas, transcriptHash: result.transcriptHash)
        } catch let error as CrossDropError {
            let effective = wasCancelled ? CrossDropError.local(ErrorCode.cancelled) : error
            // In a Turbo transfer the first failure on any connection decides for all of them (§9.10).
            var report = effective
            var tellPeer = true
            if let group = currentTurbo {
                group.fail(effective, origin: channel)
                report = group.error ?? effective
                tellPeer = group.isOrigin(channel)
            }
            currentPublisher?.finish(report.isCancellation ? .cancelled : .failed, error: report)
            if !wasCancelled && tellPeer { await channel.abort(with: error) }
        } catch {
            let wrapped = CrossDropError.violation(ErrorCode.internalError)
            var report = wrapped
            var tellPeer = true
            if let group = currentTurbo {
                group.fail(wrapped, origin: channel)
                report = group.error ?? wrapped
                tellPeer = group.isOrigin(channel)
            }
            currentPublisher?.finish(.failed, error: report)
            if tellPeer { await channel.abort(with: wrapped) }
        }
        channel.transport.close()
    }

    private func serve(peer: PeerInfo, sas: String, transcriptHash: Data) async throws {
        var paired = false
        while true {
            let message: WireMessage
            do {
                message = try await channel.receiveControl(timeout: ProtocolConstants.humanTimeout + 15)
            } catch let error as CrossDropError where paired && error.code == ErrorCode.connectionLost {
                // A pairing-only session (QR code, §9.4) simply closes after pairing.
                return
            }
            let untrusted = trust.trustedIdentityKey(for: peer.deviceId) != peer.identityKey
            switch message.type {
            case "pair.request":
                let mine = message.string("token").flatMap { $0.utf8.count <= 64 ? pairingTokens.redeem($0) : nil }
                let room = try verifyRoom(message, transcriptHash: transcriptHash)
                if untrusted && mine == nil && room == nil && privateMode() { try await refuseStranger() }
                // Precedence (same as the Kotlin core): QR token, then permanent trust we already
                // hold, then a valid room proof, then temporary trust we already hold (§9.9).
                let knownExpiry = untrusted ? nil : trust.trustExpiry(for: peer.deviceId)
                var autoConfirm = !untrusted
                var autoMine = mine
                var autoExpiresAt: Date? = nil
                if mine == nil {
                    if !untrusted && knownExpiry == nil {
                        // Permanent trust: keep it as it is.
                    } else if let room = room {
                        autoConfirm = false
                        autoMine = false
                        autoExpiresAt = max(room.expiryDate, knownExpiry ?? room.expiryDate)
                    } else if let knownExpiry = knownExpiry {
                        autoExpiresAt = knownExpiry
                    }
                }
                var extra: [String: Any] = [:]
                if let room = room {
                    extra["room"] = ["id": room.id,
                                     "proof": room.confirmProof(transcriptHash: transcriptHash).base64EncodedString()]
                }
                try await PairingFlow.run(channel: channel, peer: peer, sas: sas, role: .receiver,
                                          autoConfirm: autoConfirm, autoMine: autoMine, autoExpiresAt: autoExpiresAt,
                                          confirmExtra: extra, trust: trust, delegate: delegate,
                                          onDecision: { [weak self] d in self?.setPending(d) })
                setPending(nil)
                paired = true
            case "capture.request":
                if untrusted {
                    if privateMode() { try await refuseStranger() }
                    // No pairing in this flow (§9.7): the requester must already be paired.
                    try await refuse(ErrorCode.pairingRequired, "capture from unpaired device")
                }
                try await handleCapture(message, peer: peer)
                return
            case "transfer.offer":
                if untrusted {
                    if privateMode() { try await refuseStranger() }
                    try await channel.sendControl(WireMessage.error(ErrorCode.pairingRequired))
                    continue
                }
                try await handleOffer(message, peer: peer)
                return
            case "transfer.join":
                if untrusted {
                    if privateMode() { try await refuseStranger() }
                    // No pairing on an extra connection (§9.10).
                    try await refuse(ErrorCode.pairingRequired, "join from unpaired device")
                }
                try await handleJoin(message, peer: peer)
                return
            case "error":
                throw message.peerError()
            case "transfer.cancel":
                throw CrossDropError.peer(ErrorCode.cancelled)
            default:
                throw CrossDropError.violation(ErrorCode.unexpectedMessage)
            }
        }
    }

    /// "My devices only" (§9.5): tells an unpaired device this Mac is not receiving.
    /// Reads briefly before closing so the refusal is not lost to a TCP reset.
    private func refuseStranger() async throws -> Never {
        try await refuse(ErrorCode.notReceiving, "paired devices only")
    }

    /// Sends `error{code}`, reads briefly so it is not lost to a TCP reset, then ends the session.
    private func refuse(_ code: String, _ reason: String) async throws -> Never {
        try? await channel.sendControl(WireMessage.error(code, reason))
        for _ in 0..<3 {
            guard (try? await channel.receiveRecord(timeout: 1)) != nil else { break }
        }
        throw CrossDropError.local(code, reason)
    }

    /// The room a `pair.request` proves membership of (§9.9), or nil. A malformed `room`
    /// field is `bad_message`; an unknown room or a wrong proof just means no room, so
    /// pairing falls back to comparing codes. Only providers that can expire trust take part.
    private func verifyRoom(_ message: WireMessage, transcriptHash: Data) throws -> Room? {
        guard let raw = message.fields["room"], !(raw is NSNull) else { return nil }
        let bad = CrossDropError.violation(ErrorCode.badMessage, "invalid room")
        guard let entry = raw as? [String: Any],
              let id = entry["id"] as? String, Rooms.isValidId(id),
              let proofText = entry["proof"] as? String, proofText.utf8.count <= 128,
              let proof = Data(base64Encoded: proofText), proof.count == 32 else { throw bad }
        guard trust.supportsTrustExpiry else { return nil }
        return rooms.verify(id: id, proof: proof, transcriptHash: transcriptHash)
    }

    /// §9.7: validate, ask the app, answer `capture.ack`, done.
    private func handleCapture(_ message: WireMessage, peer: PeerInfo) async throws {
        let bad = { (why: String) in CrossDropError.violation(ErrorCode.badMessage, why) }
        let requestId = try message.requireString("requestId", maxBytes: 64)
        guard TransferOffer.isValidTransferId(requestId) else { throw bad("invalid requestId") }
        guard let kindText = message.string("kind"), let kind = CaptureKind(rawValue: kindText) else {
            throw bad("unknown capture kind")
        }
        var replyPort: UInt16? = nil
        if let rawPort = message.fields["port"], !(rawPort is NSNull) {
            guard let value = JSONValue.int(rawPort), (1...65535).contains(value) else { throw bad("invalid port") }
            replyPort = UInt16(value)
        }
        guard let host = Self.remoteHost(of: channel.transport) else {
            throw CrossDropError.violation(ErrorCode.internalError, "no peer address")
        }
        let request = CaptureRequest(requestId: requestId, kind: kind, peer: peer, replyHost: host, replyPort: replyPort)
        let accepted = delegate?.crossDropCaptureRequested(request) ?? false
        try await channel.sendControl(WireMessage.make("capture.ack", ["requestId": requestId, "accepted": accepted]))
        // Give the requester a moment to read the answer and close first.
        _ = try? await channel.transport.receive(exactly: 1, timeout: 2)
    }

    /// The numeric address this connection came from (IPv4 when it is an IPv4-mapped address).
    static func remoteHost(of transport: NWTransport) -> String? {
        let endpoint = transport.connection.currentPath?.remoteEndpoint ?? transport.connection.endpoint
        guard case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address):
            // An interface suffix ("%en0") means nothing for IPv4.
            return "\(address)".split(separator: "%").first.map { String($0) }
        case .ipv6(let address):
            let text = "\(address)"
            if text.lowercased().hasPrefix("::ffff:"), text.contains(".") { return String(text.dropFirst(7)) }
            return text
        case .name(let name, _):
            return name
        @unknown default:
            return nil
        }
    }

    private func setPending(_ decision: Decision?) {
        lock.lock()
        pendingDecision = decision
        lock.unlock()
    }

    /// An extra connection of a Turbo transfer (§9.10): check the token, then take files.
    private func handleJoin(_ message: WireMessage, peer: PeerInfo) async throws {
        let transferId = try message.requireString("transferId", maxBytes: 64)
        guard TransferOffer.isValidTransferId(transferId) else {
            throw CrossDropError.violation(ErrorCode.badMessage, "invalid transferId")
        }
        let token = try message.requireString("token", maxBytes: 64)
        guard let group = turboRegistry.find(transferId) else {
            throw CrossDropError.violation(ErrorCode.unexpectedMessage, "no such transfer")
        }
        if let code = group.join(channel, deviceId: peer.deviceId, token: token) {
            throw CrossDropError.violation(code, "join refused")
        }
        setTurbo(group)
        try await channel.sendControl(WireMessage.make("transfer.joined", ["transferId": transferId]))
        try await receiveTurboFiles(group, first: nil)
    }

    /// Turbo (§9.10): files arrive on any of the transfer's connections, in any order. Runs
    /// until the transfer has ended; a failure here ends the whole transfer.
    private func receiveTurboFiles(_ group: IncomingTurbo, first: Task<WireMessage, Error>?) async throws {
        var pending = first
        do {
            while !group.isFinished {
                let record: SecureChannel.Record
                if let task = pending {
                    pending = nil
                    let message = try await task.value
                    record = .control(message)
                } else {
                    record = try await channel.receiveRecord(timeout: ProtocolConstants.streamTimeout)
                }
                switch record {
                case .data:
                    throw CrossDropError.violation(ErrorCode.badMessage, "data outside a file")
                case .control(let message):
                    switch message.type {
                    case "transfer.start":
                        try await receiveTurboFile(message, group: group)
                    case "transfer.cancel":
                        throw CrossDropError.peer(ErrorCode.cancelled)
                    case "error":
                        throw message.peerError()
                    default:
                        throw CrossDropError.violation(ErrorCode.unexpectedMessage)
                    }
                }
            }
        } catch {
            // Closed because the transfer ended (finished, or failed on another connection).
            if group.isFinished { return }
            let failure = (error as? CrossDropError) ?? CrossDropError.violation(ErrorCode.internalError)
            group.fail(failure, origin: channel)
            throw failure
        }
    }

    private func receiveTurboFile(_ start: WireMessage, group: IncomingTurbo) async throws {
        guard try start.requireString("transferId", maxBytes: 64) == group.transferId else {
            throw CrossDropError.violation(ErrorCode.badMessage, "wrong transfer")
        }
        let index = try group.claim(try start.requireInt("fileId"))
        let file = group.offer.files[index]
        let offset = start.int("offset") ?? 0
        guard offset == 0 || offset == group.resumeAt[file.fileId] else {
            throw CrossDropError.violation(ErrorCode.badMessage, "bad offset")
        }
        let saved = try await receiveFile(file, index: index, transferId: group.transferId,
                                          directory: group.directory, publisher: group.publisher,
                                          key: Self.resumeKey(peer: group.peer, file: file), offset: offset)
        group.publisher.update(force: true) { $0.files[index].savedURL = saved }
        group.fileDone()
    }

    /// True when `task` ends within `seconds` (it keeps running otherwise).
    static func finishes(_ task: Task<Void, Error>, within seconds: TimeInterval) async -> Bool {
        let done = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            let box = ContinuationBox(continuation)
            Task {
                _ = try? await task.value
                box.resume(returning: true)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                box.resume(returning: false)
            }
        }
        return done ?? false
    }

    private func handleOffer(_ message: WireMessage, peer: PeerInfo) async throws {
        let offer = try TransferOffer.parse(message)
        // Only an answer to a capture request we sent to this very device counts (§9.7). It is
        // used up only once the offer gets past the local checks below, so a retry still counts.
        let requestCandidate = offer.requestId.flatMap { captureRequests.isOutstanding($0, deviceId: peer.deviceId) ? $0 : nil }
        let directory = destination()
        let snapshot = TransferSnapshot(
            id: offer.transferId, direction: .incoming, peerId: peer.deviceId, peerName: peer.name,
            peerPlatform: peer.platform, phase: .awaitingApproval,
            files: offer.files.map { TransferFileState(name: $0.displayPath, size: $0.size, mime: $0.mime, sha256: $0.sha256) })
        var initial = snapshot
        initial.kind = offer.kind
        initial.requestId = requestCandidate
        initial.expiresAfter = offer.expiresAfter
        let publisher = SnapshotPublisher(initial, delegate: delegate)
        lock.lock()
        self.publisher = publisher
        lock.unlock()

        func reject(_ reason: String) async {
            try? await channel.sendControl(WireMessage.make("transfer.reject", [
                "transferId": offer.transferId, "reason": reason,
            ]))
            publisher.finish(.rejected, rejectReason: reason)
        }

        if !isReceiving() {
            await reject("not_receiving")
            return
        }
        var resumeAt: [Int64: Int64] = [:]
        if offer.kind == .files {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw CrossDropError.violation(ErrorCode.storageError, "destination unavailable")
            }
            ResumeStore.removeStale(in: directory)
            for file in offer.files {
                let have = ResumeStore.keptBytes(in: directory, key: Self.resumeKey(peer: peer, file: file))
                if have > 0 && have < file.size { resumeAt[file.fileId] = have }
            }
            let needed = offer.totalBytes - resumeAt.values.reduce(0, +)
            if let free = FileNaming.availableCapacity(at: directory),
               free < needed + ProtocolConstants.freeSpaceMargin {
                await reject("insufficient_storage")
                return
            }
        }
        let requestId = requestCandidate.flatMap { captureRequests.redeem($0, deviceId: peer.deviceId) ? $0 : nil }
        // Another connection may have used it up in the meantime: then it is a normal offer.
        publisher.update(force: true) { $0.requestId = requestId }

        var nextMessage: Task<WireMessage, Error>? = nil
        let outcome: Decision.Outcome
        if requestId != nil || trust.isAutoAccept(deviceId: peer.deviceId) {
            outcome = .accepted
        } else {
            let decision = Decision(id: offer.transferId)
            setPending(decision)
            nextMessage = Task<WireMessage, Error> {
                do {
                    let message = try await self.channel.receiveControl(timeout: ProtocolConstants.humanTimeout + 15)
                    decision.cancel()
                    return message
                } catch {
                    decision.cancel()
                    throw error
                }
            }
            let prompt = OfferPrompt(transferId: offer.transferId, peer: peer, files: offer.files,
                                     totalBytes: offer.totalBytes,
                                     expiresAt: Date().addingTimeInterval(ProtocolConstants.humanTimeout),
                                     kind: offer.kind, expiresAfter: offer.expiresAfter)
            delegate?.crossDropOfferReceived(prompt, decision: decision)
            outcome = await decision.wait(timeout: ProtocolConstants.humanTimeout)
            setPending(nil)
            delegate?.crossDropOfferFinished(transferId: offer.transferId)
        }

        switch outcome {
        case .declined:
            await reject("declined")
            return
        case .timedOut:
            await reject("timeout")
            return
        case .cancelled:
            if wasCancelled {
                await reject("declined")
                return
            }
            let message = try await nextMessage!.value
            switch message.type {
            case "transfer.cancel": throw CrossDropError.peer(ErrorCode.cancelled)
            case "error": throw message.peerError()
            default: throw CrossDropError.violation(ErrorCode.unexpectedMessage)
            }
        case .accepted:
            break
        }

        var accept: [String: Any] = ["transferId": offer.transferId]
        if !resumeAt.isEmpty {
            accept["resume"] = resumeAt.keys.sorted().map { ["fileId": $0, "offset": resumeAt[$0]!] as [String: Any] }
        }
        // Turbo (§9.10): offer extra connections, within the inbound connection limit.
        var group: IncomingTurbo? = nil
        if let parallel = offer.parallel, offer.kind == .files, offer.files.count >= 2, turboEnabled() {
            let capacity = ProtocolConstants.maxInboundConnections - activeConnections() + 1
            let allowed = min(parallel, ProtocolConstants.maxTurboStreams, offer.files.count, capacity)
            if allowed >= 2 {
                let candidate = IncomingTurbo(transferId: offer.transferId, peer: peer, token: Turbo.newToken(),
                                              maxStreams: allowed, offer: offer, resumeAt: resumeAt,
                                              directory: directory, publisher: publisher, main: channel,
                                              registry: turboRegistry)
                if turboRegistry.register(candidate) {
                    group = candidate
                    setTurbo(candidate)
                    accept["join"] = ["token": candidate.token, "max": allowed] as [String: Any]
                }
            }
        }
        try await channel.sendControl(WireMessage.make("transfer.accept", accept))
        publisher.update(force: true) { $0.phase = .transferring }

        if let group = group {
            let firstMessage = nextMessage
            let reader = Task<Void, Error> { try await self.receiveTurboFiles(group, first: firstMessage) }
            try await group.wait()
            try await channel.sendControl(WireMessage.make("transfer.complete", ["transferId": offer.transferId]))
            group.complete()
            trust.touch(peer: peer)
            let streams = group.streams
            publisher.update(force: true) { $0.streams = streams }
            publisher.finish(.completed)
            // Give the sender a moment to close first; the reader ends on EOF.
            _ = await Self.finishes(reader, within: 5)
            return
        }

        for (index, file) in offer.files.enumerated() {
            let start: WireMessage
            if index == 0, let pending = nextMessage {
                start = try await pending.value
            } else {
                start = try await channel.receiveControl(timeout: ProtocolConstants.streamTimeout)
            }
            switch start.type {
            case "transfer.start":
                guard try start.requireString("transferId") == offer.transferId,
                      try start.requireInt("fileId") == file.fileId else {
                    throw CrossDropError.violation(ErrorCode.unexpectedMessage, "file order")
                }
            case "transfer.cancel":
                throw CrossDropError.peer(ErrorCode.cancelled)
            case "error":
                throw start.peerError()
            default:
                throw CrossDropError.violation(ErrorCode.unexpectedMessage)
            }
            let offset = start.int("offset") ?? 0
            guard offset == 0 || offset == resumeAt[file.fileId] else {
                throw CrossDropError.violation(ErrorCode.badMessage, "bad offset")
            }
            if offer.kind != .files {
                let text = try await receiveText(file, transferId: offer.transferId)
                publisher.update(force: true) { s in
                    s.files[index].bytes = file.size
                    s.text = text
                }
                continue
            }
            let saved = try await receiveFile(file, index: index, transferId: offer.transferId,
                                              directory: directory, publisher: publisher,
                                              key: Self.resumeKey(peer: peer, file: file), offset: offset)
            publisher.update(force: true) { $0.files[index].savedURL = saved }
        }

        try await channel.sendControl(WireMessage.make("transfer.complete", ["transferId": offer.transferId]))
        trust.touch(peer: peer)
        publisher.finish(.completed)
        // Give the sender a moment to close first; ends on EOF or after 5 s.
        _ = try? await channel.transport.receive(exactly: 1, timeout: 5)
    }

    /// A link or text payload (§9.2): small, held in memory, verified, never written to disk.
    private func receiveText(_ file: OfferedFile, transferId: String) async throws -> String {
        var buffer = Data()
        while Int64(buffer.count) < file.size {
            switch try await channel.receiveRecord(timeout: ProtocolConstants.streamTimeout) {
            case .data(let body):
                guard Int64(buffer.count + body.count) <= file.size else {
                    throw CrossDropError.violation(ErrorCode.badMessage, "more bytes than offered")
                }
                buffer.append(body)
            case .control(let message):
                switch message.type {
                case "transfer.cancel": throw CrossDropError.peer(ErrorCode.cancelled)
                case "error": throw message.peerError()
                default: throw CrossDropError.violation(ErrorCode.unexpectedMessage)
                }
            }
        }
        guard Hex.encode(CDCrypto.sha256(buffer)) == file.sha256 else {
            throw CrossDropError.violation(ErrorCode.integrityFailed)
        }
        guard let text = String(data: buffer, encoding: .utf8) else {
            throw CrossDropError.violation(ErrorCode.badMessage, "text is not UTF-8")
        }
        try await sendProgress(transferId: transferId, fileId: file.fileId, bytes: file.size)
        return text
    }

    /// Names a half-received file by sender and content, so a later offer of the same
    /// file from the same device can resume it (§9.3).
    static func resumeKey(peer: PeerInfo, file: OfferedFile) -> String {
        Hex.encode(CDCrypto.sha256(Data("CrossDrop/1 resume|\(peer.deviceId)|\(file.sha256)|\(file.size)".utf8)))
    }

    private func receiveFile(_ file: OfferedFile, index: Int, transferId: String, directory: URL,
                             publisher: SnapshotPublisher, key: String, offset: Int64) async throws -> URL {
        let fm = FileManager.default
        let group = currentTurbo
        let temporary = directory.appendingPathComponent(".crossdrop-\(UUID().uuidString).partial", isDirectory: false)
        let kept = ResumeStore.url(in: directory, key: key)
        var hash = StreamingHash()
        var received: Int64 = 0
        if offset > 0 {
            // Claim the kept part (a rename, so a parallel transfer cannot share it), then re-hash it.
            guard ResumeStore.keptBytes(in: directory, key: key) == offset,
                  (try? fm.moveItem(at: kept, to: temporary)) != nil else {
                throw CrossDropError.violation(ErrorCode.storageError, "kept part is gone")
            }
            do {
                let reader = try FileHandle(forReadingFrom: temporary)
                defer { try? reader.close() }
                while received < offset {
                    let want = Int(min(Int64(1 << 20), offset - received))
                    let chunk = try autoreleasepool { try reader.read(upToCount: want) } ?? Data()
                    if chunk.isEmpty { break }
                    hash.update(chunk)
                    received += Int64(chunk.count)
                }
            } catch {
                try? fm.removeItem(at: temporary)
                throw CrossDropError.violation(ErrorCode.storageError, "cannot read kept part")
            }
            guard received == offset else {
                try? fm.removeItem(at: temporary)
                throw CrossDropError.violation(ErrorCode.storageError, "kept part is shorter")
            }
        } else {
            try? fm.removeItem(at: kept)
            guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CrossDropError.violation(ErrorCode.storageError, "cannot create file")
            }
        }
        var handle: FileHandle?
        var finished = false
        var keepForResume = false
        defer {
            try? handle?.close()
            if !finished {
                if keepForResume {
                    try? fm.removeItem(at: kept)
                    if (try? fm.moveItem(at: temporary, to: kept)) == nil { try? fm.removeItem(at: temporary) }
                } else {
                    try? fm.removeItem(at: temporary)
                }
            }
        }
        do {
            handle = try FileHandle(forWritingTo: temporary)
            if offset > 0 { try handle?.seekToEnd() }
        } catch {
            throw CrossDropError.violation(ErrorCode.storageError, "cannot open file")
        }
        if offset > 0 {
            let bytes = offset
            publisher.update { $0.files[index].bytes = bytes }
        }

        var lastProgress = monotonicNow()
        do {
            while received < file.size {
                switch try await channel.receiveRecord(timeout: ProtocolConstants.streamTimeout) {
                case .data(let body):
                    guard received + Int64(body.count) <= file.size else {
                        throw CrossDropError.violation(ErrorCode.badMessage, "more bytes than offered")
                    }
                    do {
                        try handle?.write(contentsOf: body)
                    } catch {
                        let full = (FileNaming.availableCapacity(at: directory) ?? Int64.max) < Int64(body.count)
                        throw CrossDropError.violation(full ? ErrorCode.insufficientStorage : ErrorCode.storageError)
                    }
                    hash.update(body)
                    received += Int64(body.count)
                    group?.keepAlive()
                    let bytes = received
                    publisher.update { $0.files[index].bytes = bytes }
                    let now = monotonicNow()
                    if now - lastProgress >= ProtocolConstants.progressInterval {
                        lastProgress = now
                        try await sendProgress(transferId: transferId, fileId: file.fileId, bytes: received)
                    }
                case .control(let message):
                    switch message.type {
                    case "transfer.cancel": throw CrossDropError.peer(ErrorCode.cancelled)
                    case "error": throw message.peerError()
                    default: throw CrossDropError.violation(ErrorCode.unexpectedMessage)
                    }
                }
            }
        } catch let error as CrossDropError {
            // A dropped connection keeps what arrived for a resume (§9.3); anything else discards it.
            // In a Turbo transfer the transfer's own failure decides (this connection may just
            // have been closed because of it, §9.10).
            let decisive = group?.error ?? error
            if !wasCancelled && received > 0
                && (decisive.code == ErrorCode.connectionLost || decisive.code == ErrorCode.timeout) {
                keepForResume = true
            }
            throw error
        }
        try? handle?.close()
        handle = nil

        guard hash.finalizeHex() == file.sha256 else {
            throw CrossDropError.violation(ErrorCode.integrityFailed)
        }
        let folder = try FileNaming.subfolder(file.path, in: directory)
        let saved = try FileNaming.moveToUniqueDestination(temporary, directory: folder,
                                                           name: FileNaming.sanitize(file.name))
        finished = true
        try await sendProgress(transferId: transferId, fileId: file.fileId, bytes: file.size)
        return saved
    }

    private func sendProgress(transferId: String, fileId: Int64, bytes: Int64) async throws {
        try await channel.sendControl(WireMessage.make("transfer.progress", [
            "transferId": transferId, "fileId": fileId, "bytes": bytes,
        ]))
    }
}

/// Interrupted files kept in the destination for resuming (§9.3), named by resume key.
enum ResumeStore {
    static let prefix = ".crossdrop-resume-"

    static func url(in directory: URL, key: String) -> URL {
        directory.appendingPathComponent("\(prefix)\(key).partial", isDirectory: false)
    }

    /// Size of the kept part, or 0 when there is none (or it is not a plain file, or too old).
    static func keptBytes(in directory: URL, key: String) -> Int64 {
        // attributesOfItem does not follow symlinks, so a planted link reads as a link.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url(in: directory, key: key).path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value else { return 0 }
        if let modified = attributes[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) > ProtocolConstants.resumeKeep { return 0 }
        return size
    }

    /// Deletes kept parts older than the resume window.
    static func removeStale(in directory: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".partial") {
            let path = directory.appendingPathComponent(name).path
            guard let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  Date().timeIntervalSince(modified) > ProtocolConstants.resumeKeep else { continue }
            try? fm.removeItem(atPath: path)
        }
    }
}
