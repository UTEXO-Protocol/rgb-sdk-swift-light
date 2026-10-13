import Foundation

/// High-level wallet facade matching the semantic surface of `rgb-sdk-rn`.
///
/// Stateful wallet/RGB work is delegated to the backend. Bitcoin key
/// derivation, transaction-policy validation, and signing remain local. No
/// public wallet method accepts or returns a PSBT.
public actor UTEXOWallet {
    private enum Lifecycle: String {
        case new
        case initialized
        case unlocked
        case shutdown
        case disposed
    }

    public nonisolated let configuration: WalletConfiguration

    private let backend: any WalletBackend
    private let keyProvider: any WalletKeyProvider
    private let operationCoordinator: OperationCoordinator
    private let signingEngineFactory: any LocalSigningEngineFactory
    private var durableJournal: EncryptedOperationJournal?

    private var lifecycle: Lifecycle = .new
    private var session: BackendSession?
    private var signingEngine: (any LocalSigningEngine)?
    private var reportedCapabilities: WalletCapabilities = .locked

    // Swift actors are reentrant at `await`. This FIFO gate keeps lifecycle and
    // payment workflows atomic across backend suspension points.
    private var gateHeld = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    /// Opens local durable storage and builds the ordinary application facade.
    /// Call `initialize()` and then `unlock()` using the usual wallet lifecycle.
    /// A supplied key provider must load the same wallet identity on every unlock.
    public static func create(
        configuration: WalletConfiguration,
        service: WalletServiceConfiguration,
        storage: WalletStorageConfiguration,
        keyProvider: (any WalletKeyProvider)? = nil
    ) async throws -> UTEXOWallet {
        try Task.checkCancellation()
        let gatewayConfiguration = try GatewayBackendConfiguration(
            baseURL: service.baseURL, apiKeyProvider: service.apiKeyProvider,
            network: configuration.network,
            allowInsecureLocalDevelopment: service.allowInsecureLocalDevelopment,
            allowUnverifiedPsbtProfile: true,
            requestTimeout: service.requestTimeout,
            chainContextProvider: service.chainContextProvider,
            requiresApplicationChainContext: true
        )
        let provider = try keyProvider ?? KeychainSeedStore(
            service: storage.keychainService, walletID: configuration.walletID,
            accessPolicy: storage.seedAccessPolicy
        )
        let journal = try EncryptedOperationJournal(
            configuration: configuration, serviceURL: service.baseURL, storage: storage
        )
        do {
            try Task.checkCancellation()
            let backend = GatewayWalletBackend(
                configuration: gatewayConfiguration,
                identityObserver: { try await journal.bindGatewayUserID($0) }
            )
            return UTEXOWallet(
                configuration: configuration, backend: backend, keyProvider: provider,
                durableJournal: journal
            )
        } catch {
            await journal.close()
            throw error
        }
    }

    init(
        configuration: WalletConfiguration,
        backend: any WalletBackend,
        keyProvider: any WalletKeyProvider,
        durableJournal: EncryptedOperationJournal
    ) {
        self.configuration = configuration
        self.backend = backend
        self.keyProvider = keyProvider
        self.durableJournal = durableJournal
        signingEngineFactory = UniFFILocalSigningEngineFactory(
            gatewayProfile: backend is GatewayWalletBackend,
            gatewaySigningAvailable: (backend as? GatewayWalletBackend)?.hasApplicationChainContextProvider ?? true)
        operationCoordinator = OperationCoordinator(
            configuration: configuration, backend: backend, journal: durableJournal,
            now: { try checkedUnixMilliseconds() / 1_000 }
        )
    }

    /// Legacy infrastructure initializer; ordinary applications use `create`.
    @_spi(Backend)
    public init(
        configuration: WalletConfiguration,
        backend: any WalletBackend,
        keyProvider: any WalletKeyProvider,
        operationJournal: any OperationJournal
    ) {
        self.configuration = configuration
        self.backend = backend
        self.keyProvider = keyProvider
        signingEngineFactory = UniFFILocalSigningEngineFactory()
        operationCoordinator = OperationCoordinator(
            configuration: configuration,
            backend: backend,
            journal: operationJournal,
            now: { try checkedUnixMilliseconds() / 1_000 }
        )
    }

    init(
        configuration: WalletConfiguration,
        backend: any WalletBackend,
        keyProvider: any WalletKeyProvider,
        operationJournal: any OperationJournal,
        signingEngineFactory: any LocalSigningEngineFactory,
        now: @escaping @Sendable () -> UInt64
    ) {
        self.configuration = configuration
        self.backend = backend
        self.keyProvider = keyProvider
        self.signingEngineFactory = signingEngineFactory
        operationCoordinator = OperationCoordinator(
            configuration: configuration,
            backend: backend,
            journal: operationJournal,
            now: now
        )
    }

    public var capabilities: WalletCapabilities { reportedCapabilities }
    public nonisolated func getNetwork() -> Network { configuration.network }
    public func isDisposed() -> Bool { lifecycle == .disposed }

    /// Idempotently opens and negotiates a backend wallet session.
    public func initialize() async throws {
        try await exclusive { try await initializeLocked() }
    }

    /// Loads seed material locally and registers watch-only identity remotely.
    public func unlock() async throws {
        let parameters = WalletUnlockParameters.none()
        defer { parameters.close() }
        try await unlock(parameters)
    }

    public func unlock(_ parameters: WalletUnlockParameters) async throws {
        try await exclusive { try await unlockLocked(parameters) }
    }

    /// Idiomatic labeled spelling retained by the cross-platform contract.
    public func unlock(parameters: WalletUnlockParameters) async throws {
        try await unlock(parameters)
    }

    /// Restart-compatible RN lifecycle operation. Supplying parameters also unlocks.
    public func reinit(_ parameters: WalletUnlockParameters? = nil) async throws {
        try await exclusive {
            try await initializeLocked()
            if let parameters { try await unlockLocked(parameters) }
        }
    }

    /// Idiomatic spelling of the RN-compatible `reinit` operation.
    public func reinitialize(parameters: WalletUnlockParameters? = nil) async throws {
        try await reinit(parameters)
    }

    /// Stops the session, releases the in-memory signer, preserves durable wallet
    /// data and permits `reinit`. The app controls background/idle lock policy;
    /// there is no automatic application lifecycle observer in this SDK.
    /// Lifecycle operations serialize with in-flight wallet work. Shutdown is
    /// not cancellation or rollback of a transaction already being submitted.
    public func shutdown() async throws {
        try await exclusive { try await shutdownLocked(dispose: false) }
    }

    /// Idempotently closes this instance. It does not delete wallet/backend data.
    /// Local resources are closed even when the calling task has been cancelled.
    public func destroy() async throws {
        try await exclusive(honorCancellation: false) { try await shutdownLocked(dispose: true) }
    }

    /// RN compatibility alias.
    public func dispose() async throws { try await destroy() }

    public func getBtcBalance() async throws -> BTCBalance {
        try await withUnlocked { context, _ in
            try await backendCall { try await backend.getBtcBalance(context: context) }
        }
    }

    /// Allocates a fresh, locally ownership-verified address. The lightweight
    /// gateway does not provide persistent address reuse/pinning.
    public func getAddress() async throws -> BitcoinAddress {
        try await reserveAddress(rotate: false)
    }

    /// Allocates another fresh, locally verified address in gateway mode.
    /// This does not enable or rotate a persistent reusable-address setting.
    public func rotateVanillaAddress() async throws -> BitcoinAddress {
        try await reserveAddress(rotate: true)
    }

    public func listUnspents() async throws -> [Unspent] {
        try await withUnlocked { context, _ in
            try await backendCall { try await backend.listUnspents(context: context) }
        }
    }

    public func estimateFeeRate(blocks: BlockCount) async throws -> FeeEstimate {
        try await withUnlocked { context, _ in
            // The RN native estimator accepts confirmation targets 1...1008.
            // Reject invalid requests before any remote/indexer work occurs.
            guard (1...1_008).contains(blocks.rawValue) else {
                throw SDKError.invalidArgument("blocks", "must be between 1 and 1008")
            }
            let estimate = try await backendCall {
                try await backend.estimateFeeRate(context: context, targetBlocks: blocks)
            }
            guard estimate.targetBlocks == blocks else {
                throw SDKError.backendProtocolMismatch("fee estimate changed the requested confirmation target")
            }
            return estimate
        }
    }

    public func sendBtc(_ request: SendBtcRequest) async throws -> TransactionID {
        try await withUnlocked { context, signer in
            return try await operationCoordinator.sendBtc(
                backendContext: context,
                signer: signer,
                request: request
            )
        }
    }

    /// RN-shaped convenience overload. The default key creates a NEW logical payment
    /// on every invocation. Persist an explicit key and original request before the
    /// first call, and reuse both after cancellation, timeout, or process restart.
    public func sendBtc(
        address: BitcoinAddress,
        amount: Satoshis,
        feeRate: FeeRate = .default,
        skipSync: Bool = false,
        idempotencyKey: IdempotencyKey = .random()
    ) async throws -> TransactionID {
        try await sendBtc(
            .init(
                address: address,
                amount: amount,
                feeRate: feeRate,
                skipSync: skipSync,
                idempotencyKey: idempotencyKey
            )
        )
    }

    /// Output plans are derived from the prepared PSBT and independently
    /// validated against local keys before signing.
    public func createUtxos() async throws -> CreateUtxosResult {
        try await createUtxos(CreateUtxosRequest())
    }

    public func createUtxos(_ request: CreateUtxosRequest) async throws -> CreateUtxosResult {
        try await withUnlocked { context, signer in
            return try await operationCoordinator.createUtxos(backendContext: context, signer: signer, request: request)
        }
    }

    public func listAssets() async throws -> ListAssets {
        try await withUnlocked { context, _ in
            try await backendCall { try await backend.listAssets(context: context) }
        }
    }

    public func getAssetBalance(assetID: AssetID) async throws -> AssetBalance {
        try await withUnlocked { context, _ in
            try await backendCall { try await backend.getAssetBalance(context: context, assetID: assetID) }
        }
    }

    public func issueAssetNia(_ request: IssueAssetNiaRequest) async throws -> AssetNIA {
        try await withUnlocked { context, _ in
            try await backendCall { try await backend.issueAssetNia(context: context, request: request) }
        }
    }

    /// Swift acronym-casing compatibility alias.
    public func issueAssetNIA(_ request: IssueAssetNiaRequest) async throws -> AssetNIA {
        try await issueAssetNia(request)
    }

    public func issueAssetIfa(_ request: IssueAssetIfaRequest) async throws -> AssetIFA {
        try await withUnlocked { context, _ in
            try await backendCall { try await backend.issueAssetIfa(context: context, request: request) }
        }
    }

    /// Swift acronym-casing compatibility alias.
    public func issueAssetIFA(_ request: IssueAssetIfaRequest) async throws -> AssetIFA {
        try await issueAssetIfa(request)
    }

    public func blindReceive(_ request: InvoiceRequest) async throws -> InvoiceReceiveData {
        try await receiveInvoice(request, witness: false)
    }

    public func witnessReceive(_ request: InvoiceRequest) async throws -> InvoiceReceiveData {
        try await receiveInvoice(request, witness: true)
    }

    public func decodeRGBInvoice(_ invoice: RGBInvoice) async throws -> InvoiceData {
        try await withUnlocked { _, signer in
            try requireLocalRGBInvoiceParsing(signer)
            return try decodeRGBInvoiceLocally(invoice)
        }
    }

    public func decodeRgbInvoice(_ invoice: RGBInvoice) async throws -> InvoiceData {
        try await decodeRGBInvoice(invoice)
    }

    public func onchainReceive(_ request: OnchainReceiveRequest) async throws -> OnchainReceiveResponse {
        try await withUnlocked { context, signer in
            try requireLocalRGBInvoiceParsing(signer)
            let startedAt = try checkedUnixMilliseconds() / 1_000
            let response = try await backendCall {
                try await backend.onchainReceive(context: context, request: request)
            }
            try Task.checkCancellation()
            let completedAt = try checkedUnixMilliseconds() / 1_000
            // Validate even injected SPI adapters: an invoice method returning
            // a typed DTO does not establish that it represents this request.
            try validateReceivedRGBInvoice(
                response, request: request, network: configuration.network,
                startedAt: startedAt, completedAt: completedAt,
                duration: request.duration?.value ?? 86_400
            )
            return response
        }
    }

    private func receiveInvoice(_ request: InvoiceRequest, witness: Bool) async throws -> InvoiceReceiveData {
        try await withUnlocked { context, signer in
            try requireLocalRGBInvoiceParsing(signer)
            let startedAt = try checkedUnixMilliseconds() / 1_000
            // Native batch identity and the independently decoded invoice must
            // both satisfy this strict receive contract.
            let received = try await backendCall {
                if witness { return try await backend.witnessReceive(context: context, request: request) }
                return try await backend.blindReceive(context: context, request: request)
            }
            try Task.checkCancellation()
            let completedAt = try checkedUnixMilliseconds() / 1_000
            let intent = try OnchainReceiveRequest(
                amount: request.amount, assetID: request.assetID,
                minConfirmations: request.minConfirmations, duration: request.duration, witness: witness
            )
            try validateReceivedRGBInvoice(
                OnchainReceiveResponse(
                    invoice: received.invoice, recipientID: received.recipientID,
                    expirationTimestamp: received.expirationTimestamp,
                    batchTransferIndex: received.batchTransferIndex
                ),
                request: intent, network: configuration.network,
                startedAt: startedAt, completedAt: completedAt,
                duration: request.duration?.value ?? 86_400
            )
            return received
        }
    }

    /// Locally authorizes the invoice's Bitcoin transaction; full RGB state
    /// validation remains server-side. Missing native batch identity is nil.
    public func onchainSend(_ request: OnchainSendRequest) async throws -> OnchainSendResponse {
        try await withUnlocked { context, signer in
            return try await operationCoordinator.onchainSend(backendContext: context, signer: signer, request: request)
        }
    }

    /// RN-parity entry point, intentionally disabled until the backend and
    /// native core expose an exact inflation transition contract.
    public func inflate(_ request: InflateRequest) async throws -> TransactionID {
        try await withUnlocked { _, signer in
            try requireLocalSigning(signer, operation: .inflate)
            throw SDKError.unsupported(
                "backend-bound inflation preparation and RGB transition validation"
            )
        }
    }

    public func listTransactions() async throws -> [Transaction] {
        try await withUnlocked { context, _ in
            try await backendCall { try await backend.listTransactions(context: context) }
        }
    }

    public func listTransactionsByTxid(
        _ txid: TransactionID,
        skipSync: Bool = false
    ) async throws -> [Transaction] {
        try await withUnlocked { context, _ in
            try await backendCall {
                try await backend.listTransactions(context: context, txid: txid, skipSync: skipSync)
            }
        }
    }

    /// Idiomatic labeled spelling of `listTransactionsByTxid`.
    public func listTransactions(
        txid: TransactionID,
        skipSync: Bool = false
    ) async throws -> [Transaction] {
        try await listTransactionsByTxid(txid, skipSync: skipSync)
    }

    public func listTransfers(assetID: AssetID? = nil) async throws -> [Transfer] {
        try await withUnlocked { context, _ in
            try await backendCall { try await backend.listTransfers(context: context, assetID: assetID) }
        }
    }

    public func listTransfersByTxid(_ txid: TransactionID) async throws -> [Transfer] {
        try await withUnlocked { context, _ in
            try await backendCall { try await backend.listTransfers(context: context, txid: txid) }
        }
    }

    public func listOnchainTransfers(assetID: AssetID? = nil) async throws -> [Transfer] {
        try await listTransfers(assetID: assetID)
    }

    public func failTransfers(_ request: FailTransfersRequest) async throws -> FailTransfersResult {
        try await withUnlocked { context, _ in
            try await backendCall { try await backend.failTransfers(context: context, request: request) }
        }
    }

    public func refreshWallet() async throws -> SyncResult {
        try await withUnlocked { context, _ in
            try await backendCall { try await backend.refreshWallet(context: context) }
        }
    }

    public func syncWallet() async throws -> SyncResult {
        try await withUnlocked { context, _ in
            try await backendCall { try await backend.syncWallet(context: context) }
        }
    }

    private func reserveAddress(rotate: Bool) async throws -> BitcoinAddress {
        try await withUnlocked { context, signer in
            let reservation = try await backendCall {
                try await backend.reserveAddress(
                    .init(context: context, account: .vanilla, rotate: rotate)
                )
            }
            guard reservation.account == .vanilla, reservation.keychain == .external else {
                throw SDKError.backendProtocolMismatch(
                    "backend reserved an address outside the vanilla external branch"
                )
            }
            try signer.verifyReservedAddress(reservation)
            return reservation.address
        }
    }

    private func initializeLocked() async throws {
        switch lifecycle {
        case .disposed:
            throw SDKError.walletDisposed
        case .initialized, .unlocked:
            return
        case .new, .shutdown:
            break
        }
        let opened = try await backendCall {
            try await backend.initialize(
                .init(
                    walletID: configuration.walletID,
                    network: configuration.network,
                    minimumAPIVersion: configuration.minimumBackendAPIVersion,
                    maximumAPIVersion: configuration.maximumBackendAPIVersion
                )
            )
        }
        guard opened.network == configuration.network else {
            try? await backend.shutdown(session: opened)
            throw SDKError.wrongNetwork(expected: configuration.network, actual: opened.network)
        }
        guard (configuration.minimumBackendAPIVersion...configuration.maximumBackendAPIVersion)
            .contains(opened.apiVersion) else {
            try? await backend.shutdown(session: opened)
            throw SDKError.backendProtocolMismatch(
                "negotiated API version is outside the configured range",
                correlationID: opened.correlationID
            )
        }
        session = opened
        lifecycle = .initialized
    }

    private func unlockLocked(_ parameters: WalletUnlockParameters) async throws {
        switch lifecycle {
        case .unlocked:
            return
        case .disposed:
            throw SDKError.walletDisposed
        case .new, .shutdown:
            throw SDKError.invalidState(operation: "unlock", state: lifecycle.rawValue)
        case .initialized:
            break
        }
        guard let session else { throw SDKError.invariant("initialized wallet has no session") }

        let secret: SecretSeed
        do {
            secret = try await keyProvider.loadSeed(parameters: parameters)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SDKError {
            throw error
        } catch {
            throw SDKError.keyAccessFailed
        }
        defer { secret.close() }
        let candidate = try signingEngineFactory.open(network: configuration.network, seed: secret)
        try validateCapabilities(candidate.capabilities)
        let identity = try candidate.identity()
        try validateIdentity(identity)
        try await durableJournal?.bindSignerIdentity(identity)
        try await backendCall {
            try await backend.registerWallet(
                .init(
                    context: .init(
                        session: session,
                        walletID: configuration.walletID,
                        network: configuration.network
                    ),
                    identity: identity
                )
            )
        }
        signingEngine = candidate
        reportedCapabilities = candidate.capabilities
        lifecycle = .unlocked
    }

    private func shutdownLocked(dispose: Bool) async throws {
        if lifecycle == .disposed { return }
        signingEngine = nil
        reportedCapabilities = .locked
        let activeSession = session
        session = nil
        lifecycle = dispose ? .disposed : .shutdown
        // Release only on permanent disposal. `shutdown` retains exclusive ownership
        // because this instance may be reinitialized. Close even if backend close fails.
        if dispose { await durableJournal?.close() }
        if let activeSession {
            try await backendCall { try await backend.shutdown(session: activeSession) }
        }
    }

    private func validateCapabilities(_ capabilities: WalletCapabilities) throws {
        guard capabilities.derivationProfile == WalletCapabilities.derivationProfileV1 else {
            throw SDKError.backendProtocolMismatch("local derivation profile is incompatible")
        }
        guard capabilities.signingProfile == WalletCapabilities.signingProfileV1
            || capabilities.signingProfile == GatewaySigningContext.profile else {
            throw SDKError.backendProtocolMismatch("local signing profile is incompatible")
        }
    }

    private func validateIdentity(_ identity: WalletIdentity) throws {
        guard identity.network == configuration.network else {
            throw SDKError.wrongNetwork(expected: configuration.network, actual: identity.network)
        }
        guard identity.chainNetwork == configuration.network.chainNetwork else {
            throw SDKError.backendProtocolMismatch("local identity has the wrong chain network")
        }
        guard identity.derivationProfile == WalletCapabilities.derivationProfileV1 else {
            throw SDKError.backendProtocolMismatch("local identity has an unsupported derivation profile")
        }
        guard isASCIIHex(identity.masterFingerprint, exactByteCount: 8) else {
            throw SDKError.backendProtocolMismatch("local identity has an invalid master fingerprint")
        }
        _ = try requireBoundedText(identity.xpub, field: "xpub", maximumUTF8Bytes: 256)
        _ = try requireBoundedText(identity.accountXpubVanilla, field: "accountXpubVanilla", maximumUTF8Bytes: 256)
        _ = try requireBoundedText(identity.accountXpubColored, field: "accountXpubColored", maximumUTF8Bytes: 256)
    }

    private func requireLocalSigning(
        _ signer: any LocalSigningEngine,
        operation: OperationKind
    ) throws {
        guard signer.capabilities.localTransactionValidation,
              signer.capabilities.localTransactionSigning,
              signer.capabilities.localSigningOperations.contains(operation) else {
            throw SDKError.unsupported("complete local \(operation.rawValue) intent validation and signing")
        }
    }

    private func requireLocalRGBInvoiceParsing(_ signer: any LocalSigningEngine) throws {
        guard signer.capabilities.localRGBInvoiceParsing else {
            throw SDKError.unsupported("local RGB invoice parsing")
        }
    }

    private func unlockedContext() throws -> (BackendContext, any LocalSigningEngine) {
        switch lifecycle {
        case .disposed: throw SDKError.walletDisposed
        case .unlocked: break
        case .new, .initialized, .shutdown: throw SDKError.walletLocked
        }
        guard let session else { throw SDKError.invariant("unlocked wallet has no backend session") }
        guard let signingEngine else { throw SDKError.invariant("unlocked wallet has no local signer") }
        return (
            .init(session: session, walletID: configuration.walletID, network: configuration.network),
            signingEngine
        )
    }

    private func withUnlocked<T: Sendable>(
        _ body: (BackendContext, any LocalSigningEngine) async throws -> T
    ) async throws -> T {
        try await exclusive {
            let (context, signer) = try unlockedContext()
            return try await body(context, signer)
        }
    }

    private func acquireGate() async {
        if !gateHeld {
            gateHeld = true
            return
        }
        await withCheckedContinuation { gateWaiters.append($0) }
    }

    private func releaseGate() {
        if gateWaiters.isEmpty {
            gateHeld = false
        } else {
            gateWaiters.removeFirst().resume()
        }
    }

    private func exclusive<T: Sendable>(
        honorCancellation: Bool = true,
        _ body: () async throws -> T
    ) async throws -> T {
        await acquireGate()
        defer { releaseGate() }
        // A cancelled task may have spent time queued behind a signing or
        // lifecycle workflow. It must never execute the body after receiving
        // the FIFO token.
        if honorCancellation { try Task.checkCancellation() }
        return try await body()
    }
}
