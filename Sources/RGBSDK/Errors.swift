import Foundation
import Security

/// Stable, language-neutral error codes. Callers must not branch on error text.
public enum SDKErrorCode: String, Sendable, Codable, CaseIterable {
    case invalidArgument = "validation.invalid_argument"
    case wrongNetwork = "validation.wrong_network"
    case invalidState = "wallet.invalid_state"
    case walletLocked = "wallet.locked"
    case walletDisposed = "wallet.disposed"
    case keyAccessFailed = "wallet.key_access_failed"
    case unsupported = "configuration.unsupported"
    case cryptoEntropyUnavailable = "crypto.entropy_unavailable"
    case localSigningFailed = "signing.failed"
    case policyRejected = "policy.rejected"
    case operationConflict = "operation.conflict"
    case operationExpired = "operation.expired"
    case operationAmbiguous = "operation.ambiguous"
    case operationJournalUnavailable = "storage.operation_journal_unavailable"
    case backendUnavailable = "backend.unavailable"
    case backendProtocolMismatch = "backend.protocol_mismatch"
    case backendRejected = "backend.rejected"
    case internalInvariantViolation = "internal.invariant_violation"

    public var defaultRetryable: Bool {
        switch self {
        case .backendUnavailable, .operationAmbiguous, .operationJournalUnavailable,
             .keyAccessFailed, .cryptoEntropyUnavailable:
            true
        default:
            false
        }
    }
}

/// An SDK failure containing only fields that are safe to log.
///
/// Raw transactions, seed material, invoices, credentials, and backend bodies
/// must never be placed in `message` or `details`.
public struct SDKError: Error, LocalizedError, CustomStringConvertible, Sendable {
    public let code: SDKErrorCode
    public let retryable: Bool
    public let message: String
    public let operationID: OperationID?
    public let correlationID: String?
    public let details: [String: String]

    public init(
        code: SDKErrorCode,
        retryable: Bool? = nil,
        message: String,
        operationID: OperationID? = nil,
        correlationID: String? = nil,
        details: [String: String] = [:]
    ) {
        self.code = code
        self.retryable = retryable ?? code.defaultRetryable
        self.message = message
        self.operationID = operationID
        self.correlationID = correlationID
        self.details = details
    }

    public var errorDescription: String? { message }
    public var description: String { "\(code.rawValue): \(message)" }
}

extension SDKError {
    static func invalidArgument(_ field: String, _ reason: String) -> Self {
        .init(
            code: .invalidArgument,
            message: "Invalid \(field): \(reason)",
            details: ["field": field]
        )
    }

    static func wrongNetwork(expected: Network, actual: Network) -> Self {
        .init(
            code: .wrongNetwork,
            message: "The response belongs to a different network",
            details: ["expected": expected.rawValue, "actual": actual.rawValue]
        )
    }

    static func invalidState(operation: String, state: String) -> Self {
        .init(
            code: .invalidState,
            message: "\(operation) is not valid while the wallet is \(state)",
            details: ["operation": operation, "state": state]
        )
    }

    static var walletLocked: Self {
        .init(code: .walletLocked, message: "The wallet must be unlocked")
    }

    static var walletDisposed: Self {
        .init(code: .walletDisposed, message: "The wallet instance has been disposed")
    }

    static func unsupported(_ feature: String) -> Self {
        .init(
            code: .unsupported,
            message: "\(feature) is not available in this SDK build",
            details: ["feature": feature]
        )
    }

    static func policyRejected(_ reason: String, operationID: OperationID? = nil) -> Self {
        .init(
            code: .policyRejected,
            message: "Local signing policy rejected the transaction: \(reason)",
            operationID: operationID
        )
    }

    static func operationConflict(_ idempotencyKey: IdempotencyKey) -> Self {
        .init(
            code: .operationConflict,
            message: "The idempotency key was already used for a different request",
            details: ["idempotencyKey": idempotencyKey.value]
        )
    }

    static func operationExpired(_ operationID: OperationID) -> Self {
        .init(
            code: .operationExpired,
            message: "The prepared operation expired before submission",
            operationID: operationID
        )
    }

    static func operationAmbiguous(_ operationID: OperationID) -> Self {
        .init(
            code: .operationAmbiguous,
            message: "The operation outcome is unknown; retry with the same idempotency key",
            operationID: operationID
        )
    }

    static func backendUnavailable(correlationID: String? = nil) -> Self {
        .init(
            code: .backendUnavailable,
            message: "The wallet backend is unavailable",
            correlationID: correlationID
        )
    }

