import Foundation
import Security

/// Access-control policy installed when a new seed item is created.
/// Reopening an existing item with a different value does not change its ACL.
/// Access control protects retrieval, not each signature in an unlocked session.
public enum KeychainAccessPolicy: Sendable, Equatable {
    case whenUnlocked
    case userPresence
    case biometryCurrentSet
}

/// Actor-isolated BIP39 seed store backed by an Apple Keychain generic-password item.
///
/// The item is device-bound, never synchronizes to iCloud Keychain, and is not
/// a Secure Enclave secp256k1 key. Biometric/passcode policy protects retrieval
/// of the seed bytes; BIP32 and secp256k1 operations happen in process memory.
/// `accessPolicy` is creation-only. This type does not silently migrate the
/// protection of an existing item. Reuse the policy used during provisioning.
public actor KeychainSeedStore: WalletKeyProvider {
    private let service: String
    private let account: String
    private let accessPolicy: KeychainAccessPolicy

    public init(service: String, walletID: WalletID, accessPolicy: KeychainAccessPolicy = .whenUnlocked) throws {
        self.service = try requireBoundedText(service, field: "keychainService", maximumUTF8Bytes: 256)
        account = walletID.value
        self.accessPolicy = accessPolicy
    }

    /// Creates a new item with this store's access policy. Existing key material
    /// and installed access control are never overwritten or upgraded.
    public func storeNew(seed: SecretSeed) throws {
        guard try !markerExists() else {
            throw SDKError.invalidState(
                operation: "store seed",
                state: "already provisioned or invalidated; delete or restore explicitly"
            )
        }
        var seedBytes = try seed.withCopy { $0 }
        defer { wipe(&seedBytes) }
        var data = Data(seedBytes)
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }

        var query = try KeychainQueryBuilder.seedWrite(
            service: service,
            account: account,
            data: data,
            policy: accessPolicy
        )
        let status = SecItemAdd(query as CFDictionary, nil)
        query.removeAll(keepingCapacity: false)
        if status == errSecDuplicateItem {
            throw SDKError.invalidState(operation: "store seed", state: "already exists")
        }
        guard status == errSecSuccess else { throw SDKError.keychainUnavailable(status: status) }

        let markerStatus = SecItemAdd(
            KeychainQueryBuilder.markerWrite(service: service, account: account) as CFDictionary,
            nil
        )
        guard markerStatus == errSecSuccess || markerStatus == errSecDuplicateItem else {
            SecItemDelete(KeychainQueryBuilder.seedIdentity(service: service, account: account) as CFDictionary)
            throw SDKError.keychainUnavailable(status: markerStatus)
        }
    }

    /// Derives, stores, and promptly closes a seed without exposing seed bytes.
    public func provisionNew(
        mnemonic: SecretMnemonic,
        passphraseUTF8: [UInt8] = []
    ) throws {
        let seed = try deriveSeedFromMnemonic(
            mnemonic: mnemonic,
            passphraseUTF8: passphraseUTF8
        )
        defer { seed.close() }
        try storeNew(seed: seed)
    }

    public func loadSeed(parameters: WalletUnlockParameters) async throws -> SecretSeed {
        guard parameters.isPasswordless else {
            throw SDKError.invalidArgument(
                "password",
                "KeychainSeedStore uses operating-system authentication, not a wallet password"
            )
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            KeychainQueryBuilder.seedRead(service: service, account: account) as CFDictionary,
            &result
        )
        switch status {
        case errSecSuccess:
            guard var data = result as? Data, data.count == SecretSeed.byteCount else {
                throw SDKError.invariant("Keychain returned malformed seed data")
            }
            defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
            var bytes = Array(data)
            defer { wipe(&bytes) }
            return try SecretSeed(copying: bytes)
        case errSecItemNotFound:
            throw try markerExists() ? SDKError.keyMaterialInvalidated : SDKError.keyMaterialNotFound
        case errSecAuthFailed, errSecUserCanceled:
            throw SDKError.keychainAuthenticationFailed
        default:
            throw SDKError.keychainUnavailable(status: status)
        }
    }

    /// Explicitly deletes this wallet's seed and invalidation marker.
    public func delete() throws {
        let seedStatus = SecItemDelete(
            KeychainQueryBuilder.seedIdentity(service: service, account: account) as CFDictionary
        )
        guard seedStatus == errSecSuccess || seedStatus == errSecItemNotFound else {
            throw SDKError.keychainUnavailable(status: seedStatus)
        }
        let markerStatus = SecItemDelete(
            KeychainQueryBuilder.markerIdentity(service: service, account: account) as CFDictionary
        )
        guard markerStatus == errSecSuccess || markerStatus == errSecItemNotFound else {
            throw SDKError.keychainUnavailable(status: markerStatus)
        }
    }

    private func markerExists() throws -> Bool {
        let status = SecItemCopyMatching(
            KeychainQueryBuilder.markerRead(service: service, account: account) as CFDictionary,
            nil
        )
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw SDKError.keychainUnavailable(status: status) }
        return true
    }
}

enum KeychainQueryBuilder {
    static func seedIdentity(service: String, account: String) -> [CFString: Any] {
        base(service: service, account: account)
    }

    static func seedRead(service: String, account: String) -> [CFString: Any] {
        var query = base(service: service, account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        return query
    }

    static func seedWrite(
        service: String,
        account: String,
        data: Data,
        policy: KeychainAccessPolicy
    ) throws -> [CFString: Any] {
        var query = base(service: service, account: account)
        query[kSecValueData] = data
        switch policy {
        case .whenUnlocked:
            query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case .userPresence, .biometryCurrentSet:
            let flags: SecAccessControlCreateFlags = policy == .userPresence
                ? .userPresence
                : .biometryCurrentSet
            var error: Unmanaged<CFError>?
            guard let control = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                flags,
                &error
            ) else {
                throw SDKError(
                    code: .keyAccessFailed,
                    message: "Unable to create Keychain access control"
                )
            }
            query[kSecAttrAccessControl] = control
        }
        return query
    }

    static func markerIdentity(service: String, account: String) -> [CFString: Any] {
        base(service: service + ".utexo-seed-marker", account: account)
    }

    static func markerRead(service: String, account: String) -> [CFString: Any] {
        var query = markerIdentity(service: service, account: account)
        query[kSecMatchLimit] = kSecMatchLimitOne
        return query
    }

    static func markerWrite(service: String, account: String) -> [CFString: Any] {
        var query = markerIdentity(service: service, account: account)
        query[kSecValueData] = Data([1])
        query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return query
    }

    private static func base(service: String, account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
            kSecUseDataProtectionKeychain: true,
        ]
    }
}
