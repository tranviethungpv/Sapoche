import Foundation

/// One thing that happened in a room's chat while the person was not looking, as a notice tells it: a message, an
/// answer to one of theirs, or a reaction to one of theirs. [name] is who wrote it or reacted; [text] is the message
/// (for a reaction, the message that was reacted to); [emoji] is the reaction.
struct ChatNotice: Equatable {
    enum Kind { case chat, reply, react }

    let kind: Kind
    let room: String
    let name: String
    let text: String
    var emoji: String?

    init(kind: Kind, room: String, name: String, text: String, emoji: String? = nil) {
        self.kind = kind
        self.room = room
        self.name = name
        self.text = text
        self.emoji = emoji
    }

    /// What the notice opens with, in [language] ("vi", or anything else for English).
    func title(_ language: String) -> String {
        let vi = language == "vi"
        switch kind {
        case .chat: return name
        case .reply: return vi ? "\(name) đã trả lời bạn" : "\(name) replied to you"
        case .react: return vi ? "\(name) đã thả \(emoji ?? "") vào tin của bạn" : "\(name) reacted \(emoji ?? "") to your message"
        }
    }

    /// What the notice says under it; with [preview] false it leaves the words of the message out.
    func body(_ language: String, preview: Bool) -> String {
        if preview && !text.isEmpty { return text }
        if kind == .chat { return language == "vi" ? "đã gửi một tin nhắn" : "sent a message" }
        return ""
    }
}

/// Decides which changes of a chat are worth a notice. Mirrors ChatNotices.kt and the service worker of the web app.
enum ChatNotices {
    /// A notice shows this many characters of a message.
    static let previewChars = 120

    /// The notice for a message that just arrived, or nil when it is this device's own. [you] is this device's id in the room.
    static func forMessage(_ message: ChatMessage, room: String, you: String?) -> ChatNotice? {
        if message.by == you { return nil }
        let kind: ChatNotice.Kind = (you != nil && message.re?.by == you) ? .reply : .chat
        return ChatNotice(kind: kind, room: room, name: message.name, text: cut(message.text))
    }

    /// The notice for a message that changed when it is one of this device's own and somebody new reacted to it;
    /// [nameOf] gives the name of a member by id. Taking a reaction away, or reacting to one's own message, is no news.
    static func forUpdate(before: ChatMessage?, after: ChatMessage, room: String, you: String?, nameOf: (String) -> String?) -> ChatNotice? {
        guard let you, after.by == you else { return nil }
        // Sorted so that, with several new reactions at once, the same one is told every time
        for (who, reaction) in after.rx.sorted(by: { $0.key < $1.key }) where who != you && before?.rx[who] != reaction {
            return ChatNotice(kind: .react, room: room, name: nameOf(who) ?? "", text: cut(after.text), emoji: emoji(reaction))
        }
        return nil
    }

    /// The emoji of a reaction that goes by name; a reaction that is an emoji already is itself.
    static func emoji(_ reaction: String) -> String { names[reaction] ?? reaction }

    /// What a notice says of [count] messages that came while it was not looked at.
    static func many(_ count: Int, _ language: String) -> String { language == "vi" ? "\(count) tin nhắn mới" : "\(count) new messages" }

    private static func cut(_ text: String) -> String {
        // By characters a person sees, like the other platforms by code points: an emoji is never split
        text.count <= previewChars ? text : String(text.prefix(previewChars))
    }

    private static let names: [String: String] = [
        "heart": "❤️", "love": "😍", "kiss": "😘", "hug": "🤗", "blush": "😊", "cool": "😎", "wink": "😉",
        "pleading": "🥺", "laugh": "😂", "rofl": "🤣", "grin": "😁", "wow": "😮", "mindblown": "🤯",
        "think": "🤔", "eyes": "👀", "sad": "😢", "cry": "😭", "skull": "💀", "sleepy": "😴", "fire": "🔥",
        "clap": "👏", "raise": "🙌", "party": "🥳", "hundred": "💯", "sparkles": "✨", "rocket": "🚀",
        "muscle": "💪", "thumbsup": "👍", "thumbsdown": "👎", "ok": "👌", "pray": "🙏", "music": "🎶",
        "dance": "💃", "headphones": "🎧", "mic": "🎤", "guitar": "🎸", "drum": "🥁", "speaker": "🔊",
        "replay": "🔁",
    ]
}

/// Whether the person wants notices of the chat, whether they show the message, and which rooms they keep quiet.
/// Off until they turn it on. Mirrors the settings of ChatNotifier.kt.
final class NoticeSettings {
    private let prefs: KeyValueStore
    private let now: () -> Int64

    init(prefs: KeyValueStore, now: @escaping () -> Int64) {
        self.prefs = prefs
        self.now = now
    }

    var enabled: Bool {
        get { prefs.bool("notices_enabled") ?? false }
        set { prefs.set(newValue, for: "notices_enabled") }
    }

    var preview: Bool {
        get { prefs.bool("notices_preview") ?? true }
        set { prefs.set(newValue, for: "notices_preview") }
    }

    /// The rooms kept quiet and until when (milliseconds since 1970); those whose time has passed are let go.
    func mutes() -> [String: Int64] {
        guard let text = prefs.string("notices_mutes"), let data = text.data(using: .utf8),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        let current = now()
        var out: [String: Int64] = [:]
        for (room, until) in saved {
            if let number = (until as? NSNumber)?.int64Value, number > current { out[room] = number }
        }
        return out
    }

    /// Keeps room [code] quiet until [until], or with nil makes it loud again.
    func mute(_ code: String, until: Int64?) {
        var saved = mutes()
        saved[code] = until
        let object = saved.mapValues { NSNumber(value: $0) }
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        prefs.set(String(decoding: data, as: UTF8.self), for: "notices_mutes")
    }

    func isMuted(_ room: String) -> Bool { mutes()[room] != nil }
}
