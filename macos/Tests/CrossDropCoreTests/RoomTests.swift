import XCTest
@testable import CrossDropCore

/// Drip Room codes, hints and proofs (§9.9). The fixed values are shared with the Kotlin tests.
final class RoomTests: XCTestCase {
    private let id = "AAECAwQFBgcICQoLDA0ODw"
    private let key = Data((0..<32).map { UInt8($0) })
    private let exp: Int64 = 1_800_000_000
    private let fp = String(repeating: "ab", count: 32)
    private var now: Date { Date(timeIntervalSince1970: TimeInterval(exp - 3600)) }
    private var vectorURI: String {
        "crossdrop://room?v=1&id=AAECAwQFBgcICQoLDA0ODw&k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
            + "&n=Team%20%26%20Sync%20%C3%BC&exp=1800000000&h=192.168.1.5%2Cfe80%3A%3A1%25en0&p=47100&fp=\(fp)"
    }

    func testBuildsTheSharedVectorAndParsesItBack() throws {
        let room = try XCTUnwrap(Room(id: id, key: key, name: "Team & Sync \u{00FC}", expiresAt: exp))
        let invite = try XCTUnwrap(RoomInvite(room: room, hosts: ["192.168.1.5", "fe80::1%en0"], port: 47100,
                                              fingerprint: fp))
        XCTAssertEqual(invite.uri, vectorURI)
        let parsed = try XCTUnwrap(RoomInvite.parse(vectorURI, now: now))
        XCTAssertEqual(parsed, invite)
        XCTAssertEqual(parsed.room.key, key)
        XCTAssertEqual(parsed.room.name, "Team & Sync \u{00FC}")
        XCTAssertEqual(parsed.hosts, ["192.168.1.5", "fe80::1%en0"])
    }

    func testHintAndProofsMatchVectors() throws {
        XCTAssertEqual(Rooms.hint(roomId: id), "da19855d5fe9499b")
        let room = try XCTUnwrap(Room(id: id, key: key, name: "Room", expiresAt: exp))
        let th = Data(repeating: 0xab, count: 32)
        XCTAssertEqual(room.proof(transcriptHash: th).base64EncodedString(), "qGg0p52/zxclCMSFDlqgy6i0tL7dfuGc5AG1BGVwABk=")
        XCTAssertEqual(room.confirmProof(transcriptHash: th).base64EncodedString(),
                       "rLFTyt2qSBO6Y4akuh0ZM9XOeQgI+QtvAGidEQFTgGc=")
        XCTAssertEqual(Rooms.parseHints("da19855d5fe9499b, 0011223344556677,zz"), ["da19855d5fe9499b", "0011223344556677"])
        XCTAssertEqual(Rooms.parseHints(nil), [])
        // Only ASCII spaces around a hint are ignored (identical to the Kotlin core).
        XCTAssertEqual(Rooms.parseHints("da19855d5fe9499b,\n0011223344556677,\t0011223344556677"), ["da19855d5fe9499b"])

        let deviceId = String(repeating: "a", count: 32)
        var expected = Data()
        for entry in ["v=1", "id=\(deviceId)", "p=android", "m=1", "r=da19855d5fe9499b"] {
            expected.append(UInt8(entry.utf8.count))
            expected.append(contentsOf: Array(entry.utf8))
        }
        XCTAssertEqual(CrossDropServer.txtRecord(deviceId: deviceId, platform: "android", privateMode: true,
                                                 roomHints: ["da19855d5fe9499b", "nothex"]), expected)
    }

