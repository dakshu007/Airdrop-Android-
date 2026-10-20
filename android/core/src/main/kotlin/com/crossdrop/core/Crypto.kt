package com.crossdrop.core

import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.Signature
import java.security.SignatureException
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPublicKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** P-256 helpers using only the platform JCA providers (docs/protocol-v1.md §1). */
object P256 {
    const val PUBLIC_KEY_SIZE = 65

    val params: ECParameterSpec by lazy {
        val ap = AlgorithmParameters.getInstance("EC")
        ap.init(ECGenParameterSpec("secp256r1"))
        ap.getParameterSpec(ECParameterSpec::class.java)
    }

    private val p: BigInteger by lazy { (params.curve.field as java.security.spec.ECFieldFp).p }

    fun generate(): KeyPair =
        KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()

    /** Uncompressed X9.63 encoding: 0x04 || X || Y. */
    fun encode(key: ECPublicKey): ByteArray {
        val out = ByteArray(PUBLIC_KEY_SIZE)
        out[0] = 0x04
        fixed32(key.w.affineX).copyInto(out, 1)
        fixed32(key.w.affineY).copyInto(out, 33)
        return out
    }

    /** Decodes and validates an X9.63 point; throws [ProtocolException] (auth_failed) if invalid. */
    fun decode(bytes: ByteArray): ECPublicKey {
        if (bytes.size != PUBLIC_KEY_SIZE || bytes[0] != 0x04.toByte()) {
            throw ProtocolException(ErrorCode.AUTH_FAILED, "bad public key encoding")
        }
        val x = BigInteger(1, bytes.copyOfRange(1, 33))
        val y = BigInteger(1, bytes.copyOfRange(33, 65))
        if (x >= p || y >= p) throw ProtocolException(ErrorCode.AUTH_FAILED, "point out of range")
        val a = params.curve.a
        val b = params.curve.b
        val lhs = y.modPow(BigInteger.valueOf(2), p)
        val rhs = x.modPow(BigInteger.valueOf(3), p).add(a.multiply(x)).add(b).mod(p)
        if (lhs != rhs) throw ProtocolException(ErrorCode.AUTH_FAILED, "point not on curve")
        return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(x, y), params)) as ECPublicKey
    }

    fun privateKeyFromScalar(scalar: ByteArray): PrivateKey =
        KeyFactory.getInstance("EC").generatePrivate(ECPrivateKeySpec(BigInteger(1, scalar), params))

    /** Derives the public key for a raw scalar (used by the test tooling and identity files). */
    fun publicKeyFromScalar(scalar: ByteArray): ECPublicKey {
        val g = params.generator
        val point = multiply(g, BigInteger(1, scalar))
        return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(point, params)) as ECPublicKey
    }

    fun ecdh(privateKey: PrivateKey, peer: ECPublicKey): ByteArray {
        val ka = KeyAgreement.getInstance("ECDH")
        ka.init(privateKey)
        ka.doPhase(peer, true)
        val secret = ka.generateSecret()
        return if (secret.size == 32) secret else fixed32(BigInteger(1, secret))
    }

    fun sign(privateKey: PrivateKey, data: ByteArray): ByteArray =
        Signature.getInstance("SHA256withECDSA").run {
            initSign(privateKey)
            update(data)
            sign()
        }

    fun verify(publicKeyX963: ByteArray, data: ByteArray, derSignature: ByteArray): Boolean = try {
        Signature.getInstance("SHA256withECDSA").run {
            initVerify(decode(publicKeyX963))
            update(data)
            verify(derSignature)
        }
    } catch (e: SignatureException) {
        false
    } catch (e: ProtocolException) {
        false
    }

    private fun fixed32(v: BigInteger): ByteArray {
        val raw = v.toByteArray()
        return when {
            raw.size == 32 -> raw
            raw.size == 33 && raw[0] == 0.toByte() -> raw.copyOfRange(1, 33)
            raw.size < 32 -> ByteArray(32 - raw.size) + raw
            else -> throw IllegalArgumentException("coordinate too large")
        }
    }

    // Affine double-and-add; only used to derive public keys from stored scalars, never on secret-timing paths
    // exposed to the network (signing and ECDH use the provider).
    private fun multiply(point: ECPoint, k: BigInteger): ECPoint {
        var result: ECPoint = ECPoint.POINT_INFINITY
        var addend = point
        for (bit in 0 until k.bitLength()) {
            if (k.testBit(bit)) result = add(result, addend)
            addend = add(addend, addend)
        }
        return result
    }

    private fun add(p1: ECPoint, p2: ECPoint): ECPoint {
        if (p1 == ECPoint.POINT_INFINITY) return p2
        if (p2 == ECPoint.POINT_INFINITY) return p1
        val (x1, y1) = p1.affineX to p1.affineY
        val (x2, y2) = p2.affineX to p2.affineY
        val lambda = if (x1 == x2) {
            if (y1.add(y2).mod(p) == BigInteger.ZERO) return ECPoint.POINT_INFINITY
            x1.pow(2).multiply(BigInteger.valueOf(3)).add(params.curve.a)
                .multiply(y1.shiftLeft(1).modInverse(p)).mod(p)
        } else {
            y2.subtract(y1).multiply(x2.subtract(x1).modInverse(p)).mod(p)
        }
        val x3 = lambda.pow(2).subtract(x1).subtract(x2).mod(p)
        val y3 = lambda.multiply(x1.subtract(x3)).subtract(y1).mod(p)
        return ECPoint(x3, y3)
    }
}

