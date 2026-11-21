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
    private let privateMode: () -> Bool
    private let pairingTokens: PairingTokens

    private let lock = NSLock()
    private var publisher: SnapshotPublisher?
    private var pendingDecision: Decision?
    private var userCancelled = false

    init(transport: NWTransport, identity: DeviceIdentity, local: LocalInfo, trust: TrustProvider,
         delegate: CrossDropDelegate?, destination: @escaping () -> URL, isReceiving: @escaping () -> Bool,
         privateMode: @escaping () -> Bool = { false }, pairingTokens: PairingTokens = PairingTokens()) {
        self.channel = SecureChannel(transport: transport)
        self.identity = identity
        self.local = local
        self.trust = trust
        self.delegate = delegate
        self.destination = destination
        self.isReceiving = isReceiving
        self.privateMode = privateMode
        self.pairingTokens = pairingTokens
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
                if untrusted && mine == nil && privateMode() { try await refuseStranger() }
                try await PairingFlow.run(channel: channel, peer: peer, sas: sas, role: .receiver,
                                          autoConfirm: !untrusted, autoMine: mine, trust: trust, delegate: delegate,
                                          onDecision: { [weak self] d in self?.setPending(d) })
                setPending(nil)
                paired = true
            case "transfer.offer":
                if untrusted {
                    if privateMode() { try await refuseStranger() }
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

    /// "My devices only" (§9.5): tells an unpaired device this Mac is not receiving.
    /// Reads briefly before closing so the refusal is not lost to a TCP reset.
    private func refuseStranger() async throws -> Never {
        try? await channel.sendControl(WireMessage.error(ErrorCode.notReceiving, "paired devices only"))
        for _ in 0..<3 {
            guard (try? await channel.receiveRecord(timeout: 1)) != nil else { break }
        }
        throw CrossDropError.local(ErrorCode.notReceiving, "paired devices only")
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
            files: offer.files.map { TransferFileState(name: $0.displayPath, size: $0.size, mime: $0.mime, sha256: $0.sha256) })
        var initial = snapshot
        initial.kind = offer.kind
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
                                     expiresAt: Date().addingTimeInterval(ProtocolConstants.humanTimeout),
                                     kind: offer.kind)
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
        try await channel.sendControl(WireMessage.make("transfer.accept", accept))
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
            if !wasCancelled && received > 0
                && (error.code == ErrorCode.connectionLost || error.code == ErrorCode.timeout) {
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