    func testRejectsMalformedCodes() {
        let uri = vectorURI
        func variant(_ from: String, _ to: String) -> String { uri.replacingOccurrences(of: from, with: to) }
        let bad: [String] = [
            "https://example.com/?v=1",
            variant("crossdrop://room?", "crossdrop://pair?"),
            variant("v=1", "v=2"),
            variant("id=AAECAwQFBgcICQoLDA0ODw", "id=AAECAwQFBgcICQoLDA0OD"),
            variant("id=AAECAwQFBgcICQoLDA0ODw", "id=AAECAwQFBgcICQoLDA0ODx"),
            variant("id=AAECAwQFBgcICQoLDA0ODw", "id=AAECAwQFBgcICQoLDA0OD+"),
            variant("k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8", "k=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh"),
            variant("exp=1800000000", "exp=1799996400"),
            variant("exp=1800000000", "exp=1800014401"),
            variant("exp=1800000000", "exp=-5"),
            variant("&h=192.168.1.5%2Cfe80%3A%3A1%25en0", ""),
            variant("h=192.168.1.5", "h=192.168.1.5%2F..%2F"),
            variant("%2Cfe80", "%2C%0Afe80"), // newline before a host: no trimming
            variant("%2Cfe80", "%2C%20fe80"), // space before a host: no trimming
            variant("p=47100", "p=0"),
            variant("p=47100", "p=70000"),
            variant("fp=\(fp)", "fp=\(fp.uppercased())"),
            variant("fp=\(fp)", "fp=abc"),
            uri + "&v=1",
            variant("n=Team%20", "n=Team%2"),
            variant("n=Team", "n=Te am"),
            uri + "&" + String(repeating: "x", count: 2100),
        ]
        for raw in bad {
            XCTAssertNil(RoomInvite.parse(raw, now: now), raw)
        }
        // Unknown keys are ignored; a missing name becomes "Room".
        XCTAssertNotNil(RoomInvite.parse(uri + "&future=1", now: now))
        XCTAssertEqual(RoomInvite.parse(variant("&n=Team%20%26%20Sync%20%C3%BC", ""), now: now)?.room.name, "Room")
    }

    func testRegistryCreatesJoinsAndExpiresRooms() async throws {
        let rooms = Rooms()
        let made = try XCTUnwrap(rooms.create(name: "  Design\u{0000} review ", ttl: 600))
        XCTAssertEqual(made.name, "Design review")
        XCTAssertTrue(Rooms.isValidId(made.id))
        XCTAssertEqual(made.key.count, 32)
        XCTAssertEqual(rooms.room(id: made.id), made)
        XCTAssertEqual(rooms.hints(), [made.hint])
        XCTAssertEqual(rooms.room(forHint: made.hint), made)
        XCTAssertNil(rooms.create(name: "x", ttl: ProtocolConstants.roomMaxTTL + 1))

        let nowSeconds = Int64(Date().timeIntervalSince1970.rounded(.down))
        let old = try XCTUnwrap(Room(id: id, key: key, name: "Old", expiresAt: nowSeconds - 1))
        let tooLong = try XCTUnwrap(Room(id: id, key: key, name: "Too long",
                                         expiresAt: nowSeconds + ProtocolConstants.roomMaxTTL + ProtocolConstants.roomClockSkew + 60))
        let short = try XCTUnwrap(Room(id: id, key: key, name: "Short", expiresAt: nowSeconds + 2))
        XCTAssertFalse(rooms.join(old))
        XCTAssertFalse(rooms.join(tooLong))
        XCTAssertTrue(rooms.join(short))
        XCTAssertNotNil(rooms.room(id: id))
        try await Task.sleep(nanoseconds: 3_100_000_000)
        XCTAssertNil(rooms.room(id: id))
        XCTAssertEqual(rooms.active(), [made])
        rooms.leave(id: made.id)
        XCTAssertEqual(rooms.active(), [])
    }

    func testExpiredTrustIsUntrusted() {
        let store = InMemoryTrustStore()
        let identity = DeviceIdentity.generate()
        let peer = PeerInfo(deviceId: identity.deviceId, name: "Phone", platform: "android", appVersion: nil,
                            identityKey: identity.publicKey)
        store.storeTrust(for: peer, autoAccept: false, expiresAt: Date().addingTimeInterval(60))
        XCTAssertNotNil(store.trustedIdentityKey(for: peer.deviceId))
        store.storeTrust(for: peer, autoAccept: false, expiresAt: Date().addingTimeInterval(-1))
        XCTAssertNil(store.trustedIdentityKey(for: peer.deviceId))
        store.storeTrust(for: peer, autoAccept: true)
        XCTAssertNotNil(store.trustedIdentityKey(for: peer.deviceId))
        XCTAssertNil(store.trustExpiry(for: peer.deviceId))
        XCTAssertTrue(store.supportsTrustExpiry)
        XCTAssertTrue(store.isAutoAccept(deviceId: peer.deviceId))
    }
}
