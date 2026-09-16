import Foundation
import Testing
@testable @_spi(Backend) import RGBSDK

@Test func signedCheckpointResubmitsIdenticalBytesWithoutPreparingOrResigning() async throws {
    let fixture = try RecoveryFixture(phase: .signed)
    try await fixture.journal.save(fixture.initialCheckpoint)
    let result = try await fixture.coordinator.sendBtc(
        backendContext: fixture.backendContext,
        signer: NeverSigner(),
        request: fixture.request
    )

    #expect(result == fixture.txid)
    #expect(await fixture.backend.prepareCount == 0)
    #expect(await fixture.backend.submittedPSBTs == [fixture.signedPSBT])
    let checkpoint = await fixture.journal.load(
        walletID: fixture.configuration.walletID,
        idempotencyKey: fixture.request.idempotencyKey
    )
    #expect(checkpoint?.phase == .terminal)
    #expect(checkpoint?.signedPsbtBase64 == fixture.signedPSBT)
}

@Test func backendDecoratorCannotSilentlyBypassRequiredPreflight() async throws {
    let fixture = try RecoveryFixture(phase: .signed)
    try await fixture.journal.save(fixture.initialCheckpoint)
    let decorated = PreflightRejectingBackendDecorator(
        wrapped: fixture.backend,
        rejectAtCall: 2
    )
    let coordinator = OperationCoordinator(
        configuration: fixture.configuration,
        backend: decorated,
        journal: fixture.journal,
        now: { 1 }
    )

    do {
        _ = try await coordinator.sendBtc(
            backendContext: fixture.backendContext,
            signer: NeverSigner(),
            request: fixture.request
        )
        Issue.record("expected the decorator's required preflight policy")
    } catch let error as SDKError {
        #expect(error.code == .unsupported)
    }

    #expect(await decorated.preflightCount == 2)
    #expect(await fixture.backend.submittedPSBTs.isEmpty)
    #expect(
        await fixture.journal.load(
            walletID: fixture.configuration.walletID,
            idempotencyKey: fixture.request.idempotencyKey
        ) == fixture.initialCheckpoint
    )
}

@Test func submittingCheckpointReconcilesWithoutPreparingOrResigning() async throws {
    let fixture = try RecoveryFixture(phase: .submitting)
    try await fixture.journal.save(fixture.initialCheckpoint)
    await fixture.backend.setStatus(.succeeded(
        operationID: fixture.operationID,
        result: .sendBtc(operationID: fixture.operationID, txid: fixture.txid)
    ))

    let result = try await fixture.coordinator.sendBtc(
        backendContext: fixture.backendContext,
        signer: NeverSigner(),
        request: fixture.request
    )

    #expect(result == fixture.txid)
    #expect(await fixture.backend.prepareCount == 0)
    #expect(await fixture.backend.submittedPSBTs.isEmpty)
}

@Test func reconciliationCancellationIsPreserved() async throws {
    let fixture = try RecoveryFixture(phase: .submitting)
    try await fixture.journal.save(fixture.initialCheckpoint)
    await fixture.backend.cancelStatusLookup()

    await #expect(throws: CancellationError.self) {
        _ = try await fixture.coordinator.sendBtc(
            backendContext: fixture.backendContext,
            signer: NeverSigner(),
            request: fixture.request
        )
    }
    #expect(await fixture.backend.operationLookupCount == 1)
    let checkpoint = await fixture.journal.load(
        walletID: fixture.configuration.walletID,
        idempotencyKey: fixture.request.idempotencyKey
    )
    #expect(checkpoint?.phase == .submitting)
}

