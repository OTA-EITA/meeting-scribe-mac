import Foundation
import CryptoKit
import Security

/// 議事録の暗号鍵をログインキーチェーンに置く。初回に作り、以後は同じ鍵を使う。
/// この Mac でロックを解除している間だけ読め、iCloud キーチェーンには同期しない。
/// この項目を消すと、暗号化した議事録は読めなくなる。
enum TranscriptKeyStore {
    enum Failure: Error {
        case keychain(OSStatus)
    }

    private static let service = "MeetingScribe"
    private static let account = "transcript-encryption-key"

    static func key() throws -> SymmetricKey {
        if let data = try load() {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        try store(key.withUnsafeBytes { Data($0) })
        return key
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func load() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw Failure.keychain(status)
        }
        return data
    }

    private static func store(_ data: Data) throws {
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }
}
