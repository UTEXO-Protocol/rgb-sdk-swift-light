import Foundation

/// One typed caller request shared by all durable operation phases. No server
/// response may replace its fee, recipient, amount, or option authorization.
enum LocalOperationRequest: Sendable {
    case sendBtc(SendBtcRequest)
    case createUtxos(CreateUtxosRequest)
    case onchainSend(OnchainSendRequest)

    var kind: OperationKind {
        switch self {
        case .sendBtc: .sendBtc
        case .createUtxos: .createUtxos
        case .onchainSend: .onchainSend
        }
    }
    var idempotencyKey: IdempotencyKey {
        switch self {
        case .sendBtc(let r): r.idempotencyKey
        case .createUtxos(let r): r.idempotencyKey
        case .onchainSend(let r): r.idempotencyKey
        }
    }
    var feeRate: FeeRate {
        switch self {
        case .sendBtc(let r): r.feeRate
        case .createUtxos(let r): r.feeRate
        case .onchainSend(let r): r.feeRate
        }
    }
    func hash(network: Network) throws -> RequestHash {
        switch self {
        case .sendBtc(let r): try RequestHasher.sendBtc(network: network, request: r)
        case .createUtxos(let r): try RequestHasher.createUtxos(network: network, request: r)
        case .onchainSend(let r): try RequestHasher.onchainSend(network: network, request: r)
        }
    }
    func prepare(backend: any WalletBackend, context: OperationRequestContext) async throws
        -> PreparedTransaction
    {
        switch self {
        case .sendBtc(let r): try await backend.prepareSendBtc(.init(context: context, request: r))
        case .createUtxos(let r): try await backend.prepareCreateUtxos(.init(context: context, request: r))
        case .onchainSend(let r): try await backend.prepareOnchainSend(.init(context: context, request: r))
        }
    }
    func validateAndSign(
        signer: any LocalSigningEngine, prepared: PreparedTransaction, policy: LocalSigningPolicy, now: UInt64
    ) throws -> LocalSigningResult {
        switch self {
        case .sendBtc(let r): try signer.validateAndSign(prepared: prepared, request: r, policy: policy)
        case .createUtxos(let r):
            try signer.validateAndSignCreateUtxos(prepared: prepared, request: r, policy: policy)
        case .onchainSend(let r):
            try signer.validateAndSignOnchainSend(prepared: prepared, request: r, policy: policy, now: now)
        }
    }
    func validateBeforeSubmission(
        signer: any LocalSigningEngine, prepared: PreparedTransaction, policy: LocalSigningPolicy,
        retained: LocalValidationReport, now: UInt64
    ) throws {
        switch self {
        case .sendBtc(let r):
            try signer.validateBeforeSubmission(
                prepared: prepared, request: r, policy: policy, retainedValidation: retained)
        case .createUtxos(let r):
            try signer.validateCreateUtxosBeforeSubmission(
                prepared: prepared, request: r, policy: policy, retainedValidation: retained)
        case .onchainSend(let r):
            try signer.validateOnchainSendBeforeSubmission(
                prepared: prepared, request: r, policy: policy, retainedValidation: retained, now: now)
        }
    }
    func verifyPreparedPlan(_ prepared: PreparedTransaction, policy: LocalSigningPolicy) throws {
        guard case .createUtxos(let request) = self else {
            guard prepared.createUtxosOutputPlan == nil else {
                throw SDKError.backendProtocolMismatch("non-create operation contains a create output plan")
            }
            return
        }
        guard let outputs = prepared.createUtxosOutputPlan?.outputs,
            !outputs.isEmpty, outputs.count <= Int(policy.maximumOutputs),
            outputs.count <= Int(request.num ?? 5),
            outputs.allSatisfy({
                $0.account == .colored && $0.keychain == .external
                    && $0.index <= policy.maximumChildIndex
                    && $0.amount.value == (request.size?.value ?? 1_000)
            }),
            Set(outputs.map(\.index)).count == outputs.count
        else {
            throw SDKError.backendProtocolMismatch(
                "create output plan does not match caller count, size or owned output scope")
        }
    }
    func verifyResult(_ result: BackendOperationResult, prepared: PreparedTransaction?) throws {
        if case .createUtxos = self, case .createUtxos(let operationID, let value) = result {
            guard let count = prepared?.createUtxosOutputPlan?.outputs.count,
                Int(value.createdUtxoCount) == count
            else {
                throw SDKError.operationAmbiguous(operationID)
            }
        }
    }
}
