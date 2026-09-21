import Foundation
import CryptoKit
import Darwin
import Testing
@testable @_spi(Backend) import RGBSDK

@Test func encryptedJournalCompactsOnlyDefinitiveTerminalRecordsAcrossRestart() async throws {
    let fixture = try DurableJournalFixture()
    let journal = try fixture.open()
    try await fixture.bind(journal)
    let completed = try fixture.paymentCheckpoint(key: "completed", phase: .terminal, payloadBytes: 128_000)
    let ambiguous = try fixture.paymentCheckpoint(key: "ambiguous", phase: .submitting, payloadBytes: 128_000)
    try await journal.save(ambiguous)
    let pendingSize = try Data(contentsOf: fixture.snapshotURL()).count
    try await journal.save(completed)
    let compactedSize = try Data(contentsOf: fixture.snapshotURL()).count
    #expect(compactedSize < pendingSize + 4_096)
    #expect(try await journal.load(
        walletID: fixture.configuration.walletID, idempotencyKey: completed.idempotencyKey
    ) == completed.compactTerminal)
    await journal.close()
    let reopened = try fixture.open()
    #expect(try await reopened.load(
        walletID: fixture.configuration.walletID, idempotencyKey: ambiguous.idempotencyKey
    ) == ambiguous)
    #expect(try await reopened.load(
        walletID: fixture.configuration.walletID, idempotencyKey: completed.idempotencyKey
    ) == completed.compactTerminal)
    // A full replay cannot resurrect discarded payloads or replace a result.
    try await reopened.save(completed)
    #expect(try Data(contentsOf: fixture.snapshotURL()).count == compactedSize)
    await #expect(throws: SDKError.self) { try await reopened.save(fixture.checkpoint(key: "completed")) }
    await reopened.close()
}

@Test func legacySnapshotCompactionIsAtomicAndRecoversAnInterruptedAnchorCommit() async throws {
    let fixture = try DurableJournalFixture()
    let journal = try fixture.open()
    try await fixture.bind(journal)
    await journal.close()
    let fullTerminal = try fixture.paymentCheckpoint(key: "legacy-terminal", phase: .terminal)
    let submitting = try fixture.paymentCheckpoint(key: "legacy-pending", phase: .submitting)
    try fixture.installLegacySnapshot([fullTerminal, submitting])

    let upgrading = try fixture.open()
    #expect(try await upgrading.load(
        walletID: fixture.configuration.walletID, idempotencyKey: fullTerminal.idempotencyKey
    ) == fullTerminal)
    fixture.keys.failUpdate(afterSuccessfulUpdates: 1)
    await #expect(throws: SDKError.self) {
        try await upgrading.save(fixture.checkpoint(key: "migration-trigger"))
    }
    await upgrading.close()
    fixture.keys.allowUpdates()
    let reopened = try fixture.open()
    #expect(try await reopened.load(
        walletID: fixture.configuration.walletID, idempotencyKey: fullTerminal.idempotencyKey
    ) == fullTerminal.compactTerminal)
    #expect(try await reopened.load(
        walletID: fixture.configuration.walletID, idempotencyKey: submitting.idempotencyKey
    ) == submitting)
    #expect(fixture.keys.snapshot()?.pendingDigest == nil)
    await reopened.close()
}

@Test func terminalReceiptHistoryRetainsEveryIdempotencyKeyUnderSustainedUse() async throws {
    let fixture = try DurableJournalFixture()
    let journal = try fixture.open()
    try await fixture.bind(journal)
    for index in 0..<250 {
        // In aggregate the old full records would retain 64 MB of PSBT text;
        // receipts remain compact, but keys are never forgotten or reused.
        try await journal.save(fixture.paymentCheckpoint(
            key: "history-\(index)", phase: .terminal, payloadBytes: 128_000
        ))
    }
    #expect(try Data(contentsOf: fixture.snapshotURL()).count < 512_000)
    await journal.close()
    let reopened = try fixture.open()
    for index in [0, 1, 124, 249] {
        let original = try fixture.paymentCheckpoint(key: "history-\(index)", phase: .terminal)
        #expect(try await reopened.load(
            walletID: fixture.configuration.walletID, idempotencyKey: original.idempotencyKey
        ) == original.compactTerminal)
    }
    await reopened.close()
}

