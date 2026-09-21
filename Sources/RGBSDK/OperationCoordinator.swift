import Foundation

struct OperationCoordinator: Sendable {
    let configuration: WalletConfiguration
    let backend: any WalletBackend
    let journal: any OperationJournal
    let now: @Sendable () throws -> UInt64

    func sendBtc(
        backendContext: BackendContext,
        signer: any LocalSigningEngine,
        request: SendBtcRequest
    ) async throws -> TransactionID {
        let result = try await execute(
            backendContext: backendContext, signer: signer, request: .sendBtc(request))
        return try requireSendBtcResult(result.result, validation: result.validation)
    }

    func createUtxos(
        backendContext: BackendContext, signer: any LocalSigningEngine, request: CreateUtxosRequest
    ) async throws -> CreateUtxosResult {
        let result = try await execute(
            backendContext: backendContext, signer: signer, request: .createUtxos(request))
        guard case .createUtxos(_, let value) = result.result else {
            throw SDKError.operationAmbiguous(result.result.operationID)
        }
        // Compact terminal receipts deliberately omit the exact output plan.
        // Authenticated original result and request identity remain, so check
        // their representable count without requiring a discarded PSBT.
        guard value.createdUtxoCount >= 1, value.createdUtxoCount <= (request.num ?? 5),
            value.txid == result.validation.unsignedTxid
        else {
            throw SDKError.operationAmbiguous(result.result.operationID)
        }
        return value
    }

    func onchainSend(
        backendContext: BackendContext, signer: any LocalSigningEngine, request: OnchainSendRequest
    ) async throws -> OnchainSendResponse {
        let result = try await execute(
            backendContext: backendContext, signer: signer, request: .onchainSend(request))
        guard case .onchainSend(_, let value) = result.result else {
            throw SDKError.operationAmbiguous(result.result.operationID)
        }
        guard value.txid == result.validation.unsignedTxid else {
            throw SDKError.operationAmbiguous(result.result.operationID)
        }
        return value
    }

    private func execute(
        backendContext: BackendContext, signer: any LocalSigningEngine, request: LocalOperationRequest
    ) async throws -> (result: BackendOperationResult, validation: LocalValidationReport) {
        let hash = try request.hash(network: configuration.network)
        let context = OperationRequestContext(
            backend: backendContext,
            idempotencyKey: request.idempotencyKey,
            requestHash: hash
        )

        if let recovered = try await recoverExisting(
            context: context,
            signer: signer,
            request: request,
            operation: request.kind
        ) {
            return recovered
        }

        let prepared = try await backendCall {
            try await request.prepare(backend: backend, context: context)
        }
        try verifyPrepared(prepared, context: context, operation: request.kind)
        try request.verifyPreparedPlan(prepared, policy: configuration.signingPolicy)
        try await save(prepared, phase: .prepared)
        try await rejectExpiredBeforeSigning(prepared)

        // Prepare is a remote suspension point. Re-check a dynamic backend
        // policy before local signing; denial leaves the exact PREPARED state
        // recoverable and never advances toward submission.
        try await preflightRiskyTransition(operation: request.kind, request: request, signer: signer)
        try await rejectExpiredBeforeSigning(prepared)
        let signed = try request.validateAndSign(
            signer: signer, prepared: prepared,
            policy: configuration.signingPolicy, now: validationTime(for: request)
        )
        try await save(
            prepared,
            phase: .signed,
            signedPsbtBase64: signed.signedPsbtBase64,
            validation: signed.validation
        )

        let result = try await submit(
            context: context,
            prepared: prepared,
            signed: signed,
            request: request,
            signer: signer
        )
        return (result, signed.validation)
    }

