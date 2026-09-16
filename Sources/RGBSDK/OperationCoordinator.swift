import Foundation

struct OperationCoordinator: Sendable {
    let configuration: WalletConfiguration
    let backend: any WalletBackend
    let journal: any OperationJournal
    let now: @Sendable () -> UInt64

    func sendBtc(
        backendContext: BackendContext,
        signer: any LocalSigningEngine,
        request: SendBtcRequest
    ) async throws -> TransactionID {
        guard request.feeRate <= configuration.signingPolicy.maximumFeeRate else {
            throw SDKError.policyRejected("requested fee rate exceeds the app-owned limit")
        }

        let hash = try RequestHasher.sendBtc(network: configuration.network, request: request)
        let context = OperationRequestContext(
            backend: backendContext,
            idempotencyKey: request.idempotencyKey,
            requestHash: hash
        )

        if let recovered = try await recoverExisting(
            context: context,
            signer: signer,
            request: request,
            operation: .sendBtc
        ) {
            return try requireSendBtcResult(recovered.result, validation: recovered.validation)
        }

        let prepared = try await backendCall {
            try await backend.prepareSendBtc(.init(context: context, request: request))
        }
        try verifyPrepared(prepared, context: context, operation: .sendBtc)
        try await save(prepared, phase: .prepared)
        guard prepared.expiresAt.rawValue > now() else {
            try await saveTerminal(
                prepared: prepared,
                signed: nil,
                outcome: .expired(operationID: prepared.operationID)
            )
            throw SDKError.operationExpired(prepared.operationID)
        }

        let signed = try signer.validateAndSign(
            prepared: prepared,
            request: request,
            policy: configuration.signingPolicy
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
            signed: signed
        )
        return try requireSendBtcResult(result, validation: signed.validation)
    }

    private func recoverExisting(
        context: OperationRequestContext,
        signer: any LocalSigningEngine,
        request: SendBtcRequest,
        operation: OperationKind
    ) async throws -> (result: BackendOperationResult, validation: LocalValidationReport)? {
        guard let checkpoint = try await journalCall({
            try await journal.load(
                walletID: configuration.walletID,
                idempotencyKey: context.idempotencyKey
            )
        }) else {
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
            return nil
        case .prepared:
            guard let prepared = checkpoint.preparedTransaction else {
                throw SDKError.invariant("prepared checkpoint has no exact preparation")
            }
            try verifyPrepared(prepared, context: context, operation: operation)
            guard prepared.expiresAt.rawValue > now() else {
                try await saveTerminal(
                    prepared: prepared,
                    signed: nil,
                    outcome: .expired(operationID: prepared.operationID)
                )
                throw SDKError.operationExpired(prepared.operationID)
            }
            let signed = try signer.validateAndSign(
                prepared: prepared,
                request: request,
                policy: configuration.signingPolicy
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
                signed: signed
            )
            return (result, signed.validation)
        case .signed:
            guard let prepared = checkpoint.preparedTransaction,
                  let signedPsbtBase64 = checkpoint.signedPsbtBase64,
                  let validation = checkpoint.validation else {
                throw SDKError.invariant("signed checkpoint is incomplete")
            }
            try verifyPrepared(prepared, context: context, operation: operation)
            guard prepared.expiresAt.rawValue > now() else {
                try await saveTerminal(
                    prepared: prepared,
                    signed: .init(signedPsbtBase64: signedPsbtBase64, validation: validation),
                    outcome: .expired(operationID: prepared.operationID)
                )
                throw SDKError.operationExpired(prepared.operationID)
            }
            let result = try await submit(
                context: context,
                prepared: prepared,
                signed: .init(signedPsbtBase64: signedPsbtBase64, validation: validation)
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
                checkpoint: checkpoint
            )
            return (result, validation)
        case .terminal:
            throw SDKError.invariant("terminal checkpoint has no result")
        }
    }

    private func submit(
        context: OperationRequestContext,
        prepared: PreparedTransaction,
        signed: LocalSigningResult
    ) async throws -> BackendOperationResult {
        let operationID = prepared.operationID
        let preparedCheckpoint = try OperationCheckpoint(
            walletID: configuration.walletID,
            idempotencyKey: context.idempotencyKey,
            requestHash: context.requestHash,
            operationKind: .sendBtc,
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
                try await backend.submitSignedTransaction(submission)
            }
            try verifyResult(
                result,
                operationID: operationID,
                operation: .sendBtc,
                validation: signed.validation
            )
            try await journalCall {
                try await journal.save(
                .init(
                    walletID: configuration.walletID,
                    idempotencyKey: context.idempotencyKey,
                    requestHash: context.requestHash,
                    operationKind: .sendBtc,
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
        } catch let error as SDKError where error.code == .backendUnavailable {
            return try await reconcile(
                context: context,
                operationID: operationID,
                checkpoint: preparedCheckpoint
            )
        }
        // OperationConflict and a definitive completion-contract mismatch are
        // propagated above this boundary. The current terminal journal model
        // cannot encode those blockers, and neither condition authorizes an
        // automatic repeat of the completion request.
    }

    private func reconcile(
        context: OperationRequestContext,
        operationID: OperationID,
        checkpoint: OperationCheckpoint
    ) async throws -> BackendOperationResult {
        let status: BackendOperationStatus
        do {
            status = try await backendCall {
                try await backend.getOperation(context: context.backend, operationID: operationID)
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
