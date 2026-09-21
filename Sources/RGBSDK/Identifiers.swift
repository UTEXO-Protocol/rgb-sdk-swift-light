import Foundation

public struct WalletID: Hashable, Sendable, CustomStringConvertible {
    public let value: String
    public var description: String { value }

    public init(_ value: String) throws {
        self.value = try requireProtocolIdentifier(value, field: "walletId")
    }
}

public struct OperationID: Hashable, Sendable, CustomStringConvertible {
    public let value: String
    public var description: String { value }

    public init(_ value: String) throws {
        self.value = try requireProtocolIdentifier(value, field: "operationId")
    }
}

public struct IdempotencyKey: Hashable, Sendable, CustomStringConvertible {
    public let value: String
    public var description: String { value }

    public init(_ value: String) throws {
        self.value = try requireProtocolIdentifier(value, field: "idempotencyKey")
    }

    private init(unchecked value: String) { self.value = value }

    public static func random() -> Self {
        .init(unchecked: UUID().uuidString.lowercased())
    }
}

public struct TransactionID: Hashable, Sendable, CustomStringConvertible {
    public let hex: String
    public var description: String { hex }

    public init(_ value: String) throws { hex = try Self.validate(value) }

    private static func validate(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isASCIIHex(normalized, exactByteCount: 64, lowercaseOnly: true) else {
            throw SDKError.invalidArgument("transactionId", "must be 32 ASCII hex bytes")
        }
        return normalized
    }
}

public struct AssetID: Hashable, Sendable, CustomStringConvertible {
    public let value: String
    public var description: String { value }

    public init(_ value: String) throws {
        self.value = try requireBoundedText(value, field: "assetId", maximumUTF8Bytes: 256)
    }
}

/// A bounded address. The local signer performs full checksum/script/network validation.
public struct BitcoinAddress: Hashable, Sendable, CustomStringConvertible {
    public let value: String
    public var description: String { value }

    public init(_ value: String) throws {
        self.value = try requireBoundedText(value, field: "address", maximumUTF8Bytes: 128)
    }
}

/// Bounded transport value. `decodeRGBInvoice` performs local syntax/checksum
/// validation; construction alone does not establish a valid or trusted invoice.
public struct RGBInvoice: Hashable, Sendable, CustomStringConvertible, CustomReflectable {
    let storage: String

    public init(_ value: String) throws {
        storage = try requireBoundedText(value, field: "invoice", maximumUTF8Bytes: 16_384)
    }

    public var description: String { "RGBInvoice([REDACTED])" }
    public var customMirror: Mirror { Mirror(self, children: ["value": "[REDACTED]"]) }

    /// Explicit access for QR rendering or sharing. Treat invoices as private wallet data.
    public var value: String { storage }

    @_spi(Backend)
    public var backendValue: String { storage }
}

@_spi(Backend)
public struct RequestHash: Hashable, Sendable, CustomStringConvertible {
    public let hex: String

    public init(validating hex: String) throws {
        self.hex = try requireLowercaseSHA256(hex, field: "requestHash")
    }

    init(trustedSHA256Hex hex: String) { self.hex = hex }

    public var description: String { hex }
}
