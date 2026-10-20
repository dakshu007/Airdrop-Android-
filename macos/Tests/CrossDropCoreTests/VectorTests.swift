import XCTest
import CryptoKit
@testable import CrossDropCore

/// Checks the Swift implementation against protocol/test-vectors/v1.json.
final class VectorTests: XCTestCase {
    private var vectors: [String: Any] = [:]

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CrossDropCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
            .deletingLastPathComponent() // repository root
        let url = root.appendingPathComponent("protocol/test-vectors/v1.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        vectors = try XCTUnwrap(object as? [String: Any])
    }

    private func section(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(vectors[name] as? [String: Any], "missing \(name)")
    }

    private func hex(_ value: Any?) throws -> Data {
        let text = try XCTUnwrap(value as? String)
        return try XCTUnwrap(Hex.decode(text))
    }

    func testIdentity() throws {
        let v = try section("identity")
        for side in ["client", "server"] {
            let identity = try DeviceIdentity(rawPrivateKey: try hex(v["\(side)IdentityPrivHex"]))
            XCTAssertEqual(identity.publicKey, try hex(v["\(side)IdentityPubHex"]))
            XCTAssertEqual(identity.fingerprint, v["\(side)Fingerprint"] as? String)
            XCTAssertEqual(identity.deviceId, v["\(side)DeviceId"] as? String)
        }
    }

    func testHandshakeDerivations() throws {
        let v = try section("handshake")
        let ids = try section("identity")
        let clientEph = try P256.KeyAgreement.PrivateKey(rawRepresentation: try hex(v["clientEphPrivHex"]))
        let serverEph = try P256.KeyAgreement.PrivateKey(rawRepresentation: try hex(v["serverEphPrivHex"]))
        XCTAssertEqual(clientEph.publicKey.x963Representation, try hex(v["clientEphPubHex"]))
        XCTAssertEqual(serverEph.publicKey.x963Representation, try hex(v["serverEphPubHex"]))
        XCTAssertEqual(CDCrypto.sha256(clientEph.publicKey.x963Representation).base64EncodedString(),
                       v["ephCommitB64"] as? String)

        let shared = try CDCrypto.ecdh(privateKey: clientEph, peerPublicKey: serverEph.publicKey.x963Representation)
        XCTAssertEqual(shared, try hex(v["sharedSecretHex"]))
        XCTAssertEqual(try CDCrypto.ecdh(privateKey: serverEph, peerPublicKey: clientEph.publicKey.x963Representation), shared)

        let hello = Data(try XCTUnwrap(v["helloUtf8"] as? String).utf8)
        let challenge = Data(try XCTUnwrap(v["challengeUtf8"] as? String).utf8)
        let clientIdentityPub = try hex(ids["clientIdentityPubHex"])
        let th = CDCrypto.transcriptHash(hello: hello, challenge: challenge,
                                         clientEphPub: clientEph.publicKey.x963Representation,
                                         clientIdentityKey: clientIdentityPub)
        XCTAssertEqual(th, try hex(v["transcriptHashHex"]))

        let keys = CDCrypto.sessionKeys(sharedSecret: shared, transcriptHash: th)
        XCTAssertEqual(keys.c2s, try hex(v["keyC2sHex"]))
        XCTAssertEqual(keys.s2c, try hex(v["keyS2cHex"]))
        XCTAssertEqual(CDCrypto.sas(transcriptHash: th), v["sas"] as? String)

        // The hello and challenge in the vectors must also parse with our message rules.
        let helloMessage = try WireMessage.parse(hello)
        XCTAssertEqual(try helloMessage.requireDeviceId(), ids["clientDeviceId"] as? String)
        let challengeMessage = try WireMessage.parse(challenge)
        XCTAssertEqual(try challengeMessage.requireBase64("identityKey", length: 65), try hex(ids["serverIdentityPubHex"]))
    }

