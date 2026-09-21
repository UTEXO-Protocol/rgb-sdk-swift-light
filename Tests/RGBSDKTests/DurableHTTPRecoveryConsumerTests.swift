import CryptoKit
import Foundation
import Testing
@testable @_spi(Backend) import RGBSDK

/// The current public factory cannot create a new payment, so this test seeds a
/// genuinely locally signed synthetic SUBMITTING fixture through infrastructure
/// APIs. Recovery then uses public wallet methods and real HTTP with the profile
/// disabled. Real encrypted journal files and a file-persisted test anchor survive
/// reconstruction. The anchor is deliberately a test substitute for OS Keychain;
/// this is not a real gateway broadcast or a physical process-kill experiment.
@Test func durableHTTPConsumerRestoresOriginalIntentAndOnlyReconcilesAfterReopen() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("utexo-http-recovery-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let walletID = try WalletID("persisted-consumer")
    let configuration = try WalletConfiguration(walletID: walletID, network: .mainnet)
    let storage = try WalletStorageConfiguration(directory: root.appendingPathComponent("journal"), keychainService: "test.recovery." + UUID().uuidString)
    let peer = RecoveryHTTPPeer()
    let server = try LoopbackHTTPServer { request in try await peer.reply(request) }
    defer { server.stop() }
    let url = try await server.start()
    let anchorURL = root.appendingPathComponent("test-anchor.json")
    let intentURL = root.appendingPathComponent("application-intent.aesgcm")
    let intentKey = SymmetricKey(data: Data(repeating: 9, count: 32)) // synthetic fixture key
    let expectedTxid = try TransactionID("ec75ccb05c23b9be0b1f487b704071066e62550072ce1b36fee0576177ce336a")

    do {
        let request = try SendBtcRequest(
            address: BitcoinAddress("bc1p4qhjn9zdvkux4e44uhx8tc55attvtyu358kutcqkudyccelu0was9fqzwh"),
            amount: Satoshis(30_000), feeRate: FeeRate(satsPerVByte: 100),
            idempotencyKey: IdempotencyKey("consumer-original-intent")
        )
        // This is application-owned intent persistence before the first call.
        var encoded = try JSONEncoder().encode(PersistedConsumerIntent(
            request, configuration: configuration, serviceURL: url, accountID: "persisted-consumer-user"
        ))
        defer { encoded.resetBytes(in: encoded.startIndex..<encoded.endIndex) }
        try #require(AES.GCM.seal(encoded, using: intentKey).combined).write(to: intentURL, options: .atomic)
        let seed = try recoverySeed()
        defer { seed.close() }
        let signer = try UniFFILocalSigningEngineFactory().open(network: .mainnet, seed: seed)
        let prepared = try PreparedTransaction(
            operationID: OperationID("19191919-1919-4919-8919-191919191919"),
            idempotencyKey: request.idempotencyKey,
            requestHash: RequestHasher.sendBtc(network: .mainnet, request: request),
            network: .mainnet, operation: .sendBtc, psbtBase64: recoverySyntheticPSBT,
            expiresAt: .init(rawValue: 2_000)
        )
        let signed = try signer.validateAndSign(prepared: prepared, request: request, policy: .default)
        #expect(signed.validation.unsignedTxid == expectedTxid)
        let journal = try EncryptedOperationJournal(
            configuration: configuration, serviceURL: url, storage: storage,
            keyStore: FileRecoveryTestAnchor(url: anchorURL)
        )
        try await journal.bindSignerIdentity(signer.identity())
        try await journal.bindGatewayUserID("persisted-consumer-user")
        try await journal.save(.init(
            walletID: walletID, idempotencyKey: request.idempotencyKey,
            requestHash: prepared.requestHash, operationKind: .sendBtc, phase: .created
        ))
        for phase in [OperationPhase.prepared, .signed, .submitting] {
            try await journal.save(.init(
                walletID: walletID, idempotencyKey: request.idempotencyKey,
                requestHash: prepared.requestHash, operationKind: .sendBtc,
                phase: phase, operationID: prepared.operationID, preparedTransaction: prepared,
                signedPsbtBase64: phase == .prepared ? nil : signed.signedPsbtBase64,
                validation: phase == .prepared ? nil : signed.validation
            ))
        }
        await journal.close()
    }

    // Each pass reconstructs both the app request and all wallet/backend/journal
    // objects from disk. The first status is pending; the second is completed.
    for attempt in 0..<2 {
        let request = try restoreConsumerIntent(
            from: intentURL, key: intentKey, configuration: configuration,
            serviceURL: url, accountID: "persisted-consumer-user"
        )
        let journal = try EncryptedOperationJournal(
            configuration: configuration, serviceURL: url, storage: storage,
            keyStore: FileRecoveryTestAnchor(url: anchorURL)
        )
        let before = try #require(await journal.load(walletID: walletID, idempotencyKey: request.idempotencyKey))
        #expect(before.phase == .submitting)
        let backend = GatewayWalletBackend(configuration: try GatewayBackendConfiguration(
            baseURL: url, bearerToken: "synthetic-recovery-key", network: .mainnet,
            allowInsecureLocalDevelopment: true
        ))
        let wallet = UTEXOWallet(
            configuration: configuration, backend: backend, keyProvider: RecoveryConsumerSeedProvider(),
            durableJournal: journal
        )
        do {
            try await wallet.initialize()
            try await wallet.unlock()
            let requestCount = server.snapshot().count
            if attempt == 0 {
                do { _ = try await wallet.sendBtc(request); Issue.record("pending recovery must remain ambiguous") }
                catch let error as SDKError {
                    #expect(error.code == .operationAmbiguous && error.retryable)
                    #expect(error.operationID == before.operationID)
                }
                #expect(try await journal.load(walletID: walletID, idempotencyKey: request.idempotencyKey) == before)
            } else {
                #expect(try await wallet.sendBtc(request) == expectedTxid)
                let completed = try #require(await journal.load(walletID: walletID, idempotencyKey: request.idempotencyKey))
                #expect(completed.phase == .terminal)
                #expect(completed.validation == before.validation)
                #expect(completed.operationID == before.operationID)
                #expect(completed.preparedTransaction == nil && completed.signedPsbtBase64 == nil)
                #expect(try await wallet.sendBtc(request) == expectedTxid)
                let changed = try SendBtcRequest(
                    address: request.address, amount: Satoshis(30_001), feeRate: request.feeRate,
                    idempotencyKey: request.idempotencyKey
                )
                do { _ = try await wallet.sendBtc(changed); Issue.record("changed same-key intent must conflict") }
                catch let error as SDKError { #expect(error.code == .operationConflict) }
            }
            #expect(server.snapshot().count == requestCount + 1)
            try await wallet.destroy()
        } catch { try? await wallet.destroy(); throw error }
    }
    let requests = server.snapshot()
    #expect(requests.map(\.method) == ["GET", "POST", "GET", "GET", "POST", "GET"])
    #expect(requests.filter { $0.path.contains("/operations/") }.count == 2)
    #expect(!requests.contains { $0.path.contains("/prepare") || $0.path.contains("/complete") })
}

@Test func durableConsumerIntentRejectsTamperingAndWrongBindingsBeforeRecovery() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("utexo-intent-binding-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("intent.aesgcm")
    let configuration = try WalletConfiguration(walletID: WalletID("consumer-binding"), network: .mainnet)
    let serviceURL = try #require(URL(string: "https://gateway.example"))
    let key = SymmetricKey(data: Data(repeating: 10, count: 32))
    let request = try SendBtcRequest(
        address: BitcoinAddress("bc1p4qhjn9zdvkux4e44uhx8tc55attvtyu358kutcqkudyccelu0was9fqzwh"),
        amount: Satoshis(30_000), feeRate: FeeRate(milliSatsPerVByte: 5_001), skipSync: true,
        idempotencyKey: IdempotencyKey("explicit-persisted-payment")
    )
    let encoded = try JSONEncoder().encode(PersistedConsumerIntent(
        request, configuration: configuration, serviceURL: serviceURL, accountID: "bound-account"
    ))
    func restore() throws -> SendBtcRequest {
        try restoreConsumerIntent(
            from: url, key: key, configuration: configuration, serviceURL: serviceURL, accountID: "bound-account"
        )
    }
    let sealed = try #require(AES.GCM.seal(encoded, using: key).combined)
    try sealed.write(to: url, options: .atomic)
    #expect(try restore() == request)
    let original = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    for (field, wrongValue): (String, Any) in [
        ("schemaVersion", 2), ("walletID", "another-wallet"), ("network", "regtest"),
        ("serviceURL", "https://another-gateway.example"), ("accountID", "another-account"),
    ] {
        // Valid encryption does not make a record for another wallet/account applicable.
        var fields = original
        fields[field] = wrongValue
        let wrongBinding = try JSONSerialization.data(withJSONObject: fields)
        try #require(AES.GCM.seal(wrongBinding, using: key).combined).write(to: url, options: .atomic)
        #expect(throws: ConsumerIntentBindingError.self) { try restore() }
    }
    var tampered = sealed
    tampered[tampered.startIndex + 16] ^= 1
    try tampered.write(to: url, options: .atomic)
    #expect(throws: (any Error).self) { try restore() }
}

private enum ConsumerIntentBindingError: Error { case incompatibleRecord }

private struct PersistedConsumerIntent: Codable {
    let schemaVersion: Int
    let walletID: String
    let network: String
    let serviceURL: String
    let accountID: String
    let address: String
    let amount: UInt64
    let milliSatsPerVByte: UInt64
    let skipSync: Bool
    let idempotencyKey: String
    init(_ request: SendBtcRequest, configuration: WalletConfiguration, serviceURL: URL, accountID: String) {
        schemaVersion = 1; walletID = configuration.walletID.value; network = configuration.network.rawValue
        self.serviceURL = serviceURL.absoluteString; self.accountID = accountID
        address = request.address.value; amount = request.amount.value
        milliSatsPerVByte = request.feeRate.milliSatsPerVByte; skipSync = request.skipSync
        idempotencyKey = request.idempotencyKey.value
    }
    func request(configuration: WalletConfiguration, serviceURL: URL, accountID: String) throws -> SendBtcRequest {
        guard schemaVersion == 1, walletID == configuration.walletID.value,
              network == configuration.network.rawValue, self.serviceURL == serviceURL.absoluteString,
              self.accountID == accountID else { throw ConsumerIntentBindingError.incompatibleRecord }
        return try SendBtcRequest(
            address: BitcoinAddress(address), amount: Satoshis(amount),
            feeRate: FeeRate(milliSatsPerVByte: milliSatsPerVByte), skipSync: skipSync,
            idempotencyKey: IdempotencyKey(idempotencyKey)
        )
    }
}

private func restoreConsumerIntent(
    from url: URL, key: SymmetricKey, configuration: WalletConfiguration, serviceURL: URL, accountID: String
) throws -> SendBtcRequest {
    var plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: url)), using: key)
    defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
    return try JSONDecoder().decode(PersistedConsumerIntent.self, from: plaintext).request(
        configuration: configuration, serviceURL: serviceURL, accountID: accountID
    )
}

