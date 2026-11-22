import XCTest
import Network
@testable import CrossDropCore

/// End-to-end tests over 127.0.0.1 using the real Network-framework transport.
final class LoopbackTests: XCTestCase {
    final class TestDelegate: CrossDropDelegate {
        /// nil = never answer.
        var acceptPairing: Bool? = true
        var acceptOffer: Bool? = true
        var acceptCapture = true
        var onUpdate: ((TransferSnapshot) -> Void)?

        private let lock = NSLock()
        private(set) var codes: [String] = []
        private(set) var finished: [TransferSnapshot] = []
        private(set) var offersFinished: [String] = []
        private var offers: [String] = []
        private var captureLog: [CaptureRequest] = []

        func crossDropPairingRequested(_ prompt: PairingPrompt, decision: Decision) {
            lock.lock()
            codes.append(prompt.code)
            lock.unlock()
            if let accept = acceptPairing { decision.resolve(accept) }
        }

        func crossDropPairingFinished(id: String, success: Bool) {}

        func crossDropOfferReceived(_ offer: OfferPrompt, decision: Decision) {
            lock.lock()
            offers.append(offer.transferId)
            lock.unlock()
            if let accept = acceptOffer { decision.resolve(accept) }
        }

        func crossDropCaptureRequested(_ request: CaptureRequest) -> Bool {
            lock.lock()
            captureLog.append(request)
            lock.unlock()
            return acceptCapture
        }

        /// Offers that reached the user (prompted).
        var offersReceived: [String] {
            lock.lock()
            defer { lock.unlock() }
            return offers
        }

        var captures: [CaptureRequest] {
            lock.lock()
            defer { lock.unlock() }
            return captureLog
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

    private func makeRig(privateMode: Bool = false, turbo: Bool = true) async throws -> Rig {
        let serverIdentity = DeviceIdentity.generate()
        let serverTrust = InMemoryTrustStore()
        let serverDelegate = TestDelegate()
        let inbox = self.inbox
        let server = CrossDropServer(configuration: .init(identity: serverIdentity,
                                                          local: LocalInfo(name: "Test Mac", appVersion: "test"),
                                                          trust: serverTrust, destination: { inbox },
                                                          privateMode: { privateMode }, turbo: { turbo }))
        server.delegate = serverDelegate
        let port = try await startServer(server)
        return Rig(server: server, serverIdentity: serverIdentity, serverTrust: serverTrust,
                   serverDelegate: serverDelegate, clientIdentity: .generate(), clientTrust: InMemoryTrustStore(),
                   clientDelegate: TestDelegate(), port: port)
    }

    private func transfer(_ rig: Rig, files: [URL], path: [String] = []) -> OutgoingTransfer {
        transfer(rig, outgoing: files.map { OutgoingFile(url: $0, mime: "application/octet-stream", path: path) })
    }

    private func transfer(_ rig: Rig, outgoing: [OutgoingFile], kind: OfferKind = .files, qr: QrPairing? = nil,
                          identity: DeviceIdentity? = nil, expiresAfter: Int64? = nil, room: Room? = nil,
                          turbo: Int = 1) -> OutgoingTransfer {
        OutgoingTransfer(endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: rig.port)!),
                         peerName: "server", peerId: nil, peerPlatform: nil,
                         files: outgoing,
                         identity: identity ?? rig.clientIdentity, local: LocalInfo(name: "Test Client", appVersion: "test"),
                         trust: identity == nil ? rig.clientTrust : InMemoryTrustStore(), delegate: rig.clientDelegate,
                         kind: kind, qr: qr, expiresAfter: expiresAfter, room: room, turbo: turbo)
    }

    /// The requester's own receiver (same identity and trust as the rig's client), which
    /// gets the answer to a capture request (§9.7). It declines anything it is asked about.
    private struct Requester {
        let server: CrossDropServer
        let delegate: TestDelegate
        let port: UInt16
    }

    private func makeRequester(_ rig: Rig) async throws -> Requester {
        let folder = workDir.appendingPathComponent("requester")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let delegate = TestDelegate()
        delegate.acceptOffer = false
        let server = CrossDropServer(configuration: .init(identity: rig.clientIdentity,
                                                          local: LocalInfo(name: "Test Requester", appVersion: "test"),
                                                          trust: rig.clientTrust, destination: { folder }))
        server.delegate = delegate
        let port = try await startServer(server)
        return Requester(server: server, delegate: delegate, port: port)
    }