@Test func definitiveBackendRejectionIsPersistedAndReplayed() async throws {
    let fixture = try RecoveryFixture(phase: .submitting)
    try await fixture.journal.save(fixture.initialCheckpoint)
    await fixture.backend.setStatus(
        .failed(
            operationID: fixture.operationID,
            safeMessage: "transaction rejected",
            retryable: false,
            backendCode: "policy_rejected",
            correlationID: "correlation-1"
        )
    )

    for _ in 0..<2 {
        do {
            _ = try await fixture.coordinator.sendBtc(
                backendContext: fixture.backendContext,
                signer: NeverSigner(),
                request: fixture.request
            )
            Issue.record("expected durable backend rejection")
        } catch let error as SDKError {
            #expect(error.code == .backendRejected)
            #expect(error.retryable == false)
            #expect(error.details["backendCode"] == "policy_rejected")
        }
    }

    #expect(await fixture.backend.operationLookupCount == 1)
    let checkpoint = await fixture.journal.load(
        walletID: fixture.configuration.walletID,
        idempotencyKey: fixture.request.idempotencyKey
    )
    #expect(checkpoint?.phase == .terminal)
    guard case .rejected = checkpoint?.terminalOutcome else {
        Issue.record("expected rejected terminal outcome")
        return
    }
}

@Test func definitiveBackendExpiryIsPersistedAndReplayed() async throws {
    let fixture = try RecoveryFixture(phase: .submitting)
    try await fixture.journal.save(fixture.initialCheckpoint)
    await fixture.backend.setStatus(.expired(operationID: fixture.operationID))

    for _ in 0..<2 {
        do {
            _ = try await fixture.coordinator.sendBtc(
                backendContext: fixture.backendContext,
                signer: NeverSigner(),
                request: fixture.request
            )
            Issue.record("expected durable operation expiry")
        } catch let error as SDKError {
            #expect(error.code == .operationExpired)
        }
    }

    #expect(await fixture.backend.operationLookupCount == 1)
    let checkpoint = await fixture.journal.load(
        walletID: fixture.configuration.walletID,
        idempotencyKey: fixture.request.idempotencyKey
    )
    #expect(checkpoint?.phase == .terminal)
    guard case .expired = checkpoint?.terminalOutcome else {
        Issue.record("expected expired terminal outcome")
        return
    }
}

@Test func preparedCheckpointSignsExactPersistedPreparationWithoutPreparingAgain() async throws {
    let fixture = try RecoveryFixture(phase: .prepared)
    try await fixture.journal.save(fixture.initialCheckpoint)
    let signer = RecordingSigner(
        signedPsbtBase64: fixture.signedPSBT,
        validation: fixture.validation
    )

    let result = try await fixture.coordinator.sendBtc(
        backendContext: fixture.backendContext,
        signer: signer,
        request: fixture.request
    )

    #expect(result == fixture.txid)
    #expect(await fixture.backend.prepareCount == 0)
    #expect(signer.preparedPSBTs == [fixture.preparedPSBT])
    #expect(await fixture.backend.submittedPSBTs == [fixture.signedPSBT])
}

@Test func expiryAfterSigningIsPersistedWithoutSubmitting() async throws {
    let fixture = try RecoveryFixture(phase: .prepared)
    try await fixture.journal.save(fixture.initialCheckpoint)
    let signer = RecordingSigner(
        signedPsbtBase64: fixture.signedPSBT,
        validation: fixture.validation
    )
    let clock = StepClock([1_000, 1_000, 1_001])
    let coordinator = OperationCoordinator(
        configuration: fixture.configuration,
        backend: fixture.backend,
        journal: fixture.journal,
        now: { clock.next() }
    )

    do {
        _ = try await coordinator.sendBtc(
            backendContext: fixture.backendContext,
            signer: signer,
            request: fixture.request
        )
        Issue.record("expected the operation to expire after local signing")
    } catch let error as SDKError {
        #expect(error.code == .operationExpired)
        #expect(error.operationID == fixture.operationID)
    }

    #expect(await fixture.backend.submittedPSBTs.isEmpty)
    let checkpoint = await fixture.journal.load(
        walletID: fixture.configuration.walletID,
        idempotencyKey: fixture.request.idempotencyKey
    )
    #expect(checkpoint?.phase == .terminal)
    #expect(checkpoint?.signedPsbtBase64 == fixture.signedPSBT)
    #expect(checkpoint?.validation == fixture.validation)
    guard case let .expired(operationID) = checkpoint?.terminalOutcome else {
        Issue.record("expected a durable expired outcome")
        return
    }
    #expect(operationID == fixture.operationID)
}

