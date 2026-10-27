package app.sapoche.sync

import kotlin.io.encoding.Base64
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ChatCipherTest {
    private val url = Base64.UrlSafe.withPadding(Base64.PaddingOption.ABSENT)
    private val vectors = Json.parseToJsonElement(
        checkNotNull(javaClass.getResource("/e2ee_vectors.json")) { "e2ee_vectors.json is missing" }.readText(),
    ).jsonObject
    private val secret = url.decode(vectors.getValue("secret").jsonPrimitive.content)
    private val room = vectors.getValue("code").jsonPrimitive.content

    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }

    @Test
    fun `derives the keys the other platforms derive`() {
        val keys = vectors.getValue("keys").jsonObject
        assertEquals(keys.getValue("1").jsonPrimitive.content, hex(ChatCipher.key(secret, room, 1)))
        assertEquals(keys.getValue("2").jsonPrimitive.content, hex(ChatCipher.key(secret, room, 2)))
        // The code is the room's name, however it was typed
        assertEquals(hex(ChatCipher.key(secret, room, 1)), hex(ChatCipher.key(secret, room.lowercase(), 1)))
    }

    @Test
    fun `seals what the other platforms seal and opens what they sealed`() {
        for (case in vectors.getValue("cases").jsonArray.map { it.jsonObject }) {
            val by = case.getValue("by").jsonPrimitive.content
            val preview = case.getValue("kind").jsonPrimitive.content == "pv"
            val epoch = case.getValue("epoch").jsonPrimitive.int
            val plaintext = url.decode(case.getValue("plaintext").jsonPrimitive.content)
            val envelope = case.getValue("envelope").jsonPrimitive.content
            val nonce = url.decode(case.getValue("nonce").jsonPrimitive.content)
            assertEquals(envelope, ChatCipher.seal(secret, room, by, plaintext, preview, epoch, nonce))
            assertContentEquals(plaintext, ChatCipher.open(secret, room, by, envelope, preview))
        }
    }

    @Test
    fun `will not open a message for another sender, room, secret or kind, or one that was touched`() {
        val case = vectors.getValue("cases").jsonArray.first().jsonObject
        val by = case.getValue("by").jsonPrimitive.content
        val envelope = case.getValue("envelope").jsonPrimitive.content
        assertNotNull(ChatCipher.open(secret, room, by, envelope))
        assertNull(ChatCipher.open(secret, room, "0a1b2c3d4e5f6071", envelope))
        assertNull(ChatCipher.open(secret, "XYZ789", by, envelope))
        assertNull(ChatCipher.open(ChatCipher.newSecret(), room, by, envelope))
        assertNull(ChatCipher.open(secret, room, by, envelope, preview = true))
        val bytes = url.decode(envelope)
        bytes[bytes.size - 1] = (bytes.last().toInt() xor 1).toByte()
        assertNull(ChatCipher.open(secret, room, by, url.encode(bytes)))
        assertNull(ChatCipher.open(secret, room, by, "not an envelope"))
        assertNull(ChatCipher.open(secret, room, by, ""))
    }

    @Test
    fun `a message with its quote goes through the room and comes back readable`() {
        val quote = ChatQuote(4, "b9f77f9b6e1bf750", "Bình", "cũ hơn")
        val (ct, pv) = ChatCipher.sealMessage(secret, room, "a1", "Xin chào 🌸 \"quoted\"", quote)
        assertNotEquals(ct, pv)
        val arrived = ChatMessage(7, "a1", "Ann", "", 5, ct = ct, pv = pv)
        val read = assertNotNull(ChatCipher.openMessage(secret, room, arrived))
        assertEquals("Xin chào 🌸 \"quoted\"", read.text)
        assertEquals(quote, read.re)
        assertFalse(read.locked)
        assertEquals("Xin chào 🌸 \"quoted\"", String(assertNotNull(ChatCipher.open(secret, room, "a1", pv, preview = true))))
        // The same words are never sealed the same way twice, and their length says little
        assertNotEquals(ct, ChatCipher.sealMessage(secret, room, "a1", "Xin chào 🌸 \"quoted\"", quote).first)
        val short = ChatCipher.sealMessage(secret, room, "a1", "a", null).first
        val longer = ChatCipher.sealMessage(secret, room, "a1", "a".repeat(20), null).first
        assertEquals(short.length, longer.length)
        // Not sealed, or sealed for somebody else: nothing to read
        assertNull(ChatCipher.openMessage(secret, room, arrived.copy(by = "other")))
        assertNull(ChatCipher.openMessage(secret, room, arrived.copy(ct = null)))
    }

    @Test
    fun `a preview is cut to 120 characters`() {
        val (_, pv) = ChatCipher.sealMessage(secret, room, "a1", "é".repeat(300), null)
        assertEquals("é".repeat(120), String(assertNotNull(ChatCipher.open(secret, room, "a1", pv, preview = true))))
    }

    @Test
    fun `a secret is written and read as base64url, and only 32 bytes are one`() {
        val made = ChatCipher.newSecret()
        assertEquals(32, made.size)
        assertContentEquals(made, ChatCipher.decodeSecret(ChatCipher.encodeSecret(made)))
        assertNull(ChatCipher.decodeSecret("abc"))
        assertNull(ChatCipher.decodeSecret(""))
        assertTrue(ChatCipher.encodeSecret(made).matches(Regex("[A-Za-z0-9_-]{43}")))
    }
}
