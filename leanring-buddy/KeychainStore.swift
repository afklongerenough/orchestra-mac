//
//  KeychainStore.swift
//  leanring-buddy
//
//  Tiny wrapper around the macOS Keychain for the secrets Orchestra needs
//  (Gemini API key, Hermes bridge token). Nothing secret ever ships in the
//  app binary or lands in UserDefaults.
//

import Foundation
import Security

enum KeychainStore {
    private static let service = "com.paulsabyss.orchestra"

    enum Key: String {
        case geminiAPIKey = "gemini-api-key"
        case hermesBridgeToken = "hermes-bridge-token"
        case spotifyClientID = "spotify-client-id"
        case spotifyClientSecret = "spotify-client-secret"
        case openCodeAPIKey = "opencode-api-key"
    }

    static func read(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    static func write(_ value: String, for key: Key) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        delete(key)
        guard !trimmed.isEmpty else { return true }

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ key: Key) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }
}
