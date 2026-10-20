package com.crossdrop.core

import java.io.File
import java.security.interfaces.ECPublicKey
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Checks the Kotlin implementation against protocol/test-vectors/v1.json. */
@Suppress("UNCHECKED_CAST")
class VectorsTest {
    private val v: Map<String, Any?> = Json.parse(File(System.getProperty("crossdrop.vectors")).readText()) as Map<String, Any?>
    private val id = v["identity"] as Map<String, String>
    private val hs = v["handshake"] as Map<String, String>

    @Test
    fun identityDerivation() {
        for (side in listOf("client", "server")) {
            val identity = SoftwareIdentity.fromScalar(id["${side}IdentityPrivHex"]!!.hexToBytes())
            assertEquals(id["${side}IdentityPubHex"], identity.publicKey.toHex())
            assertEquals(id["${side}Fingerprint"], identity.fingerprint)
            assertEquals(id["${side}DeviceId"], identity.deviceId)
        }
    }

    @Test
    fun keyScheduleAndSas() {
        val clientEphPub = P256.encode(P256.publicKeyFromScalar(hs["clientEphPrivHex"]!!.hexToBytes()))
        assertEquals(hs["clientEphPubHex"], clientEphPub.toHex())
        assertEquals(hs["ephCommitB64"], B64.encode(Hashing.sha256(clientEphPub)))
        val serverEph = P256.decode(hs["serverEphPubHex"]!!.hexToBytes())
        val shared = P256.ecdh(P256.privateKeyFromScalar(hs["clientEphPrivHex"]!!.hexToBytes()), serverEph)
        assertEquals(hs["sharedSecretHex"], shared.toHex())
        val sharedFromServer = P256.ecdh(P256.privateKeyFromScalar(hs["serverEphPrivHex"]!!.hexToBytes()), P256.decode(clientEphPub))
        assertContentEquals(shared, sharedFromServer)

        val th = KeySchedule.transcriptHash(
            hs["helloUtf8"]!!.toByteArray(),
            hs["challengeUtf8"]!!.toByteArray(),
            clientEphPub,
            id["clientIdentityPubHex"]!!.hexToBytes(),
        )
        assertEquals(hs["transcriptHashHex"], th.toHex())
        assertEquals(hs["keyC2sHex"], KeySchedule.c2s(shared, th).toHex())
        assertEquals(hs["keyS2cHex"], KeySchedule.s2c(shared, th).toHex())
        assertEquals(hs["sas"], KeySchedule.sas(th))
    }

    @Test
    fun signatures() {
        val th = hs["transcriptHashHex"]!!.hexToBytes()
        val clientPub = id["clientIdentityPubHex"]!!.hexToBytes()
        val serverPub = id["serverIdentityPubHex"]!!.hexToBytes()
        val clientSig = hs["clientSignatureDerHex"]!!.hexToBytes()
        val serverSig = hs["serverSignatureDerHex"]!!.hexToBytes()
        assertTrue(P256.verify(clientPub, Protocol.LABEL_CLIENT_PROOF + th, clientSig))
        assertTrue(P256.verify(serverPub, Protocol.LABEL_SERVER_PROOF + th, serverSig))
        val tampered = th.copyOf().also { it[0] = (it[0].toInt() xor 1).toByte() }
        assertFalse(P256.verify(clientPub, Protocol.LABEL_CLIENT_PROOF + tampered, clientSig))
        assertFalse(P256.verify(serverPub, Protocol.LABEL_CLIENT_PROOF + th, serverSig), "labels must differ")
        // Our own signatures verify too.
        val identity = SoftwareIdentity.fromScalar(id["clientIdentityPrivHex"]!!.hexToBytes())
        assertTrue(P256.verify(clientPub, byteArrayOf(1, 2, 3), identity.sign(byteArrayOf(1, 2, 3))))
    }

    @Test
    fun records() {
        val keys = mapOf("c2s" to hs["keyC2sHex"]!!.hexToBytes(), "s2c" to hs["keyS2cHex"]!!.hexToBytes())
        for (r in v["records"] as List<Map<String, Any?>>) {
            val seq = (r["seq"] as Long)
            val key = keys[r["direction"] as String]!!
            val sealer = RecordCipher(key, encrypt = true)
            val opener = RecordCipher(key, encrypt = false)
            // Advance to the vector's sequence number.
            repeat(seq.toInt()) {
                opener.open(sealer.seal(byteArrayOf(0)))
            }
            val plain = byteArrayOf((r["kind"] as Long).toByte()) + (r["bodyHex"] as String).hexToBytes()
            val payload = sealer.seal(plain)
            assertEquals(r["payloadHex"], payload.toHex())
            assertContentEquals(plain, opener.open(payload))
            assertEquals(r["frameHex"], (KeySchedule.lp(payload)).toHex())
        }
    }

    @Test
    fun tamperedRecordFails() {
        val key = hs["keyC2sHex"]!!.hexToBytes()
        val payload = RecordCipher(key, true).seal(byteArrayOf(1, 2, 3))
        payload[0] = (payload[0].toInt() xor 0x80).toByte()
        val e = assertFailsWith<ProtocolException> { RecordCipher(key, false).open(payload) }
        assertEquals(ErrorCode.BAD_FRAME, e.code)
    }

    @Test
    fun hkdfRfc5869() {
        val c = v["hkdfRfc5869Case1"] as Map<String, Any?>
        val okm = Hashing.hkdf((c["ikmHex"] as String).hexToBytes(), (c["saltHex"] as String).hexToBytes(), (c["infoHex"] as String).hexToBytes(), (c["length"] as Long).toInt())
        assertEquals(c["okmHex"], okm.toHex())
    }

    @Test
    fun sha256() {
        for (c in v["sha256"] as List<Map<String, String>>) {
            assertEquals(c["hex"], Hashing.sha256(c["utf8"]!!.toByteArray()).toHex())
        }
    }

    @Test
    fun sanitize() {
        for (c in v["sanitize"] as List<Map<String, String>>) {
            assertEquals(c["output"], Sanitizer.fileName(c["input"]!!), "input: ${c["input"]}")
        }
    }

    @Test
    fun invalidPointsRejected() {
        val good = id["clientIdentityPubHex"]!!.hexToBytes()
        val offCurve = good.copyOf().also { it[64] = (it[64].toInt() xor 1).toByte() }
        assertFailsWith<ProtocolException> { P256.decode(offCurve) }
        assertFailsWith<ProtocolException> { P256.decode(good.copyOf(64)) }
        val decoded: ECPublicKey = P256.decode(good)
        assertContentEquals(good, P256.encode(decoded))
    }
}
