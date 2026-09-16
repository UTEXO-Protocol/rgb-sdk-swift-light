import Foundation

@_spi(Backend)
public enum OperationPhase: UInt8, Sendable, Comparable, Hashable {
    case created
    case prepared
    case signed
    case submitting
    case terminal

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A definitive backend outcome retained by the durable operation journal.
///
/// Rejections contain only backend-designated log-safe metadata. Transaction
/// bytes remain in the checkpoint's protected payload and never appear here.
@_spi(Backend)
public enum OperationTerminalOutcome: Hashable, Sendable {
    case succeeded(BackendOperationResult)
    case rejected(
        operationID: OperationID,
        safeMessage: String,
        retryable: Bool,
        backendCode: String?,
        correlationID: String?
    )
    case expired(operationID: OperationID)

    public var operationID: OperationID {
        switch self {
        case let .succeeded(result): result.operationID
        case let .rejected(operationID, _, _, _, _): operationID
        case let .expired(operationID): operationID
        }
    }
}

/// Durable recovery state for one caller-authorized operation.
///
/// Production journals must atomically encrypt and authenticate the encoded
/// checkpoint because both prepared and signed PSBT bytes are sensitive. The
/// exact prepared transaction is retained from PREPARED onward, and the exact
/// signed bytes are retained from SIGNED onward. A restart never prepares or
/// signs a different transaction for the same caller intent.
@_spi(Backend)
public struct OperationCheckpoint: Hashable, Sendable {
    public let walletID: WalletID
    public let idempotencyKey: IdempotencyKey
    public let requestHash: RequestHash
    public let operationKind: OperationKind
    public let phase: OperationPhase
    public let operationID: OperationID?
    public let preparedTransaction: PreparedTransaction?
    public let signedPsbtBase64: String?
    public let validation: LocalValidationReport?
    public let terminalOutcome: OperationTerminalOutcome?

    /// Compatibility accessor for successful terminal results.
    public var terminalResult: BackendOperationResult? {
        guard case let .succeeded(result) = terminalOutcome else { return nil }
        return result
    }

