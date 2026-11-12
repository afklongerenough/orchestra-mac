//
//  KeychainStore.swift
//  leanring-buddy
//
//  Where Orchestra keeps its secrets (Gemini / OpenCode keys, Hermes token,
//  Spotify id/secret/sign-in). Nothing secret ships in the app binary.
//
//  Why not the Keychain any more: macOS ties a Keychain item's access to the
//  app's "partition", and for apps without an Apple team ID that partition is
//  the exact build's hash. So every update made macOS ask for the login
//  password again for every secret. Secrets now live in a file only this
//  user account can read (~/Library/Application Support/Orchestra/secrets.json,
//  folder 700, file 600) — the same way tools like gh and npm keep tokens.
//  Old Keychain items are copied over the first time each one is needed
//  (that's the last password prompt for it).
//

import Foundation
import Security

enum KeychainStore {
    private static let legacyKeychainService = "com.paulsabyss.orchestra"

    enum Key: String, CaseIterable {
        case geminiAPIKey = "gemini-api-key"
        case hermesBridgeToken = "hermes-bridge-token"
        case spotifyClientID = "spotify-client-id"
        case spotifyClientSecret = "spotify-client-secret"
        case openCodeAPIKey = "opencode-api-key"
        case spotifyRefreshToken = "spotify-refresh-token"
    }

    private static let secretsLock = NSLock()
    /// Loaded once from disk, then kept in memory (guarded by secretsLock).
    private static var cachedSecrets: [String: String]?
    /// Keys whose old Keychain item was found (and moved) or doesn't exist.
    private static var legacyKeychainLookupsTried = Set<String>()
    /// After a dismissed/denied password prompt, wait before asking again.
    private static var legacyKeychainRetryAfterDateByKey: [String: Date] = [:]

    private static var secretsFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Orchestra", isDirectory: true)
            .appendingPathComponent("secrets.json")
    }

    static func read(_ key: Key) -> String? {
        secretsLock.lock()
        var secrets = loadSecretsLocked()
        if let savedValue = secrets[key.rawValue], !savedValue.isEmpty {
            secretsLock.unlock()
            return savedValue
        }
        let shouldTryLegacyKeychain = !legacyKeychainLookupsTried.contains(key.rawValue)
            && Date() >= (legacyKeychainRetryAfterDateByKey[key.rawValue] ?? .distantPast)
        secretsLock.unlock()
        guard shouldTryLegacyKeychain else { return nil }

        // One-time move from the old Keychain item (may show one last password prompt).
        let (legacyLookupStatus, legacyValue) = readLegacyKeychainItem(key)
        secretsLock.lock()
        defer { secretsLock.unlock() }
        switch legacyLookupStatus {
        case errSecSuccess:
            legacyKeychainLookupsTried.insert(key.rawValue)
            guard let legacyValue else { return nil }
            secrets = loadSecretsLocked()
            // A key typed in while the prompt was up wins over the old one.
            if let newerValue = secrets[key.rawValue], !newerValue.isEmpty { return newerValue }
            secrets[key.rawValue] = legacyValue
            saveSecretsLocked(secrets)
            return legacyValue
        case errSecItemNotFound:
            legacyKeychainLookupsTried.insert(key.rawValue)
            return nil
        default:
            // Prompt dismissed or denied: try again in 10 minutes, not on every read.
            legacyKeychainRetryAfterDateByKey[key.rawValue] = Date().addingTimeInterval(600)
            OrchestraLog.write("🔑 Couldn't read the saved \(key.rawValue) from the Keychain (status \(legacyLookupStatus)); will ask again later, or paste it again under Connections")
            return nil
        }
    }

    @discardableResult
    static func write(_ value: String, for key: Key) -> Bool {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        secretsLock.lock()
        defer { secretsLock.unlock() }
        var secrets = loadSecretsLocked()
        if trimmedValue.isEmpty {
            secrets[key.rawValue] = nil
        } else {
            secrets[key.rawValue] = trimmedValue
        }
        // A value saved here wins over anything left in the old Keychain.
        legacyKeychainLookupsTried.insert(key.rawValue)
        return saveSecretsLocked(secrets)
    }

    static func delete(_ key: Key) {
        secretsLock.lock()
        var secrets = loadSecretsLocked()
        secrets[key.rawValue] = nil
        saveSecretsLocked(secrets)
        legacyKeychainLookupsTried.insert(key.rawValue)
        secretsLock.unlock()
        deleteLegacyKeychainItem(key)
    }

    // MARK: - File (call with secretsLock held)

    private static func loadSecretsLocked() -> [String: String] {
        if let cachedSecrets { return cachedSecrets }
        var loadedSecrets: [String: String] = [:]
        if let secretsData = try? Data(contentsOf: secretsFileURL) {
            if let decodedSecrets = try? JSONDecoder().decode([String: String].self, from: secretsData) {
                loadedSecrets = decodedSecrets
            } else {
                // Never overwrite an unreadable file: set it aside so nothing is lost.
                let backupFileURL = secretsFileURL.deletingLastPathComponent()
                    .appendingPathComponent("secrets-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: secretsFileURL, to: backupFileURL)
                print("⚠️ secrets.json couldn't be read; moved it to \(backupFileURL.lastPathComponent)")
            }
        }
        cachedSecrets = loadedSecrets
        return loadedSecrets
    }

    @discardableResult
    private static func saveSecretsLocked(_ secrets: [String: String]) -> Bool {
        let folderURL = secretsFileURL.deletingLastPathComponent()
        let temporaryFileURL = folderURL.appendingPathComponent(".secrets-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryFileURL) }
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folderURL.path)
            let secretsData = try JSONEncoder().encode(secrets)
            // Write to a private temp file first, then move it in (never world-readable, never half-written).
            guard FileManager.default.createFile(atPath: temporaryFileURL.path, contents: secretsData,
                                                 attributes: [.posixPermissions: 0o600]) else { return false }
            if FileManager.default.fileExists(atPath: secretsFileURL.path) {
                _ = try FileManager.default.replaceItemAt(secretsFileURL, withItemAt: temporaryFileURL)
            } else {
                try FileManager.default.moveItem(at: temporaryFileURL, to: secretsFileURL)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretsFileURL.path)
            // Only remember what really reached the disk.
            cachedSecrets = secrets
            return true
        } catch {
            print("⚠️ Couldn't save secrets: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Old Keychain items (read once to migrate)

    private static func readLegacyKeychainItem(_ key: Key) -> (status: OSStatus, value: String?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let lookupStatus = SecItemCopyMatching(query as CFDictionary, &item)
        guard lookupStatus == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return (lookupStatus, nil)
        }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (lookupStatus, trimmedValue.isEmpty ? nil : trimmedValue)
    }

    private static func deleteLegacyKeychainItem(_ key: Key) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecAttrAccount as String: key.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }
}