    static var operationJournalUnavailable: Self {
        .init(
            code: .operationJournalUnavailable,
            message: "Durable operation state could not be accessed"
        )
    }

    static func backendProtocolMismatch(
        _ reason: String,
        operationID: OperationID? = nil,
        correlationID: String? = nil
    ) -> Self {
        .init(
            code: .backendProtocolMismatch,
            message: "The wallet backend returned an incompatible response: \(reason)",
            operationID: operationID,
            correlationID: correlationID
        )
    }

    static func invariant(_ reason: String) -> Self {
        .init(
            code: .internalInvariantViolation,
            message: "SDK invariant failed: \(reason)"
        )
    }

    static var keyMaterialNotFound: Self {
        .init(
            code: .keyAccessFailed,
            retryable: false,
            message: "No key material exists for this wallet",
            details: ["reason": "not_found"]
        )
    }

    static var keyMaterialInvalidated: Self {
        .init(
            code: .keyAccessFailed,
            retryable: false,
            message: "The protected key material was invalidated; restore the existing wallet explicitly",
            details: ["reason": "invalidated"]
        )
    }

    static var keychainAuthenticationFailed: Self {
        .init(
            code: .keyAccessFailed,
            retryable: true,
            message: "Keychain authentication failed or was cancelled",
            details: ["reason": "authentication_failed"]
        )
    }

    static func keychainUnavailable(status: OSStatus) -> Self {
        .init(
            code: .keyAccessFailed,
            retryable: true,
            message: "The Keychain is unavailable",
            details: ["osStatus": String(status)]
        )
    }


    static var keyAccessFailed: Self {
        .init(code: .keyAccessFailed, message: "Protected wallet key material could not be loaded")
    }

    static var entropyUnavailable: Self {
        .init(
            code: .cryptoEntropyUnavailable,
            message: "Secure operating-system entropy is unavailable"
        )
    }

    static func localSigningFailed(_ reason: String, operationID: OperationID? = nil) -> Self {
        .init(
            code: .localSigningFailed,
            message: "Local transaction signing failed: \(reason)",
            operationID: operationID
        )
    }
}

@inline(__always)
func requireBoundedDisplayText(_ value: String, field: String, maximumUTF8Bytes: Int) throws -> String {
    guard !value.isEmpty, value.utf8.count <= maximumUTF8Bytes else {
        throw SDKError.invalidArgument(field, "must be nonempty and at most \(maximumUTF8Bytes) UTF-8 bytes")
    }
    return value
}

@inline(__always)
func requireBoundedText(_ value: String, field: String, maximumUTF8Bytes: Int) throws -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw SDKError.invalidArgument(field, "must not be empty") }
    guard normalized.utf8.count <= maximumUTF8Bytes else {
        throw SDKError.invalidArgument(field, "must be at most \(maximumUTF8Bytes) UTF-8 bytes")
    }
    return normalized
}

@inline(__always)
func requireProtocolIdentifier(_ value: String, field: String) throws -> String {
    let normalized = try requireBoundedText(value, field: field, maximumUTF8Bytes: 128)
    guard normalized.utf8.allSatisfy({ byte in
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || byte == UInt8(ascii: "-")
            || byte == UInt8(ascii: "_")
            || byte == UInt8(ascii: ".")
            || byte == UInt8(ascii: ":")
    }) else {
        throw SDKError.invalidArgument(field, "contains unsupported characters")
    }
    return normalized
}

@inline(__always)
func isASCIIHex(_ value: String, exactByteCount: Int, lowercaseOnly: Bool = false) -> Bool {
    guard value.utf8.count == exactByteCount else { return false }
    return value.utf8.allSatisfy { byte in
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            || (!lowercaseOnly && (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte))
    }
}

@inline(__always)
func requireLowercaseSHA256(_ value: String, field: String) throws -> String {
    guard isASCIIHex(value, exactByteCount: 64, lowercaseOnly: true) else {
        throw SDKError.invalidArgument(field, "must be exactly 32 lowercase ASCII hex bytes")
    }
    return value
}

@inline(__always)
func requireBoundedBase64(
    _ value: String,
    field: String,
    maximumUTF8Bytes: Int
) throws -> String {
    let bounded = try requireBoundedText(value, field: field, maximumUTF8Bytes: maximumUTF8Bytes)
    guard bounded == value, Data(base64Encoded: bounded) != nil else {
        throw SDKError.invalidArgument(field, "must be canonical bounded Base64 without whitespace")
    }
    return bounded
}

@inline(__always)
func wipe(_ bytes: inout [UInt8]) {
    _ = bytes.withUnsafeMutableBytes { buffer in
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
    }
}
