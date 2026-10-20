import XCTest
import Network
@testable import CrossDropCore

/// End-to-end tests over 127.0.0.1 using the real Network-framework transport.
final class LoopbackTests: XCTestCase {
    final class TestDelegate: CrossDropDelegate {
        /// nil = never answer.
        var acceptPairing: Bool? = true
        var acceptOffer: Bool? = true
        var onUpdate: ((TransferSnapshot) -> Void)?

        private let lock = NSLock()
        private(set) var codes: [String] = []
        private(set) var finished: [TransferSnapshot] = []
        private(set) var offersFinished: [String] = []

        func crossDropPairingRequested(_ prompt: PairingPrompt, decision: Decision) {
            lock.lock()
            codes.append(prompt.code)
            lock.unlock()
            if let accept = acceptPairing { decision.resolve(accept) }
        }

        func crossDropPairingFinished(id: String, success: Bool) {}

        func crossDropOfferReceived(_ offer: OfferPrompt, decision: Decision) {
            if let accept = acceptOffer { decision.resolve(accept) }
        }

        func crossDropOfferFinished(transferId: String) {
            lock.lock()
            offersFinished.append(transferId)
            lock.unlock()
        }

        func crossDropTransferUpdated(_ snapshot: TransferSnapshot) {
            if snapshot.phase.isFinished {
                lock.lock()
                finished.append(snapshot)
                lock.unlock()
            }
            onUpdate?(snapshot)
        }

        var seenCodes: [String] {
            lock.lock()
            defer { lock.unlock() }
            return codes
        }

        func waitForFinished(count: Int = 1, seconds: Double = 20) async throws -> TransferSnapshot {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                lock.lock()
                let done = finished
                lock.unlock()
                if done.count >= count { return done[count - 1] }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw CrossDropError.local(ErrorCode.timeout, "no finished transfer")
        }
    }

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("crossdrop-loopback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir.appendingPathComponent("in"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workDir.appendingPathComponent("out"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private var inbox: URL { workDir.appendingPathComponent("in") }

    private func makeFile(_ name: String, bytes: Int) throws -> URL {
        var data = Data(count: bytes)
        if bytes > 0 {
            data.withUnsafeMutableBytes { buffer in
                for i in 0..<buffer.count { buffer[i] = UInt8.random(in: 0...255) }
            }
        }
        let url = workDir.appendingPathComponent("out").appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func startServer(_ server: CrossDropServer) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let box = ContinuationBox(continuation)
            server.onStateChange = { state in
                switch state {
                case .ready(let port): box.resume(returning: port)
                case .failed(let message): box.resume(throwing: CrossDropError.local(ErrorCode.internalError, message))
                default: break
                }
            }
            do {
                try server.start(port: nil, advertise: false)
            } catch {
                box.resume(throwing: error)
            }
        }
    }

    private struct Rig {
        let server: CrossDropServer
        let serverIdentity: DeviceIdentity
        let serverTrust: InMemoryTrustStore
        let serverDelegate: TestDelegate
        let clientIdentity: DeviceIdentity
        let clientTrust: InMemoryTrustStore
        let clientDelegate: TestDelegate
        let port: UInt16
    }

    private func makeRig() async throws -> Rig {
        let serverIdentity = DeviceIdentity.generate()
        let serverTrust = InMemoryTrustStore()
        let serverDelegate = TestDelegate()
        let inbox = self.inbox
        let server = CrossDropServer(configuration: .init(identity: serverIdentity,
                                                          local: LocalInfo(name: "Test Mac", appVersion: "test"),
                                                          trust: serverTrust, destination: { inbox }))
        server.delegate = serverDelegate
        let port = try await startServer(server)
        return Rig(server: server, serverIdentity: serverIdentity, serverTrust: serverTrust,
                   serverDelegate: serverDelegate, clientIdentity: .generate(), clientTrust: InMemoryTrustStore(),
                   clientDelegate: TestDelegate(), port: port)
    }