@Test func cancelledWalletDisposalStillReleasesExclusiveStorageOwnership() async throws {
    let fixture = try DurableJournalFixture()
    let journal = try fixture.open()
    let service = try GatewayBackendConfiguration(
        baseURL: URL(string: "https://gateway.example")!, bearerToken: "unused", network: .regtest
    )
    let wallet = UTEXOWallet(
        configuration: fixture.configuration, backend: GatewayWalletBackend(configuration: service),
        keyProvider: JournalNeverKeyProvider(), durableJournal: journal
    )
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await wallet.dispose()
    }
    try await task.value
    #expect(await wallet.isDisposed())
    let reopened = try fixture.open()
    await reopened.close()
}

@Test func encryptedJournalHoldsKernelLockUntilClose() async throws {
    let fixture = try DurableJournalFixture()
    let journal = try fixture.open()
    let lockURL = try fixture.snapshotURL().deletingLastPathComponent().appendingPathComponent("session.lock")
    let fd = Darwin.open(lockURL.path, O_RDWR | O_CLOEXEC)
    #expect(fd >= 0)
    defer { _ = Darwin.close(fd) }
    #expect(flock(fd, LOCK_EX | LOCK_NB) != 0)
    await journal.close()
    #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
}

@Test func journalBindingSurvivesApplicationContainerUUIDChanges() throws {
    let oldRoot = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/OLD-UUID")
    let newRoot = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/NEW-UUID")
    let relative = "Library/Application Support/Wallet/operations"
    let old = stableJournalStorageBinding(
        directory: oldRoot.appendingPathComponent(relative), applicationContainer: oldRoot, applicationID: "com.example.wallet"
    )
    let new = stableJournalStorageBinding(
        directory: newRoot.appendingPathComponent(relative), applicationContainer: newRoot, applicationID: "com.example.wallet"
    )
    #expect(old == new)
    #expect(old != stableJournalStorageBinding(
        directory: newRoot.appendingPathComponent("Library/another-store"),
        applicationContainer: newRoot, applicationID: "com.example.wallet"
    ))
    #expect(old != stableJournalStorageBinding(
        directory: newRoot.appendingPathComponent(relative), applicationContainer: newRoot, applicationID: "com.other.wallet"
    ))
}

@Test func encryptedJournalRejectsConcurrentWalletThroughSymlinkAlias() async throws {
    let fixture = try DurableJournalFixture()
    let journal = try fixture.open()
    let alias = fixture.root.appendingPathComponent("root-alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
    let storage = try WalletStorageConfiguration(directory: alias, keychainService: fixture.storage.keychainService)
    #expect(throws: SDKError.self) {
        try EncryptedOperationJournal(
            configuration: fixture.configuration, serviceURL: URL(string: "https://gateway.example")!,
            storage: storage, keyStore: fixture.keys
        )
    }
    await journal.close()
}

@Test func encryptedJournalFinishesInterruptedBootstrapWithSameKeyAndCiphertext() async throws {
    let fixture = try DurableJournalFixture()
    fixture.keys.failUpdate(afterSuccessfulUpdates: 0)
    #expect(throws: SDKError.self) { try fixture.open() }
    let originalKey = try #require(fixture.keys.snapshot())
    let originalData = try #require(originalKey.bootstrapSnapshot)
    try FileManager.default.removeItem(at: fixture.snapshotURL())
    fixture.keys.allowUpdates()
    let journal = try fixture.open()
    #expect(fixture.keys.snapshot()?.key == originalKey.key)
    #expect(try Data(contentsOf: fixture.snapshotURL()) == originalData)
    #expect(fixture.keys.snapshot()?.bootstrapSnapshot == nil)
    await journal.close()
}