    private func recoverExisting(
        context: OperationRequestContext,
        signer: any LocalSigningEngine,
        request: LocalOperationRequest,
        operation: OperationKind
    ) async throws -> (result: BackendOperationResult, validation: LocalValidationReport)? {
        guard
            let checkpoint = try await journalCall({
                try await journal.load(
                    walletID: configuration.walletID,
                    idempotencyKey: context.idempotencyKey
                )
        }) else {
            // A new operation must pass an adapter's side-effect-free gate
            // before even CREATED is persisted. A disabled provisional
            // profile therefore leaves no misleading recovery state behind.
            try await preflightRiskyTransition(operation: operation, request: request, signer: signer)
            try await journalCall {
                try await journal.save(
                .init(
                    walletID: configuration.walletID,
                    idempotencyKey: context.idempotencyKey,
                    requestHash: context.requestHash,
                    operationKind: operation,
                    phase: .created
                    )
                )
            }
            return nil
        }

        guard checkpoint.requestHash == context.requestHash,
              checkpoint.operationKind == operation else {
            throw SDKError.operationConflict(context.idempotencyKey)
        }

        if let terminal = checkpoint.terminalOutcome {
            switch terminal {
            case let .succeeded(result):
                guard let validation = checkpoint.validation else {
                    throw SDKError.invariant("successful checkpoint has no local validation report")
                }
                return (result, validation)
            case let .rejected(operationID, safeMessage, retryable, backendCode, correlationID):
                throw backendRejection(
                    operationID: operationID,
                    safeMessage: safeMessage,
                    retryable: retryable,
                    backendCode: backendCode,
                    correlationID: correlationID
                )
            case let .expired(operationID):
                throw SDKError.operationExpired(operationID)
            }
        }

        switch checkpoint.phase {
        case .created:
            try await preflightRiskyTransition(operation: operation, request: request, signer: signer)
            return nil
        case .prepared:
            guard let prepared = checkpoint.preparedTransaction else {
                throw SDKError.invariant("prepared checkpoint has no exact preparation")
            }
            try verifyPrepared(prepared, context: context, operation: operation)
            try request.verifyPreparedPlan(prepared, policy: configuration.signingPolicy)
            try await rejectExpiredBeforeSigning(prepared)
            try await preflightRiskyTransition(operation: operation, request: request, signer: signer)
            try await rejectExpiredBeforeSigning(prepared)
            let signed = try request.validateAndSign(
                signer: signer, prepared: prepared,
                policy: configuration.signingPolicy, now: validationTime(for: request)
            )
            try await save(
                prepared,
                phase: .signed,
                signedPsbtBase64: signed.signedPsbtBase64,
                validation: signed.validation
            )
            let result = try await submit(
                context: context,
                prepared: prepared,
                signed: signed,
                request: request,
                signer: signer
            )
            return (result, signed.validation)
        case .signed:
            guard let prepared = checkpoint.preparedTransaction,
                  let signedPsbtBase64 = checkpoint.signedPsbtBase64,
                  let validation = checkpoint.validation else {
                throw SDKError.invariant("signed checkpoint is incomplete")
            }
            try verifyPrepared(prepared, context: context, operation: operation)
            try request.verifyPreparedPlan(prepared, policy: configuration.signingPolicy)
            guard try prepared.expiresAt.rawValue > now() else {
                try await saveTerminal(
                    prepared: prepared,
                    signed: .init(signedPsbtBase64: signedPsbtBase64, validation: validation),
                    outcome: .expired(operationID: prepared.operationID)
                )
                throw SDKError.operationExpired(prepared.operationID)
            }
            try await preflightRiskyTransition(operation: operation, request: request, signer: signer)
            let result = try await submit(
                context: context,
                prepared: prepared,
                signed: .init(signedPsbtBase64: signedPsbtBase64, validation: validation),
                request: request,
                signer: signer
            )
            return (result, validation)
        case .submitting:
            guard let operationID = checkpoint.operationID,
                  let prepared = checkpoint.preparedTransaction,
                  let validation = checkpoint.validation else {
                throw SDKError.invariant("submitting checkpoint is incomplete")
            }
            try verifyPrepared(prepared, context: context, operation: operation)
            let result = try await reconcile(
                context: context,
                operationID: operationID,
                checkpoint: checkpoint,
                request: request
            )
            return (result, validation)
        case .terminal:
            throw SDKError.invariant("terminal checkpoint has no result")
        }
    }

