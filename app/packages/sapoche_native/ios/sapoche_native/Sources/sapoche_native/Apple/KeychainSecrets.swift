import Foundation
import Security

/// The secrets of the rooms with end-to-end encrypted chat, kept in the Keychain: they stay on this phone, are not in its
/// backups to other devices, and can be read once the phone has been unlocked after it started (the room is joined by
/// the app while the phone is locked, playing).
final class KeychainSecrets: RoomSecretStore {
    private let service = "app.sapoche.room-secrets"

    private func query(_ room: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: room.uppercased()]
    }

    func secret(for room: String) -> Data? {
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query(room).merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 } as CFDictionary, &found)
        return status == errSecSuccess ? found as? Data : nil
    }

    func save(_ secret: Data, for room: String) {
        SecItemDelete(query(room) as CFDictionary)
        let item = query(room).merging([
            kSecValueData as String: secret,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { $1 }
        SecItemAdd(item as CFDictionary, nil)
    }
}