@Test func encryptedJournalRestartsWithExactCheckpointAndOpaqueDiskContent() async throws {
    let fixture = try DurableJournalFixture()
    let journal = try fixture.open()
    try await fixture.bind(journal)
    let checkpoint = try fixture.checkpoint(key: "private-operation-key")
    try await journal.save(checkpoint)
    let ciphertext = try Data(contentsOf: fixture.snapshotURL())
    #expect(!String(decoding: ciphertext, as: UTF8.self).contains(checkpoint.idempotencyKey.value))
    await journal.close()

    let restarted = try fixture.open()
    #expect(try await restarted.load(walletID: fixture.configuration.walletID, idempotencyKey: checkpoint.idempotencyKey) == checkpoint)
    await restarted.close()
}

@Test func encryptedJournalRejectsTamperAndCrossServiceReplacement() async throws {
    let fixture = try DurableJournalFixture()
    let journal = try fixture.open()
    try await fixture.bind(journal)
    await journal.close()
    let original = try Data(contentsOf: fixture.snapshotURL())
    var tampered = original
    tampered[tampered.count / 2] ^= 0xff
    try tampered.write(to: fixture.snapshotURL())
    #expect(throws: SDKError.self) { try fixture.open() }
    try original.write(to: fixture.snapshotURL())
    #expect(throws: SDKError.self) {
        try fixture.open(serviceURL: URL(string: "https://another.example")!)
    }
}

@Test func encryptedJournalRejectsLossOfKeyOrFileWithoutGeneratingReplacement() async throws {
    let fixture = try DurableJournalFixture()
    let journal = try fixture.open()
    try await fixture.bind(journal)
    await journal.close()
    let record = fixture.keys.snapshot()
    fixture.keys.set(nil)
    #expect(throws: SDKError.self) { try fixture.open() }
    #expect(fixture.keys.snapshot() == nil)
    fixture.keys.set(record)
    try FileManager.default.removeItem(at: fixture.snapshotURL())
    #expect(throws: SDKError.self) { try fixture.open() }
    #expect(fixture.keys.snapshot()?.committedDigest == record?.committedDigest)
}

@Test func encryptedJournalRejectsRollbackToPreviouslyValidCiphertext() async throws {
    let fixture = try DurableJournalFixture()
    let journal = try fixture.open()
    try await fixture.bind(journal)
    let previous = try Data(contentsOf: fixture.snapshotURL())
    try await journal.save(fixture.checkpoint(key: "authorized-payment"))
    await journal.close()
    try previous.write(to: fixture.snapshotURL())
    #expect(throws: SDKError.self) { try fixture.open() }
}

@Test func encryptedJournalRecoversCrashAfterAtomicFileBeforeFinalKeychainCommit() async throws {
    let fixture = try DurableJournalFixture()
    let journal = try fixture.open()
    try await fixture.bind(journal)
    let checkpoint = try fixture.checkpoint(key: "crash-after-file")
    fixture.keys.failUpdate(afterSuccessfulUpdates: 1)
    await #expect(throws: SDKError.self) { try await journal.save(checkpoint) }
    #expect(fixture.keys.snapshot()?.pendingDigest != nil)
    await journal.close()
    fixture.keys.allowUpdates()

    let restarted = try fixture.open()
    #expect(try await restarted.load(walletID: fixture.configuration.walletID, idempotencyKey: checkpoint.idempotencyKey) == checkpoint)
    #expect(fixture.keys.snapshot()?.pendingDigest == nil)
    await restarted.close()
}

@Test func encryptedJournalRecoversCrashBeforeAtomicReplacementToLastCommittedFile() async throws {
    let fixture = try DurableJournalFixture()
    let journal = try fixture.open()
    try await fixture.bind(journal)
    await journal.close()
    var anchor = try #require(fixture.keys.snapshot())
    anchor.pendingDigest = String(repeating: "a", count: 64)
    fixture.keys.set(anchor)
    let restarted = try fixture.open()
    #expect(fixture.keys.snapshot()?.pendingDigest == nil)
    #expect(fixture.keys.snapshot()?.committedDigest == anchor.committedDigest)
    await restarted.close()
}

