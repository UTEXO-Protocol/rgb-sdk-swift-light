import CryptoKit
import Darwin
import Foundation
import Security

/// One authenticated snapshot, plus a device-bound Keychain commit anchor. The anchor
/// detects rollback/deletion as well as ciphertext tampering. This is deliberately
/// internal: an app should never compose transaction persistence itself.
actor EncryptedOperationJournal: OperationJournal {
    static let maximumSnapshotBytes = 64 * 1_024 * 1_024
    static let maximumCheckpointCount = 100_000
    static let snapshotName = "operations.v1.aesgcm"

    private let walletID: WalletID
    private let network: Network
    private let authenticatedContext: Data
    private let storageBinding: String
    private let keyStore: any JournalKeyStore
    private let files: JournalFiles
    private var closed = false

    private struct Snapshot: Codable {
        var version: UInt32 = 1
        var signerIdentity: String?
        var gatewayUserID: String?
        var checkpoints: [String: Data] = [:]
    }

    init(
        configuration: WalletConfiguration,
        serviceURL: URL,
        storage: WalletStorageConfiguration,
        keyStore override: (any JournalKeyStore)? = nil,
        fileFaultInjector: (any JournalFileFaultInjector)? = nil
    ) throws {
        walletID = configuration.walletID
        network = configuration.network
        let scope = try Self.context([
            "walletID": walletID.value, "network": network.rawValue,
            "keychainService": storage.keychainService,
        ])
        let account = Self.digest(scope)
        authenticatedContext = try Self.context([
            "domain": "utexo.swift.operation-journal.v1",
            "walletID": walletID.value, "network": network.rawValue,
            "keychainService": storage.keychainService, "serviceURL": serviceURL.absoluteString,
        ])
        files = try JournalFiles(
            directory: storage.directory.appendingPathComponent(account, isDirectory: true),
            ownershipScope: Self.digest(scope),
            faultInjector: fileFaultInjector
        )
        storageBinding = stableJournalStorageBinding(directory: files.directory)
        keyStore = override ?? KeychainJournalKeyStore(service: storage.keychainService, account: account)
        do {
            if let key = try keyStore.load() {
                _ = try Self.readSnapshot(
                    files: files, keyStore: keyStore, key: key,
                    storageBinding: storageBinding, context: authenticatedContext
                )
            } else {
                // An encrypted file or commit marker without its key is never a new wallet.
                guard try files.read(Self.snapshotName) == nil,
                      !files.hasProvisioningMarker() else { throw SDKError.operationJournalUnavailable }
                var keyBytes = Data(count: 32)
                let status = keyBytes.withUnsafeMutableBytes {
                    SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
                }
                guard status == errSecSuccess else { throw SDKError.operationJournalUnavailable }
                defer { keyBytes.resetBytes(in: keyBytes.startIndex..<keyBytes.endIndex) }
                let data = try Self.seal(Snapshot(), key: keyBytes, context: authenticatedContext)
                var record = JournalKeyRecord(
                    key: keyBytes, storageBinding: storageBinding,
                    committedDigest: nil, pendingDigest: Self.digest(data), bootstrapSnapshot: data
                )
                try keyStore.create(record)
                try files.writeProvisioningMarker()
                try files.replace(Self.snapshotName, with: data)
                record.committedDigest = record.pendingDigest
                record.pendingDigest = nil
                record.bootstrapSnapshot = nil
                try keyStore.update(record)
            }
        } catch {
            files.close()
            throw SDKError.operationJournalUnavailable
        }
    }

    func bindSignerIdentity(_ identity: WalletIdentity) throws {
        try requireOpen()
        guard identity.network == network else { throw SDKError.operationJournalUnavailable }
        let digest = Self.digest(try Self.context([
            "network": identity.network.rawValue, "profile": identity.derivationProfile,
            "fingerprint": identity.masterFingerprint, "xpub": identity.xpub,
            "vanilla": identity.accountXpubVanilla, "colored": identity.accountXpubColored,
        ]))
        var (snapshot, key) = try read()
        if let existing = snapshot.signerIdentity {
            // A different seed is permanent, not a retryable storage failure.
            guard existing == digest else {
                throw SDKError.invalidState(operation: "unlock", state: "bound to different wallet key material")
            }
            return
        }
        guard snapshot.checkpoints.isEmpty else { throw SDKError.operationJournalUnavailable }
        snapshot.signerIdentity = digest
        try persist(snapshot, key: &key)
    }

    func bindGatewayUserID(_ userID: String) throws {
        try requireOpen()
        guard try requireProtocolIdentifier(userID, field: "gatewayUserId") == userID else {
            throw SDKError.operationJournalUnavailable
        }
        var (snapshot, key) = try read()
        if let existing = snapshot.gatewayUserID {
            // Another gateway account is permanent, not a retryable storage failure.
            guard existing == userID else {
                throw SDKError.invalidState(operation: "initialize", state: "bound to a different service or account")
            }
            return
        }
        guard snapshot.checkpoints.isEmpty else { throw SDKError.operationJournalUnavailable }
        snapshot.gatewayUserID = userID
        try persist(snapshot, key: &key)
    }

    func load(walletID: WalletID, idempotencyKey: IdempotencyKey) throws -> OperationCheckpoint? {
        try requireOpen()
        guard walletID == self.walletID else { throw SDKError.operationJournalUnavailable }
        let (snapshot, _) = try read()
        guard let data = snapshot.checkpoints[idempotencyKey.value] else { return nil }
        let checkpoint = try OperationCheckpointCodec.decode(data)
        try validateScope(checkpoint)
        guard checkpoint.idempotencyKey == idempotencyKey else { throw SDKError.operationJournalUnavailable }
        return checkpoint
    }

    func save(_ checkpoint: OperationCheckpoint) throws {
        try requireOpen()
        try validateScope(checkpoint)
        var (snapshot, key) = try read()
        guard snapshot.signerIdentity != nil, snapshot.gatewayUserID != nil else {
            throw SDKError.operationJournalUnavailable
        }
        if let data = snapshot.checkpoints[checkpoint.idempotencyKey.value] {
            let current = try OperationCheckpointCodec.decode(data)
            try validateCheckpointTransition(from: current, to: checkpoint)
            if try current == checkpoint.compactTerminal { return }
        }
        guard snapshot.checkpoints[checkpoint.idempotencyKey.value] != nil
                || snapshot.checkpoints.count < Self.maximumCheckpointCount else {
            throw SDKError.operationJournalUnavailable
        }
        snapshot.checkpoints[checkpoint.idempotencyKey.value] = try OperationCheckpointCodec.encode(
            checkpoint.compactTerminal
        )
        try persist(snapshot, key: &key)
    }

    func close() {
        closed = true
        files.close()
    }

    private func requireOpen() throws {
        guard !closed else { throw SDKError.operationJournalUnavailable }
    }

    private func validateScope(_ checkpoint: OperationCheckpoint) throws {
        guard checkpoint.walletID == walletID,
              checkpoint.preparedTransaction.map({ $0.network == network }) ?? true else {
            throw SDKError.operationJournalUnavailable
        }
    }

    private func read() throws -> (Snapshot, JournalKeyRecord) {
        do {
            guard let key = try keyStore.load() else { throw SDKError.operationJournalUnavailable }
            return try Self.readSnapshot(
                files: files, keyStore: keyStore, key: key,
                storageBinding: storageBinding, context: authenticatedContext
            )
        } catch { throw SDKError.operationJournalUnavailable }
    }

    private static func readSnapshot(
        files: JournalFiles, keyStore: any JournalKeyStore, key original: JournalKeyRecord,
        storageBinding: String, context: Data
    ) throws -> (Snapshot, JournalKeyRecord) {
        var key = original
        guard key.version == 1, key.key.count == 32, key.storageBinding == storageBinding else {
            throw SDKError.operationJournalUnavailable
        }
        let data: Data
        let restoreBootstrap: Bool
        if let existing = try files.read(snapshotName) {
            data = existing
            restoreBootstrap = false
        } else if key.committedDigest == nil, let bootstrap = key.bootstrapSnapshot {
            // Only a never-committed empty journal may finish an interrupted bootstrap.
            // The exact original ciphertext/key are retained; no replacement key is made.
            data = bootstrap
            restoreBootstrap = true
        } else { throw SDKError.operationJournalUnavailable }
        let hash = digest(data)
        guard hash == key.committedDigest || hash == key.pendingDigest else {
            throw SDKError.operationJournalUnavailable
        }
        var plaintext = try AES.GCM.open(
            AES.GCM.SealedBox(combined: data), using: SymmetricKey(data: key.key), authenticating: context
        )
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: plaintext)
        guard (1...2).contains(snapshot.version),
              snapshot.checkpoints.count <= maximumCheckpointCount else {
            throw SDKError.operationJournalUnavailable
        }
        if key.bootstrapSnapshot != nil {
            guard key.committedDigest == nil, snapshot.checkpoints.isEmpty,
                  snapshot.signerIdentity == nil, snapshot.gatewayUserID == nil else {
                throw SDKError.operationJournalUnavailable
            }
            if restoreBootstrap {
                try files.writeProvisioningMarker()
                try files.replace(snapshotName, with: data)
            }
        }
        // A crash can leave either the old file or the fully persisted new file.
        // No caller may submit until save returns, after the final anchor commit.
        if key.pendingDigest != nil {
            // A process restart is not a hardware flush. A prior rename may be visible
            // even when its directory fsync failed; preserve both anchors until durable.
            try files.synchronizeDirectory()
            key.committedDigest = hash
            key.pendingDigest = nil
            key.bootstrapSnapshot = nil
            try keyStore.update(key)
        }
        return (snapshot, key)
    }

    private func persist(_ snapshot: Snapshot, key: inout JournalKeyRecord) throws {
        do {
            var upgraded = snapshot
            if upgraded.version == 1 {
                // This upgrade uses the same write-ahead anchor + atomic-file
                // protocol as every state transition. A crash retains either
                // complete v1 or complete v2; never a partially pruned history.
                for (operationKey, data) in upgraded.checkpoints {
                    let checkpoint = try OperationCheckpointCodec.decode(data)
                    try validateScope(checkpoint)
                    guard checkpoint.idempotencyKey.value == operationKey else {
                        throw SDKError.operationJournalUnavailable
                    }
                    upgraded.checkpoints[operationKey] = try OperationCheckpointCodec.encode(
                        checkpoint.compactTerminal
                    )
                }
                upgraded.version = 2
            }
            let data = try Self.seal(upgraded, key: key.key, context: authenticatedContext)
            key.pendingDigest = Self.digest(data)
            try keyStore.update(key)
            try files.replace(Self.snapshotName, with: data)
            key.committedDigest = key.pendingDigest
            key.pendingDigest = nil
            try keyStore.update(key)
        } catch { throw SDKError.operationJournalUnavailable }
    }

    private static func seal(_ snapshot: Snapshot, key: Data, context: Data) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var plaintext = try encoder.encode(snapshot)
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        guard plaintext.count <= maximumSnapshotBytes - 28,
              let ciphertext = try AES.GCM.seal(
                plaintext, using: SymmetricKey(data: key), authenticating: context
              ).combined else { throw SDKError.operationJournalUnavailable }
        return ciphertext
    }

    private static func context(_ fields: [String: String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields, options: .sortedKeys)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct JournalKeyRecord: Codable, Sendable {
    var version: UInt32 = 1
    var key: Data
    var storageBinding: String
    var committedDigest: String?
    var pendingDigest: String?
    var bootstrapSnapshot: Data? = nil
}

protocol JournalKeyStore: Sendable {
    func load() throws -> JournalKeyRecord?
    func create(_ record: JournalKeyRecord) throws
    func update(_ record: JournalKeyRecord) throws
}

/// Internal deterministic fault points for crash-consistency tests. Production
/// construction never supplies an injector, so every check compiles down to an
/// optional no-op while tests can exercise otherwise impractical ENOSPC/EIO
/// boundaries without filling or corrupting a developer's filesystem.
enum JournalFileOperation: Sendable, Equatable {
    case temporaryFileCreation
    case write
    case fileSynchronize
    case fullFileSynchronize
    case rename
    case directorySynchronize
}

protocol JournalFileFaultInjector: Sendable {
    func before(_ operation: JournalFileOperation) throws
}

private struct KeychainJournalKeyStore: JournalKeyStore {
    let service: String
    let account: String

    func load() throws -> JournalKeyRecord? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            KeychainQueryBuilder.seedRead(service: service + ".utexo-journal", account: account) as CFDictionary,
            &result
        )
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, var data = result as? Data, data.count <= 4_096 else {
            throw SDKError.operationJournalUnavailable
        }
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
        return try JSONDecoder().decode(JournalKeyRecord.self, from: data)
    }

    func create(_ record: JournalKeyRecord) throws {
        var data = try JSONEncoder().encode(record)
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
        let query = try KeychainQueryBuilder.seedWrite(
            service: service + ".utexo-journal", account: account, data: data, policy: .whenUnlocked
        )
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw SDKError.operationJournalUnavailable
        }
    }

    func update(_ record: JournalKeyRecord) throws {
        var data = try JSONEncoder().encode(record)
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
        guard SecItemUpdate(
            KeychainQueryBuilder.seedIdentity(service: service + ".utexo-journal", account: account) as CFDictionary,
            [kSecValueData: data] as CFDictionary
        ) == errSecSuccess else { throw SDKError.operationJournalUnavailable }
    }
}