    public init(
        walletID: WalletID,
        idempotencyKey: IdempotencyKey,
        requestHash: RequestHash,
        operationKind: OperationKind,
        phase: OperationPhase,
        operationID: OperationID? = nil,
        preparedTransaction: PreparedTransaction? = nil,
        signedPsbtBase64: String? = nil,
        validation: LocalValidationReport? = nil,
        terminalOutcome: OperationTerminalOutcome? = nil
    ) throws {
        let hasPreparedState = phase != .created
        guard hasPreparedState == (operationID != nil),
              hasPreparedState == (preparedTransaction != nil) else {
            throw SDKError.invalidArgument(
                "preparedTransaction",
                "operation ID and exact preparation must be present after the created phase"
            )
        }
        if let operationID, let preparedTransaction {
            guard preparedTransaction.operationID == operationID,
                  preparedTransaction.idempotencyKey == idempotencyKey,
                  preparedTransaction.requestHash == requestHash,
                  preparedTransaction.operation == operationKind else {
                throw SDKError.invalidArgument(
                    "preparedTransaction",
                    "does not match the checkpoint identity"
                )
            }
        }

        guard (signedPsbtBase64 == nil) == (validation == nil) else {
            throw SDKError.invalidArgument("validation", "must accompany signed transaction bytes")
        }
        if let signedPsbtBase64 {
            guard try requireBoundedText(
                signedPsbtBase64,
                field: "signedPsbt",
                maximumUTF8Bytes: 5_400_000
            ) == signedPsbtBase64 else {
                throw SDKError.invalidArgument(
                    "signedPsbt",
                    "must not contain surrounding whitespace"
                )
            }
        }
        if phase == .created || phase == .prepared, signedPsbtBase64 != nil {
            throw SDKError.invalidArgument(
                "signedPsbt",
                "must not be present before the signed phase"
            )
        }
        if phase == .signed || phase == .submitting, signedPsbtBase64 == nil {
            throw SDKError.invalidArgument("signedPsbt", "must be present after signing")
        }

        guard (phase == .terminal) == (terminalOutcome != nil) else {
            throw SDKError.invalidArgument(
                "terminalOutcome",
                "must be present exactly for terminal state"
            )
        }
        if let terminalOutcome {
            guard terminalOutcome.operationID == operationID else {
                throw SDKError.invalidArgument(
                    "terminalOutcome",
                    "operation ID does not match checkpoint"
                )
            }
            switch terminalOutcome {
            case let .succeeded(result):
                guard result.operationKind == operationKind else {
                    throw SDKError.invalidArgument(
                        "terminalOutcome",
                        "result variant does not match operation kind"
                    )
                }
                guard let validation, signedPsbtBase64 != nil else {
                    throw SDKError.invalidArgument(
                        "terminalOutcome",
                        "a successful outcome requires the exact signed payload and validation"
                    )
                }
                guard result.transactionID == validation.unsignedTxid else {
                    throw SDKError.invalidArgument(
                        "terminalOutcome",
                        "result transaction ID does not match local validation"
                    )
                }
            case let .rejected(_, safeMessage, _, backendCode, correlationID):
                try validateTerminalRejectionFields(
                    safeMessage: safeMessage,
                    backendCode: backendCode,
                    correlationID: correlationID
                )
            case .expired:
                break
            }
        }

        self.walletID = walletID
        self.idempotencyKey = idempotencyKey
        self.requestHash = requestHash
        self.operationKind = operationKind
        self.phase = phase
        self.operationID = operationID
        self.preparedTransaction = preparedTransaction
        self.signedPsbtBase64 = signedPsbtBase64
        self.validation = validation
        self.terminalOutcome = terminalOutcome
    }
}

func validateTerminalRejectionFields(
    safeMessage: String,
    backendCode: String?,
    correlationID: String?
) throws {
    guard try requireBoundedText(
        safeMessage,
        field: "safeMessage",
        maximumUTF8Bytes: 512
    ) == safeMessage else {
        throw SDKError.invalidArgument("safeMessage", "must not contain surrounding whitespace")
    }
    if let backendCode {
        guard try requireProtocolIdentifier(backendCode, field: "backendCode") == backendCode else {
            throw SDKError.invalidArgument("backendCode", "must not contain surrounding whitespace")
        }
    }
    if let correlationID {
        guard try requireProtocolIdentifier(correlationID, field: "correlationID") == correlationID else {
            throw SDKError.invalidArgument("correlationID", "must not contain surrounding whitespace")
        }
    }
}

/// Crash-recovery persistence boundary. Production implementations must make
/// `save` atomic and encrypt/authenticate `OperationCheckpointCodec` data.
@_spi(Backend)
public protocol OperationJournal: Sendable {
    func load(walletID: WalletID, idempotencyKey: IdempotencyKey) async throws -> OperationCheckpoint?
    func save(_ checkpoint: OperationCheckpoint) async throws
}

/// Volatile journal for tests and prototypes. It is not safe for production payments.
@_spi(Backend)
public actor InMemoryOperationJournal: OperationJournal {
    private struct Key: Hashable { let walletID: WalletID; let idempotencyKey: IdempotencyKey }
    private var checkpoints: [Key: OperationCheckpoint] = [:]

    public init() {}

    public func load(walletID: WalletID, idempotencyKey: IdempotencyKey) -> OperationCheckpoint? {
        checkpoints[Key(walletID: walletID, idempotencyKey: idempotencyKey)]
    }

    public func save(_ checkpoint: OperationCheckpoint) throws {
        let key = Key(walletID: checkpoint.walletID, idempotencyKey: checkpoint.idempotencyKey)
        if let current = checkpoints[key] {
            if current == checkpoint { return }
            if current.phase == .terminal {
                throw SDKError.invariant("terminal operation checkpoint is immutable")
            }
            guard current.requestHash == checkpoint.requestHash,
                  current.operationKind == checkpoint.operationKind else {
                throw SDKError.operationConflict(checkpoint.idempotencyKey)
            }
            guard checkpoint.phase > current.phase else {
                throw SDKError.invariant("operation phase did not advance monotonically")
            }
            if let existing = current.operationID, existing != checkpoint.operationID {
                throw SDKError.backendProtocolMismatch(
                    "operation ID changed for an existing idempotency key",
                    operationID: checkpoint.operationID
                )
            }
            if let existing = current.preparedTransaction,
               existing != checkpoint.preparedTransaction {
                throw SDKError.invariant("prepared transaction changed during retry")
            }
            if let existing = current.signedPsbtBase64,
               existing != checkpoint.signedPsbtBase64 {
                throw SDKError.invariant("signed transaction bytes changed during retry")
            }
            if let existing = current.validation, existing != checkpoint.validation {
                throw SDKError.invariant("local validation report changed during retry")
            }
        }
        checkpoints[key] = checkpoint
    }
}
