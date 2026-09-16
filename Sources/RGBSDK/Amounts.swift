import Foundation

/// Exact Bitcoin amount. The maximum is Bitcoin's 21 million BTC supply.
public struct Satoshis: Hashable, Comparable, Sendable, CustomStringConvertible {
    public static let maximum: UInt64 = 2_100_000_000_000_000
    public static let zero = Satoshis(unchecked: 0)

    public let value: UInt64
    public var description: String { String(value) }

    public init(_ value: UInt64) throws {
        guard value <= Self.maximum else {
            throw SDKError.invalidArgument("satoshis", "must be at most \(Self.maximum)")
        }
        self.value = value
    }

    init(unchecked value: UInt64) { self.value = value }

    static func positive(_ value: Self, field: String) throws -> Self {
        guard value.value > 0 else { throw SDKError.invalidArgument(field, "must be greater than zero") }
        return value
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
}

/// Exact fee rate stored as milli-satoshis per virtual byte.
public struct FeeRate: Hashable, Comparable, Sendable, CustomStringConvertible {
    public static let `default` = FeeRate(uncheckedMilliSatsPerVByte: 1_500)
    public static let maximumSupported = FeeRate(uncheckedMilliSatsPerVByte: 10_000_000)

    public let milliSatsPerVByte: UInt64

    public init(milliSatsPerVByte: UInt64) throws {
        guard milliSatsPerVByte > 0,
              milliSatsPerVByte <= Self.maximumSupported.milliSatsPerVByte else {
            throw SDKError.invalidArgument(
                "feeRate",
                "must be between 1 and \(Self.maximumSupported.milliSatsPerVByte) msat/vB"
            )
        }
        self.milliSatsPerVByte = milliSatsPerVByte
    }

    public init(satsPerVByte: Decimal) throws {
        guard satsPerVByte > 0 else {
            throw SDKError.invalidArgument("feeRate", "must be greater than zero")
        }
        var source = satsPerVByte * 1_000
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, 0, .plain)
        guard rounded == source else {
            throw SDKError.invalidArgument("feeRate", "must have at most three decimal places")
        }
        let number = NSDecimalNumber(decimal: rounded)
        guard number != .notANumber,
              number.compare(NSDecimalNumber(value: UInt64.max)) != .orderedDescending else {
            throw SDKError.invalidArgument("feeRate", "is outside the supported range")
        }
        try self.init(milliSatsPerVByte: number.uint64Value)
    }

    public init(satsPerVByte: Double) throws {
        guard satsPerVByte.isFinite else {
            throw SDKError.invalidArgument("feeRate", "must be finite")
        }
        try self.init(satsPerVByte: Decimal(satsPerVByte))
    }

    init(uncheckedMilliSatsPerVByte: UInt64) {
        milliSatsPerVByte = uncheckedMilliSatsPerVByte
    }

    public var description: String {
        let value = Decimal(milliSatsPerVByte) / 1_000
        return "\(NSDecimalNumber(decimal: value).stringValue) sat/vB"
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.milliSatsPerVByte < rhs.milliSatsPerVByte
    }
}

public struct AssetAmount: Hashable, Comparable, Sendable, CustomStringConvertible {
    public static let maximumDecimal = "18446744073709551615"
    public static let zero = AssetAmount(unchecked: "0", numeric: 0)

    public let decimal: String
    private let numeric: UInt64
    public var description: String { decimal }

    public init(_ value: UInt64) {
        decimal = String(value)
        numeric = value
    }

    public init(parsing value: String) throws {
        guard !value.isEmpty, value.allSatisfy(\.isNumber), let parsed = UInt64(value) else {
            throw SDKError.invalidArgument("assetAmount", "must be an unsigned 64-bit base-10 integer")
        }
        decimal = String(parsed)
        numeric = parsed
    }

    private init(unchecked: String, numeric: UInt64) {
        decimal = unchecked
        self.numeric = numeric
    }

    static func positive(_ value: Self, field: String) throws -> Self {
        guard value.numeric > 0 else { throw SDKError.invalidArgument(field, "must be greater than zero") }
        return value
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.numeric < rhs.numeric }
}

public struct BlockCount: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
}

public struct DurationSeconds: Hashable, Sendable {
    public let value: UInt64
    public init(_ value: UInt64) throws {
        guard value > 0 else { throw SDKError.invalidArgument("durationSeconds", "must be greater than zero") }
        self.value = value
    }
}

public struct UnixSeconds: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}
