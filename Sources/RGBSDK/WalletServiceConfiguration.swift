import Foundation
import Security

/// Short-lived API credential. Description and reflection never reveal its value.
/// The SDK closes each credential returned by a provider after building the request.
public final class WalletAPIKey: @unchecked Sendable, CustomStringConvertible, CustomReflectable {
    private let lock = NSLock()
    private var bytes: [UInt8]?

    public init(copyingUTF8 bytes: [UInt8]) throws {
        guard !bytes.isEmpty, bytes.count <= 512,
              bytes.allSatisfy({ $0 > 0x20 && $0 < 0x7f }) else {
            throw SDKError.invalidArgument("apiKey", "must be a bounded non-empty ASCII header value")
        }
        self.bytes = Array(bytes)
    }

    deinit { close() }

    public func close() {
        lock.withLock {
            if bytes != nil { wipe(&bytes!) }
            bytes = nil
        }
    }

    func withBytes<T>(_ body: (inout [UInt8]) throws -> T) throws -> T {
        var copy = try lock.withLock { () throws -> [UInt8] in
            guard let bytes else { throw SDKError.keyAccessFailed }
            return bytes
        }
        defer { wipe(&copy) }
        return try body(&copy)
    }

    public var description: String { "WalletAPIKey([REDACTED])" }
    public var customMirror: Mirror { Mirror(self, children: ["value": "[REDACTED]"]) }
}

/// Returns a fresh credential for each request, allowing rotation without rebuilding a wallet.
/// Implementations must not return a shared `WalletAPIKey`: the SDK consumes/closes it.
public protocol WalletAPIKeyProvider: Sendable {
    func loadAPIKey() async throws -> WalletAPIKey
}

/// Device-bound, non-synchronizing credential storage. Updating an existing item is explicit.
public actor KeychainAPIKeyStore: WalletAPIKeyProvider {
    private let service: String
    private let account: String

    public init(service: String, account: String) throws {
        self.service = try requireBoundedText(service, field: "keychainService", maximumUTF8Bytes: 256)
        self.account = try requireBoundedText(account, field: "credentialAccount", maximumUTF8Bytes: 128)
    }

    public func storeNew(apiKey: WalletAPIKey) throws {
        var data = try apiKey.withBytes { Data($0) }
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
        let query = try KeychainQueryBuilder.seedWrite(
            service: service + ".utexo-api-key", account: account, data: data, policy: .whenUnlocked
        )
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status != errSecDuplicateItem else {
            throw SDKError.invalidState(operation: "store API key", state: "already provisioned")
        }
        guard status == errSecSuccess else { throw SDKError.keychainUnavailable(status: status) }
    }

    /// Replaces only an existing credential. A missing item must be provisioned explicitly.
    public func replace(apiKey: WalletAPIKey) throws {
        var data = try apiKey.withBytes { Data($0) }
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
        let status = SecItemUpdate(
            KeychainQueryBuilder.seedIdentity(service: service + ".utexo-api-key", account: account) as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        guard status != errSecItemNotFound else { throw SDKError.keyMaterialNotFound }
        guard status == errSecSuccess else { throw SDKError.keychainUnavailable(status: status) }
    }

    public func loadAPIKey() async throws -> WalletAPIKey {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            KeychainQueryBuilder.seedRead(service: service + ".utexo-api-key", account: account) as CFDictionary,
            &result
        )
        guard status != errSecItemNotFound else { throw SDKError.keyMaterialNotFound }
        guard status == errSecSuccess else { throw SDKError.keychainUnavailable(status: status) }
        guard var data = result as? Data else { throw SDKError.keyAccessFailed }
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
        var bytes = Array(data)
        defer { wipe(&bytes) }
        return try WalletAPIKey(copyingUTF8: bytes)
    }
}

/// Stable app-facing service options. The full local SDK must preserve this initializer,
/// even when it no longer needs a wallet orchestration service.
public struct WalletServiceConfiguration: Sendable, CustomStringConvertible, CustomReflectable {
    public let baseURL: URL
    public let apiKeyProvider: any WalletAPIKeyProvider
    public let allowInsecureLocalDevelopment: Bool
    public let requestTimeout: TimeInterval

    public init(
        baseURL: URL,
        apiKeyProvider: any WalletAPIKeyProvider,
        allowInsecureLocalDevelopment: Bool = false,
        requestTimeout: TimeInterval = 30
    ) throws {
        // Reuse the transport policy; network-specific validation happens in the factory.
        let validated = try GatewayBackendConfiguration(
            baseURL: baseURL, apiKeyProvider: apiKeyProvider, network: .regtest,
            allowInsecureLocalDevelopment: allowInsecureLocalDevelopment,
            requestTimeout: requestTimeout
        )
        self.baseURL = validated.baseURL
        self.apiKeyProvider = apiKeyProvider
        self.allowInsecureLocalDevelopment = allowInsecureLocalDevelopment
        self.requestTimeout = requestTimeout
    }

    public var description: String { "WalletServiceConfiguration(baseURL=\(baseURL), apiKeyProvider=[REDACTED])" }
    public var customMirror: Mirror {
        Mirror(self, children: ["baseURL": baseURL.absoluteString, "apiKeyProvider": "[REDACTED]"])
    }
}

/// Storage shared by successive SDK versions. Keep this directory/service stable across upgrades.
/// Use a dedicated app/app-group container directory, or an external directory
/// the user explicitly granted the app access to. The caller maintains any
/// required security-scoped access; supplying a path does not grant permission.
public struct WalletStorageConfiguration: Sendable {
    public let directory: URL
    public let keychainService: String
    /// Match the policy used when provisioning the seed. This is not an ACL
    /// migration request; changing it cannot strengthen an existing Keychain item.
    public let seedAccessPolicy: KeychainAccessPolicy

    public init(
        directory: URL,
        keychainService: String,
        seedAccessPolicy: KeychainAccessPolicy = .whenUnlocked
    ) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/"), directory.path != "/",
              directory.host == nil || directory.host == "" || directory.host == "localhost",
              directory.user == nil, directory.password == nil, directory.port == nil,
              !directory.path.utf8.contains(0), directory.path.utf8.count <= 4_096,
              directory.query == nil, directory.fragment == nil else {
            throw SDKError.invalidArgument("directory", "must be a dedicated absolute local storage directory")
        }
        self.directory = directory.standardizedFileURL
        self.keychainService = try requireBoundedText(
            keychainService, field: "keychainService", maximumUTF8Bytes: 256
        )
        self.seedAccessPolicy = seedAccessPolicy
    }
}

/// Retains the legacy SPI token initializer without forcing app callers to retain a raw token.
struct LegacyStaticAPIKeyProvider: WalletAPIKeyProvider {
    let token: String
    func loadAPIKey() async throws -> WalletAPIKey { try WalletAPIKey(copyingUTF8: Array(token.utf8)) }
}