    private func transfer(_ rig: Rig, files: [URL]) -> OutgoingTransfer {
        OutgoingTransfer(endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: rig.port)!),
                         peerName: "server", peerId: nil, peerPlatform: nil,
                         files: files.map { OutgoingFile(url: $0, mime: "application/octet-stream") },
                         identity: rig.clientIdentity, local: LocalInfo(name: "Test Client", appVersion: "test"),
                         trust: rig.clientTrust, delegate: rig.clientDelegate)
    }

    func testPairAndTransferTwoFiles() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop() }
        let empty = try makeFile("empty.txt", bytes: 0)
        let random = try makeFile("random.bin", bytes: 1_048_576 + 12_345)

        let result = await transfer(rig, files: [empty, random]).run()
        XCTAssertEqual(result.phase, .completed, "error: \(String(describing: result.error))")
        let incoming = try await rig.serverDelegate.waitForFinished()
        XCTAssertEqual(incoming.phase, .completed)

        XCTAssertEqual(try Data(contentsOf: inbox.appendingPathComponent("empty.txt")), Data())
        XCTAssertEqual(try Data(contentsOf: inbox.appendingPathComponent("random.bin")), try Data(contentsOf: random))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: inbox.path).filter { $0.hasSuffix(".partial") }
        XCTAssertEqual(leftovers, [])

        // Both sides showed the same code, and both now trust each other.
        XCTAssertEqual(rig.serverDelegate.seenCodes.count, 1)
        XCTAssertEqual(rig.serverDelegate.seenCodes, rig.clientDelegate.seenCodes)
        XCTAssertEqual(rig.serverTrust.trustedIdentityKey(for: rig.clientIdentity.deviceId), rig.clientIdentity.publicKey)
        XCTAssertEqual(rig.clientTrust.trustedIdentityKey(for: rig.serverIdentity.deviceId), rig.serverIdentity.publicKey)

        // Second transfer: already paired (no new code), and the name collides.
        let second = await transfer(rig, files: [random]).run()
        XCTAssertEqual(second.phase, .completed, "error: \(String(describing: second.error))")
        _ = try await rig.serverDelegate.waitForFinished(count: 2)
        XCTAssertEqual(rig.clientDelegate.seenCodes.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("random (1).bin").path))
    }

    func testReceiverDeclinesOffer() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop() }
        rig.serverDelegate.acceptOffer = false
        let file = try makeFile("a.txt", bytes: 10)
        let result = await transfer(rig, files: [file]).run()
        XCTAssertEqual(result.phase, .rejected)
        XCTAssertEqual(result.rejectReason, "declined")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path), [])
    }

    func testReceiverDeclinesPairing() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop() }
        rig.serverDelegate.acceptPairing = false
        let file = try makeFile("a.txt", bytes: 10)
        let result = await transfer(rig, files: [file]).run()
        XCTAssertEqual(result.phase, .failed)
        XCTAssertEqual(result.error?.code, ErrorCode.pairingRejected)
        XCTAssertNil(rig.clientTrust.trustedIdentityKey(for: rig.serverIdentity.deviceId))
        XCTAssertNil(rig.serverTrust.trustedIdentityKey(for: rig.clientIdentity.deviceId))
    }

    func testSenderCancelsWhileWaitingForApproval() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop() }
        rig.serverDelegate.acceptOffer = nil
        let file = try makeFile("a.txt", bytes: 10)
        let outgoing = transfer(rig, files: [file])
        rig.clientDelegate.onUpdate = { snapshot in
            if snapshot.phase == .waitingForAcceptance {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { outgoing.cancel() }
            }
        }
        let result = await outgoing.run()
        XCTAssertEqual(result.phase, .cancelled)
        let incoming = try await rig.serverDelegate.waitForFinished()
        XCTAssertEqual(incoming.phase, .cancelled)
        XCTAssertEqual(rig.serverDelegate.offersFinished.count, 1)
    }

    func testChangedIdentityIsRefused() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop() }
        // The client believes a different key belongs to the server's deviceId.
        let impostorKey = DeviceIdentity.generate().publicKey
        rig.clientTrust.storeTrust(for: PeerInfo(deviceId: rig.serverIdentity.deviceId, name: "old", platform: "macos",
                                                 appVersion: nil, identityKey: impostorKey))
        let file = try makeFile("a.txt", bytes: 10)
        let result = await transfer(rig, files: [file]).run()
        XCTAssertEqual(result.phase, .failed)
        XCTAssertEqual(result.error?.code, ErrorCode.peerChangedIdentity)
    }
}
