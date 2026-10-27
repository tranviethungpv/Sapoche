package app.sapoche.sync

import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.io.encoding.Base64
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/**
 * End-to-end encryption of a room's chat (protocol 15). The room has one secret of 32 bytes, made on the device of its
 * owner and handed to the others in the invitation link, never through the server. The key for a message is
 * HKDF-SHA256 of that secret, salted with a label and bound to the room's code and a key epoch; a message is sealed with
 * AES-256-GCM, with the sender and the room as associated data, so the server can neither move it to another room nor
 * sign it with another member's name. Mirrors ChatCipher.swift and `chat_cipher.dart`; the three read the same vectors
 * (`e2ee_vectors.json`).
 *
 * A sealed message is base64url of: version (1), epoch (1), nonce (12), ciphertext and tag. What is sealed is JSON,
 * `{"t": text, "q": the quote of the message answered}`, padded with spaces to a multiple of 64 bytes so that its length
 * says little. The preview, for a notice, is the first 120 characters sealed apart.
 */
object ChatCipher {
    private const val LABEL = "sapoche-chat-v1"
    private const val VERSION = 1
    private const val NONCE_BYTES = 12
    private const val TAG_BITS = 128
    private const val PAD = 64
    private const val PREVIEW_CHARS = 120

    /** The epoch a new message is sealed in: one until keys can be changed. */
    const val EPOCH = 1

    private val random = SecureRandom()
    private val base64 = Base64.UrlSafe.withPadding(Base64.PaddingOption.ABSENT)
    private val json = Json { ignoreUnknownKeys = true }

    /** A new secret for a room. */
    fun newSecret(): ByteArray = ByteArray(32).also(random::nextBytes)

    fun encodeSecret(secret: ByteArray): String = base64.encode(secret)

    /** The secret in [text] (as in an invitation link), or null when it is not one. */
    fun decodeSecret(text: String): ByteArray? =
        try {
            base64.decode(text.trim()).takeIf { it.size == 32 }
        } catch (_: IllegalArgumentException) {
            null
        }

    /** The key of [epoch] for room [room]. */
    fun key(secret: ByteArray, room: String, epoch: Int = EPOCH): ByteArray {
        // HKDF (RFC 5869) with SHA-256 and one block of output
        val extract = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(LABEL.toByteArray(), "HmacSHA256")) }
        val prk = extract.doFinal(secret)
        val expand = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(prk, "HmacSHA256")) }
        expand.update("${room.uppercase()}|$epoch".toByteArray())
        expand.update(1)
        return expand.doFinal()
    }

    private fun associated(room: String, by: String, epoch: Int, preview: Boolean) =
        "$LABEL|${room.uppercase()}|$by|$epoch${if (preview) "|pv" else ""}".toByteArray()

    /** [plaintext] sealed for [by] in [room]. [nonce] is only given by the tests. */
    fun seal(
        secret: ByteArray,
        room: String,
        by: String,
        plaintext: ByteArray,
        preview: Boolean = false,
        epoch: Int = EPOCH,
        nonce: ByteArray = ByteArray(NONCE_BYTES).also(random::nextBytes),
    ): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key(secret, room, epoch), "AES"), GCMParameterSpec(TAG_BITS, nonce))
        cipher.updateAAD(associated(room, by, epoch, preview))
        val sealed = cipher.doFinal(plaintext)
        return base64.encode(byteArrayOf(VERSION.toByte(), epoch.toByte()) + nonce + sealed)
    }

    /** What [envelope], sent by [by] in [room], holds; null when it is not from this room's secret, this sender, or intact. */
    fun open(secret: ByteArray, room: String, by: String, envelope: String, preview: Boolean = false): ByteArray? =
        try {
            val bytes = base64.decode(envelope)
            if (bytes.size < 2 + NONCE_BYTES + TAG_BITS / 8 || bytes[0].toInt() != VERSION) {
                null
            } else {
                val epoch = bytes[1].toInt() and 0xff
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(
                    Cipher.DECRYPT_MODE,
                    SecretKeySpec(key(secret, room, epoch), "AES"),
                    GCMParameterSpec(TAG_BITS, bytes.copyOfRange(2, 2 + NONCE_BYTES)),
                )
                cipher.updateAAD(associated(room, by, epoch, preview))
                cipher.doFinal(bytes, 2 + NONCE_BYTES, bytes.size - 2 - NONCE_BYTES)
            }
        } catch (_: Exception) {
            null
        }

    /** The sealed words of a message by [by], with the quote of what it answers inside, and the sealed preview. */
    fun sealMessage(secret: ByteArray, room: String, by: String, text: String, quote: ChatQuote?): Pair<String, String> {
        val body = buildJsonObject {
            put("t", text)
            if (quote != null) {
                put("q", buildJsonObject {
                    put("id", quote.id)
                    put("by", quote.by)
                    put("name", quote.name)
                    put("text", quote.text)
                })
            }
        }.toString().toByteArray()
        val padded = body + ByteArray((PAD - body.size % PAD) % PAD) { ' '.code.toByte() }
        val cut = text.codePointCount(0, text.length).let { if (it <= PREVIEW_CHARS) text else text.substring(0, text.offsetByCodePoints(0, PREVIEW_CHARS)) }
        return seal(secret, room, by, padded) to seal(secret, room, by, cut.toByteArray(), preview = true)
    }

    /**
     * [message] as the room sent it, with its words read: the text and the quote of what it answers. Null when it is not
     * sealed or cannot be read with [secret].
     */
    fun openMessage(secret: ByteArray, room: String, message: ChatMessage): ChatMessage? {
        val ct = message.ct ?: return null
        val body = open(secret, room, message.by, ct) ?: return null
        return try {
            val obj: JsonObject = json.parseToJsonElement(String(body)).jsonObject
            val quote = (obj["q"] as? JsonObject)?.let {
                ChatQuote(
                    it["id"]?.jsonPrimitive?.longOrNull ?: return null,
                    it["by"]?.jsonPrimitive?.contentOrNull ?: return null,
                    it["name"]?.jsonPrimitive?.contentOrNull ?: return null,
                    it["text"]?.jsonPrimitive?.contentOrNull ?: return null,
                )
            }
            message.copy(text = obj["t"]?.jsonPrimitive?.contentOrNull ?: return null, re = quote, locked = false)
        } catch (_: Exception) {
            null
        }
    }
}
