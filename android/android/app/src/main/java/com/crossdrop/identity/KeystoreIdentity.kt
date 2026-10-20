package com.crossdrop.identity

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.crossdrop.core.IdentityKey
import com.crossdrop.core.P256
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec

/**
 * Device identity (docs/protocol-v1.md §1.1) held in the Android Keystore.
 * The private key never leaves the Keystore; only signing operations are performed.
 */
class KeystoreIdentity private constructor(
    private val privateKey: PrivateKey,
    override val publicKey: ByteArray,
) : IdentityKey {

    override fun sign(data: ByteArray): ByteArray = Signature.getInstance("SHA256withECDSA").run {
        initSign(privateKey)
        update(data)
        sign()
    }

    companion object {
        private const val ALIAS = "crossdrop_identity_v1"
        private const val PROVIDER = "AndroidKeyStore"

        @Synchronized
        fun loadOrCreate(): KeystoreIdentity {
            val ks = KeyStore.getInstance(PROVIDER).apply { load(null) }
            if (!ks.containsAlias(ALIAS)) {
                val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    .setDigests(KeyProperties.DIGEST_SHA256)
                    .build()
                KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, PROVIDER).apply {
                    initialize(spec)
                    generateKeyPair()
                }
            }
            val privateKey = ks.getKey(ALIAS, null) as PrivateKey
            val publicKey = ks.getCertificate(ALIAS).publicKey as ECPublicKey
            return KeystoreIdentity(privateKey, P256.encode(publicKey))
        }
    }
}
