import Foundation
import Testing

@testable @_spi(Backend) import RGBSDK

@Test func createAndRgbFreshOperationsPersistExactResultsAndReplayWithoutWork() async throws {
    for create in [true, false] {
        let fixture = try GenericOperationFixture(create: create)
        let expected = try await fixture.perform()
        #expect(try await fixture.perform() == expected)
        #expect(await fixture.backend.prepareCount == 1)
        #expect(await fixture.backend.submitCount == 1)
        let terminal = try #require(await fixture.checkpoint())
        #expect(terminal.phase == .terminal && terminal.terminalResult == expected)
        #expect(terminal.operationKind == fixture.request.kind)
        try await fixture.journal.save(terminal.compactTerminal)
        #expect(try await fixture.perform() == expected)
        #expect(await fixture.backend.submitCount == 1)
    }
}

@Test func createAndRgbPreflightRejectsBeforePrepareOrJournalMutation() async throws {
    for create in [true, false] {
        let fixture = try GenericOperationFixture(create: create)
        await fixture.backend.setDenied(true)
        do {
            _ = try await fixture.perform()
            Issue.record("expected operation gate")
        } catch let error as SDKError { #expect(error.code == .unsupported) }
        #expect(await fixture.checkpoint() == nil)
        #expect(await fixture.backend.prepareCount == 0)
        #expect(await fixture.backend.submitCount == 0)
    }
}

@Test func createAndRgbAmbiguityRetainsEvidenceAndNextCallOnlyReconciles() async throws {
    for create in [true, false] {
        let fixture = try GenericOperationFixture(create: create)
        await fixture.backend.setTimeout(true)
        do {
            _ = try await fixture.perform()
            Issue.record("expected ambiguous submission")
        } catch let error as SDKError { #expect(error.code == .operationAmbiguous) }
        let submitting = try #require(await fixture.checkpoint())
        #expect(submitting.phase == .submitting)
        #expect(submitting.signedPsbtBase64 != nil && submitting.validation != nil)
        await fixture.backend.setDenied(true)
        await fixture.backend.setCompleted(true)
        // Read-only recovery is allowed even when every new money operation
        // is now gated. The retained native signature is not recreated.
        #expect(
            try await fixture.perform(
                now: 2_000_000_001, signerOverride: GatewayNativeFixtures.signer(gateway: false)
            ) == fixture.result)
        #expect(await fixture.backend.prepareCount == 1)
        #expect(await fixture.backend.submitCount == 1)
        #expect(await fixture.backend.statusCount == 2)
    }
}

@Test func createResultCountMustEqualLocallyAuthorizedOutputsBeforeTerminalPersistence() async throws {
    let fixture = try GenericOperationFixture(create: true)
    await fixture.backend.setResult(
        .createUtxos(
            operationID: fixture.prepared.operationID,
            result: .init(txid: fixture.result.transactionID, createdUtxoCount: 4)))
    do {
        _ = try await fixture.perform()
        Issue.record("expected changed result count")
    } catch let error as SDKError { #expect(error.code == .operationAmbiguous) }
    #expect(await fixture.checkpoint()?.phase == .submitting)
    await fixture.backend.setCompleted(true)
    do {
        _ = try await fixture.perform()
        Issue.record("status cannot bless the wrong count")
    } catch let error as SDKError { #expect(error.code == .operationAmbiguous) }
    #expect(await fixture.backend.submitCount == 1)
    #expect(await fixture.checkpoint()?.phase == .submitting)
    await fixture.backend.setResult(fixture.result)
    #expect(try await fixture.perform() == fixture.result)
}

@Test func createAcceptsNativePartialCountButReturnsActualCount() async throws {
    // Same local fixture transaction, authorizing a larger requested maximum;
    // this is an authorization test, not a claim of a new gateway capture.
    let fixture = try GenericOperationFixture(create: true, createDesiredCount: 6)
    #expect(try await fixture.perform() == fixture.result)
    let terminal = try #require(await fixture.checkpoint())
    guard case .createUtxos(_, let result) = terminal.terminalResult else {
        Issue.record("expected create result")
        return
    }
    #expect(result.createdUtxoCount == 5)
    try await fixture.journal.save(terminal.compactTerminal)
    #expect(try await fixture.perform() == fixture.result)
}

@Test func createAndRgbRetainedSignedStateSubmitsIdenticalBytesAfterCurrentPolicyValidation() async throws {
    for create in [true, false] {
        let fixture = try GenericOperationFixture(create: create)
        let signed = try fixture.request.validateAndSign(
            signer: fixture.signer, prepared: fixture.prepared, policy: .default, now: 1_800_000_000)
        try await fixture.journal.save(
            .init(
                walletID: fixture.context.walletID,
                idempotencyKey: fixture.request.idempotencyKey, requestHash: fixture.prepared.requestHash,
                operationKind: fixture.request.kind, phase: .signed,
                operationID: fixture.prepared.operationID,
                preparedTransaction: fixture.prepared, signedPsbtBase64: signed.signedPsbtBase64,
                validation: signed.validation))
        #expect(try await fixture.perform() == fixture.result)
        #expect(await fixture.backend.prepareCount == 0)
        #expect(await fixture.backend.lastSignedPSBT == signed.signedPsbtBase64)
    }
}

@Test func createAndRgbPreparedStateNeverCrossesChangedRequestIdentity() async throws {
    for create in [true, false] {
        let fixture = try GenericOperationFixture(create: create)
        try await fixture.journal.save(
            .init(
                walletID: fixture.context.walletID,
                idempotencyKey: fixture.request.idempotencyKey,
                requestHash: RequestHash(validating: String(repeating: "a", count: 64)),
                operationKind: fixture.request.kind, phase: .created))
        do {
            _ = try await fixture.perform()
            Issue.record("expected request identity conflict")
        } catch let error as SDKError { #expect(error.code == .operationConflict) }
        #expect(await fixture.backend.prepareCount == 0)
        #expect(await fixture.backend.submitCount == 0)
    }
}

@Test func expiredRgbInvoiceStillAllowsSubmittingRecoveryAndTerminalReplay() async throws {
    let fixture = try GenericOperationFixture(create: false, rgbExpiry: 1_800_000_005)
    await fixture.backend.setTimeout(true)
    do {
        _ = try await fixture.perform()
        Issue.record("expected retained submitting state")
    } catch let error as SDKError { #expect(error.code == .operationAmbiguous) }
    await fixture.backend.setCompleted(true)
    #expect(try await fixture.perform(now: 1_800_000_006) == fixture.result)
    #expect(try await fixture.perform(now: 1_800_000_007) == fixture.result)
    #expect(await fixture.backend.submitCount == 1)
    #expect(await fixture.backend.statusCount == 2)
}

@Test func privateCreateAndRgbSignersRejectWrongRequestHashWithoutCoordinator() throws {
    for create in [true, false] {
        let fixture = try GenericOperationFixture(create: create)
        let original = fixture.prepared
        let wrong = try PreparedTransaction(
            operationID: original.operationID, idempotencyKey: original.idempotencyKey,
            requestHash: RequestHash(validating: String(repeating: "a", count: 64)),
            network: original.network, operation: original.operation,
            psbtBase64: original.psbtBase64, expiresAt: original.expiresAt,
            createUtxosOutputPlan: original.createUtxosOutputPlan
        )
        #expect(throws: SDKError.self) {
            try fixture.request.validateAndSign(
                signer: fixture.signer, prepared: wrong, policy: .default, now: 1_800_000_000)
        }
    }
}

@Test func createOutputPlanRejectsWrongDefaultsScopesDuplicatesAndCounts() throws {
    let request = try CreateUtxosRequest(upTo: false)
    let valid = try (0..<5).map {
        try ExpectedWalletOutput(
            account: .colored, keychain: .external, index: UInt32($0), amount: Satoshis(1_000))
    }
    let variants = try [
        valid + [valid[0]],
        [ExpectedWalletOutput(account: .vanilla, keychain: .external, index: 0, amount: Satoshis(1_000))]
            + valid.dropFirst(),
        [ExpectedWalletOutput(account: .colored, keychain: .change, index: 0, amount: Satoshis(1_000))]
            + valid.dropFirst(),
        [ExpectedWalletOutput(account: .colored, keychain: .external, index: 0, amount: Satoshis(2_000))]
            + valid.dropFirst(),
        [valid[1]] + valid.dropFirst(),
    ]
    for outputs in variants {
        let prepared = try GatewayNativeFixtures.prepared(
            .createUtxos(request), psbt: "synthetic", plan: CreateUtxosOutputPlan(outputs: outputs))
        #expect(throws: SDKError.self) {
            try LocalOperationRequest.createUtxos(request).verifyPreparedPlan(prepared, policy: .default)
        }
    }
}

private struct GenericOperationFixture {
    let request: LocalOperationRequest
    let prepared: PreparedTransaction
    let result: BackendOperationResult
    let context: BackendContext
    let signer: any LocalSigningEngine
    let backend: GenericOperationBackend
    let journal = InMemoryOperationJournal()

    init(create: Bool, rgbExpiry: UInt64? = nil, createDesiredCount: UInt16 = 5) throws {
        context = try .init(
            session: BackendSession(id: "generic", apiVersion: 1, network: .regtest),
            walletID: WalletID("generic"), network: .regtest)
        signer = try GatewayNativeFixtures.signer()
        if create {
            let r = try CreateUtxosRequest(
                upTo: false, num: createDesiredCount, size: Satoshis(5_000),
                feeRate: FeeRate(satsPerVByte: 2),
                idempotencyKey: IdempotencyKey("generic-create"))
            request = .createUtxos(r)
            let outputs = try [6, 7, 9, 8, 10].map {
                try ExpectedWalletOutput(
                    account: .colored, keychain: .external, index: UInt32($0), amount: Satoshis(5_000))
            }
            prepared = try GatewayNativeFixtures.prepared(
                request, psbt: GatewayNativeFixtures.create, plan: CreateUtxosOutputPlan(outputs: outputs))
            result = .createUtxos(
                operationID: prepared.operationID,
                result: .init(
                    txid: try TransactionID(
                        "9f4b8d594d577e5b73cd941db229870965f099bf0092df8cf9444cc309986967"),
                    createdUtxoCount: 5))
        } else {
            let r = try OnchainSendRequest(
                invoice: RGBInvoice(
                    rgbExpiry.map {
                        GatewayNativeFixtures.rgbInvoice.replacingOccurrences(
                            of: "?endpoints=", with: "?expiry=\($0)&endpoints=")
                    } ?? GatewayNativeFixtures.rgbInvoice),
                amount: AssetAmount(40),
                feeRate: FeeRate(satsPerVByte: 2), idempotencyKey: IdempotencyKey("generic-rgb"))
            request = .onchainSend(r)
            prepared = try GatewayNativeFixtures.prepared(request, psbt: GatewayNativeFixtures.rgb)
            result = .onchainSend(
                operationID: prepared.operationID,
                result: .init(
                    txid: try TransactionID(
                        "e41e4ebdc769b0575126a5d728394d4c01206110e7eaebf6446029d5acd0d814"),
                    batchTransferIndex: 42))
        }
        backend = GenericOperationBackend(prepared: prepared, result: result)
    }

    func perform(
        now: UInt64 = 1_800_000_001, signerOverride: (any LocalSigningEngine)? = nil
    ) async throws -> BackendOperationResult {
        let coordinator = OperationCoordinator(
            configuration: try WalletConfiguration(walletID: context.walletID, network: .regtest),
            backend: backend, journal: journal, now: { now })
        switch request {
        case .createUtxos(let r):
            return .createUtxos(
                operationID: prepared.operationID,
                result: try await coordinator.createUtxos(
                    backendContext: context, signer: signerOverride ?? signer, request: r)
            )
        case .onchainSend(let r):
            return .onchainSend(
                operationID: prepared.operationID,
                result: try await coordinator.onchainSend(
                    backendContext: context, signer: signerOverride ?? signer, request: r)
            )
        default: throw SDKError.invariant("not a generic fixture")
        }
    }
    func checkpoint() async -> OperationCheckpoint? {
        await journal.load(walletID: context.walletID, idempotencyKey: request.idempotencyKey)
    }
}

private actor GenericOperationBackend: WalletBackend {
    let prepared: PreparedTransaction
    var result: BackendOperationResult
    var denied = false
    var timeout = false
    var completed = false
    var prepareCount = 0
    var submitCount = 0
    var statusCount = 0
    var lastSignedPSBT: String?

    init(prepared: PreparedTransaction, result: BackendOperationResult) {
        self.prepared = prepared
        self.result = result
    }
    func setDenied(_ value: Bool) { denied = value }
    func setTimeout(_ value: Bool) { timeout = value }
    func setCompleted(_ value: Bool) { completed = value }
    func setResult(_ value: BackendOperationResult) { result = value }
    func preflightOperation(_ operation: OperationKind) async throws {
        if denied { throw SDKError.unsupported("server contract remains gated") }
    }
    func initialize(_ request: BackendInitializeRequest) async throws -> BackendSession {
        throw SDKError.unsupported("fixture")
    }
    func registerWallet(_ request: RegisterWalletRequest) async throws {}
    func shutdown(session: BackendSession) async throws {}
    func prepareCreateUtxos(_ request: PrepareCreateUtxosRequest) async throws -> PreparedTransaction {
        prepareCount += 1
        return prepared
    }
    func prepareOnchainSend(_ request: PrepareOnchainSendRequest) async throws -> PreparedTransaction {
        prepareCount += 1
        return prepared
    }
    func submitSignedTransaction(_ request: SignedTransactionSubmission) async throws
        -> BackendOperationResult
    {
        submitCount += 1
        lastSignedPSBT = request.signedPsbtBase64
        if timeout { throw SDKError.backendUnavailable() }
        return result
    }
    func getOperation(context: BackendContext, operationID: OperationID) async throws
        -> BackendOperationStatus
    {
        statusCount += 1
        return completed
            ? .succeeded(operationID: operationID, result: result)
            : .pending(operationID: operationID, phase: "submitting")
    }
}
