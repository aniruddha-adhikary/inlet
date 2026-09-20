import CryptoKit
import Foundation
import Security

/// Encryption for message content at rest. One random 256-bit key, created on
/// first launch and kept in the login keychain, readable only by this app.
/// Payloads are sealed with AES-GCM; content hashes are keyed (HMAC) so a copy
/// of the database can't be used to test guesses about what a message says.
nonisolated final class Vault: Sendable {
    enum VaultError: Error { case keychain(OSStatus), corrupt }

    static let shared = Vault()

    private let key: SymmetricKey

    private init() {
        do {
            key = try Self.loadOrCreateKey()
        } catch {
            // Without the keychain there is no safe way to persist content. Use a
            // process-lifetime key: the app still works, nothing readable survives a relaunch.
            DebugLog.write("vault: keychain unavailable (\(error)); using an ephemeral key")
            key = SymmetricKey(size: .bits256)
        }
    }

    private static let service = (Bundle.main.bundleIdentifier ?? "inlet") + ".vault"
    private static let account = "content-key-v1"

    private static func loadOrCreateKey() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var item: CFTypeRef?
        var lookup = query
        lookup[kSecReturnData as String] = true
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound || status == errSecSuccess else { throw VaultError.keychain(status) }

        let fresh = SymmetricKey(size: .bits256)
        var add = query
        add[kSecValueData as String] = fresh.withUnsafeBytes { Data($0) }
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        SecItemDelete(query as CFDictionary)
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw VaultError.keychain(added) }
        return fresh
    }

    func seal(_ plaintext: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: key).combined else { throw VaultError.corrupt }
        return combined
    }

    func open(_ sealed: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key)
    }

    func keyedHash(_ data: Data) -> String {
        HMAC<SHA256>.authenticationCode(for: data, using: key).map { String(format: "%02x", $0) }.joined()
    }

    /// Destroys the key: everything sealed with it becomes unreadable for good.
    static func destroyKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