@Test func encryptedJournalChecksKeychainWriteBeforeWritingDisk() async throws {
    let fixture = try DurableJournalFixture()
    let journal = try fixture.open()
    try await fixture.bind(journal)
    let previous = try Data(contentsOf: fixture.snapshotURL())
    fixture.keys.failUpdate(afterSuccessfulUpdates: 0)
    await #expect(throws: SDKError.self) { try await journal.save(fixture.checkpoint(key: "write-denied")) }
    #expect(try Data(contentsOf: fixture.snapshotURL()) == previous)
    await journal.close()
}

@Test func encryptedJournalBindsSignerGatewayUserAndWalletNetwork() async throws {
    let fixture = try DurableJournalFixture()
    let journal = try fixture.open()
    try await fixture.bind(journal)
    await #expect(throws: SDKError.self) { try await journal.bindSignerIdentity(fixture.identity(xpub: "different-wallet")) }
    await #expect(throws: SDKError.self) { try await journal.bindGatewayUserID("different-user") }
    await #expect(throws: SDKError.self) {
        try await journal.load(walletID: WalletID("another-wallet"), idempotencyKey: IdempotencyKey("query"))
    }
    await journal.close()
    let restarted = try fixture.open()
    await #expect(throws: SDKError.self) { try await restarted.bindGatewayUserID("different-user") }
    await restarted.close()
}

@Test func encryptedJournalExclusiveOwnershipLastsThroughShutdownButNotDestroy() async throws {
    let fixture = try DurableJournalFixture()
    let journal = try fixture.open()
    #expect(throws: SDKError.self) { try fixture.open() }
    let service = try GatewayBackendConfiguration(
        baseURL: URL(string: "https://gateway.example")!, bearerToken: "unused", network: .regtest
    )
    let wallet = UTEXOWallet(
        configuration: fixture.configuration, backend: GatewayWalletBackend(configuration: service),
        keyProvider: JournalNeverKeyProvider(), durableJournal: journal
    )
    try await wallet.shutdown()
    #expect(throws: SDKError.self) { try fixture.open() }
    try await wallet.destroy()
    let reopened = try fixture.open()
    await reopened.close()
    await #expect(throws: SDKError.self) { try await wallet.reinit() }
    await #expect(throws: SDKError.self) {
        try await journal.load(walletID: fixture.configuration.walletID, idempotencyKey: IdempotencyKey("query"))
    }
}

@Test func encryptedJournalRejectsSnapshotSymlinkAndHardLink() async throws {
    for symlink in [true, false] {
        let fixture = try DurableJournalFixture()
        let journal = try fixture.open()
        await journal.close()
        let snapshot = try fixture.snapshotURL()
        let destination = fixture.root.appendingPathComponent("target")
        try FileManager.default.moveItem(at: snapshot, to: destination)
        if symlink {
            try FileManager.default.createSymbolicLink(at: snapshot, withDestinationURL: destination)
        } else {
            try FileManager.default.linkItem(at: destination, to: snapshot)
        }
        #expect(throws: SDKError.self) { try fixture.open() }
    }
}

@Test func encryptedJournalDetectsRecordDeletionWhileWalletIsOpen() async throws {
    let fixture = try DurableJournalFixture()
    let journal = try fixture.open()
    try await fixture.bind(journal)
    try FileManager.default.removeItem(at: fixture.snapshotURL())
    await #expect(throws: SDKError.self) { try await journal.save(fixture.checkpoint(key: "not-written")) }
    await journal.close()
}

