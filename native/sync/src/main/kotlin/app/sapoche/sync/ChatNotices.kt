package app.sapoche.sync

/**
 * One thing that happened in a room's chat while the person was not looking, as a notice tells it: a message, an
 * answer to one of theirs, or a reaction to one of theirs. [name] is who wrote it or reacted; [text] is the message
 * (for a reaction, the message that was reacted to); [emoji] is the reaction.
 */
data class ChatNotice(
    val kind: Kind,
    val room: String,
    val name: String,
    val text: String,
    val emoji: String? = null,
) {
    enum class Kind { CHAT, REPLY, REACT }

    /** What the notice opens with, in [language] ("vi", or anything else for English). */
    fun title(language: String): String {
        val vi = language == "vi"
        return when (kind) {
            Kind.CHAT -> name
            Kind.REPLY -> if (vi) "$name đã trả lời bạn" else "$name replied to you"
            Kind.REACT -> if (vi) "$name đã thả $emoji vào tin của bạn" else "$name reacted $emoji to your message"
        }
    }

    /** What the notice says under it; with [preview] false it leaves the words of the message out. */
    fun body(language: String, preview: Boolean): String = when {
        preview && text.isNotEmpty() -> text
        kind == Kind.CHAT -> if (language == "vi") "đã gửi một tin nhắn" else "sent a message"
        else -> ""
    }
}

/** Decides which changes of a chat are worth a notice. Mirrors ChatNotices.swift and the service worker of the web app. */
object ChatNotices {
    /** A notice shows this many characters of a message. */
    const val PREVIEW_CHARS = 120

    /** The notice for a message that just arrived, or null when it is this device's own. [you] is this device's id in the room. */
    fun forMessage(message: ChatMessage, room: String, you: String?): ChatNotice? {
        if (message.by == you) return null
        val kind = if (message.re?.by == you && you != null) ChatNotice.Kind.REPLY else ChatNotice.Kind.CHAT
        return ChatNotice(kind, room, message.name, cut(message.text))
    }

    /**
     * The notice for a message that changed when it is one of this device's own and somebody new reacted to it;
     * [nameOf] gives the name of a member by id. Taking a reaction away, or reacting to one's own message, is no news.
     */
    fun forUpdate(before: ChatMessage?, after: ChatMessage, room: String, you: String?, nameOf: (String) -> String?): ChatNotice? {
        if (you == null || after.by != you) return null
        val (who, reaction) = after.rx.entries.firstOrNull { (id, e) -> id != you && before?.rx?.get(id) != e } ?: return null
        return ChatNotice(ChatNotice.Kind.REACT, room, nameOf(who) ?: "", cut(after.text), emoji(reaction))
    }

    /** The emoji of a reaction that goes by name; a reaction that is an emoji already is itself. */
    fun emoji(reaction: String): String = NAMES[reaction] ?: reaction

    /** What a notice says of [count] messages that came while it was not looked at. */
    fun many(count: Int, language: String): String = if (language == "vi") "$count tin nhắn mới" else "$count new messages"

    private fun cut(text: String): String {
        val points = text.codePointCount(0, text.length)
        return if (points <= PREVIEW_CHARS) text else text.substring(0, text.offsetByCodePoints(0, PREVIEW_CHARS))
    }

    private val NAMES = mapOf(
        "heart" to "❤️", "love" to "😍", "kiss" to "😘", "hug" to "🤗", "blush" to "😊", "cool" to "😎", "wink" to "😉",
        "pleading" to "🥺", "laugh" to "😂", "rofl" to "🤣", "grin" to "😁", "wow" to "😮", "mindblown" to "🤯",
        "think" to "🤔", "eyes" to "👀", "sad" to "😢", "cry" to "😭", "skull" to "💀", "sleepy" to "😴", "fire" to "🔥",
        "clap" to "👏", "raise" to "🙌", "party" to "🥳", "hundred" to "💯", "sparkles" to "✨", "rocket" to "🚀",
        "muscle" to "💪", "thumbsup" to "👍", "thumbsdown" to "👎", "ok" to "👌", "pray" to "🙏", "music" to "🎶",
        "dance" to "💃", "headphones" to "🎧", "mic" to "🎤", "guitar" to "🎸", "drum" to "🥁", "speaker" to "🔊",
        "replay" to "🔁",
    )
}
