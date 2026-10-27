import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The secrets of the rooms whose chat is end-to-end encrypted, by room code. On the phone they live in the Keychain.
protocol RoomSecretStore: AnyObject {
    func secret(for room: String) -> Data?
    func save(_ secret: Data, for room: String)
}

/// Secrets kept in memory only: for the tests, and for a build with no Keychain.
final class MemorySecrets: RoomSecretStore {
    private var kept: [String: Data] = [:]

    func secret(for room: String) -> Data? { kept[room.uppercased()] }
    func save(_ secret: Data, for room: String) { kept[room.uppercased()] = secret }
}

/// End-to-end encryption of a room's chat (protocol 15). The room has one secret of 32 bytes, made on the device of its
/// owner and handed to the others in the invitation link, never through the server. The key for a message is HKDF-SHA256
/// of that secret, salted with a label and bound to the room's code and a key epoch; a message is sealed with AES-256-GCM,
/// with the sender and the room as associated data, so the server can neither move it to another room nor sign it with
/// another member's name. Mirrors ChatCipher.kt and `chat_cipher.dart`; the three read the same vectors (`e2ee_vectors.json`).
///
/// A sealed message is base64url of: version (1), epoch (1), nonce (12), ciphertext and tag. What is sealed is JSON,
/// `{"t": text, "q": the quote of the message answered}`, padded with spaces to a multiple of 64 bytes so that its length
/// says little. The preview, for a notice, is the first 120 characters sealed apart.
enum ChatCipher {
    private static let label = "sapoche-chat-v1"
    private static let version: UInt8 = 1
    private static let nonceBytes = 12
    private static let tagBytes = 16
    private static let pad = 64
    private static let previewChars = 120

    /// The epoch a new message is sealed in: one until keys can be changed.
    static let epoch = 1

    /// A new secret for a room.
    static func newSecret() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }

    static func encodeSecret(_ secret: Data) -> String { base64url(secret) }

    /// The secret in [text] (as in an invitation link), or nil when it is not one.
    static func decodeSecret(_ text: String) -> Data? {
        guard let bytes = unbase64url(text.trimmingCharacters(in: .whitespacesAndNewlines)), bytes.count == 32 else { return nil }
        return bytes
    }

    /// The key of [epoch] for room [room].
    static func key(secret: Data, room: String, epoch: Int = ChatCipher.epoch) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: Data(label.utf8),
            info: Data("\(room.uppercased())|\(epoch)".utf8),
            outputByteCount: 32
        )
    }

    /// The key as bytes: for the tests, which compare it with the other platforms'.
    static func keyBytes(secret: Data, room: String, epoch: Int = ChatCipher.epoch) -> Data {
        key(secret: secret, room: room, epoch: epoch).withUnsafeBytes { Data($0) }
    }

    private static func associated(room: String, by: String, epoch: Int, preview: Bool) -> Data {
        Data("\(label)|\(room.uppercased())|\(by)|\(epoch)\(preview ? "|pv" : "")".utf8)
    }

    /// [plaintext] sealed for [by] in [room]. [nonce] is only given by the tests.
    static func seal(secret: Data, room: String, by: String, plaintext: Data, preview: Bool = false, epoch: Int = ChatCipher.epoch,
                     nonce: Data? = nil) -> String? {
        do {
            let nonce = try nonce.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
            let box = try AES.GCM.seal(plaintext, using: key(secret: secret, room: room, epoch: epoch), nonce: nonce,
                                       authenticating: associated(room: room, by: by, epoch: epoch, preview: preview))
            return base64url(Data([version, UInt8(epoch)]) + Data(nonce) + box.ciphertext + box.tag)
        } catch {
            return nil
        }
    }

    /// What [envelope], sent by [by] in [room], holds; nil when it is not from this room's secret, this sender, or intact.
    static func open(secret: Data, room: String, by: String, envelope: String, preview: Bool = false) -> Data? {
        guard let bytes = unbase64url(envelope), bytes.count >= 2 + nonceBytes + tagBytes, bytes[bytes.startIndex] == version else { return nil }
        let start = bytes.startIndex
        let epoch = Int(bytes[start + 1])
        let nonce = bytes[(start + 2)..<(start + 2 + nonceBytes)]
        let sealed = bytes[(start + 2 + nonceBytes)...]
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: sealed.dropLast(tagBytes), tag: sealed.suffix(tagBytes))
            return try AES.GCM.open(box, using: key(secret: secret, room: room, epoch: epoch),
                                    authenticating: associated(room: room, by: by, epoch: epoch, preview: preview))
        } catch {
            return nil
        }
    }

    /// The sealed words of a message by [by], with the quote of what it answers inside, and the sealed preview.
    static func sealMessage(secret: Data, room: String, by: String, text: String, quote: ChatQuote?) -> (ct: String, pv: String)? {
        var body: [String: Any] = ["t": text]
        if let quote { body["q"] = ["id": quote.id, "by": quote.by, "name": quote.name, "text": quote.text] as [String: Any] }
        guard var bytes = try? JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes]) else { return nil }
        bytes.append(Data(repeating: 0x20, count: (pad - bytes.count % pad) % pad))
        let cut = String(String.UnicodeScalarView(text.unicodeScalars.prefix(previewChars)))
        guard let ct = seal(secret: secret, room: room, by: by, plaintext: bytes),
              let pv = seal(secret: secret, room: room, by: by, plaintext: Data(cut.utf8), preview: true) else { return nil }
        return (ct, pv)
    }

    /// [message] as the room sent it, with its words read: the text and the quote of what it answers. Nil when it is not
    /// sealed or cannot be read with [secret].
    static func openMessage(secret: Data, room: String, message: ChatMessage) -> ChatMessage? {
        guard let ct = message.ct, let body = open(secret: secret, room: room, by: message.by, envelope: ct),
              let json = JSON.parse(String(decoding: body, as: UTF8.self)), let text = json["t"].string else { return nil }
        var opened = message
        opened.text = text
        opened.re = ChatQuote(json["q"])
        opened.locked = false
        return opened
    }

    // MARK: base64url without padding

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func unbase64url(_ text: String) -> Data? {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base += String(repeating: "=", count: (4 - base.count % 4) % 4)
        return Data(base64Encoded: base)
    }
}