@Test func encryptedJournalRecoversEveryAtomicWriteFailureWithoutLosingCommittedEvidence() async throws {
    let operations: [JournalFileOperation] = [
        .temporaryFileCreation,
        .write,
        .fileSynchronize,
        .fullFileSynchronize,
        .rename,
        .directorySynchronize,
    ]
    for operation in operations {
        let fixture = try DurableJournalFixture()
        let faults = ControlledJournalFileFaultInjector()
        let journal = try fixture.open(fileFaultInjector: faults)
        try await fixture.bind(journal)
        let committed = try fixture.checkpoint(key: "committed-before-\(operation)")
        try await journal.save(committed)
        let interrupted = try fixture.checkpoint(key: "interrupted-at-\(operation)")

        faults.arm(operation, error: operation == .temporaryFileCreation ? ENOSPC : EIO)
        await #expect(throws: SDKError.self) { try await journal.save(interrupted) }
        #expect(faults.triggeredOperations() == [operation])
        #expect(fixture.keys.snapshot()?.pendingDigest != nil)
        faults.disarm()
        await journal.close()

        let reopened = try fixture.open()
        #expect(try await reopened.load(
            walletID: fixture.configuration.walletID,
            idempotencyKey: committed.idempotencyKey
        ) == committed)
        let recovered = try await reopened.load(
            walletID: fixture.configuration.walletID,
            idempotencyKey: interrupted.idempotencyKey
        )
        // Only the directory-sync failure occurs after atomic rename. Earlier
        // failures truthfully retain the last committed snapshot instead.
        #expect(recovered == (operation == .directorySynchronize ? interrupted : nil))
        #expect(fixture.keys.snapshot()?.pendingDigest == nil)
        await reopened.close()

        let pendingFiles = try fixture.operationDirectoryContents().filter {
            $0.lastPathComponent.hasPrefix(".pending-")
        }
        #expect(pendingFiles.isEmpty)
    }
}

@Suite(.serialized)
struct EncryptedOperationJournalCapacityTests {
    @Test func exactCheckpointCountIsAcceptedAndOneMoreIsRejected() async throws {
        let fixture = try DurableJournalFixture()
        let bootstrap = try fixture.open()
        await bootstrap.close()

        let testStart = Date()
        var exact: [String: Data]? = [:]
        exact?.reserveCapacity(EncryptedOperationJournal.maximumCheckpointCount)
        for index in 0..<EncryptedOperationJournal.maximumCheckpointCount {
            let key = "capacity-\(index)"
            exact?[key] = try OperationCheckpointCodec.encode(fixture.checkpoint(key: key))
        }
        let exactCiphertextBytes = try fixture.installSnapshot(checkpoints: try #require(exact))
        exact = nil
        #expect(exactCiphertextBytes <= EncryptedOperationJournal.maximumSnapshotBytes)

        let residentBeforeOpen = currentResidentMemoryBytes()
        let openStart = Date()
        let full = try fixture.open()
        let openSeconds = Date().timeIntervalSince(openStart)
        let last = try await full.load(
            walletID: fixture.configuration.walletID,
            idempotencyKey: IdempotencyKey("capacity-99999")
        )
        let expectedLast = try fixture.checkpoint(key: "capacity-99999")
        #expect(last == expectedLast)
        await #expect(throws: SDKError.self) {
            try await full.save(fixture.checkpoint(key: "capacity-overflow"))
        }
        await full.close()
        let residentAfterOpen = currentResidentMemoryBytes()

        // The over-count fixture remains below the byte ceiling, proving this
        // rejection is caused by record count rather than file size. Individual
        // checkpoint validity is immaterial because count is rejected first.
        let template = try OperationCheckpointCodec.encode(fixture.checkpoint(key: "template"))
        var over: [String: Data]? = [:]
        over?.reserveCapacity(EncryptedOperationJournal.maximumCheckpointCount + 1)
        for index in 0...EncryptedOperationJournal.maximumCheckpointCount {
            over?["overflow-\(index)"] = template
        }
        let overCiphertextBytes = try fixture.installSnapshot(checkpoints: try #require(over))
        over = nil
        #expect(overCiphertextBytes <= EncryptedOperationJournal.maximumSnapshotBytes)
        #expect(throws: SDKError.self) { try fixture.open() }

        print(
            "S5_METRIC platform=macOS records=100000 ciphertextBytes=\(exactCiphertextBytes) "
                + "totalSeconds=\(Date().timeIntervalSince(testStart)) "
                + "openSeconds=\(openSeconds) residentBefore=\(residentBeforeOpen) "
                + "residentAfter=\(residentAfterOpen)"
        )
    }

    @Test func exactSnapshotByteLimitIsAcceptedAndOneByteMoreIsRejected() async throws {
        let fixture = try DurableJournalFixture()
        let bootstrap = try fixture.open()
        await bootstrap.close()

        var ciphertext = try fixture.makeCiphertext(
            exactBytes: EncryptedOperationJournal.maximumSnapshotBytes
        )
        #expect(ciphertext.count == EncryptedOperationJournal.maximumSnapshotBytes)
        try fixture.installCiphertext(ciphertext)
        let atLimit = try fixture.open()
        await atLimit.close()

        ciphertext.append(0)
        #expect(ciphertext.count == EncryptedOperationJournal.maximumSnapshotBytes + 1)
        try fixture.installCiphertext(ciphertext)
        #expect(throws: SDKError.self) { try fixture.open() }
    }
}

@Test func encryptedJournalRejectsChangingStorageRootForExistingKey() async throws {
    let fixture = try DurableJournalFixture()
    let journal = try fixture.open()
    await journal.close()
    let second = try WalletStorageConfiguration(
        directory: fixture.root.appendingPathComponent("other-root"), keychainService: fixture.storage.keychainService
    )
    #expect(throws: SDKError.self) {
        try EncryptedOperationJournal(
            configuration: fixture.configuration, serviceURL: URL(string: "https://gateway.example")!,
            storage: second, keyStore: fixture.keys
        )
    }
}