    func testSignatures() throws {
        let v = try section("handshake")
        let ids = try section("identity")
        let th = try hex(v["transcriptHashHex"])
        let clientPub = try hex(ids["clientIdentityPubHex"])
        let serverPub = try hex(ids["serverIdentityPubHex"])
        let clientSig = try hex(v["clientSignatureDerHex"])
        let serverSig = try hex(v["serverSignatureDerHex"])

        XCTAssertTrue(CDCrypto.verify(signature: clientSig, over: Labels.clientProof + th, publicKey: clientPub))
        XCTAssertTrue(CDCrypto.verify(signature: serverSig, over: Labels.serverProof + th, publicKey: serverPub))
        // Wrong label, wrong key, tampered transcript.
        XCTAssertFalse(CDCrypto.verify(signature: clientSig, over: Labels.serverProof + th, publicKey: clientPub))
        XCTAssertFalse(CDCrypto.verify(signature: clientSig, over: Labels.clientProof + th, publicKey: serverPub))
        var tampered = th
        tampered[tampered.startIndex] ^= 0x01
        XCTAssertFalse(CDCrypto.verify(signature: clientSig, over: Labels.clientProof + tampered, publicKey: clientPub))

        // Our own signatures verify too.
        let identity = try DeviceIdentity(rawPrivateKey: try hex(ids["clientIdentityPrivHex"]))
        let mine = try identity.sign(Labels.clientProof + th)
        XCTAssertTrue(CDCrypto.verify(signature: mine, over: Labels.clientProof + th, publicKey: clientPub))
    }

    func testHKDFRFC5869() throws {
        let v = try section("hkdfRfc5869Case1")
        let length = try XCTUnwrap(v["length"] as? Int)
        let okm = CDCrypto.hkdf(ikm: try hex(v["ikmHex"]), salt: try hex(v["saltHex"]),
                                info: try hex(v["infoHex"]), length: length)
        XCTAssertEqual(okm, try hex(v["okmHex"]))
    }

    func testRecords() throws {
        let v = try section("handshake")
        let keys = ["c2s": try hex(v["keyC2sHex"]), "s2c": try hex(v["keyS2cHex"])]
        let records = try XCTUnwrap(vectors["records"] as? [[String: Any]])
        XCTAssertFalse(records.isEmpty)
        for record in records {
            let key = try XCTUnwrap(keys[try XCTUnwrap(record["direction"] as? String)])
            let seq = UInt64(try XCTUnwrap(record["seq"] as? Int))
            let kind = UInt8(try XCTUnwrap(record["kind"] as? Int))
            let body = try hex(record["bodyHex"])
            let payload = try CDCrypto.seal(key: key, seq: seq, kind: kind, body: body)
            XCTAssertEqual(payload, try hex(record["payloadHex"]))
            var frame = ByteCodec.u32be(UInt32(payload.count))
            frame.append(payload)
            XCTAssertEqual(frame, try hex(record["frameHex"]))

            let opened = try CDCrypto.open(key: key, seq: seq, payload: payload)
            XCTAssertEqual(opened.kind, kind)
            XCTAssertEqual(opened.body, body)
            XCTAssertThrowsError(try CDCrypto.open(key: key, seq: seq + 1, payload: payload))
        }
    }

    func testSHA256() throws {
        let cases = try XCTUnwrap(vectors["sha256"] as? [[String: Any]])
        for item in cases {
            let input = Data(try XCTUnwrap(item["utf8"] as? String).utf8)
            var hash = StreamingHash()
            hash.update(input)
            XCTAssertEqual(hash.finalizeHex(), item["hex"] as? String)
        }
    }

    func testSanitize() throws {
        let cases = try XCTUnwrap(vectors["sanitize"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for item in cases {
            let input = try XCTUnwrap(item["input"] as? String)
            let expected = try XCTUnwrap(item["output"] as? String)
            XCTAssertEqual(FileNaming.sanitize(input), expected, "input: \(input.debugDescription)")
        }
    }

    func testFrameLimits() throws {
        let v = try section("frames")
        let maxPlain = try XCTUnwrap(v["maxPlaintextPayload"] as? Int)
        let maxEncrypted = try XCTUnwrap(v["maxEncryptedPayload"] as? Int)
        XCTAssertEqual(maxPlain, ProtocolConstants.maxPlaintextPayload)
        XCTAssertEqual(maxEncrypted, ProtocolConstants.maxEncryptedPayload)
        XCTAssertEqual(v["maxDataBody"] as? Int, ProtocolConstants.maxDataBody)

        for prefix in try XCTUnwrap(v["invalidLengthPrefixesHex"] as? [String]) {
            let length = Int(ByteCodec.readU32be(try XCTUnwrap(Hex.decode(prefix))))
            XCTAssertThrowsError(try SecureChannel.validateLength(length, encrypted: false))
        }
        XCTAssertNoThrow(try SecureChannel.validateLength(maxPlain, encrypted: false))
        XCTAssertNoThrow(try SecureChannel.validateLength(maxEncrypted, encrypted: true))
        XCTAssertThrowsError(try SecureChannel.validateLength(maxEncrypted + 1, encrypted: true))
        XCTAssertThrowsError(try SecureChannel.validateLength(0, encrypted: true))
    }
}