@Test func expiryDuringPreSignPreflightNeverProducesASignature() async throws {
    let fixture = try RecoveryFixture(phase: .prepared)
    try await fixture.journal.save(fixture.initialCheckpoint)
    let signer = RecordingSigner(
        signedPsbtBase64: fixture.signedPSBT,
        validation: fixture.validation
    )
    let clock = StepClock([1_000, 1_001])
    let coordinator = OperationCoordinator(
        configuration: fixture.configuration,
        backend: fixture.backend,
        journal: fixture.journal,
        now: { clock.next() }
    )

    do {
        _ = try await coordinator.sendBtc(
            backendContext: fixture.backendContext,
            signer: signer,
            request: fixture.request
        )
        Issue.record("expected expiry after the pre-sign policy suspension")
    } catch let error as SDKError {
        #expect(error.code == .operationExpired)
        #expect(error.operationID == fixture.operationID)
    }

    #expect(signer.preparedPSBTs.isEmpty)
    #expect(await fixture.backend.submittedPSBTs.isEmpty)
    let checkpoint = await fixture.journal.load(
        walletID: fixture.configuration.walletID,
        idempotencyKey: fixture.request.idempotencyKey
    )
    #expect(checkpoint?.phase == .terminal)
    #expect(checkpoint?.signedPsbtBase64 == nil)
    #expect(checkpoint?.validation == nil)
}

@Test func requestFeeRateIsAnAuthorizationCap() throws {
    let appPolicy = LocalSigningPolicy.default
    let requested = try FeeRate(satsPerVByte: 1.5)
    #expect(authorizedFeeRateCap(appPolicy: appPolicy, requested: requested) == 1_500)
}

@Test func mismatchedBackendTxidIsAmbiguousAndNeverPersistedAsTerminal() async throws {
    let fixture = try RecoveryFixture(phase: .signed)
    try await fixture.journal.save(fixture.initialCheckpoint)
    await fixture.backend.setResult(
        .sendBtc(
            operationID: fixture.operationID,
            txid: try TransactionID(String(repeating: "9", count: 64))
        )
    )

    do {
        _ = try await fixture.coordinator.sendBtc(
            backendContext: fixture.backendContext,
            signer: NeverSigner(),
            request: fixture.request
        )
        Issue.record("expected ambiguous operation outcome")
    } catch let error as SDKError {
        #expect(error.code == .operationAmbiguous)
        #expect(error.operationID == fixture.operationID)
    }

    let checkpoint = await fixture.journal.load(
        walletID: fixture.configuration.walletID,
        idempotencyKey: fixture.request.idempotencyKey
    )
    #expect(checkpoint?.phase == .submitting)
    #expect(checkpoint?.terminalResult == nil)
}

@Test func mismatchedBackendOperationIDIsAmbiguousAndNeverPersistedAsTerminal() async throws {
    let fixture = try RecoveryFixture(phase: .signed)
    try await fixture.journal.save(fixture.initialCheckpoint)
    await fixture.backend.setResult(
        .sendBtc(
            operationID: try OperationID("different-operation"),
            txid: fixture.txid
        )
    )

    do {
        _ = try await fixture.coordinator.sendBtc(
            backendContext: fixture.backendContext,
            signer: NeverSigner(),
            request: fixture.request
        )
        Issue.record("expected ambiguous operation identity")
    } catch let error as SDKError {
        #expect(error.code == .operationAmbiguous)
        #expect(error.operationID == fixture.operationID)
    }

    let checkpoint = await fixture.journal.load(
        walletID: fixture.configuration.walletID,
        idempotencyKey: fixture.request.idempotencyKey
    )
    #expect(checkpoint?.phase == .submitting)
    #expect(checkpoint?.terminalResult == nil)
}

