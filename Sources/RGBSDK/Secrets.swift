import Foundation

/// Short-lived seed material. Copies are wiped on a best-effort basis.
///
/// Swift, Foundation, and FFI runtimes may make opaque copies, so this type
/// must not be interpreted as a hard zeroization guarantee.
public final class SecretSeed: @unchecked Sendable, CustomStringConvertible, CustomReflectable {
    public static let byteCount = 64

    private let lock = NSLock()
    private var bytes: [UInt8]?

    public init(copying bytes: [UInt8]) throws {
        guard bytes.count == Self.byteCount else {
            throw SDKError.invalidArgument("seed", "must be a 64-byte BIP39 seed")
        }
        self.bytes = Array(bytes)
    }

    deinit { close() }

    public func close() {
        lock.withLock {
            _ = bytes?.withUnsafeMutableBytes {
                $0.initializeMemory(as: UInt8.self, repeating: 0)
            }
            bytes = nil
        }
    }

    func withCopy<T>(_ body: (inout [UInt8]) throws -> T) throws -> T {
        var copy = try lock.withLock {
            guard let bytes else { throw SDKError.invalidState(operation: "read seed", state: "closed") }
            return bytes
        }
        defer { wipe(&copy) }
        return try body(&copy)
    }

    public var description: String { "SecretSeed([REDACTED])" }
    public var customMirror: Mirror { Mirror(self, children: ["value": "[REDACTED]"]) }
}

/// Unlock input consumed only by the local key provider.
public final class WalletUnlockParameters: @unchecked Sendable, CustomStringConvertible, CustomReflectable {
    private let lock = NSLock()
    private var passwordUTF8: [UInt8]?
    private var closed = false

    private init(passwordUTF8: [UInt8]?) { self.passwordUTF8 = passwordUTF8 }

    deinit { close() }

    public static func none() -> Self { .init(passwordUTF8: nil) }

    /// Prefer mutable UTF-8 bytes so the caller can wipe its own buffer too.
    public static func password(copyingUTF8 password: [UInt8]) throws -> Self {
        guard !password.isEmpty else { throw SDKError.invalidArgument("password", "must not be empty") }
        guard String(bytes: password, encoding: .utf8) != nil else {
            throw SDKError.invalidArgument("password", "must be valid UTF-8")
        }
        return .init(passwordUTF8: Array(password))
    }

    public func close() {
        lock.withLock {
            _ = passwordUTF8?.withUnsafeMutableBytes {
                $0.initializeMemory(as: UInt8.self, repeating: 0)
            }
            passwordUTF8 = nil
            closed = true
        }
    }

    public func withPasswordUTF8<T>(_ body: ([UInt8]?) throws -> T) throws -> T {
        var copy: [UInt8]? = try lock.withLock {
            guard !closed else {
                throw SDKError.invalidState(operation: "read unlock parameters", state: "closed")
            }
            return passwordUTF8
        }
        defer {
            _ = copy?.withUnsafeMutableBytes {
                $0.initializeMemory(as: UInt8.self, repeating: 0)
            }
            copy = nil
        }
        return try body(copy)
    }

    var isPasswordless: Bool {
        lock.withLock { !closed && passwordUTF8 == nil }
    }

    public var description: String { "WalletUnlockParameters(password=[REDACTED])" }
    public var customMirror: Mirror { Mirror(self, children: ["password": "[REDACTED]"]) }
}

/// Loads protected seed material only for the duration of `unlock`.
public protocol WalletKeyProvider: Sendable {
    func loadSeed(parameters: WalletUnlockParameters) async throws -> SecretSeed
}

/// Redacting, one-shot recovery phrase returned during wallet creation.
public final class RecoveryPhrase: @unchecked Sendable, CustomStringConvertible, CustomReflectable {
    private let lock = NSLock()
    private var utf8: [UInt8]?

    init(_ value: String) { utf8 = Array(value.utf8) }

    public init(copyingUTF8 value: [UInt8]) throws {
        guard !value.isEmpty, value.count <= 512 else {
            throw SDKError.invalidArgument("mnemonic", "must be a bounded non-empty phrase")
        }
        guard let text = String(bytes: value, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SDKError.invalidArgument("mnemonic", "must be valid non-blank UTF-8")
        }
        utf8 = Array(value)
    }
    deinit { close() }

    public func consume<T>(_ body: ([UInt8]) throws -> T) throws -> T {
        var value = try lock.withLock { () throws -> [UInt8] in
            guard let current = utf8 else {
                throw SDKError.invalidState(operation: "read recovery phrase", state: "consumed")
            }
            utf8 = nil
            return current
        }
        defer { wipe(&value) }
        return try body(value)
    }

    func withCopy<T>(_ body: (inout [UInt8]) throws -> T) throws -> T {
        var value = try lock.withLock { () throws -> [UInt8] in
            guard let utf8 else {
                throw SDKError.invalidState(operation: "read recovery phrase", state: "closed")
            }
            return utf8
        }
        defer { wipe(&value) }
        return try body(&value)
    }

    public func close() {
        lock.withLock {
            _ = utf8?.withUnsafeMutableBytes {
                $0.initializeMemory(as: UInt8.self, repeating: 0)
            }
            utf8 = nil
        }
    }

    public var description: String { "RecoveryPhrase([REDACTED])" }
    public var customMirror: Mirror { Mirror(self, children: ["value": "[REDACTED]"]) }
}

/// Explicitly dangerous compatibility export; never log or serialize it.
public final class ExtendedPrivateKey: @unchecked Sendable, CustomStringConvertible, CustomReflectable {
    private let lock = NSLock()
    private var utf8: [UInt8]?

    init(_ value: String) { utf8 = Array(value.utf8) }

    public init(copyingUTF8 value: [UInt8]) throws {
        guard !value.isEmpty, value.count <= 256, String(bytes: value, encoding: .utf8) != nil else {
            throw SDKError.invalidArgument("xpriv", "must be a bounded non-empty UTF-8 key")
        }
        utf8 = Array(value)
    }
    deinit { close() }

    public func consume<T>(_ body: ([UInt8]) throws -> T) throws -> T {
        var value = try lock.withLock { () throws -> [UInt8] in
            guard let current = utf8 else {
                throw SDKError.invalidState(operation: "read extended private key", state: "consumed")
            }
            utf8 = nil
            return current
        }
        defer { wipe(&value) }
        return try body(value)
    }

    func withStringCopy<T>(_ body: (String) throws -> T) throws -> T {
        var copy = try lock.withLock { () throws -> [UInt8] in
            guard let utf8 else {
                throw SDKError.invalidState(operation: "read extended private key", state: "closed")
            }
            return utf8
        }
        defer { wipe(&copy) }
        guard let string = String(bytes: copy, encoding: .utf8) else {
            throw SDKError.invariant("extended private key storage is not UTF-8")
        }
        return try body(string)
    }

    public func close() {
        lock.withLock {
            _ = utf8?.withUnsafeMutableBytes {
                $0.initializeMemory(as: UInt8.self, repeating: 0)
            }
            utf8 = nil
        }
    }

    public var description: String { "ExtendedPrivateKey([REDACTED])" }
    public var customMirror: Mirror { Mirror(self, children: ["value": "[REDACTED]"]) }
}

public typealias SecretMnemonic = RecoveryPhrase
public typealias SecretExtendedPrivateKey = ExtendedPrivateKey
