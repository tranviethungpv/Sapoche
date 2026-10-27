package app.sapoche

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The secrets of the rooms whose chat is end-to-end encrypted, by room code (see [app.sapoche.sync.ChatCipher]). Each is
 * kept sealed with a key that lives in the Android Keystore and never leaves it; where the Keystore will not give one, the
 * secret is kept as it is in the app's private storage, which is no worse than the rest of what the app keeps.
 */
class RoomKeys(context: Context) {
    private val prefs = context.getSharedPreferences("room_keys", Context.MODE_PRIVATE)

    private fun wrapper(): SecretKey? =
        try {
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            (store.getKey(ALIAS, null) as? SecretKey) ?: KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
                .apply {
                    init(
                        KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                            .setKeySize(256)
                            .build(),
                    )
                }.generateKey()
        } catch (_: Exception) {
            null
        }

    fun has(room: String): Boolean = prefs.contains(room.uppercase())

    fun get(room: String): ByteArray? {
        val saved = prefs.getString(room.uppercase(), null) ?: return null
        return try {
            if (saved.startsWith(PLAIN)) return Base64.decode(saved.removePrefix(PLAIN), FLAGS)
            val bytes = Base64.decode(saved, FLAGS)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, wrapper() ?: return null, GCMParameterSpec(128, bytes.copyOfRange(0, IV_BYTES)))
            cipher.doFinal(bytes, IV_BYTES, bytes.size - IV_BYTES)
        } catch (_: Exception) {
            null
        }
    }

    fun put(room: String, secret: ByteArray) {
        val value = try {
            val key = wrapper()
            if (key == null) {
                PLAIN + Base64.encodeToString(secret, FLAGS)
            } else {
                val iv = ByteArray(IV_BYTES).also(SecureRandom()::nextBytes)
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, iv))
                Base64.encodeToString(iv + cipher.doFinal(secret), FLAGS)
            }
        } catch (_: Exception) {
            PLAIN + Base64.encodeToString(secret, FLAGS)
        }
        prefs.edit().putString(room.uppercase(), value).apply()
    }

    private companion object {
        const val ALIAS = "sapoche.roomkeys"
        const val IV_BYTES = 12
        const val PLAIN = "plain:"
        const val FLAGS = Base64.NO_WRAP or Base64.NO_PADDING
    }
}