@Test func directDefinitiveBackendRejectionIsPersistedAndReplayed() async throws {
    let fixture = try RecoveryFixture(phase: .signed)
    try await fixture.journal.save(fixture.initialCheckpoint)
    await fixture.backend.setSubmissionError(
        SDKError(
            code: .backendRejected,
            retryable: false,
            message: "The gateway rejected the locally signed transaction",
            operationID: fixture.operationID,
            correlationID: "correlation-direct-rejection",
            details: ["backendCode": "PSBT_MISMATCH"]
        )
    )

    for _ in 0..<2 {
        do {
            _ = try await fixture.coordinator.sendBtc(
                backendContext: fixture.backendContext,
                signer: NeverSigner(),
                request: fixture.request
            )
            Issue.record("expected durable direct backend rejection")
        } catch let error as SDKError {
            #expect(error.code == .backendRejected)
            #expect(error.retryable == false)
            #expect(error.operationID == fixture.operationID)
            #expect(error.details["backendCode"] == "PSBT_MISMATCH")
        }
    }

    #expect(await fixture.backend.submittedPSBTs.count == 1)
    let checkpoint = await fixture.journal.load(
        walletID: fixture.configuration.walletID,
        idempotencyKey: fixture.request.idempotencyKey
    )
    #expect(checkpoint?.phase == .terminal)
    guard case .rejected = checkpoint?.terminalOutcome else {
        Issue.record("expected rejected terminal outcome")
        return
    }
}

@Test func directDefinitiveBackendExpiryIsPersistedAndReplayed() async throws {
    let fixture = try RecoveryFixture(phase: .signed)
    try await fixture.journal.save(fixture.initialCheckpoint)
    await fixture.backend.setSubmissionError(SDKError.operationExpired(fixture.operationID))

    for _ in 0..<2 {
        do {
            _ = try await fixture.coordinator.sendBtc(
                backendContext: fixture.backendContext,
                signer: NeverSigner(),
                request: fixture.request
            )
            Issue.record("expected durable direct operation expiry")
        } catch let error as SDKError {
            #expect(error.code == .operationExpired)
            #expect(error.operationID == fixture.operationID)
        }
    }

    #expect(await fixture.backend.submittedPSBTs.count == 1)
    let checkpoint = await fixture.journal.load(
        walletID: fixture.configuration.walletID,
        idempotencyKey: fixture.request.idempotencyKey
    )
    #expect(checkpoint?.phase == .terminal)
    guard case .expired = checkpoint?.terminalOutcome else {
        Issue.record("expected expired terminal outcome")
        return
    }
}

@Test func arbitraryJournalErrorsAreMappedToStableSafeError() async throws {
    let fixture = try RecoveryFixture(phase: .created)
    let coordinator = OperationCoordinator(
        configuration: fixture.configuration,
        backend: fixture.backend,
        journal: FailingJournal(),
        now: { 1 }
    )
    do {
        _ = try await coordinator.sendBtc(
            backendContext: fixture.backendContext,
            signer: NeverSigner(),
            request: fixture.request
        )
        Issue.record("expected operation journal failure")
    } catch let error as SDKError {
        #expect(error.code == .operationJournalUnavailable)
        #expect(!error.message.contains("database-path"))
    }
}

@Test func walletLifecycleIsIdempotentAndDisposeIsTerminal() async throws {
    let fixture = try RecoveryFixture(phase: .created)
    let wallet = UTEXOWallet(
        configuration: fixture.configuration,
        backend: fixture.backend,
        keyProvider: StaticKeyProvider(),
        operationJournal: fixture.journal,
        signingEngineFactory: IdentitySignerFactory(),
        now: { 1 }
    )

    await #expect(throws: SDKError.self) { try await wallet.getBtcBalance() }
    try await wallet.initialize()
    try await wallet.initialize()
    #expect(await fixture.backend.initializeCount == 1)

    try await wallet.unlock()
    #expect(await wallet.capabilities.localTransactionSigning)
    try await wallet.shutdown()
    #expect(!(await wallet.capabilities.localTransactionSigning))

    let parameters = WalletUnlockParameters.none()
    defer { parameters.close() }
    try await wallet.reinitialize(parameters: parameters)
    #expect(await wallet.capabilities.localTransactionSigning)

    try await wallet.dispose()
    try await wallet.dispose()
    #expect(await wallet.isDisposed())
    await #expect(throws: SDKError.self) { try await wallet.initialize() }
}

