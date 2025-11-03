import Foundation
import Security
import CryptoKit

/// Manages encryption keys stored in the macOS Keychain
///
/// PRIVACY: This class manages the AES-256 encryption key used to protect
/// user transcripts at rest. The key is stored in macOS Keychain and never
/// leaves the device. All transcript data is encrypted before being written
/// to disk, ensuring privacy even if the file system is compromised.
class KeychainManager {
    static let shared = KeychainManager()

    private let logger = Logger.shared
    private let service = "com.transcribe.encryption"
    private let account = "transcript-encryption-key"

    private init() {}

    // MARK: - Public API

    /// Retrieves or generates the encryption key
    /// - Returns: 256-bit symmetric encryption key
    func getEncryptionKey() throws -> SymmetricKey {
        // Try to retrieve existing key first
        if let existingKey = try? retrieveKey() {
            logger.debug("Retrieved existing encryption key from Keychain", category: .file)
            return existingKey
        }

        // No existing key - generate new one
        logger.info("Generating new encryption key (first launch)", category: .file)
        let newKey = SymmetricKey(size: .bits256)
        try storeKey(newKey)
        logger.info("✅ Encryption key generated and stored in Keychain", category: .file)

        return newKey
    }

    // MARK: - Private Methods

    /// Store a symmetric key in the Keychain
    private func storeKey(_ key: SymmetricKey) throws {
        // Convert key to Data
        let keyData = key.withUnsafeBytes { Data($0) }

        // Create Keychain query
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        // Delete any existing key first
        SecItemDelete(query as CFDictionary)

        // Add new key
        let status = SecItemAdd(query as CFDictionary, nil)

        guard status == errSecSuccess else {
            logger.error("Failed to store encryption key in Keychain: \(status)", category: .file)
            throw KeychainError.storeFailed(status)
        }

        logger.debug("Stored encryption key in Keychain", category: .file)
    }

    /// Retrieve a symmetric key from the Keychain
    private func retrieveKey() throws -> SymmetricKey {
        // Create Keychain query
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        // Retrieve key data
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.keyNotFound
            }
            logger.error("Failed to retrieve encryption key from Keychain: \(status)", category: .file)
            throw KeychainError.retrieveFailed(status)
        }

        guard let keyData = result as? Data else {
            logger.error("Retrieved key data is not Data type", category: .file)
            throw KeychainError.invalidKeyData
        }

        // Convert Data back to SymmetricKey
        let key = SymmetricKey(data: keyData)
        return key
    }
}

// MARK: - Errors

enum KeychainError: LocalizedError {
    case storeFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case keyNotFound
    case invalidKeyData

    var errorDescription: String? {
        switch self {
        case .storeFailed(let status):
            return "Failed to store encryption key in Keychain (status: \(status))"
        case .retrieveFailed(let status):
            return "Failed to retrieve encryption key from Keychain (status: \(status))"
        case .keyNotFound:
            return "Encryption key not found in Keychain"
        case .invalidKeyData:
            return "Invalid key data retrieved from Keychain"
        }
    }
}
