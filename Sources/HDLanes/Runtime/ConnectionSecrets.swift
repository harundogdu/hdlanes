import CryptoKit
import Foundation
import HDCore
import Security

/// Connection secrets in the login Keychain (generic passwords). The service name includes a hash of
/// the hdlanes home, so a test instance (`HDLANES_HOME=/tmp/…`) never sees the real app's tokens.
/// Secrets are never logged and never written to state.json.
struct ConnectionSecrets {
    let service: String

    init(paths: HDPaths) {
        let digest = SHA256.hash(data: Data(paths.root.standardizedFileURL.path.utf8))
        service = "hdlanes.connections." + digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    func read(_ id: UUID) -> String? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func exists(_ id: UUID) -> Bool {
        var q = query(id)
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    func write(_ secret: String, for id: UUID) throws {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(id)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            add[kSecAttrLabel as String] = "hdlanes connection"
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    func delete(_ id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
    }
}

struct KeychainError: LocalizedError {
    var status: OSStatus
    var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}