private final class DurableJournalFixture: @unchecked Sendable {
    let root: URL
    let storage: WalletStorageConfiguration
    let configuration: WalletConfiguration
    let keys = FakeJournalKeyStore()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("utexo-journal-test-" + UUID().uuidString)
        storage = try WalletStorageConfiguration(directory: root, keychainService: "unit.test.journal." + UUID().uuidString)
        configuration = try WalletConfiguration(walletID: WalletID("journal-wallet"), network: .regtest)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func open(
        serviceURL: URL = URL(string: "https://gateway.example")!,
        fileFaultInjector: (any JournalFileFaultInjector)? = nil
    ) throws -> EncryptedOperationJournal {
        try EncryptedOperationJournal(
            configuration: configuration,
            serviceURL: serviceURL,
            storage: storage,
            keyStore: keys,
            fileFaultInjector: fileFaultInjector
        )
    }

    func bind(_ journal: EncryptedOperationJournal) async throws {
        try await journal.bindSignerIdentity(identity())
        try await journal.bindGatewayUserID("gateway-user")
    }

    func identity(xpub: String = "test-root-xpub") -> WalletIdentity {
        WalletIdentity(
            network: .regtest, chainNetwork: "regtest", derivationProfile: WalletCapabilities.derivationProfileV1,
            masterFingerprint: "12345678", xpub: xpub, accountXpubVanilla: "test-vanilla", accountXpubColored: "test-colored"
        )
    }

    func checkpoint(key: String) throws -> OperationCheckpoint {
        try OperationCheckpoint(
            walletID: configuration.walletID, idempotencyKey: IdempotencyKey(key),
            requestHash: RequestHash(validating: String(repeating: "b", count: 64)),
            operationKind: .sendBtc, phase: .created
        )
    }