@Test func cancelledQueuedSendNeverReachesBackendOrCreatesJournalState() async throws {
    let configuration = try WalletConfiguration(
        walletID: WalletID("cancel-wallet"),
        network: .signet
    )
    let backend = BlockingBalanceBackend(
        session: try BackendSession(id: "cancel-session", apiVersion: 1, network: .signet)
    )
    let journal = InMemoryOperationJournal()
    let wallet = UTEXOWallet(
        configuration: configuration,
        backend: backend,
        keyProvider: StaticKeyProvider(),
        operationJournal: journal,
        signingEngineFactory: IdentitySignerFactory(),
        now: { 1 }
    )
    try await wallet.initialize()
    try await wallet.unlock()

    let first = Task { try await wallet.getBtcBalance() }
    await backend.waitUntilFirstCallStarts()
    let request = try SendBtcRequest(
        address: BitcoinAddress(
            "tb1ptestaddress000000000000000000000000000000000000000000000000000"
        ),
        amount: Satoshis(10_000),
        idempotencyKey: IdempotencyKey("cancelled-send")
    )
    let cancelled = Task { try await wallet.sendBtc(request) }
    await Task.yield()
    cancelled.cancel()
    await backend.releaseFirstCall()

    _ = try await first.value
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(await backend.balanceCallCount == 1)
    #expect(await backend.prepareCount == 0)
    let checkpoint = await journal.load(
        walletID: configuration.walletID,
        idempotencyKey: request.idempotencyKey
    )
    #expect(checkpoint == nil)
}

private struct RecoveryFixture {
    let configuration: WalletConfiguration
    let backend: RecoveryBackend
    let journal: InMemoryOperationJournal
    let coordinator: OperationCoordinator
    let backendContext: BackendContext
    let request: SendBtcRequest
    let operationID: OperationID
    let txid: TransactionID
    let preparedPSBT = "prepared-psbt"
    let signedPSBT = "signed-psbt"
    let prepared: PreparedTransaction
    let validation: LocalValidationReport
    let initialCheckpoint: OperationCheckpoint

    init(phase: OperationPhase) throws {
        configuration = try WalletConfiguration(
            walletID: WalletID("recovery-wallet"),
            network: .signet
        )
        request = try SendBtcRequest(
            address: BitcoinAddress(
                "tb1ptestaddress000000000000000000000000000000000000000000000000000"
            ),
            amount: Satoshis(10_000),
            idempotencyKey: IdempotencyKey("recovery-key")
        )
        operationID = try OperationID("operation-1")
        txid = try TransactionID(String(repeating: "1", count: 64))
        let session = try BackendSession(id: "session-1", apiVersion: 1, network: .signet)
        backendContext = .init(
            session: session,
            walletID: configuration.walletID,
            network: configuration.network
        )
        backend = RecoveryBackend(
            result: .sendBtc(operationID: operationID, txid: txid),
            session: session
        )
        journal = InMemoryOperationJournal()
        coordinator = OperationCoordinator(
            configuration: configuration,
            backend: backend,
            journal: journal,
            now: { 1 }
        )

        let hash = try RequestHasher.sendBtc(network: .signet, request: request)
        validation = try LocalValidationReport(
            psbtSHA256: String(repeating: "2", count: 64),
            intentSHA256: String(repeating: "3", count: 64),
            unsignedTxid: txid,
            totalInput: try Satoshis(20_000),
            totalOutput: try Satoshis(19_000),
            fee: try Satoshis(1_000),
            estimatedVbytes: 100,
            feeRate: try FeeRate(satsPerVByte: 10.0),
            externalOutput: try Satoshis(10_000),
            change: try Satoshis(9_000),
            inputCount: 1,
            outputCount: 2,
            opReturnCount: 0
        )
        prepared = try PreparedTransaction(
            operationID: operationID,
            idempotencyKey: request.idempotencyKey,
            requestHash: hash,
            network: configuration.network,
            operation: .sendBtc,
            psbtBase64: preparedPSBT,
            expiresAt: .init(rawValue: 1_001)
        )
        initialCheckpoint = try OperationCheckpoint(
            walletID: configuration.walletID,
            idempotencyKey: request.idempotencyKey,
            requestHash: hash,
            operationKind: .sendBtc,
            phase: phase,
            operationID: phase == .created ? nil : operationID,
            preparedTransaction: phase == .created ? nil : prepared,
            signedPsbtBase64: phase >= .signed ? signedPSBT : nil,
            validation: phase >= .signed ? validation : nil
        )
    }
}