private struct FileRecoveryTestAnchor: JournalKeyStore {
    let url: URL
    func load() throws -> JournalKeyRecord? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(JournalKeyRecord.self, from: Data(contentsOf: url))
    }
    func create(_ record: JournalKeyRecord) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw SDKError.operationJournalUnavailable }
        try update(record)
    }
    func update(_ record: JournalKeyRecord) throws {
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
    }
}

private struct RecoveryConsumerSeedProvider: WalletKeyProvider {
    func loadSeed(parameters: WalletUnlockParameters) async throws -> SecretSeed { try recoverySeed() }
}

private func recoverySeed() throws -> SecretSeed {
    let phrase = try SecretMnemonic(copyingUTF8: Array(
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about".utf8
    ))
    defer { phrase.close() }
    return try deriveSeedFromMnemonic(mnemonic: phrase)
}

private actor RecoveryHTTPPeer {
    private var statusReads = 0
    func reply(_ request: LoopbackHTTPServer.Request) throws -> LoopbackHTTPServer.Response {
        switch request.path {
        case "/v1/me": return .json(#"{"userId":"persisted-consumer-user","createdAt":1}"#)
        case "/v1/wallet/xpubs":
            let fields = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: String])
            return .json("{\"fingerprint\":\"\(try #require(fields["fingerprint"]))\",\"address\":\"bc1pbounded-registration-fixture\"}", status: 201)
        case "/v1/onchain/operations/19191919-1919-4919-8919-191919191919":
            statusReads += 1
            let completed = statusReads > 1
            let body: [String: Any] = [
                "opId": "19191919-1919-4919-8919-191919191919", "kind": "send_btc",
                "state": completed ? "completed" : "pending", "mayHaveBroadcast": false,
                "txid": completed ? "ec75ccb05c23b9be0b1f487b704071066e62550072ce1b36fee0576177ce336a" : NSNull(),
                "createdAt": 1_000_000, "expiresAt": 2_000_000,
                "intent": [
                    "kind": "send_btc", "feeRateSatPerVb": 100, "asset": NSNull(), "utxos": NSNull(),
                    "recipients": [["address": "bc1p4qhjn9zdvkux4e44uhx8tc55attvtyu358kutcqkudyccelu0was9fqzwh", "amountSat": 30_000, "scriptHex": "5120a82f29944d65b86ae6b5e5cc75e294ead6c59391a1edc5e016e3498c67fc7bbb"]],
                ],
            ]
            return .json(String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self))
        default: return .json("{}", status: 404)
        }
    }
}

