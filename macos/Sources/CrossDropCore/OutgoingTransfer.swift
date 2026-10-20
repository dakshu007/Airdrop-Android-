import Foundation
import Network

/// A file the user chose to send.
public struct OutgoingFile: Equatable {
    public let url: URL
    public let name: String
    public let mime: String?

    public init(url: URL, name: String? = nil, mime: String? = nil) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.mime = mime
    }
}

/// Sender side of one transfer (client role). Create, then `await run()`.
public final class OutgoingTransfer {
    public let id: String
    public let files: [OutgoingFile]
    public let endpoint: NWEndpoint

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

    public init(endpoint: NWEndpoint, peerName: String, peerId: String?, peerPlatform: String?,
                files: [OutgoingFile], identity: DeviceIdentity, local: LocalInfo, trust: TrustProvider,
                delegate: CrossDropDelegate?, id: String = UUID().uuidString) {
        self.id = id
        self.endpoint = endpoint
        self.files = files
        self.identity = identity
        self.local = local
        self.trust = trust
        self.delegate = delegate
        let states = files.map { TransferFileState(name: $0.name, size: 0, mime: $0.mime, sourceURL: $0.url) }
        self.publisher = SnapshotPublisher(
            TransferSnapshot(id: id, direction: .outgoing, peerId: peerId, peerName: peerName,
                             peerPlatform: peerPlatform, phase: .preparing, files: states),
            delegate: delegate)
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

            let offer = TransferOffer(transferId: id, files: offerFiles)
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
            let (size, digest) = try Self.hashFile(file.url) { [weak self] in self?.isCancelled ?? true }
            result.append(OfferedFile(fileId: Int64(index), name: file.name, size: size, mime: file.mime, sha256: digest))
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
        try await channel.sendControl(WireMessage.make("pair.request"))
        try await PairingFlow.run(channel: channel, peer: peer, sas: sas, role: .sender, autoConfirm: false,
                                  trust: trust, delegate: delegate,
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
            try await channel.sendControl(WireMessage.make("transfer.start", [
                "transferId": offer.transferId, "fileId": file.fileId,
            ]))
            let handle: FileHandle
            do {
                handle = try FileHandle(forReadingFrom: files[index].url)
            } catch {
                throw CrossDropError.local(ErrorCode.fileUnreadable)
            }
            defer { try? handle.close() }
            var sent: Int64 = 0
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
            }
        }
    }
}