    private func preflightRiskyTransition(
        operation: OperationKind,
        request: LocalOperationRequest,
        signer: any LocalSigningEngine
    ) async throws {
        // Terminal outcomes must always replay and SUBMITTING must always be
        // allowed to perform status-only reconciliation after a restart, even
        // if a provisional profile has since been disabled or an app-owned
        // policy has changed. Callers invoke this hook only for phases that
        // could prepare, sign, or submit.
        guard request.feeRate <= configuration.signingPolicy.maximumFeeRate else {
            throw SDKError.policyRejected("requested fee rate exceeds the app-owned limit")
        }
        if operation != .sendBtc {
            let capabilities = signer.capabilities
            guard capabilities.localTransactionValidation, capabilities.localTransactionSigning,
                  capabilities.localSigningOperations.contains(operation) else {
                throw SDKError.unsupported("local operation-specific signing authorization")
            }
        }
        if case .onchainSend(let rgbRequest) = request {
            guard signer.capabilities.localRGBInvoiceParsing else { throw SDKError.unsupported("local RGB invoice parsing") }
            _ = try validateOutgoingRGBInvoice(rgbRequest, network: configuration.network, now: now())
        }
        if let gateway = backend as? GatewayWalletBackend {
            try await gateway.validateRequest(request)
        }
        try await backendCall {
            try await backend.preflightOperation(operation)
        }
        // A capability check may suspend. Recheck local invoice expiry after
        // it returns; even CREATED must not be persisted for an expired intent.
        if case .onchainSend(let rgbRequest) = request {
            _ = try validateOutgoingRGBInvoice(rgbRequest, network: configuration.network, now: now())
        }
    }

    private func submit(
        context: OperationRequestContext,
        prepared: PreparedTransaction,
        signed: LocalSigningResult,
        request: LocalOperationRequest,
        signer: any LocalSigningEngine
    ) async throws -> BackendOperationResult {
        let operationID = prepared.operationID
        // Signing and an earlier preflight may take time or cross an actor
        // suspension. Preserve an already-known expiry before consulting a
        // dynamic backend gate, then re-run that side-effect-free policy. A
        // final expiry check closes the suspension window immediately before
        // recording SUBMITTING. A gate failure leaves the checkpoint SIGNED;
        // expiry is terminal and retains immutable replay/validation evidence
        // (the durable journal may then compact its no-longer-submittable PSBTs).
        try await rejectExpiredBeforeSubmission(prepared: prepared, signed: signed)
        try await preflightRiskyTransition(operation: request.kind, request: request, signer: signer)
        try request.validateBeforeSubmission(
            signer: signer, prepared: prepared,
            policy: configuration.signingPolicy,
            retained: signed.validation, now: validationTime(for: request)
        )
        try await rejectExpiredBeforeSubmission(prepared: prepared, signed: signed)
        let preparedCheckpoint = try OperationCheckpoint(
            walletID: configuration.walletID,
            idempotencyKey: context.idempotencyKey,
            requestHash: context.requestHash,
            operationKind: request.kind,
            phase: .submitting,
            operationID: operationID,
            preparedTransaction: prepared,
            signedPsbtBase64: signed.signedPsbtBase64,
            validation: signed.validation
        )
        try await journalCall { try await journal.save(preparedCheckpoint) }

        let submission = try SignedTransactionSubmission(
            context: context,
            operationID: operationID,
            signedPsbtBase64: signed.signedPsbtBase64,
            validation: signed.validation
        )

        do {
            let result = try await backendCall {
                if let gateway = backend as? GatewayWalletBackend, request.kind == .createUtxos {
                    return try await gateway.submitCreateUtxos(submission, prepared: prepared)
                }
                return try await backend.submitSignedTransaction(submission)
            }
            try verifyResult(
                result,
                operationID: operationID,
                operation: request.kind,
                validation: signed.validation
            )
            try request.verifyResult(result, prepared: prepared)
            try await journalCall {
                try await journal.save(
                .init(
                    walletID: configuration.walletID,
                    idempotencyKey: context.idempotencyKey,
                    requestHash: context.requestHash,
                    operationKind: request.kind,
                    phase: .terminal,
                    operationID: operationID,
                    preparedTransaction: prepared,
                    signedPsbtBase64: signed.signedPsbtBase64,
                    validation: signed.validation,
                    terminalOutcome: .succeeded(result)
                    )
                )
            }
            return result
        } catch is CancellationError {
            // SUBMITTING was committed first. Cancellation ends this wait; it
            // cannot prove that backend processing or broadcast was cancelled.
            throw CancellationError()
        } catch let error as SDKError where error.code == .operationExpired {
            // Expiry is definitive only when the backend binds it to the
            // operation we submitted. Persist it before reporting it so a
            // restart cannot reinterpret this proven pre-broadcast outcome as
            // ambiguous.
            guard error.operationID == operationID else {
                throw SDKError.operationAmbiguous(operationID)
            }
            try await saveTerminal(
                checkpoint: preparedCheckpoint,
                outcome: .expired(operationID: operationID)
            )
            throw SDKError.operationExpired(operationID)
        } catch let error as SDKError
            where error.code == .backendRejected && !error.retryable {
            // A non-retryable rejection is terminal only when its identity and
            // log-safe metadata validate. Otherwise the response cannot prove
            // what happened to this submission.
            guard error.operationID == operationID else {
                throw SDKError.operationAmbiguous(operationID)
            }
            let outcome: OperationTerminalOutcome
            do {
                outcome = try validatedRejection(
                    operationID: operationID,
                    safeMessage: error.message,
                    retryable: false,
                    backendCode: error.details["backendCode"],
                    correlationID: error.correlationID
                )
            } catch {
                throw SDKError.operationAmbiguous(operationID)
            }
            try await saveTerminal(checkpoint: preparedCheckpoint, outcome: outcome)
            guard case let .rejected(_, safeMessage, retryable, backendCode, correlationID) = outcome
            else {
                throw SDKError.invariant("validated rejection has the wrong terminal variant")
            }
            throw backendRejection(
                operationID: operationID,
                safeMessage: safeMessage,
                retryable: retryable,
                backendCode: backendCode,
                correlationID: correlationID
            )
        } catch let error as SDKError where error.code == .backendUnavailable
            || (backend is GatewayWalletBackend
                && error.code == .operationAmbiguous && error.operationID == operationID) {
            return try await reconcile(
                context: context,
                operationID: operationID,
                checkpoint: preparedCheckpoint,
                request: request
            )
        }
        // Other injected-backend errors propagate without authorizing another
        // completion request. The gateway maps every unproven completion 4xx,
        // including known idempotency/kind conflicts, to bound ambiguity above.
    }