// Same public BIP86 mnemonic and nonexistent prevout as the native smoke test.
// It references a synthetic nonexistent prevout; no test broadcasts. Never fund fixture keys.
private let recoverySyntheticPSBT = "cHNidP8BAIkCAAAAAQcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHAAAAAAD9////AjB1AAAAAAAAIlEgqC8plE1luGrmteXMdeKU6tbFk5Gh7cXgFuNJjGf8e7t8DwEAAAAAACJRIIgtdOXQVy1agWzvAEGpa2wd6DL2+WdtlgXETV6al9PcAAAAAAABASughgEAAAAAACJRIKYIafDbzx3GWcnOy6+AUBNeqejNxIcFPx3GiAlJ3GhMIRbMikvGTYl73cX7wvZw96i6CzhneRBs8SI8b8XXzW/BFRkAc8XaClYAAIAAAACAAAAAgAAAAAAAAAAAARcgzIpLxk2Je93F+8L2cPeougs4Z3kQbPEiPG/F181vwRUAAAEFIDmfGy9Dk/KaGMk3hZxd2KdzUBAxV+uIDwLowIIUJ3zvIQc5nxsvQ5PymhjJN4WcXdinc1AQMVfriA8C6MCCFCd87xkAc8XaClYAAIAAAACAAAAAgAEAAAAAAAAAAA=="