/// Directory-relative POSIX operations keep all records on the locked directory inode.
/// Files are private, symlinks/hard links are rejected, and replacement is atomic and synced.
private final class JournalFiles: @unchecked Sendable {
    let directory: URL
    private let ownership: WalletStorageLease
    private let faultInjector: (any JournalFileFaultInjector)?
    private let guardLock = NSLock()
    private var directoryFD: Int32 = -1
    private var lockFD: Int32 = -1
    private let provisioningMarker = "provisioned.v1"

    init(
        directory requested: URL,
        ownershipScope: String,
        faultInjector: (any JournalFileFaultInjector)? = nil
    ) throws {
        ownership = try WalletStorageRegistry.shared.acquire(ownershipScope)
        self.faultInjector = faultInjector
        try FileManager.default.createDirectory(
            at: requested, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        // Standardization alone does not resolve symlinks. Bind the Keychain record
        // to the canonical directory, so a second location cannot open the same wallet.
        directory = requested.resolvingSymlinksInPath().standardizedFileURL
        // Open the requested final component with NOFOLLOW, before using the resolved
        // alias for identity. A malicious per-wallet symlink must not redirect chmod.
        directoryFD = Darwin.open(requested.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw SDKError.operationJournalUnavailable }
        do {
            guard fchmod(directoryFD, 0o700) == 0 else { throw SDKError.operationJournalUnavailable }
            lockFD = openat(directoryFD, "session.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lockFD >= 0, try Self.regularPrivateFile(lockFD),
                  flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
                throw SDKError.invalidState(operation: "open wallet storage", state: "already in use or unavailable")
            }
            var excluded = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path
            )
            #endif
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    func close() {
        guardLock.withLock {
            if lockFD >= 0 { _ = Darwin.close(lockFD); lockFD = -1 }
            if directoryFD >= 0 { _ = Darwin.close(directoryFD); directoryFD = -1 }
            ownership.close()
        }
    }

    func hasProvisioningMarker() -> Bool {
        var info = stat()
        return fstatat(directoryFD, provisioningMarker, &info, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT
    }

    func writeProvisioningMarker() throws { try replace(provisioningMarker, with: Data([1])) }

    func synchronizeDirectory() throws {
        try faultInjector?.before(.directorySynchronize)
        guard directoryFD >= 0, fsync(directoryFD) == 0 else {
            throw SDKError.operationJournalUnavailable
        }
    }

    func read(_ name: String) throws -> Data? {
        guard directoryFD >= 0 else { throw SDKError.operationJournalUnavailable }
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw SDKError.operationJournalUnavailable }
        defer { _ = Darwin.close(fd) }
        guard try Self.regularPrivateFile(fd) else { throw SDKError.operationJournalUnavailable }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0,
              info.st_size <= EncryptedOperationJournal.maximumSnapshotBytes else {
            throw SDKError.operationJournalUnavailable
        }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw SDKError.operationJournalUnavailable }
                offset += count
            }
        }
        var extra: UInt8 = 0
        guard Darwin.read(fd, &extra, 1) == 0 else { throw SDKError.operationJournalUnavailable }
        return data
    }

    func replace(_ name: String, with data: Data) throws {
        guard directoryFD >= 0, data.count <= EncryptedOperationJournal.maximumSnapshotBytes else {
            throw SDKError.operationJournalUnavailable
        }
        let temporary = ".pending-" + UUID().uuidString.lowercased()
        try faultInjector?.before(.temporaryFileCreation)
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SDKError.operationJournalUnavailable }
        defer { _ = Darwin.close(fd); _ = unlinkat(directoryFD, temporary, 0) }
        try faultInjector?.before(.write)
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw SDKError.operationJournalUnavailable }
                offset += count
            }
        }
        // F_FULLFSYNC also requests a hardware-cache flush on Apple filesystems.
        try faultInjector?.before(.fileSynchronize)
        guard fsync(fd) == 0 else { throw SDKError.operationJournalUnavailable }
        try faultInjector?.before(.fullFileSynchronize)
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw SDKError.operationJournalUnavailable }
        try faultInjector?.before(.rename)
        guard renameat(directoryFD, temporary, directoryFD, name) == 0 else {
            throw SDKError.operationJournalUnavailable
        }
        try synchronizeDirectory()
    }

    private static func regularPrivateFile(_ fd: Int32) throws -> Bool {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw SDKError.operationJournalUnavailable }
        return info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1
            && info.st_uid == getuid() && info.st_mode & 0o077 == 0
    }
}

