//
//  DrivePasswords.swift
//  DriveGuard
//

import Foundation
import Security

/// Passwords for encrypted drives, kept in the user's own keychain (never in DriveGuard's settings,
/// never in the log). One entry per drive, keyed by the drive's key.
nonisolated enum DrivePasswords {
    private static let service = "vault.DriveGuard.drive-password"

    private static func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id]
    }

    /// Whether a password is saved. Asks for attributes only, so it never needs the password itself.
    static func has(_ id: String) -> Bool {
        var q = query(id)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess
    }

    /// The saved password, read only at the moment a locked drive has to be unlocked.
    static func read(_ id: String) -> String? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ password: String, for id: String, label: String) -> Bool {
        remove(id)
        var q = query(id)
        q[kSecAttrLabel as String] = label
        q[kSecValueData as String] = Data(password.utf8)
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func remove(_ id: String) {
        SecItemDelete(query(id) as CFDictionary)
    }
}