    private func rejectExpiredBeforeSubmission(
        prepared: PreparedTransaction,
        signed: LocalSigningResult
    ) async throws {
        let operationID = prepared.operationID
        guard try prepared.expiresAt.rawValue > now() else {
            try await saveTerminal(
                prepared: prepared,
                signed: signed,
                outcome: .expired(operationID: operationID)
            )
            throw SDKError.operationExpired(operationID)
        }
    }

    private func rejectExpiredBeforeSigning(_ prepared: PreparedTransaction) async throws {
        let operationID = prepared.operationID
        guard try prepared.expiresAt.rawValue > now() else {
            try await saveTerminal(
                prepared: prepared,
                signed: nil,
                outcome: .expired(operationID: operationID)
            )
            throw SDKError.operationExpired(operationID)
        }
    }

    private func reconcile(
        context: OperationRequestContext,
        operationID: OperationID,
        checkpoint: OperationCheckpoint,
        request: LocalOperationRequest
    ) async throws -> BackendOperationResult {
        let status: BackendOperationStatus
        do {
            status = try await backendCall {
                // The gateway's status is not an authoritative negative
                // outcome and carries no request hash. Bind it to the exact
                // authenticated local evidence without widening the public
                // backend protocol or exposing PSBTs to applications.
                if let gateway = backend as? GatewayWalletBackend {
                    switch request {
                    case .sendBtc(let btcRequest):
                        return try await gateway.getOperationForRecovery(
                            context: context.backend, checkpoint: checkpoint, request: btcRequest
                        )
                    case .createUtxos(let createRequest):
                        return try await gateway.getOperationForRecovery(
                            context: context.backend, checkpoint: checkpoint, request: createRequest
                        )
                    case .onchainSend:
                        throw SDKError.operationAmbiguous(operationID)
                    }
                }
                return try await backend.getOperation(context: context.backend, operationID: operationID)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SDKError.operationAmbiguous(operationID)
        }
        guard status.operationID == operationID else {
            throw SDKError.backendProtocolMismatch(
                "operation status has the wrong operation ID",
                operationID: operationID
            )
        }
        switch status {
        case .pending:
            throw SDKError.operationAmbiguous(operationID)
        case let .succeeded(_, result):
            guard let validation = checkpoint.validation else {
                throw SDKError.invariant("submitting checkpoint has no validation report")
            }
            try verifyResult(
                result,
                operationID: operationID,
                operation: checkpoint.operationKind,
                validation: validation
            )
            try request.verifyResult(result, prepared: checkpoint.preparedTransaction)
            try await journalCall {
                try await journal.save(
                .init(
                    walletID: checkpoint.walletID,
                    idempotencyKey: checkpoint.idempotencyKey,
                    requestHash: checkpoint.requestHash,
                    operationKind: checkpoint.operationKind,
                    phase: .terminal,
                    operationID: operationID,
                    preparedTransaction: checkpoint.preparedTransaction,
                    signedPsbtBase64: checkpoint.signedPsbtBase64,
                    validation: checkpoint.validation,
                    terminalOutcome: .succeeded(result)
                    )
                )
            }
            return result
        case let .failed(_, safeMessage, retryable, backendCode, correlationID):
            let rejection = try validatedRejection(
                operationID: operationID,
                safeMessage: safeMessage,
                retryable: retryable,
                backendCode: backendCode,
                correlationID: correlationID
            )
            try await saveTerminal(checkpoint: checkpoint, outcome: rejection)
            throw backendRejection(
                operationID: operationID,
                safeMessage: safeMessage,
                retryable: retryable,
                backendCode: backendCode,
                correlationID: correlationID
            )
        case .expired:
            try await saveTerminal(
                checkpoint: checkpoint,
                outcome: .expired(operationID: operationID)
            )
            throw SDKError.operationExpired(operationID)
        }
    }

    private func verifyPrepared(
        _ prepared: PreparedTransaction,
        context: OperationRequestContext,
        operation: OperationKind
    ) throws {
        guard prepared.idempotencyKey == context.idempotencyKey else {
            throw SDKError.backendProtocolMismatch(
                "prepared idempotency key does not match",
                operationID: prepared.operationID,
                correlationID: prepared.correlationID
            )
        }
        guard prepared.requestHash == context.requestHash else {
            throw SDKError.backendProtocolMismatch(
                "prepared request hash does not match the local request",
                operationID: prepared.operationID,
                correlationID: prepared.correlationID
            )
        }
        guard prepared.network == configuration.network else {
            throw SDKError.wrongNetwork(expected: configuration.network, actual: prepared.network)
        }
        guard prepared.operation == operation else {
            throw SDKError.backendProtocolMismatch(
                "prepared operation type does not match",
                operationID: prepared.operationID,
                correlationID: prepared.correlationID
            )
        }
    }

    private func validationTime(for request: LocalOperationRequest) throws -> UInt64 {
        if case .onchainSend = request { return try now() }
        return 0
    }

    private func verifyResult(
        _ result: BackendOperationResult,
        operationID: OperationID,
        operation: OperationKind,
        validation: LocalValidationReport
    ) throws {
        guard result.operationID == operationID else {
            // Submission may already have broadcast. A success payload that
            // cannot be bound to this operation does not establish the
            // intended operation's outcome.
            throw SDKError.operationAmbiguous(operationID)
        }
        let resultTxid: TransactionID
        switch (operation, result) {
        case let (.sendBtc, .sendBtc(_, txid)):
            resultTxid = txid
        case let (.createUtxos, .createUtxos(_, value)):
            resultTxid = value.txid
        case let (.onchainSend, .onchainSend(_, value)):
            resultTxid = value.txid
        default:
            throw SDKError.operationAmbiguous(operationID)
        }
        guard resultTxid == validation.unsignedTxid else {
            throw SDKError.operationAmbiguous(operationID)
        }
    }

    private func requireSendBtcResult(
        _ result: BackendOperationResult,
        validation: LocalValidationReport
    ) throws -> TransactionID {
        guard case let .sendBtc(_, txid) = result else {
            throw SDKError.backendProtocolMismatch(
                "backend returned the wrong result type",
                operationID: result.operationID
            )
        }
        guard txid == validation.unsignedTxid else {
            throw SDKError.backendProtocolMismatch(
                "backend transaction ID differs from the locally signed transaction",
                operationID: result.operationID
            )
        }
        return txid
    }

    private func save(
        _ prepared: PreparedTransaction,
        phase: OperationPhase,
        signedPsbtBase64: String? = nil,
        validation: LocalValidationReport? = nil
    ) async throws {
        try await journalCall {
            try await journal.save(
            .init(
                walletID: configuration.walletID,
                idempotencyKey: prepared.idempotencyKey,
                requestHash: prepared.requestHash,
                operationKind: prepared.operation,
                phase: phase,
                operationID: prepared.operationID,
                preparedTransaction: prepared,
                signedPsbtBase64: signedPsbtBase64,
                validation: validation
                )
            )
        }
    }

    private func saveTerminal(
        prepared: PreparedTransaction,
        signed: LocalSigningResult?,
        outcome: OperationTerminalOutcome
    ) async throws {
        try await saveTerminal(
            checkpoint: .init(
                walletID: configuration.walletID,
                idempotencyKey: prepared.idempotencyKey,
                requestHash: prepared.requestHash,
                operationKind: prepared.operation,
                phase: signed == nil ? .prepared : .signed,
                operationID: prepared.operationID,
                preparedTransaction: prepared,
                signedPsbtBase64: signed?.signedPsbtBase64,
                validation: signed?.validation
            ),
            outcome: outcome
        )
    }

    private func saveTerminal(
        checkpoint: OperationCheckpoint,
        outcome: OperationTerminalOutcome
    ) async throws {
        try await journalCall {
            try await journal.save(
                .init(
                    walletID: checkpoint.walletID,
                    idempotencyKey: checkpoint.idempotencyKey,
                    requestHash: checkpoint.requestHash,
                    operationKind: checkpoint.operationKind,
                    phase: .terminal,
                    operationID: checkpoint.operationID,
                    preparedTransaction: checkpoint.preparedTransaction,
                    signedPsbtBase64: checkpoint.signedPsbtBase64,
                    validation: checkpoint.validation,
                    terminalOutcome: outcome
                )
            )
        }
    }

    private func validatedRejection(
        operationID: OperationID,
        safeMessage: String,
        retryable: Bool,
        backendCode: String?,
        correlationID: String?
    ) throws -> OperationTerminalOutcome {
        do {
            try validateTerminalRejectionFields(
                safeMessage: safeMessage,
                backendCode: backendCode,
                correlationID: correlationID
            )
            return .rejected(
                operationID: operationID,
                safeMessage: safeMessage,
                retryable: retryable,
                backendCode: backendCode,
                correlationID: correlationID
            )
        } catch {
            throw SDKError.backendProtocolMismatch(
                "operation rejection metadata is malformed",
                operationID: operationID
            )
        }
    }
}

private func backendRejection(
    operationID: OperationID,
    safeMessage: String,
    retryable: Bool,
    backendCode: String?,
    correlationID: String?
) -> SDKError {
    SDKError(
        code: .backendRejected,
        retryable: retryable,
        message: safeMessage,
        operationID: operationID,
        correlationID: correlationID,
        details: backendCode.map { ["backendCode": $0] } ?? [:]
    )
}

private func journalCall<T: Sendable>(
    _ body: @Sendable () async throws -> T
) async throws -> T {
    do {
        return try await body()
    } catch is CancellationError {
        throw CancellationError()
    } catch let error as SDKError {
        throw error
    } catch {
        throw SDKError.operationJournalUnavailable
    }
}

func backendCall<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
    do {
        return try await body()
    } catch is CancellationError {
        throw CancellationError()
    } catch let error as SDKError {
        throw error
    } catch {
        // Do not leak transport errors or response bodies into log-safe errors.
        throw SDKError.backendUnavailable()
    }
}