/// iOS changes the absolute sandbox container UUID on some updates/restores. Bind
/// app-owned storage to its logical relative path so a dependency update stays usable.
func stableJournalStorageBinding(
    directory: URL,
    applicationContainer: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
    applicationID: String = Bundle.main.bundleIdentifier ?? "current-application"
) -> String {
    let path = directory.resolvingSymlinksInPath().standardizedFileURL.path
    let container = applicationContainer.resolvingSymlinksInPath().standardizedFileURL.path
    let identity: String
    if path.hasPrefix(container + "/") {
        identity = "application-container\u{0}" + applicationID + "\u{0}" + String(path.dropFirst(container.count + 1))
    } else {
        identity = "external-directory\u{0}" + path
    }
    return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
}

private final class WalletStorageRegistry: @unchecked Sendable {
    static let shared = WalletStorageRegistry()
    private let lock = NSLock()
    private var active: Set<String> = []

    func acquire(_ scope: String) throws -> WalletStorageLease {
        try lock.withLock {
            guard active.insert(scope).inserted else {
                throw SDKError.invalidState(operation: "open wallet storage", state: "already in use")
            }
            return WalletStorageLease(scope: scope)
        }
    }

    func release(_ scope: String) { _ = lock.withLock { active.remove(scope) } }
}

private final class WalletStorageLease: @unchecked Sendable {
    private let lock = NSLock()
    private var scope: String?
    init(scope: String) { self.scope = scope }
    deinit { close() }
    func close() {
        lock.withLock {
            if let scope { WalletStorageRegistry.shared.release(scope) }
            scope = nil
        }
    }
}
