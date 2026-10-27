package app.sapoche.sync

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class ChatNoticesTest {

    private fun message(id: Long, by: String, text: String, re: ChatQuote? = null, rx: Map<String, String> = emptyMap()) =
        ChatMessage(id = id, by = by, name = by.uppercase(), text = text, at = 0, re = re, rx = rx)

    @Test
    fun `a message of somebody else is a notice, and one of this device is not`() {
        assertEquals(
            ChatNotice(ChatNotice.Kind.CHAT, "ROOM", "B", "hello"),
            ChatNotices.forMessage(message(1, "b", "hello"), "ROOM", "me"),
        )
        assertNull(ChatNotices.forMessage(message(2, "me", "mine"), "ROOM", "me"))
    }

    @Test
    fun `an answer to a message of this device is told as an answer, and one to another is not`() {
        val toMe = ChatQuote(id = 1, by = "me", name = "Me", text = "q")
        val toOther = ChatQuote(id = 1, by = "c", name = "C", text = "q")
        assertEquals(ChatNotice.Kind.REPLY, ChatNotices.forMessage(message(3, "b", "a", re = toMe), "ROOM", "me")?.kind)
        assertEquals(ChatNotice.Kind.CHAT, ChatNotices.forMessage(message(4, "b", "a", re = toOther), "ROOM", "me")?.kind)
    }

    @Test
    fun `a long message is cut to 120 characters, not in the middle of an emoji`() {
        val text = "🍕".repeat(130)
        val cut = ChatNotices.forMessage(message(5, "b", text), "ROOM", "me")!!.text
        assertEquals(120, cut.codePointCount(0, cut.length))
    }

    @Test
    fun `a new reaction to a message of this device is a notice with the name of who gave it`() {
        val before = message(1, "me", "song?")
        val after = before.copy(rx = mapOf("b" to "fire"))
        assertEquals(
            ChatNotice(ChatNotice.Kind.REACT, "ROOM", "Bea", "song?", "🔥"),
            ChatNotices.forUpdate(before, after, "ROOM", "me") { if (it == "b") "Bea" else null },
        )
    }

    @Test
    fun `a reaction that was there, one taken away, one of this device and one to another message are no news`() {
        val mine = message(1, "me", "x", rx = mapOf("b" to "fire"))
        assertNull(ChatNotices.forUpdate(mine, mine.copy(rx = mapOf("b" to "fire")), "ROOM", "me") { "Bea" })
        assertNull(ChatNotices.forUpdate(mine, mine.copy(rx = emptyMap()), "ROOM", "me") { "Bea" })
        assertNull(ChatNotices.forUpdate(mine, mine.copy(rx = mapOf("b" to "fire", "me" to "heart")), "ROOM", "me") { "Bea" })
        val theirs = message(2, "b", "y")
        assertNull(ChatNotices.forUpdate(theirs, theirs.copy(rx = mapOf("c" to "fire")), "ROOM", "me") { "Cy" })
    }

    @Test
    fun `a changed reaction counts, and an emoji sent as it is stays itself`() {
        val before = message(1, "me", "x", rx = mapOf("b" to "fire"))
        val changed = ChatNotices.forUpdate(before, before.copy(rx = mapOf("b" to "🙃")), "ROOM", "me") { "Bea" }
        assertEquals("🙃", changed?.emoji)
    }

    @Test
    fun `the words follow the language, and the preview can be left out`() {
        val chat = ChatNotice(ChatNotice.Kind.CHAT, "R", "Bea", "hi")
        assertEquals("Bea", chat.title("en"))
        assertEquals("hi", chat.body("en", preview = true))
        assertEquals("sent a message", chat.body("en", preview = false))
        assertEquals("đã gửi một tin nhắn", chat.body("vi", preview = false))
        val reply = ChatNotice(ChatNotice.Kind.REPLY, "R", "Bea", "yes")
        assertEquals("Bea replied to you", reply.title("en"))
        assertEquals("Bea đã trả lời bạn", reply.title("vi"))
        assertEquals("", reply.body("en", preview = false))
        val react = ChatNotice(ChatNotice.Kind.REACT, "R", "Bea", "song?", "🔥")
        assertEquals("Bea reacted 🔥 to your message", react.title("en"))
        assertEquals("Bea đã thả 🔥 vào tin của bạn", react.title("vi"))
        assertEquals("3 new messages", ChatNotices.many(3, "en"))
        assertEquals("3 tin nhắn mới", ChatNotices.many(3, "vi"))
    }
}