private struct NeverSigner: LocalSigningEngine {
    let capabilities = WalletCapabilities.locked
    func identity() throws -> WalletIdentity { throw SDKError.invariant("unexpected identity") }
    func verifyReservedAddress(_ reservation: ReservedAddress) throws {
        throw SDKError.invariant("unexpected address verification")
    }
    func validateAndSign(
        prepared: PreparedTransaction,
        request: SendBtcRequest,
        policy: LocalSigningPolicy
    ) throws -> LocalSigningResult {
        throw SDKError.invariant("unexpected signing")
    }
}

private final class RecordingSigner: LocalSigningEngine, @unchecked Sendable {
    let capabilities = WalletCapabilities(
        localKeyDerivation: true,
        localTransactionValidation: true,
        localTransactionSigning: true,
        localRGBInvoiceParsing: false,
        localRGBValidation: false,
        localSigningOperations: [.sendBtc],
        derivationProfile: WalletCapabilities.derivationProfileV1,
        signingProfile: WalletCapabilities.signingProfileV1
    )

    private let lock = NSLock()
    private let result: LocalSigningResult
    private var recordedPSBTs: [String] = []

    init(signedPsbtBase64: String, validation: LocalValidationReport) {
        result = .init(signedPsbtBase64: signedPsbtBase64, validation: validation)
    }

    var preparedPSBTs: [String] { lock.withLock { recordedPSBTs } }

    func identity() throws -> WalletIdentity { throw SDKError.invariant("unexpected identity") }
    func verifyReservedAddress(_ reservation: ReservedAddress) throws {
        throw SDKError.invariant("unexpected address verification")
    }
    func validateAndSign(
        prepared: PreparedTransaction,
        request: SendBtcRequest,
        policy: LocalSigningPolicy
    ) throws -> LocalSigningResult {
        lock.withLock { recordedPSBTs.append(prepared.psbtBase64) }
        return result
    }
}

private actor RecoveryBackend: WalletBackend {
    private var result: BackendOperationResult
    let session: BackendSession
    private(set) var prepareCount = 0
    private(set) var initializeCount = 0
    private(set) var submittedPSBTs: [String] = []
    private(set) var operationLookupCount = 0
    private var status: BackendOperationStatus?
    private var cancelNextStatusLookup = false
    private var submissionError: SDKError?

    init(result: BackendOperationResult, session: BackendSession) {
        self.result = result
        self.session = session
    }

    func preflightOperation(_ operation: OperationKind) async throws {}
    func setResult(_ result: BackendOperationResult) { self.result = result }
    func setStatus(_ status: BackendOperationStatus) { self.status = status }
    func cancelStatusLookup() { cancelNextStatusLookup = true }
    func setSubmissionError(_ error: SDKError?) { submissionError = error }
    func initialize(_ request: BackendInitializeRequest) async throws -> BackendSession {
        initializeCount += 1
        return session
    }
    func registerWallet(_ request: RegisterWalletRequest) async throws {}
    func shutdown(session: BackendSession) async throws {}

    func prepareSendBtc(_ request: PrepareSendBtcRequest) async throws -> PreparedTransaction {
        prepareCount += 1
        throw SDKError.invariant("prepare must not be called during recovery")
    }

    func submitSignedTransaction(
        _ request: SignedTransactionSubmission
    ) async throws -> BackendOperationResult {
        submittedPSBTs.append(request.signedPsbtBase64)
        if let submissionError { throw submissionError }
        return result
    }

    func getOperation(
        context: BackendContext,
        operationID: OperationID
    ) async throws -> BackendOperationStatus {
        operationLookupCount += 1
        if cancelNextStatusLookup {
            cancelNextStatusLookup = false
            throw CancellationError()
        }
        return status ?? .pending(operationID: operationID, phase: "unknown")
    }
}

