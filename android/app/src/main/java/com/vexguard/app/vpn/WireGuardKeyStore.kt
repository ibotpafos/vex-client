package com.vexguard.app.vpn

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.amnezia.awg.crypto.KeyPair
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class WireGuardKeyStore(context: Context) {
  private val appContext = context.applicationContext
  private val preferences = appContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

  fun getOrCreateKeyPair(): StoredWireGuardKeyPair {
    try {
      readStoredKeyPair()?.let { return it }
    } catch (_: Throwable) {
      resetKeyPair()
    }

    val stored = generateKeyPair(keyEpoch = INITIAL_KEY_EPOCH)
    replaceKeyPair(stored)
    return stored
  }

  fun generateNextKeyPair(): StoredWireGuardKeyPair {
    return generateKeyPair(keyEpoch = currentKeyEpoch() + 1)
  }

  fun replaceKeyPair(keyPair: StoredWireGuardKeyPair) {
    persistKeyPair(keyPair.normalized())
  }

  fun resetKeyPair() {
    preferences.edit()
      .remove(KEY_PUBLIC)
      .remove(KEY_PRIVATE_CIPHERTEXT)
      .remove(KEY_PRIVATE_IV)
      .remove(KEY_EPOCH)
      .apply()
  }

  private fun generateKeyPair(keyEpoch: Int): StoredWireGuardKeyPair {
    val keyPair = KeyPair()
    return StoredWireGuardKeyPair(
      privateKey = keyPair.privateKey.toBase64(),
      publicKey = keyPair.publicKey.toBase64(),
      keyEpoch = keyEpoch,
    )
  }

  private fun readStoredKeyPair(): StoredWireGuardKeyPair? {
    val publicKey = preferences.getString(KEY_PUBLIC, null)?.trim().orEmpty()
    val ciphertext = preferences.getString(KEY_PRIVATE_CIPHERTEXT, null)?.trim().orEmpty()
    val iv = preferences.getString(KEY_PRIVATE_IV, null)?.trim().orEmpty()
    if (publicKey.isEmpty() || ciphertext.isEmpty() || iv.isEmpty()) {
      return null
    }
    return StoredWireGuardKeyPair(
      privateKey = decrypt(ciphertext, iv),
      publicKey = publicKey,
      keyEpoch = currentKeyEpoch(),
    )
  }

  private fun persistKeyPair(keyPair: StoredWireGuardKeyPair) {
    val encrypted = encrypt(keyPair.privateKey)
    preferences.edit()
      .putString(KEY_PUBLIC, keyPair.publicKey)
      .putString(KEY_PRIVATE_CIPHERTEXT, encrypted.ciphertext)
      .putString(KEY_PRIVATE_IV, encrypted.iv)
      .putInt(KEY_EPOCH, keyPair.keyEpoch.coerceAtLeast(INITIAL_KEY_EPOCH))
      .apply()
  }

  private fun StoredWireGuardKeyPair.normalized(): StoredWireGuardKeyPair {
    val normalizedPrivateKey = privateKey.trim()
    val normalizedPublicKey = publicKey.trim()
    require(normalizedPrivateKey.isNotEmpty()) { "WireGuard private key is empty." }
    require(normalizedPublicKey.isNotEmpty()) { "WireGuard public key is empty." }
    return copy(
      privateKey = normalizedPrivateKey,
      publicKey = normalizedPublicKey,
      keyEpoch = keyEpoch.coerceAtLeast(INITIAL_KEY_EPOCH),
    )
  }

  private fun currentKeyEpoch(): Int {
    return preferences.getInt(KEY_EPOCH, INITIAL_KEY_EPOCH).coerceAtLeast(INITIAL_KEY_EPOCH)
  }

  private fun encrypt(value: String): EncryptedValue {
    val cipher = Cipher.getInstance(TRANSFORMATION)
    cipher.init(Cipher.ENCRYPT_MODE, secretKey())
    return EncryptedValue(
      ciphertext = Base64.encodeToString(cipher.doFinal(value.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP),
      iv = Base64.encodeToString(cipher.iv, Base64.NO_WRAP),
    )
  }

  private fun decrypt(ciphertext: String, iv: String): String {
    val cipher = Cipher.getInstance(TRANSFORMATION)
    val ivBytes = Base64.decode(iv, Base64.NO_WRAP)
    cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(GCM_TAG_BITS, ivBytes))
    val plain = cipher.doFinal(Base64.decode(ciphertext, Base64.NO_WRAP))
    return String(plain, Charsets.UTF_8)
  }

  private fun secretKey(): SecretKey {
    val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
    (keyStore.getKey(KEYSTORE_ALIAS, null) as? SecretKey)?.let { return it }

    val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
    val spec = KeyGenParameterSpec.Builder(
      KEYSTORE_ALIAS,
      KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
    )
      .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
      .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
      .setRandomizedEncryptionRequired(true)
      .build()
    generator.init(spec)
    return generator.generateKey()
  }

  private data class EncryptedValue(
    val ciphertext: String,
    val iv: String,
  )

  companion object {
    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    private const val GCM_TAG_BITS = 128
    private const val INITIAL_KEY_EPOCH = 1
    private const val KEYSTORE_ALIAS = "vex_wireguard_private_key_v1"
    private const val KEY_EPOCH = "wireguard_key_epoch"
    private const val KEY_PRIVATE_CIPHERTEXT = "wireguard_private_key_ciphertext"
    private const val KEY_PRIVATE_IV = "wireguard_private_key_iv"
    private const val KEY_PUBLIC = "wireguard_public_key"
    private const val PREFERENCES_NAME = "vex_wireguard_keys"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
  }
}

data class StoredWireGuardKeyPair(
  val privateKey: String,
  val publicKey: String,
  val keyEpoch: Int = 1,
)