    private func requestCapture(_ rig: Rig, _ requester: Requester, kind: CaptureKind = .photo) async throws -> String {
        try await CaptureClient.request(endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: rig.port)!),
                                        expectedDeviceId: rig.serverIdentity.deviceId,
                                        identity: rig.clientIdentity, local: LocalInfo(name: "Test Client", appVersion: "test"),
                                        trust: rig.clientTrust, kind: kind, replyPort: requester.port,
                                        registry: requester.server.captureRequests)
    }

    /// The phone (rig server identity, or `identity`) sends a small file to the requester, answering `requestId`.
    private func answer(_ rig: Rig, _ requester: Requester, requestId: String?,
                        identity: DeviceIdentity? = nil, trust: InMemoryTrustStore? = nil) async throws -> TransferSnapshot {
        let file = try makeFile("photo-\(UUID().uuidString.prefix(6)).jpg", bytes: 3)
        return await OutgoingTransfer(endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: requester.port)!),
                                      peerName: "requester", peerId: nil, peerPlatform: nil,
                                      files: [OutgoingFile(url: file)],
                                      identity: identity ?? rig.serverIdentity, local: LocalInfo(name: "Phone", platform: "android", appVersion: "test"),
                                      trust: trust ?? rig.serverTrust, delegate: TestDelegate(),
                                      requestId: requestId).run()
    }

    private func pairClientWithServer(_ rig: Rig) async throws {
        let file = try makeFile("warmup.txt", bytes: 1)
        let warmup = await transfer(rig, files: [file]).run()
        XCTAssertEqual(warmup.phase, .completed, "error: \(String(describing: warmup.error))")
        _ = try await rig.serverDelegate.waitForFinished()
    }

    private func clientPeer(_ rig: Rig) -> PeerInfo {
        PeerInfo(deviceId: rig.clientIdentity.deviceId, name: "Test Client", platform: "macos", appVersion: nil,
                 identityKey: rig.clientIdentity.publicKey)
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

    // MARK: v1 extensions (docs/protocol-v1.md §9)

    func testFoldersKeepTheirStructureButNeverEscape() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop() }
        let file = try makeFile("a.txt", bytes: 10)
        let result = await transfer(rig, files: [file], path: ["Trip", "Day 1"]).run()
        XCTAssertEqual(result.phase, .completed, "error: \(String(describing: result.error))")
        _ = try await rig.serverDelegate.waitForFinished()
        XCTAssertEqual(try Data(contentsOf: inbox.appendingPathComponent("Trip/Day 1/a.txt")), try Data(contentsOf: file))

        // A hostile path is flattened into harmless folder names inside the destination.
        XCTAssertEqual(try TransferOffer.parsePath("../../etc/./x\\..\\y"), ["etc", "x", "y"])
        XCTAssertEqual(try TransferOffer.parsePath("/.hidden/ok"), ["hidden", "ok"])
        XCTAssertThrowsError(try TransferOffer.parsePath(Array(repeating: "a", count: 17).joined(separator: "/")))
    }

    func testLinkArrivesAsTextAndIsNotSaved() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop() }
        let link = "https://example.com/a?b=c"
        let result = await transfer(rig, outgoing: [.text(link, name: "Link")], kind: .link).run()
        XCTAssertEqual(result.phase, .completed, "error: \(String(describing: result.error))")
        let incoming = try await rig.serverDelegate.waitForFinished()
        XCTAssertEqual(incoming.kind, .link)
        XCTAssertEqual(incoming.text, link)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path), [])
    }

    func testTooLargeTextOfferIsRefused() throws {
        let big = WireMessage(type: "transfer.offer", version: 1, fields: [
            "transferId": "abcdefgh-1234",
            "kind": "text",
            "files": [["fileId": 0, "name": "t", "size": 65_537, "sha256": String(repeating: "a", count: 64)]],
        ])
        XCTAssertThrowsError(try TransferOffer.parse(big))
        let unknown = WireMessage(type: "transfer.offer", version: 1, fields: [
            "transferId": "abcdefgh-1234",
            "kind": "hologram",
            "files": [["fileId": 0, "name": "t", "size": 1, "sha256": String(repeating: "a", count: 64)]],
        ])
        XCTAssertThrowsError(try TransferOffer.parse(unknown))
    }

    func testQrTokenPairsWithoutPromptsAndRemembersMine() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop() }
        let token = rig.server.pairingTokens.issue(mine: true)
        let qr = QrPairing(token: token, fingerprint: rig.serverIdentity.fingerprint, mine: true)
        let file = try makeFile("a.txt", bytes: 10)
        let outgoing = transfer(rig, outgoing: [OutgoingFile(url: file)], qr: qr)
        let result = await outgoing.run()
        XCTAssertEqual(result.phase, .completed, "error: \(String(describing: result.error))")
        XCTAssertEqual(rig.serverDelegate.seenCodes, [])
        XCTAssertEqual(rig.clientDelegate.seenCodes, [])
        XCTAssertTrue(rig.serverTrust.isAutoAccept(deviceId: rig.clientIdentity.deviceId))
        XCTAssertTrue(rig.clientTrust.isAutoAccept(deviceId: rig.serverIdentity.deviceId))
        // The token is single-use.
        XCTAssertNil(rig.server.pairingTokens.redeem(token))
    }

    func testQrCodeForAnotherDeviceIsRefused() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop() }
        let token = rig.server.pairingTokens.issue(mine: false)
        let qr = QrPairing(token: token, fingerprint: DeviceIdentity.generate().fingerprint, mine: false)
        let file = try makeFile("a.txt", bytes: 10)
        let result = await transfer(rig, outgoing: [OutgoingFile(url: file)], qr: qr).run()
        XCTAssertEqual(result.phase, .failed)
        XCTAssertEqual(result.error?.code, ErrorCode.authFailed)
        XCTAssertNil(rig.serverTrust.trustedIdentityKey(for: rig.clientIdentity.deviceId))
    }

    func testPrivateModeOnlyAcceptsPairedDevicesOrQrTokens() async throws {
        let rig = try await makeRig(privateMode: true)
        defer { rig.server.stop() }
        let file = try makeFile("a.txt", bytes: 10)

        let stranger = await transfer(rig, outgoing: [OutgoingFile(url: file)], identity: DeviceIdentity.generate()).run()
        XCTAssertEqual(stranger.phase, .failed)
        XCTAssertEqual(stranger.error?.code, ErrorCode.notReceiving)

        let qr = QrPairing(token: rig.server.pairingTokens.issue(mine: false),
                           fingerprint: rig.serverIdentity.fingerprint, mine: false)
        let paired = await transfer(rig, outgoing: [OutgoingFile(url: file)], qr: qr).run()
        XCTAssertEqual(paired.phase, .completed, "error: \(String(describing: paired.error))")

        // Now paired: no token needed.
        let again = await transfer(rig, outgoing: [OutgoingFile(url: file)]).run()
        XCTAssertEqual(again.phase, .completed, "error: \(String(describing: again.error))")
    }

    func testPairOnlyClosesQuietly() async throws {
        let rig = try await makeRig(privateMode: true)
        defer { rig.server.stop() }
        let qr = QrPairing(token: rig.server.pairingTokens.issue(mine: true),
                           fingerprint: rig.serverIdentity.fingerprint, mine: true)
        let peer = try await QrPairingClient.pairOnly(
            endpoints: [.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: rig.port)!)],
            qr: qr, identity: rig.clientIdentity, local: LocalInfo(name: "Test Client", appVersion: "test"),
            trust: rig.clientTrust, delegate: rig.clientDelegate)
        XCTAssertEqual(peer.deviceId, rig.serverIdentity.deviceId)
        XCTAssertNotNil(rig.clientTrust.trustedIdentityKey(for: rig.serverIdentity.deviceId))
        // The server stores trust when it reads our confirmation, just after we return.
        for _ in 0..<150 where rig.serverTrust.trustedIdentityKey(for: rig.clientIdentity.deviceId) == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(rig.serverTrust.trustedIdentityKey(for: rig.clientIdentity.deviceId))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(rig.serverDelegate.finished.count, 0)
    }

    // MARK: §9.7 capture requests

    func testCaptureRequestIsAcceptedAndItsAnswerArrivesWithoutPromptOnce() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop() }
        try await pairClientWithServer(rig)
        let requester = try await makeRequester(rig)
        defer { requester.server.stop() }

        let id = try await requestCapture(rig, requester)
        let seen = rig.serverDelegate.captures
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.requestId, id)
        XCTAssertEqual(seen.first?.kind, .photo)
        XCTAssertEqual(seen.first?.peer.deviceId, rig.clientIdentity.deviceId)
        XCTAssertEqual(seen.first?.replyHost, "127.0.0.1")
        XCTAssertEqual(seen.first?.replyPort, requester.port)
        XCTAssertEqual(requester.server.captureRequests.outstanding, 1)

        // The phone answers: accepted without a prompt (the requester would decline one).
        let answered = try await answer(rig, requester, requestId: id)
        XCTAssertEqual(answered.phase, .completed, "error: \(String(describing: answered.error))")
        let incoming = try await requester.delegate.waitForFinished()
        XCTAssertEqual(incoming.phase, .completed)
        XCTAssertEqual(incoming.requestId, id)
        XCTAssertEqual(requester.delegate.offersReceived.count, 0)

        // Single use: the same requestId again is a normal offer, which is prompted (and declined).
        let again = try await answer(rig, requester, requestId: id)
        XCTAssertEqual(again.phase, .rejected)
        XCTAssertEqual(again.rejectReason, "declined")
        XCTAssertEqual(requester.delegate.offersReceived.count, 1)
    }

    func testCaptureAnswerOnlyCountsFromTheDeviceItWasSentTo() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop() }
        try await pairClientWithServer(rig)
        let requester = try await makeRequester(rig)
        defer { requester.server.stop() }

        // Another device the requester has also paired with.
        let other = DeviceIdentity.generate()
        let otherTrust = InMemoryTrustStore()
        requester.delegate.acceptOffer = true
        let warm = try await answer(rig, requester, requestId: nil, identity: other, trust: otherTrust)
        XCTAssertEqual(warm.phase, .completed, "error: \(String(describing: warm.error))")
        requester.delegate.acceptOffer = false
        let promptsBefore = requester.delegate.offersReceived.count

        let id = try await requestCapture(rig, requester)
        let foreign = try await answer(rig, requester, requestId: id, identity: other, trust: otherTrust)
        XCTAssertEqual(foreign.phase, .rejected, "a foreign requestId is ignored, so the offer is prompted")
        XCTAssertEqual(requester.delegate.offersReceived.count, promptsBefore + 1)
        // The real device still gets its answer through.
        let real = try await answer(rig, requester, requestId: id)
        XCTAssertEqual(real.phase, .completed, "error: \(String(describing: real.error))")
        XCTAssertEqual(requester.delegate.offersReceived.count, promptsBefore + 1)
    }

    func testDeclinedCaptureRequestIsForgotten() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop() }
        try await pairClientWithServer(rig)
        rig.serverDelegate.acceptCapture = false
        let requester = try await makeRequester(rig)
        defer { requester.server.stop() }
        do {
            _ = try await requestCapture(rig, requester, kind: .pick)
            XCTFail("the capture request should be declined")
        } catch let error as CrossDropError {
            XCTAssertEqual(error.code, ErrorCode.declined)
        }
        XCTAssertEqual(rig.serverDelegate.captures.first?.kind, .pick)
        XCTAssertEqual(requester.server.captureRequests.outstanding, 0)
    }

    func testCaptureRequestFromUnpairedDeviceIsRefused() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop() }
        let requester = try await makeRequester(rig)
        defer { requester.server.stop() }
        // Not paired on either side: the client refuses to ask.
        do {
            _ = try await requestCapture(rig, requester)
            XCTFail("an unpaired device must not be asked")
        } catch let error as CrossDropError {
            XCTAssertEqual(error.code, ErrorCode.pairingRequired)
            XCTAssertFalse(error.fromPeer)
        }
        // The client trusts the server, but the server doesn't know the client: pairing_required, no pairing.
        rig.clientTrust.storeTrust(for: PeerInfo(deviceId: rig.serverIdentity.deviceId, name: "Test Mac", platform: "macos",
                                                 appVersion: nil, identityKey: rig.serverIdentity.publicKey))
        do {
            _ = try await requestCapture(rig, requester)
            XCTFail("the server must refuse an unpaired requester")
        } catch let error as CrossDropError {
            XCTAssertEqual(error.code, ErrorCode.pairingRequired)
            XCTAssertTrue(error.fromPeer)
        }
        XCTAssertEqual(rig.serverDelegate.captures.count, 0)
        XCTAssertNil(rig.serverTrust.trustedIdentityKey(for: rig.clientIdentity.deviceId))
        XCTAssertEqual(rig.serverDelegate.seenCodes, [])
        XCTAssertEqual(requester.server.captureRequests.outstanding, 0)
    }

    func testCaptureRequestsExpireAndAreBoundToOneDevice() {
        let requests = CaptureRequests()
        let a = String(repeating: "a", count: 32)
        let b = String(repeating: "b", count: 32)
        XCTAssertTrue(requests.expect("request-0001", deviceId: a))
        XCTAssertFalse(requests.redeem("request-0001", deviceId: b))
        XCTAssertTrue(requests.redeem("request-0001", deviceId: a))
        XCTAssertFalse(requests.redeem("request-0001", deviceId: a))
        XCTAssertTrue(requests.expect("request-0002", deviceId: a, ttl: -1))
        XCTAssertFalse(requests.redeem("request-0002", deviceId: a))
        XCTAssertFalse(requests.expect("bad id!", deviceId: a))
    }

    // MARK: §9.8 expiring drops

    func testExpiresAfterRoundTripsAndOutOfRangeIsRejected() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop() }
        let file = try makeFile("a.txt", bytes: 10)
        let result = await transfer(rig, outgoing: [OutgoingFile(url: file)], expiresAfter: 3600).run()
        XCTAssertEqual(result.phase, .completed, "error: \(String(describing: result.error))")
        let incoming = try await rig.serverDelegate.waitForFinished()
        XCTAssertEqual(incoming.expiresAfter, 3600)

        let tooShort = await transfer(rig, outgoing: [OutgoingFile(url: file)], expiresAfter: 59).run()
        XCTAssertEqual(tooShort.phase, .failed)

        let sha = String(repeating: "a", count: 64)
        func offer(_ extra: [String: Any]) -> WireMessage {
            var fields: [String: Any] = [
                "transferId": "abcdefgh-1234",
                "files": [["fileId": 0, "name": "t", "size": 1, "sha256": sha]],
            ]
            for (key, value) in extra { fields[key] = value }
            return WireMessage(type: "transfer.offer", version: 1, fields: fields)
        }
        XCTAssertEqual(try TransferOffer.parse(offer(["expiresAfter": 60])).expiresAfter, 60)
        XCTAssertEqual(try TransferOffer.parse(offer(["requestId": "request-0001"])).requestId, "request-0001")
        XCTAssertNil(try TransferOffer.parse(offer([:])).expiresAfter)
        let badValues: [Any] = [59, 2_592_001, "3600", 60.5]
        for bad in badValues {
            XCTAssertThrowsError(try TransferOffer.parse(offer(["expiresAfter": bad])))
        }
        XCTAssertThrowsError(try TransferOffer.parse(offer(["requestId": "no spaces allowed"])))
        let encoded = TransferOffer(transferId: "abcdefgh-1234", files: [], requestId: "request-0001", expiresAfter: 600).toMessage()
        XCTAssertEqual(encoded["requestId"] as? String, "request-0001")
        XCTAssertEqual(encoded["expiresAfter"] as? Int64, 600)
    }

    // MARK: §9.9 Drip Rooms

    func testRoomPairsWithoutPromptsAndTrustIsTemporary() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop() }
        let room = try XCTUnwrap(rig.server.rooms.create(name: "Standup", ttl: 3600))
        // Neither side may ask its user.
        rig.serverDelegate.acceptPairing = false
        rig.clientDelegate.acceptPairing = false
        let file = try makeFile("slides.pdf", bytes: 10)
        let result = await transfer(rig, outgoing: [OutgoingFile(url: file)], room: room).run()
        XCTAssertEqual(result.phase, .completed, "error: \(String(describing: result.error))")
        XCTAssertEqual(rig.serverDelegate.seenCodes, [])
        XCTAssertEqual(rig.clientDelegate.seenCodes, [])
        XCTAssertEqual(rig.serverTrust.trustExpiry(for: rig.clientIdentity.deviceId), room.expiryDate)
        XCTAssertEqual(rig.clientTrust.trustExpiry(for: rig.serverIdentity.deviceId), room.expiryDate)
        XCTAssertFalse(rig.serverTrust.isAutoAccept(deviceId: rig.clientIdentity.deviceId))

        // When the room ends, so does the trust: the next transfer has to pair again, with codes.
        rig.serverTrust.storeTrust(for: clientPeer(rig), autoAccept: false, expiresAt: Date().addingTimeInterval(-1))
        XCTAssertNil(rig.serverTrust.trustedIdentityKey(for: rig.clientIdentity.deviceId))
        rig.serverDelegate.acceptPairing = true
        rig.clientDelegate.acceptPairing = true
        let again = await transfer(rig, outgoing: [OutgoingFile(url: file)]).run()
        XCTAssertEqual(again.phase, .completed, "error: \(String(describing: again.error))")
        XCTAssertEqual(rig.serverDelegate.seenCodes.count, 1, "expired room trust means comparing codes again")
        XCTAssertNotNil(rig.serverTrust.trustedIdentityKey(for: rig.clientIdentity.deviceId))
        XCTAssertNil(rig.serverTrust.trustExpiry(for: rig.clientIdentity.deviceId))
    }

    func testWrongRoomKeyFallsBackToCodeComparison() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop() }
        let room = try XCTUnwrap(rig.server.rooms.create(name: "Standup", ttl: 3600))
        let forged = try XCTUnwrap(Room(id: room.id, key: Data(repeating: 9, count: 32), name: room.name,
                                        expiresAt: room.expiresAt))
        let file = try makeFile("a.txt", bytes: 10)
        let result = await transfer(rig, outgoing: [OutgoingFile(url: file)], room: forged).run()
        XCTAssertEqual(result.phase, .completed, "error: \(String(describing: result.error))")
        XCTAssertEqual(rig.serverDelegate.seenCodes.count, 1)
        XCTAssertEqual(rig.serverDelegate.seenCodes, rig.clientDelegate.seenCodes)
        XCTAssertNotNil(rig.serverTrust.trustedIdentityKey(for: rig.clientIdentity.deviceId))
        XCTAssertNil(rig.serverTrust.trustExpiry(for: rig.clientIdentity.deviceId), "code-compared trust is permanent")
    }

    func testPrivateModeAcceptsRoomProofAndRoomCodeNamesTheHost() async throws {
        let rig = try await makeRig(privateMode: true)
        defer { rig.server.stop() }
        let room = try XCTUnwrap(rig.server.rooms.create(name: "Standup", ttl: 3600))
        let invite = try XCTUnwrap(RoomInvite(room: room, hosts: ["127.0.0.1"], port: rig.port,
                                              fingerprint: rig.serverIdentity.fingerprint))
        let parsed = try XCTUnwrap(RoomInvite.parse(invite.uri))
        let local = LocalInfo(name: "Test Client", appVersion: "test")

        // A code naming another device's key is refused before pairing.
        let wrongHost = try XCTUnwrap(RoomInvite(room: parsed.room, hosts: parsed.hosts, port: parsed.port,
                                                 fingerprint: String(repeating: "0", count: 64)))
        do {
            _ = try await RoomPairingClient.pairOnly(invite: wrongHost, identity: rig.clientIdentity, local: local,
                                                    trust: rig.clientTrust, delegate: rig.clientDelegate)
            XCTFail("a code for another device must be refused")
        } catch let error as CrossDropError {
            XCTAssertEqual(error.code, ErrorCode.authFailed)
        }

        rig.serverDelegate.acceptPairing = false
        rig.clientDelegate.acceptPairing = false
        let peer = try await RoomPairingClient.pairOnly(invite: parsed, identity: rig.clientIdentity, local: local,
                                                        trust: rig.clientTrust, delegate: rig.clientDelegate)
        XCTAssertEqual(peer.deviceId, rig.serverIdentity.deviceId)
        for _ in 0..<150 where rig.serverTrust.trustedIdentityKey(for: rig.clientIdentity.deviceId) == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(rig.serverTrust.trustExpiry(for: rig.clientIdentity.deviceId), room.expiryDate)
        // Now a (temporary) paired device, it gets through "My devices only".
        let file = try makeFile("a.txt", bytes: 10)
        let result = await transfer(rig, outgoing: [OutgoingFile(url: file)]).run()
        XCTAssertEqual(result.phase, .completed, "error: \(String(describing: result.error))")
        XCTAssertEqual(rig.serverDelegate.seenCodes, [])
    }

    // MARK: §9.10 Turbo

    /// Thread-safe "only once" switch for callbacks that arrive on background threads.
    private final class Once {
        private let lock = NSLock()
        private var done = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    private func makeZeroFile(_ name: String, bytes: Int) throws -> URL {
        let url = workDir.appendingPathComponent("out").appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        return url
    }

    private func waitForIdle(_ rig: Rig) async throws {
        for _ in 0..<250 where rig.server.activeConnectionCount > 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Raw `transfer.join` as the rig's (paired) client; returns the server's answer.
    private func rawJoin(_ rig: Rig, transferId: String, token: String) async throws -> WireMessage {
        let transport = NWTransport.connect(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: rig.port)!))
        let channel = SecureChannel(transport: transport)
        defer { transport.close() }
        try await transport.start(timeout: 5)
        _ = try await Handshake.runClient(channel: channel, identity: rig.clientIdentity,
                                          local: LocalInfo(name: "Test Client", appVersion: "test"), trust: rig.clientTrust)
        try await channel.sendControl(WireMessage.make("transfer.join", ["transferId": transferId, "token": token]))
        return try await channel.receiveControl(timeout: 5)
    }

    func testTurboSpreadsFilesOverThreeConnections() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop() }
        let sizes = [0, 1, 700_000, 1_000_003, 900_000]
        var urls: [URL] = []
        for (index, size) in sizes.enumerated() {
            urls.append(try makeFile("turbo-\(index).bin", bytes: size))
        }
        let result = await transfer(rig, outgoing: urls.map { OutgoingFile(url: $0) }, turbo: 3).run()
        XCTAssertEqual(result.phase, .completed, "error: \(String(describing: result.error))")
        XCTAssertEqual(result.streams, 3)
        let incoming = try await rig.serverDelegate.waitForFinished()
        XCTAssertEqual(incoming.phase, .completed)
        XCTAssertEqual(incoming.streams, 3)
        XCTAssertEqual(rig.serverDelegate.seenCodes.count, 1, "the first connection pairs as usual")
        for url in urls {
            XCTAssertEqual(try Data(contentsOf: inbox.appendingPathComponent(url.lastPathComponent)), try Data(contentsOf: url))
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: inbox.path).filter { $0.hasSuffix(".partial") }
        XCTAssertEqual(leftovers, [])
        try await waitForIdle(rig)
        XCTAssertEqual(rig.server.activeConnectionCount, 0)
    }

    func testReceiverWithoutTurboUsesOneConnection() async throws {
        let rig = try await makeRig(turbo: false)
        defer { rig.server.stop() }
        var urls: [URL] = []
        for index in 1...3 {
            urls.append(try makeFile("plain-\(index).bin", bytes: 200_000 * index))
        }
        let result = await transfer(rig, outgoing: urls.map { OutgoingFile(url: $0) }, turbo: 3).run()
        XCTAssertEqual(result.phase, .completed, "error: \(String(describing: result.error))")
        XCTAssertEqual(result.streams, 1)
        let incoming = try await rig.serverDelegate.waitForFinished()
        XCTAssertEqual(incoming.streams, 1)
        for url in urls {
            XCTAssertEqual(try Data(contentsOf: inbox.appendingPathComponent(url.lastPathComponent)), try Data(contentsOf: url))
        }

        // `parallel` on the offer and `join` on the accept are validated.
        let sha = String(repeating: "a", count: 64)
        func offer(_ parallel: Any?) -> WireMessage {
            var fields: [String: Any] = [
                "transferId": "abcdefgh-1234",
                "files": [["fileId": 0, "name": "a", "size": 1, "sha256": sha],
                          ["fileId": 1, "name": "b", "size": 1, "sha256": sha]],
            ]
            if let parallel = parallel { fields["parallel"] = parallel }
            return WireMessage(type: "transfer.offer", version: 1, fields: fields)
        }
        XCTAssertEqual(try TransferOffer.parse(offer(2)).parallel, 2)
        XCTAssertNil(try TransferOffer.parse(offer(nil)).parallel)
        let badValues: [Any] = [1, 5, "3", 2.5]
        for bad in badValues {
            XCTAssertThrowsError(try TransferOffer.parse(offer(bad)))
        }
        let encoded = TransferOffer(transferId: "abcdefgh-1234", files: [], parallel: 3).toMessage()
        XCTAssertEqual(encoded["parallel"] as? Int, 3)

        let token = Turbo.newToken()
        XCTAssertTrue(Turbo.isValidToken(token))
        func accept(_ join: [String: Any]) -> WireMessage {
            WireMessage(type: "transfer.accept", version: 1, fields: ["transferId": "abcdefgh-1234", "join": join])
        }
        XCTAssertEqual(try Turbo.parseJoin(accept(["token": token, "max": 3]), requested: 3)?.max, 3)
        XCTAssertNil(try Turbo.parseJoin(accept(["token": token, "max": 3]), requested: nil), "ignored when not asked for")
        XCTAssertThrowsError(try Turbo.parseJoin(accept(["token": token, "max": 4]), requested: 3))
        XCTAssertThrowsError(try Turbo.parseJoin(accept(["token": token, "max": 1]), requested: 3))
        XCTAssertThrowsError(try Turbo.parseJoin(accept(["token": "short", "max": 2]), requested: 3))
    }

    func testCancelDuringTurboClosesEveryConnection() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop() }
        var urls: [URL] = []
        for index in 1...3 {
            urls.append(try makeZeroFile("big-\(index).bin", bytes: 16_000_000))
        }
        let outgoing = transfer(rig, outgoing: urls.map { OutgoingFile(url: $0) }, turbo: 3)
        // Slow the stream down so the cancel lands mid-transfer.
        outgoing.onChunkSent = { _ in _ = usleep(10_000) }
        let once = Once()
        rig.clientDelegate.onUpdate = { snapshot in
            if snapshot.streams == 3, once.claim() {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { outgoing.cancel() }
            }
        }
        let result = await outgoing.run()
        XCTAssertEqual(result.phase, .cancelled)
        XCTAssertEqual(result.streams, 3)
        let incoming = try await rig.serverDelegate.waitForFinished()
        XCTAssertTrue(incoming.phase == .cancelled || incoming.phase == .failed, "got \(incoming.phase)")
        XCTAssertEqual(rig.serverDelegate.finished.count, 1, "reported once")
        // Every connection of the transfer closes, and no temporary file is left behind.
        try await waitForIdle(rig)
        XCTAssertEqual(rig.server.activeConnectionCount, 0)
        let temporary = try FileManager.default.contentsOfDirectory(atPath: inbox.path)
            .filter { $0.hasSuffix(".partial") && !$0.hasPrefix(ResumeStore.prefix) }
        XCTAssertEqual(temporary, [])
    }

    func testBadJoinIsRefusedAndTheTransferCarriesOn() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop() }
        try await pairClientWithServer(rig)
        try await waitForIdle(rig)

        // No such transfer.
        let unknown = try await rawJoin(rig, transferId: "no-such-transfer", token: String(repeating: "A", count: 22))
        XCTAssertEqual(unknown.type, "error")
        XCTAssertEqual(unknown.string("code"), ErrorCode.unexpectedMessage)
        try await waitForIdle(rig)

        let first = try makeFile("first.bin", bytes: 2_000_000)
        let second = try makeFile("second.bin", bytes: 100_000)
        let outgoing = transfer(rig, outgoing: [OutgoingFile(url: first), OutgoingFile(url: second)], turbo: 2)
        let gate = DispatchSemaphore(value: 0)
        outgoing.onChunkSent = { sent in
            // Hold the big file after its first record until the bad join has been tried.
            if sent == Int64(ProtocolConstants.maxDataBody) { _ = gate.wait(timeout: .now() + 10) }
        }
        let running = Task { await outgoing.run() }
        for _ in 0..<250 where !(outgoing.snapshot.streams == 2 && rig.server.activeConnectionCount == 2) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(outgoing.snapshot.streams, 2)

        // Right transfer, wrong token: refused, and the transfer is not affected.
        let wrong = try await rawJoin(rig, transferId: outgoing.id, token: String(repeating: "B", count: 22))
        XCTAssertEqual(wrong.type, "error")
        XCTAssertEqual(wrong.string("code"), ErrorCode.authFailed)

        gate.signal()
        let result = await running.value
        XCTAssertEqual(result.phase, .completed, "error: \(String(describing: result.error))")
        let incoming = try await rig.serverDelegate.waitForFinished(count: 2)
        XCTAssertEqual(incoming.phase, .completed)
        XCTAssertEqual(incoming.streams, 2)
        XCTAssertEqual(try Data(contentsOf: inbox.appendingPathComponent("first.bin")), try Data(contentsOf: first))
        XCTAssertEqual(try Data(contentsOf: inbox.appendingPathComponent("second.bin")), try Data(contentsOf: second))
    }
}