private actor PreflightRejectingBackendDecorator: WalletBackend {
    let wrapped: RecoveryBackend
    let rejectAtCall: Int
    private(set) var preflightCount = 0

    init(wrapped: RecoveryBackend, rejectAtCall: Int) {
        self.wrapped = wrapped
        self.rejectAtCall = rejectAtCall
    }

    func preflightOperation(_ operation: OperationKind) async throws {
        preflightCount += 1
        if preflightCount >= rejectAtCall {
            throw SDKError.unsupported("decorated backend money movement")
        }
    }

    func initialize(_ request: BackendInitializeRequest) async throws -> BackendSession {
        try await wrapped.initialize(request)
    }

    func registerWallet(_ request: RegisterWalletRequest) async throws {
        try await wrapped.registerWallet(request)
    }

    func shutdown(session: BackendSession) async throws {
        try await wrapped.shutdown(session: session)
    }

    func submitSignedTransaction(
        _ request: SignedTransactionSubmission
    ) async throws -> BackendOperationResult {
        try await wrapped.submitSignedTransaction(request)
    }
}

private final class StepClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]

    init(_ values: [UInt64]) {
        self.values = values
    }

    func next() -> UInt64 {
        lock.withLock {
            guard !values.isEmpty else { return .max }
            return values.removeFirst()
        }
    }
}

private struct StaticKeyProvider: WalletKeyProvider {
    func loadSeed(parameters: WalletUnlockParameters) async throws -> SecretSeed {
        try SecretSeed(copying: [UInt8](repeating: 7, count: SecretSeed.byteCount))
    }
}

private struct IdentitySignerFactory: LocalSigningEngineFactory {
    func open(network: Network, seed: SecretSeed) throws -> any LocalSigningEngine {
        IdentitySigner(network: network)
    }
}

private struct IdentitySigner: LocalSigningEngine {
    let network: Network
    let capabilities = WalletCapabilities(
        localKeyDerivation: true,
        localTransactionValidation: true,
        localTransactionSigning: true,
        localRGBInvoiceParsing: false,
        localRGBValidation: false,
        localSigningOperations: [.sendBtc],
        derivationProfile: WalletCapabilities.derivationProfileV1,
        signingProfile: WalletCapabilities.signingProfileV1
    )

    func identity() throws -> WalletIdentity {
        WalletIdentity(
            network: network,
            chainNetwork: network.chainNetwork,
            derivationProfile: WalletCapabilities.derivationProfileV1,
            masterFingerprint: "42424232",
            xpub: "tpub-root",
            accountXpubVanilla: "tpub-vanilla",
            accountXpubColored: "tpub-colored"
        )
    }

    func verifyReservedAddress(_ reservation: ReservedAddress) throws {}

    func validateAndSign(
        prepared: PreparedTransaction,
        request: SendBtcRequest,
        policy: LocalSigningPolicy
    ) throws -> LocalSigningResult {
        throw SDKError.invariant("not used")
    }
}

private struct FailingJournal: OperationJournal {
    private struct StorageFailure: Error {}

    func load(walletID: WalletID, idempotencyKey: IdempotencyKey) async throws -> OperationCheckpoint? {
        throw StorageFailure()
    }

    func save(_ checkpoint: OperationCheckpoint) async throws {
        throw StorageFailure()
    }
}

private actor BlockingBalanceBackend: WalletBackend {
    let session: BackendSession
    private(set) var balanceCallCount = 0
    private(set) var prepareCount = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstCallRelease: CheckedContinuation<Void, Never>?

    init(session: BackendSession) { self.session = session }

    func preflightOperation(_ operation: OperationKind) async throws {}
    func initialize(_ request: BackendInitializeRequest) async throws -> BackendSession { session }
    func registerWallet(_ request: RegisterWalletRequest) async throws {}
    func shutdown(session: BackendSession) async throws {}

    func getBtcBalance(context: BackendContext) async throws -> BTCBalance {
        balanceCallCount += 1
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if balanceCallCount == 1 {
            await withCheckedContinuation { firstCallRelease = $0 }
        }
        let zero = Balance(settled: .zero, future: .zero, spendable: .zero)
        return BTCBalance(vanilla: zero, colored: zero)
    }

    func prepareSendBtc(_ request: PrepareSendBtcRequest) async throws -> PreparedTransaction {
        prepareCount += 1
        throw SDKError.invariant("a cancelled queued send reached the backend")
    }

    func waitUntilFirstCallStarts() async {
        if balanceCallCount > 0 { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseFirstCall() {
        firstCallRelease?.resume()
        firstCallRelease = nil
    }
}