object Hashing {
    fun sha256(vararg parts: ByteArray): ByteArray {
        val md = MessageDigest.getInstance("SHA-256")
        for (part in parts) md.update(part)
        return md.digest()
    }

    fun hmacSha256(key: ByteArray, vararg parts: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(if (key.isEmpty()) ByteArray(32) else key, "HmacSHA256"))
        for (part in parts) mac.update(part)
        return mac.doFinal()
    }

    /** HKDF-SHA256 (RFC 5869). */
    fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        require(length in 1..255 * 32)
        val prk = hmacSha256(salt, ikm)
        val out = ByteArray(length)
        var previous = ByteArray(0)
        var offset = 0
        var counter = 1
        while (offset < length) {
            previous = hmacSha256(prk, previous, info, byteArrayOf(counter.toByte()))
            val n = minOf(previous.size, length - offset)
            previous.copyInto(out, offset, 0, n)
            offset += n
            counter++
        }
        return out
    }
}

/**
 * AES-256-GCM with the protocol's counter nonce (0x00000000 || u64be(seq)).
 * One instance per direction; not thread-safe (callers serialise access).
 */
class RecordCipher(key: ByteArray, private val encrypt: Boolean) {
    private val keySpec = SecretKeySpec(key, "AES")
    private val cipher: Cipher = Cipher.getInstance("AES/GCM/NoPadding")
    private val nonce = ByteArray(12)
    var seq: Long = 0
        private set

    init {
        require(key.size == 32)
    }

    private fun prepare() {
        if (seq == Long.MAX_VALUE) throw ProtocolException(ErrorCode.INTERNAL, "sequence exhausted")
        for (k in 0 until 8) nonce[4 + k] = (seq ushr (56 - 8 * k)).toByte()
        cipher.init(if (encrypt) Cipher.ENCRYPT_MODE else Cipher.DECRYPT_MODE, keySpec, GCMParameterSpec(128, nonce))
        seq++
    }

    /** Seals input[off, off+len) into output starting at outOff; returns bytes written. */
    fun seal(input: ByteArray, off: Int, len: Int, output: ByteArray, outOff: Int): Int {
        check(encrypt)
        prepare()
        return cipher.doFinal(input, off, len, output, outOff)
    }

    fun seal(plaintext: ByteArray): ByteArray {
        val out = ByteArray(plaintext.size + 16)
        seal(plaintext, 0, plaintext.size, out, 0)
        return out
    }

    /** Opens a record; throws [ProtocolException] with bad_frame if authentication fails. */
    fun open(payload: ByteArray, len: Int = payload.size): ByteArray {
        check(!encrypt)
        prepare()
        return try {
            cipher.doFinal(payload, 0, len)
        } catch (e: javax.crypto.AEADBadTagException) {
            throw ProtocolException(ErrorCode.BAD_FRAME, "record authentication failed")
        }
    }
}