    func paymentCheckpoint(key: String, phase: OperationPhase, payloadBytes: Int = 32) throws -> OperationCheckpoint {
        let identity = try checkpoint(key: key)
        let operationID = try OperationID("operation-" + key)
        let txid = try TransactionID(String(repeating: "a", count: 64))
        let prepared = try PreparedTransaction(
            operationID: operationID, idempotencyKey: identity.idempotencyKey,
            requestHash: identity.requestHash, network: .regtest, operation: .sendBtc,
            psbtBase64: String(repeating: "a", count: payloadBytes), expiresAt: .init(rawValue: 2_000)
        )
        let validation = try LocalValidationReport(
            psbtSHA256: String(repeating: "b", count: 64), intentSHA256: String(repeating: "c", count: 64),
            unsignedTxid: txid, totalInput: Satoshis(20_000), totalOutput: Satoshis(19_000),
            fee: Satoshis(1_000), estimatedVbytes: 200, feeRate: FeeRate(satsPerVByte: 5),
            externalOutput: Satoshis(10_000), change: Satoshis(9_000),
            inputCount: 1, outputCount: 2, opReturnCount: 0
        )
        return try OperationCheckpoint(
            walletID: identity.walletID, idempotencyKey: identity.idempotencyKey,
            requestHash: identity.requestHash, operationKind: .sendBtc, phase: phase,
            operationID: operationID, preparedTransaction: prepared,
            signedPsbtBase64: String(repeating: "b", count: payloadBytes), validation: validation,
            terminalOutcome: phase == .terminal ? .succeeded(.sendBtc(operationID: operationID, txid: txid)) : nil
        )
    }

    /// Seeds authenticated v1 data without asking the new writer to create it.
    func installLegacySnapshot(_ checkpoints: [OperationCheckpoint]) throws {
        var record = try #require(keys.snapshot())
        let context = try JSONSerialization.data(withJSONObject: [
            "domain": "utexo.swift.operation-journal.v1",
            "walletID": configuration.walletID.value, "network": configuration.network.rawValue,
            "keychainService": storage.keychainService, "serviceURL": "https://gateway.example",
        ], options: .sortedKeys)
        let previous = try AES.GCM.open(
            AES.GCM.SealedBox(combined: Data(contentsOf: snapshotURL())),
            using: SymmetricKey(data: record.key), authenticating: context
        )
        var envelope = try #require(JSONSerialization.jsonObject(with: previous) as? [String: Any])
        envelope["version"] = 1
        envelope["checkpoints"] = try Dictionary(uniqueKeysWithValues: checkpoints.map {
            ($0.idempotencyKey.value, try OperationCheckpointCodec.encode($0).base64EncodedString())
        })
        let ciphertext = try #require(AES.GCM.seal(
            JSONSerialization.data(withJSONObject: envelope, options: .sortedKeys),
            using: SymmetricKey(data: record.key), authenticating: context
        ).combined)
        try ciphertext.write(to: snapshotURL())
        record.committedDigest = SHA256.hash(data: ciphertext).map { String(format: "%02x", $0) }.joined()
        record.pendingDigest = nil
        keys.set(record)
    }

    @discardableResult
    func installSnapshot(checkpoints: [String: Data]) throws -> Int {
        let envelope: [String: Any] = [
            "version": 2,
            "signerIdentity": "capacity-test-signer",
            "gatewayUserID": "gateway-user",
            "checkpoints": checkpoints.mapValues { $0.base64EncodedString() },
        ]
        let plaintext = try JSONSerialization.data(withJSONObject: envelope, options: .sortedKeys)
        var record = try #require(keys.snapshot())
        let ciphertext = try #require(AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: record.key),
            authenticating: authenticatedContext()
        ).combined)
        try installCiphertext(ciphertext, record: &record)
        return ciphertext.count
    }

    func makeCiphertext(exactBytes: Int) throws -> Data {
        guard exactBytes >= 28 else { throw SDKError.operationJournalUnavailable }
        var envelope: [String: Any] = [
            "version": 2,
            "signerIdentity": "capacity-test-signer",
            "gatewayUserID": "gateway-user",
            "checkpoints": [String: String](),
            "padding": "",
        ]
        let base = try JSONSerialization.data(withJSONObject: envelope, options: .sortedKeys)
        let paddingBytes = exactBytes - 28 - base.count
        guard paddingBytes >= 0 else { throw SDKError.operationJournalUnavailable }
        envelope["padding"] = String(repeating: "p", count: paddingBytes)
        var plaintext = try JSONSerialization.data(withJSONObject: envelope, options: .sortedKeys)
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        guard plaintext.count == exactBytes - 28 else { throw SDKError.operationJournalUnavailable }
        let record = try #require(keys.snapshot())
        let ciphertext = try #require(AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: record.key),
            authenticating: authenticatedContext()
        ).combined)
        guard ciphertext.count == exactBytes else { throw SDKError.operationJournalUnavailable }
        return ciphertext
    }

    func installCiphertext(_ ciphertext: Data) throws {
        var record = try #require(keys.snapshot())
        try installCiphertext(ciphertext, record: &record)
    }

    func operationDirectoryContents() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: snapshotURL().deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
    }

    private func installCiphertext(
        _ ciphertext: Data,
        record: inout JournalKeyRecord
    ) throws {
        try ciphertext.write(to: snapshotURL())
        record.committedDigest = SHA256.hash(data: ciphertext).map {
            String(format: "%02x", $0)
        }.joined()
        record.pendingDigest = nil
        record.bootstrapSnapshot = nil
        keys.set(record)
    }

    private func authenticatedContext() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "domain": "utexo.swift.operation-journal.v1",
            "walletID": configuration.walletID.value,
            "network": configuration.network.rawValue,
            "keychainService": storage.keychainService,
            "serviceURL": "https://gateway.example",
        ], options: .sortedKeys)
    }

    func snapshotURL() throws -> URL {
        let directory = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        return directory.appendingPathComponent(EncryptedOperationJournal.snapshotName)
    }
}

