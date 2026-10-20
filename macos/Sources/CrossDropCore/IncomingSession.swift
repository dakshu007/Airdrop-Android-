import Foundation

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

    private let lock = NSLock()
    private var publisher: SnapshotPublisher?
    private var pendingDecision: Decision?
    private var userCancelled = false

    init(transport: NWTransport, identity: DeviceIdentity, local: LocalInfo, trust: TrustProvider,
         delegate: CrossDropDelegate?, destination: @escaping () -> URL, isReceiving: @escaping () -> Bool) {
        self.channel = SecureChannel(transport: transport)
        self.identity = identity
        self.local = local
        self.trust = trust
        self.delegate = delegate
        self.destination = destination
        self.isReceiving = isReceiving
    }

    var transferId: String? {
        currentPublisher?.current.id
    }

    private var currentPublisher: SnapshotPublisher? {
        lock.lock()
        defer { lock.unlock() }
        return publisher
    }

    /// Local user cancels (or declines) whatever is in progress.
    func cancel() {
        lock.lock()
        userCancelled = true
        let decision = pendingDecision
        lock.unlock()
        if let decision = decision {
            // Waiting on this user: answering "no" sends the right reply to the peer.
            decision.resolve(false)
            return
        }
        Task {
            if self.channel.isEncrypted, let id = self.transferId {
                try? await self.channel.sendControl(WireMessage.make("transfer.cancel", [
                    "transferId": id, "reason": "user",
                ]))
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
            try await serve(peer: result.peer, sas: result.sas)
        } catch let error as CrossDropError {
            let effective = wasCancelled ? CrossDropError.local(ErrorCode.cancelled) : error
            currentPublisher?.finish(effective.isCancellation ? .cancelled : .failed, error: effective)
            if !wasCancelled { await channel.abort(with: error) }
        } catch {
            let wrapped = CrossDropError.violation(ErrorCode.internalError)
            currentPublisher?.finish(.failed, error: wrapped)
            await channel.abort(with: wrapped)
        }
        channel.transport.close()
    }

    private func serve(peer: PeerInfo, sas: String) async throws {
        while true {
            let message = try await channel.receiveControl(timeout: ProtocolConstants.humanTimeout + 15)
            switch message.type {
            case "pair.request":
                let alreadyTrusted = trust.trustedIdentityKey(for: peer.deviceId) == peer.identityKey
                try await PairingFlow.run(channel: channel, peer: peer, sas: sas, role: .receiver,
                                          autoConfirm: alreadyTrusted, trust: trust, delegate: delegate,
                                          onDecision: { [weak self] d in self?.setPending(d) })
                setPending(nil)
            case "transfer.offer":
                guard trust.trustedIdentityKey(for: peer.deviceId) == peer.identityKey else {
                    try await channel.sendControl(WireMessage.error(ErrorCode.pairingRequired))
                    continue
                }
                try await handleOffer(message, peer: peer)
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

    private func setPending(_ decision: Decision?) {
        lock.lock()
        pendingDecision = decision
        lock.unlock()
    }

    private func handleOffer(_ message: WireMessage, peer: PeerInfo) async throws {
        let offer = try TransferOffer.parse(message)
        let directory = destination()
        let snapshot = TransferSnapshot(
            id: offer.transferId, direction: .incoming, peerId: peer.deviceId, peerName: peer.name,
            peerPlatform: peer.platform, phase: .awaitingApproval,
            files: offer.files.map { TransferFileState(name: FileNaming.sanitize($0.name), size: $0.size, mime: $0.mime, sha256: $0.sha256) })
        let publisher = SnapshotPublisher(snapshot, delegate: delegate)
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
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw CrossDropError.violation(ErrorCode.storageError, "destination unavailable")
        }
        if let free = FileNaming.availableCapacity(at: directory),
           free < offer.totalBytes + ProtocolConstants.freeSpaceMargin {
            await reject("insufficient_storage")
            return
        }
        publisher.update(force: true) { _ in }

        var nextMessage: Task<WireMessage, Error>? = nil
        let outcome: Decision.Outcome
        if trust.isAutoAccept(deviceId: peer.deviceId) {
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
                                     expiresAt: Date().addingTimeInterval(ProtocolConstants.humanTimeout))
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

        try await channel.sendControl(WireMessage.make("transfer.accept", ["transferId": offer.transferId]))
        publisher.update(force: true) { $0.phase = .transferring }

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
            let saved = try await receiveFile(file, index: index, transferId: offer.transferId,
                                              directory: directory, publisher: publisher)
            publisher.update(force: true) { $0.files[index].savedURL = saved }
        }

        try await channel.sendControl(WireMessage.make("transfer.complete", ["transferId": offer.transferId]))
        trust.touch(peer: peer)
        publisher.finish(.completed)
        // Give the sender a moment to close first; ends on EOF or after 5 s.
        _ = try? await channel.transport.receive(exactly: 1, timeout: 5)
    }

    private func receiveFile(_ file: OfferedFile, index: Int, transferId: String, directory: URL,
                             publisher: SnapshotPublisher) async throws -> URL {
        let fm = FileManager.default
        let temporary = directory.appendingPathComponent(".crossdrop-\(UUID().uuidString).partial", isDirectory: false)
        guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CrossDropError.violation(ErrorCode.storageError, "cannot create file")
        }
        var handle: FileHandle?
        var finished = false
        defer {
            try? handle?.close()
            if !finished { try? fm.removeItem(at: temporary) }
        }
        do {
            handle = try FileHandle(forWritingTo: temporary)
        } catch {
            throw CrossDropError.violation(ErrorCode.storageError, "cannot open file")
        }

        var hash = StreamingHash()
        var received: Int64 = 0
        var lastProgress = monotonicNow()
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
        try? handle?.close()
        handle = nil

        guard hash.finalizeHex() == file.sha256 else {
            throw CrossDropError.violation(ErrorCode.integrityFailed)
        }
        let saved = try FileNaming.moveToUniqueDestination(temporary, directory: directory,
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
