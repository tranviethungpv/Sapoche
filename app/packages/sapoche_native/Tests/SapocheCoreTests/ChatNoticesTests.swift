import XCTest
@testable import SapocheCore

final class ChatNoticesTests: XCTestCase {
    private func message(_ id: Int64, _ by: String, _ text: String, re: ChatQuote? = nil, rx: [String: String] = [:]) -> ChatMessage {
        ChatMessage(id: id, by: by, name: by.uppercased(), text: text, at: 0, re: re, rx: rx)
    }

    func testAMessageOfSomebodyElseIsANoticeAndOneOfThisDeviceIsNot() {
        XCTAssertEqual(ChatNotices.forMessage(message(1, "b", "hello"), room: "ROOM", you: "me"),
                       ChatNotice(kind: .chat, room: "ROOM", name: "B", text: "hello"))
        XCTAssertNil(ChatNotices.forMessage(message(2, "me", "mine"), room: "ROOM", you: "me"))
    }

    func testAnAnswerToAMessageOfThisDeviceIsToldAsAnAnswerAndOneToAnotherIsNot() {
        let toMe = ChatQuote(id: 1, by: "me", name: "Me", text: "q")
        let toOther = ChatQuote(id: 1, by: "c", name: "C", text: "q")
        XCTAssertEqual(ChatNotices.forMessage(message(3, "b", "a", re: toMe), room: "ROOM", you: "me")?.kind, .reply)
        XCTAssertEqual(ChatNotices.forMessage(message(4, "b", "a", re: toOther), room: "ROOM", you: "me")?.kind, .chat)
    }

    func testALongMessageIsCutTo120CharactersNotInTheMiddleOfAnEmoji() {
        let cut = ChatNotices.forMessage(message(5, "b", String(repeating: "🍕", count: 130)), room: "ROOM", you: "me")?.text
        XCTAssertEqual(cut?.count, 120)
    }

    func testANewReactionToAMessageOfThisDeviceIsANoticeWithTheNameOfWhoGaveIt() {
        let before = message(1, "me", "song?")
        var after = before
        after.rx = ["b": "fire"]
        XCTAssertEqual(ChatNotices.forUpdate(before: before, after: after, room: "ROOM", you: "me") { $0 == "b" ? "Bea" : nil },
                       ChatNotice(kind: .react, room: "ROOM", name: "Bea", text: "song?", emoji: "🔥"))
    }

    func testAReactionThatWasThereOneTakenAwayOneOfThisDeviceAndOneToAnotherMessageAreNoNews() {
        var mine = message(1, "me", "x")
        mine.rx = ["b": "fire"]
        var same = mine
        same.rx = ["b": "fire"]
        XCTAssertNil(ChatNotices.forUpdate(before: mine, after: same, room: "ROOM", you: "me") { _ in "Bea" })
        var taken = mine
        taken.rx = [:]
        XCTAssertNil(ChatNotices.forUpdate(before: mine, after: taken, room: "ROOM", you: "me") { _ in "Bea" })
        var own = mine
        own.rx = ["b": "fire", "me": "heart"]
        XCTAssertNil(ChatNotices.forUpdate(before: mine, after: own, room: "ROOM", you: "me") { _ in "Bea" })
        var theirs = message(2, "b", "y")
        theirs.rx = ["c": "fire"]
        XCTAssertNil(ChatNotices.forUpdate(before: message(2, "b", "y"), after: theirs, room: "ROOM", you: "me") { _ in "Cy" })
    }

    func testAChangedReactionCountsAndAnEmojiSentAsItIsStaysItself() {
        var before = message(1, "me", "x")
        before.rx = ["b": "fire"]
        var after = before
        after.rx = ["b": "🙃"]
        XCTAssertEqual(ChatNotices.forUpdate(before: before, after: after, room: "ROOM", you: "me") { _ in "Bea" }?.emoji, "🙃")
    }

    func testTheWordsFollowTheLanguageAndThePreviewCanBeLeftOut() {
        let chat = ChatNotice(kind: .chat, room: "R", name: "Bea", text: "hi")
        XCTAssertEqual(chat.title("en"), "Bea")
        XCTAssertEqual(chat.body("en", preview: true), "hi")
        XCTAssertEqual(chat.body("en", preview: false), "sent a message")
        XCTAssertEqual(chat.body("vi", preview: false), "đã gửi một tin nhắn")
        let reply = ChatNotice(kind: .reply, room: "R", name: "Bea", text: "yes")
        XCTAssertEqual(reply.title("en"), "Bea replied to you")
        XCTAssertEqual(reply.title("vi"), "Bea đã trả lời bạn")
        XCTAssertEqual(reply.body("en", preview: false), "")
        let react = ChatNotice(kind: .react, room: "R", name: "Bea", text: "song?", emoji: "🔥")
        XCTAssertEqual(react.title("en"), "Bea reacted 🔥 to your message")
        XCTAssertEqual(react.title("vi"), "Bea đã thả 🔥 vào tin của bạn")
        XCTAssertEqual(ChatNotices.many(3, "en"), "3 new messages")
        XCTAssertEqual(ChatNotices.many(3, "vi"), "3 tin nhắn mới")
    }

    func testTheSettingsAreOffAndLoudByDefaultAndForgetAQuietThatHasPassed() {
        var now: Int64 = 1_000
        let settings = NoticeSettings(prefs: MemoryStore()) { now }
        XCTAssertFalse(settings.enabled)
        XCTAssertTrue(settings.preview)
        settings.mute("ABC234", until: 5_000)
        settings.mute("XYZ789", until: 500)
        XCTAssertEqual(settings.mutes(), ["ABC234": 5_000])
        XCTAssertTrue(settings.isMuted("ABC234"))
        now = 6_000
        XCTAssertFalse(settings.isMuted("ABC234"))
        settings.mute("ABC234", until: 9_000)
        settings.mute("ABC234", until: nil)
        XCTAssertTrue(settings.mutes().isEmpty)
    }
}
