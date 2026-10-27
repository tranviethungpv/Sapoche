import XCTest
@testable import SapocheCore

final class ChatCipherTests: XCTestCase {
    private func unbase64url(_ text: String) -> Data {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base += String(repeating: "=", count: (4 - base.count % 4) % 4)
        return Data(base64Encoded: base)!
    }

    private func vectors() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: fixture("e2ee_vectors")) as! [String: Any]
    }

    func testDerivesTheKeysTheOtherPlatformsDerive() throws {
        let v = try vectors()
        let secret = unbase64url(v["secret"] as! String)
        let code = v["code"] as! String
        let keys = v["keys"] as! [String: String]
        for epoch in [1, 2] {
            let hex = ChatCipher.keyBytes(secret: secret, room: code, epoch: epoch).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hex, keys["\(epoch)"])
        }
        // The code is the room's name, however it was typed
        XCTAssertEqual(ChatCipher.keyBytes(secret: secret, room: code), ChatCipher.keyBytes(secret: secret, room: code.lowercased()))
    }

    func testSealsWhatTheOtherPlatformsSealAndOpensWhatTheySealed() throws {
        let v = try vectors()
        let secret = unbase64url(v["secret"] as! String)
        let code = v["code"] as! String
        for c in v["cases"] as! [[String: Any]] {
            let by = c["by"] as! String
            let preview = (c["kind"] as! String) == "pv"
            let plaintext = unbase64url(c["plaintext"] as! String)
            let envelope = c["envelope"] as! String
            XCTAssertEqual(
                ChatCipher.seal(secret: secret, room: code, by: by, plaintext: plaintext, preview: preview, epoch: c["epoch"] as! Int,
                                nonce: unbase64url(c["nonce"] as! String)),
                envelope
            )
            XCTAssertEqual(ChatCipher.open(secret: secret, room: code, by: by, envelope: envelope, preview: preview), plaintext)
        }
    }

    func testWillNotOpenAMessageForAnotherSenderRoomSecretOrKindOrOneThatWasTouched() throws {
        let v = try vectors()
        let secret = unbase64url(v["secret"] as! String)
        let code = v["code"] as! String
        let first = (v["cases"] as! [[String: Any]])[0]
        let by = first["by"] as! String
        let envelope = first["envelope"] as! String
        XCTAssertNotNil(ChatCipher.open(secret: secret, room: code, by: by, envelope: envelope))
        XCTAssertNil(ChatCipher.open(secret: secret, room: code, by: "0a1b2c3d4e5f6071", envelope: envelope))
        XCTAssertNil(ChatCipher.open(secret: secret, room: "XYZ789", by: by, envelope: envelope))
        XCTAssertNil(ChatCipher.open(secret: ChatCipher.newSecret(), room: code, by: by, envelope: envelope))
        XCTAssertNil(ChatCipher.open(secret: secret, room: code, by: by, envelope: envelope, preview: true))
        var bytes = unbase64url(envelope)
        bytes[bytes.count - 1] ^= 1
        let touched = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertNil(ChatCipher.open(secret: secret, room: code, by: by, envelope: touched))
        XCTAssertNil(ChatCipher.open(secret: secret, room: code, by: by, envelope: "not an envelope"))
        XCTAssertNil(ChatCipher.open(secret: secret, room: code, by: by, envelope: ""))
    }

    func testAMessageWithItsQuoteGoesThroughTheRoomAndComesBackReadable() throws {
        let secret = ChatCipher.newSecret()
        let quote = ChatQuote(id: 4, by: "b9f77f9b6e1bf750", name: "Bình", text: "cũ hơn")
        let text = "Xin chào 🌸 \"quoted\" a/b"
        let sealed = try XCTUnwrap(ChatCipher.sealMessage(secret: secret, room: "ABC234", by: "a1", text: text, quote: quote))
        XCTAssertNotEqual(sealed.ct, sealed.pv)
        let arrived = ChatMessage(id: 7, by: "a1", name: "Ann", text: "", at: 5, ct: sealed.ct, pv: sealed.pv)
        let read = try XCTUnwrap(ChatCipher.openMessage(secret: secret, room: "ABC234", message: arrived))
        XCTAssertEqual(read.text, text)
        XCTAssertEqual(read.re, quote)
        XCTAssertFalse(read.locked)
        XCTAssertEqual(ChatCipher.open(secret: secret, room: "ABC234", by: "a1", envelope: sealed.pv, preview: true).map { String(decoding: $0, as: UTF8.self) }, text)
        // The same words are never sealed the same way twice, and their length says little
        let again = try XCTUnwrap(ChatCipher.sealMessage(secret: secret, room: "ABC234", by: "a1", text: text, quote: quote))
        XCTAssertNotEqual(sealed.ct, again.ct)
        let short = try XCTUnwrap(ChatCipher.sealMessage(secret: secret, room: "ABC234", by: "a1", text: "a", quote: nil))
        let longer = try XCTUnwrap(ChatCipher.sealMessage(secret: secret, room: "ABC234", by: "a1", text: String(repeating: "a", count: 20), quote: nil))
        XCTAssertEqual(short.ct.count, longer.ct.count)
        // Not sealed, or sealed for somebody else: nothing to read
        var other = arrived
        other.by = "other"
        XCTAssertNil(ChatCipher.openMessage(secret: secret, room: "ABC234", message: other))
        var plain = arrived
        plain.ct = nil
        XCTAssertNil(ChatCipher.openMessage(secret: secret, room: "ABC234", message: plain))
    }

    func testAPreviewIsCutTo120Characters() throws {
        let secret = ChatCipher.newSecret()
        let sealed = try XCTUnwrap(ChatCipher.sealMessage(secret: secret, room: "ABC234", by: "a1", text: String(repeating: "é", count: 300), quote: nil))
        let preview = try XCTUnwrap(ChatCipher.open(secret: secret, room: "ABC234", by: "a1", envelope: sealed.pv, preview: true))
        XCTAssertEqual(String(decoding: preview, as: UTF8.self), String(repeating: "é", count: 120))
    }

    func testASecretIsWrittenAndReadAsBase64urlAndOnly32BytesAreOne() {
        let made = ChatCipher.newSecret()
        XCTAssertEqual(made.count, 32)
        XCTAssertEqual(ChatCipher.decodeSecret(ChatCipher.encodeSecret(made)), made)
        XCTAssertNil(ChatCipher.decodeSecret("abc"))
        XCTAssertNil(ChatCipher.decodeSecret(""))
        XCTAssertEqual(ChatCipher.encodeSecret(made).count, 43)
    }
}