private final class ControlledJournalFileFaultInjector: JournalFileFaultInjector, @unchecked Sendable {
    private let lock = NSLock()
    private var armed: (operation: JournalFileOperation, error: Int32)?
    private var triggered: [JournalFileOperation] = []

    func arm(_ operation: JournalFileOperation, error: Int32) {
        lock.withLock {
            armed = (operation, error)
            triggered.removeAll(keepingCapacity: true)
        }
    }

    func disarm() { lock.withLock { armed = nil } }

    func triggeredOperations() -> [JournalFileOperation] { lock.withLock { triggered } }

    func before(_ operation: JournalFileOperation) throws {
        let error: Int32? = lock.withLock {
            guard armed?.operation == operation else { return nil }
            let value = armed?.error
            armed = nil
            triggered.append(operation)
            return value
        }
        if let error { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
    }
}

private func currentResidentMemoryBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}

private final class FakeJournalKeyStore: JournalKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var record: JournalKeyRecord?
    private var updatesRemaining: Int?
    func snapshot() -> JournalKeyRecord? { lock.withLock { record } }
    func set(_ value: JournalKeyRecord?) { lock.withLock { record = value } }
    func failUpdate(afterSuccessfulUpdates count: Int) { lock.withLock { updatesRemaining = count } }
    func allowUpdates() { lock.withLock { updatesRemaining = nil } }
    func load() throws -> JournalKeyRecord? { snapshot() }
    func create(_ value: JournalKeyRecord) throws {
        try lock.withLock {
            guard record == nil else { throw SDKError.operationJournalUnavailable }
            record = value
        }
    }
    func update(_ value: JournalKeyRecord) throws {
        try lock.withLock {
            guard record != nil else { throw SDKError.operationJournalUnavailable }
            if let remaining = updatesRemaining {
                guard remaining > 0 else { throw SDKError.operationJournalUnavailable }
                updatesRemaining = remaining - 1
            }
            record = value
        }
    }
}

private struct JournalNeverKeyProvider: WalletKeyProvider {
    func loadSeed(parameters: WalletUnlockParameters) async throws -> SecretSeed { throw SDKError.keyAccessFailed }
}
