import CryptoKit
import Foundation

/// Canonical, versioned persistence encoding for operation checkpoints.
///
/// This schema is byte-for-byte shared with the Kotlin SDK: `UTXOPCHK`, a
/// big-endian UInt32 schema version, length-prefixed UTF-8 fields, fixed-width
/// integers, and a trailing SHA-256. The digest detects accidental corruption;
/// it does not authenticate the record. Encoded data contains raw prepared and
/// signed PSBTs, so production journals must encrypt and authenticate it before
/// atomically writing it to storage.
@_spi(Backend)
public enum OperationCheckpointCodec {
    /// Full-record wire version, retained for existing infrastructure clients.
    /// Compact terminal receipts use version 2; decode accepts both versions.
    public static let schemaVersion: UInt32 = 1
    static let compactTerminalSchemaVersion: UInt32 = 2
    public static let maximumEncodedBytes = 16_000_000

    private static let checksumBytes = 32
    private static let magic = Data("UTXOPCHK".utf8)

    public static func encode(_ checkpoint: OperationCheckpoint) throws -> Data {
        do {
            var writer = CheckpointWriter()
            writer.append(magic)
            if checkpoint.phase == .terminal, checkpoint.preparedTransaction == nil {
                writer.append(compactTerminalSchemaVersion)
                try writer.appendCompactTerminal(checkpoint)
            } else {
                writer.append(schemaVersion)
                try writer.append(checkpoint)
            }
            let body = writer.data
            guard body.count <= maximumEncodedBytes - checksumBytes else {
                throw SDKError.operationJournalUnavailable
            }
            var encoded = body
            encoded.append(contentsOf: SHA256.hash(data: body))
            return encoded
        } catch {
            // Underlying codec/provider errors may contain sensitive fields.
            throw SDKError.operationJournalUnavailable
        }
    }

    public static func decode(_ encoded: Data) throws -> OperationCheckpoint {
        do {
            guard encoded.count > magic.count + MemoryLayout<UInt32>.size + checksumBytes,
                  encoded.count <= maximumEncodedBytes else {
                throw SDKError.operationJournalUnavailable
            }
            // A Data.SubSequence is also Data and may retain a nonzero start
            // index. Count is a length, never an absolute collection index.
            let bodyEnd = encoded.index(encoded.endIndex, offsetBy: -checksumBytes)
            let body = Data(encoded[..<bodyEnd])
            let expectedDigest = encoded[bodyEnd...]
            let actualDigest = SHA256.hash(data: body)
            guard expectedDigest.elementsEqual(actualDigest) else {
                throw SDKError.operationJournalUnavailable
            }

            var reader = CheckpointReader(data: body)
            guard try reader.readData(count: magic.count) == magic else {
                throw SDKError.operationJournalUnavailable
            }
            let checkpoint: OperationCheckpoint
            switch try reader.readUInt32() {
            case schemaVersion: checkpoint = try reader.readCheckpoint()
            case compactTerminalSchemaVersion: checkpoint = try reader.readCompactTerminal()
            default: throw SDKError.operationJournalUnavailable
            }
            guard reader.isAtEnd else { throw SDKError.operationJournalUnavailable }
            return checkpoint
        } catch {
            throw SDKError.operationJournalUnavailable
        }
    }
}

private struct CheckpointWriter {
    private(set) var data = Data()

    mutating func appendCompactTerminal(_ checkpoint: OperationCheckpoint) throws {
        guard checkpoint.phase == .terminal, checkpoint.preparedTransaction == nil,
              checkpoint.signedPsbtBase64 == nil,
              let operationID = checkpoint.operationID,
              let outcome = checkpoint.terminalOutcome else {
            throw SDKError.operationJournalUnavailable
        }
        try append(checkpoint.walletID.value, maximumBytes: 128)
        try append(checkpoint.idempotencyKey.value, maximumBytes: 128)
        try append(checkpoint.requestHash.hex, maximumBytes: 64)
        try append(checkpoint.operationKind.rawValue, maximumBytes: 32)
        try append(checkpoint.phase.wireValue, maximumBytes: 32)
        try append(operationID.value, maximumBytes: 128)
        try appendOptional(checkpoint.validation) { writer, value in try writer.append(value) }
        try append(outcome)
    }

    mutating func append(_ checkpoint: OperationCheckpoint) throws {
        try append(checkpoint.walletID.value, maximumBytes: 128)
        try append(checkpoint.idempotencyKey.value, maximumBytes: 128)
        try append(checkpoint.requestHash.hex, maximumBytes: 64)
        try append(checkpoint.operationKind.rawValue, maximumBytes: 32)
        try append(checkpoint.phase.wireValue, maximumBytes: 32)
        try appendOptional(checkpoint.operationID) { writer, value in
            try writer.append(value.value, maximumBytes: 128)
        }
        try appendOptional(checkpoint.preparedTransaction) { writer, value in
            try writer.append(value)
        }
        if let signedPsbtBase64 = checkpoint.signedPsbtBase64,
           let validation = checkpoint.validation {
            append(UInt8(1))
            try append(signedPsbtBase64, maximumBytes: 5_400_000)
            try append(validation)
        } else {
            append(UInt8(0))
        }
        try appendOptional(checkpoint.terminalOutcome) { writer, value in
            try writer.append(value)
        }
    }

    private mutating func append(_ prepared: PreparedTransaction) throws {
        try append(prepared.operationID.value, maximumBytes: 128)
        try append(prepared.idempotencyKey.value, maximumBytes: 128)
        try append(prepared.requestHash.hex, maximumBytes: 64)
        try append(prepared.network.rawValue, maximumBytes: 32)
        try append(prepared.operation.rawValue, maximumBytes: 32)
        try append(prepared.psbtBase64, maximumBytes: 5_400_000)
        try appendNonnegativeLong(prepared.expiresAt.rawValue)
        try appendOptional(prepared.createUtxosOutputPlan) { writer, plan in
            guard (1...256).contains(plan.outputs.count) else {
                throw SDKError.operationJournalUnavailable
            }
            writer.append(UInt32(plan.outputs.count))
            for output in plan.outputs {
                try writer.append(output.account.rawValue, maximumBytes: 32)
                try writer.append(output.keychain.rawValue, maximumBytes: 32)
                writer.append(output.index)
                try writer.appendNonnegativeLong(output.amount.value)
            }
        }
        try appendOptional(prepared.correlationID) { writer, value in
            try writer.append(value, maximumBytes: 128)
        }
    }

    private mutating func append(_ validation: LocalValidationReport) throws {
        try append(validation.psbtSHA256, maximumBytes: 64)
        try append(validation.intentSHA256, maximumBytes: 64)
        try append(validation.unsignedTxid.hex, maximumBytes: 64)
        try appendNonnegativeLong(validation.totalInput.value)
        try appendNonnegativeLong(validation.totalOutput.value)
        try appendNonnegativeLong(validation.fee.value)
        try appendNonnegativeLong(validation.estimatedVbytes)
        try appendNonnegativeLong(validation.feeRate.milliSatsPerVByte)
        try appendNonnegativeLong(validation.externalOutput.value)
        try appendNonnegativeLong(validation.change.value)
        append(validation.inputCount)
        append(validation.outputCount)
        append(validation.opReturnCount)
    }

    private mutating func append(_ outcome: OperationTerminalOutcome) throws {
        switch outcome {
        case let .succeeded(result):
            append(UInt8(1))
            try append(result)
        case let .rejected(operationID, safeMessage, retryable, backendCode, correlationID):
            append(UInt8(2))
            try append(operationID.value, maximumBytes: 128)
            try append(safeMessage, maximumBytes: 512)
            append(retryable ? UInt8(1) : UInt8(0))
            try appendOptional(backendCode) { writer, value in
                try writer.append(value, maximumBytes: 128)
            }
            try appendOptional(correlationID) { writer, value in
                try writer.append(value, maximumBytes: 128)
            }
        case let .expired(operationID):
            append(UInt8(3))
            try append(operationID.value, maximumBytes: 128)
        }
    }

    private mutating func append(_ result: BackendOperationResult) throws {
        switch result {
        case let .sendBtc(operationID, txid):
            append(UInt8(1))
            try append(operationID.value, maximumBytes: 128)
            try append(txid.hex, maximumBytes: 64)
        case let .createUtxos(operationID, result):
            append(UInt8(2))
            try append(operationID.value, maximumBytes: 128)
            try append(result.txid.hex, maximumBytes: 64)
            append(UInt32(result.createdUtxoCount))
        case let .onchainSend(operationID, result):
            // Preserve v1's discriminator 3 + concrete u64 byte-for-byte.
            // The additive discriminator 4 represents an honestly absent ID.
            append(UInt8(result.batchTransferIndex == nil ? 4 : 3))
            try append(operationID.value, maximumBytes: 128)
            try append(result.txid.hex, maximumBytes: 64)
            if let index = result.batchTransferIndex { try appendNonnegativeLong(index) }
        }
    }

    private mutating func appendOptional<T>(
        _ value: T?,
        write: (inout CheckpointWriter, T) throws -> Void
    ) throws {
        guard let value else {
            append(UInt8(0))
            return
        }
        append(UInt8(1))
        try write(&self, value)
    }

    private mutating func append(_ value: String, maximumBytes: Int) throws {
        let bytes = Data(value.utf8)
        guard bytes.count <= maximumBytes else { throw SDKError.operationJournalUnavailable }
        append(UInt32(bytes.count))
        append(bytes)
    }

    private mutating func appendNonnegativeLong(_ value: UInt64) throws {
        guard value <= UInt64(Int64.max) else { throw SDKError.operationJournalUnavailable }
        append(value)
    }

    mutating func append(_ value: UInt8) {
        data.append(value)
    }

    mutating func append(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private mutating func append(_ value: UInt64) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func append(_ value: Data) {
        data.append(value)
    }
}

private struct CheckpointReader {
    let data: Data
    private(set) var offset = 0

    var isAtEnd: Bool { offset == data.count }

    mutating func readCompactTerminal() throws -> OperationCheckpoint {
        let walletID = try WalletID(readString(maximumBytes: 128))
        let idempotencyKey = try IdempotencyKey(readString(maximumBytes: 128))
        let requestHash = try RequestHash(validating: readString(maximumBytes: 64))
        guard let operationKind = OperationKind(rawValue: try readString(maximumBytes: 32)),
              try readString(maximumBytes: 32) == "terminal" else {
            throw SDKError.operationJournalUnavailable
        }
        return try OperationCheckpoint(
            walletID: walletID, idempotencyKey: idempotencyKey,
            requestHash: requestHash, operationKind: operationKind,
            phase: .terminal, operationID: OperationID(readString(maximumBytes: 128)),
            validation: readOptional { reader in try reader.readValidation() },
            terminalOutcome: readOutcome()
        )
    }

    mutating func readCheckpoint() throws -> OperationCheckpoint {
        let walletID = try WalletID(readString(maximumBytes: 128))
        let idempotencyKey = try IdempotencyKey(readString(maximumBytes: 128))
        let requestHash = try RequestHash(validating: readString(maximumBytes: 64))
        guard let operationKind = OperationKind(rawValue: try readString(maximumBytes: 32)),
              let phase = OperationPhase(wireValue: try readString(maximumBytes: 32)) else {
            throw SDKError.operationJournalUnavailable
        }
        let operationID = try readOptional { reader in
            try OperationID(reader.readString(maximumBytes: 128))
        }
        let prepared = try readOptional { reader in try reader.readPreparedTransaction() }
        let signed: (String, LocalValidationReport)? = try readOptional { reader in
            (
                try reader.readString(maximumBytes: 5_400_000),
                try reader.readValidation()
            )
        }
        let outcome = try readOptional { reader in try reader.readOutcome() }
        // V1 never represented compact receipts. Keep its historical shape
        // strict, and reserve omission of terminal payloads for version 2.
        guard phase == .created || prepared != nil else {
            throw SDKError.operationJournalUnavailable
        }
        return try OperationCheckpoint(
            walletID: walletID,
            idempotencyKey: idempotencyKey,
            requestHash: requestHash,
            operationKind: operationKind,
            phase: phase,
            operationID: operationID,
            preparedTransaction: prepared,
            signedPsbtBase64: signed?.0,
            validation: signed?.1,
            terminalOutcome: outcome
        )
    }

    private mutating func readPreparedTransaction() throws -> PreparedTransaction {
        let operationID = try OperationID(readString(maximumBytes: 128))
        let idempotencyKey = try IdempotencyKey(readString(maximumBytes: 128))
        let requestHash = try RequestHash(validating: readString(maximumBytes: 64))
        guard let network = Network(rawValue: try readString(maximumBytes: 32)),
              let operation = OperationKind(rawValue: try readString(maximumBytes: 32)) else {
            throw SDKError.operationJournalUnavailable
        }
        let psbtBase64 = try readString(maximumBytes: 5_400_000)
        let expiresAt = try readNonnegativeLong()
        let outputPlan = try readOptional { reader -> CreateUtxosOutputPlan in
            let count = try reader.readUInt32()
            guard (1...256).contains(count) else { throw SDKError.operationJournalUnavailable }
            var outputs: [ExpectedWalletOutput] = []
            outputs.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let account = AccountKind(rawValue: try reader.readString(maximumBytes: 32)),
                      let keychain = Keychain(rawValue: try reader.readString(maximumBytes: 32)) else {
                    throw SDKError.operationJournalUnavailable
                }
                outputs.append(
                    try ExpectedWalletOutput(
                        account: account,
                        keychain: keychain,
                        index: reader.readUInt32(),
                        amount: Satoshis(reader.readNonnegativeLong())
                    )
                )
            }
            return try CreateUtxosOutputPlan(outputs: outputs)
        }
        let correlationID = try readOptional { reader in
            try reader.readString(maximumBytes: 128)
        }
        return try PreparedTransaction(
            operationID: operationID,
            idempotencyKey: idempotencyKey,
            requestHash: requestHash,
            network: network,
            operation: operation,
            psbtBase64: psbtBase64,
            expiresAt: .init(rawValue: expiresAt),
            createUtxosOutputPlan: outputPlan,
            correlationID: correlationID
        )
    }

    private mutating func readValidation() throws -> LocalValidationReport {
        try LocalValidationReport(
            psbtSHA256: readString(maximumBytes: 64),
            intentSHA256: readString(maximumBytes: 64),
            unsignedTxid: TransactionID(readString(maximumBytes: 64)),
            totalInput: Satoshis(readNonnegativeLong()),
            totalOutput: Satoshis(readNonnegativeLong()),
            fee: Satoshis(readNonnegativeLong()),
            estimatedVbytes: readNonnegativeLong(),
            feeRate: FeeRate(milliSatsPerVByte: readNonnegativeLong()),
            externalOutput: Satoshis(readNonnegativeLong()),
            change: Satoshis(readNonnegativeLong()),
            inputCount: readUInt32(),
            outputCount: readUInt32(),
            opReturnCount: readUInt32()
        )
    }

    private mutating func readOutcome() throws -> OperationTerminalOutcome {
        switch try readUInt8() {
        case 1:
            return try .succeeded(readResult())
        case 2:
            return try .rejected(
                operationID: OperationID(readString(maximumBytes: 128)),
                safeMessage: readString(maximumBytes: 512),
                retryable: readBool(),
                backendCode: readOptional { reader in try reader.readString(maximumBytes: 128) },
                correlationID: readOptional { reader in try reader.readString(maximumBytes: 128) }
            )
        case 3:
            return try .expired(operationID: OperationID(readString(maximumBytes: 128)))
        default:
            throw SDKError.operationJournalUnavailable
        }
    }

    private mutating func readResult() throws -> BackendOperationResult {
        switch try readUInt8() {
        case 1:
            return try .sendBtc(
                operationID: OperationID(readString(maximumBytes: 128)),
                txid: TransactionID(readString(maximumBytes: 64))
            )
        case 4:
            return try .onchainSend(
                operationID: OperationID(readString(maximumBytes: 128)),
                result: .init(txid: TransactionID(readString(maximumBytes: 64)))
            )
        case 2:
            return try .createUtxos(
                operationID: OperationID(readString(maximumBytes: 128)),
                result: .init(
                    txid: TransactionID(readString(maximumBytes: 64)),
                    createdUtxoCount: UInt16(exactly: readUInt32())
                        ?? { throw SDKError.operationJournalUnavailable }()
                )
            )
        case 3:
            return try .onchainSend(
                operationID: OperationID(readString(maximumBytes: 128)),
                result: .init(
                    txid: TransactionID(readString(maximumBytes: 64)),
                    batchTransferIndex: readNonnegativeLong()
                )
            )
        default:
            throw SDKError.operationJournalUnavailable
        }
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, count <= data.count - offset else {
            throw SDKError.operationJournalUnavailable
        }
        let range = offset..<(offset + count)
        offset += count
        return Data(data[range])
    }

    private mutating func readString(maximumBytes: Int) throws -> String {
        let length = try readUInt32()
        guard length <= UInt32(maximumBytes),
              let value = String(data: try readData(count: Int(length)), encoding: .utf8) else {
            throw SDKError.operationJournalUnavailable
        }
        return value
    }

    private mutating func readOptional<T>(
        _ read: (inout CheckpointReader) throws -> T
    ) throws -> T? {
        guard try readBool() else { return nil }
        return try read(&self)
    }

    private mutating func readBool() throws -> Bool {
        switch try readUInt8() {
        case 0: false
        case 1: true
        default: throw SDKError.operationJournalUnavailable
        }
    }

    private mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else { throw SDKError.operationJournalUnavailable }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readData(count: 4)
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private mutating func readNonnegativeLong() throws -> UInt64 {
        let bytes = try readData(count: 8)
        let value = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard value <= UInt64(Int64.max) else { throw SDKError.operationJournalUnavailable }
        return value
    }
}

private extension OperationPhase {
    var wireValue: String {
        switch self {
        case .created: "created"
        case .prepared: "prepared"
        case .signed: "signed"
        case .submitting: "submitting"
        case .terminal: "terminal"
        }
    }

    init?(wireValue: String) {
        switch wireValue {
        case "created": self = .created
        case "prepared": self = .prepared
        case "signed": self = .signed
        case "submitting": self = .submitting
        case "terminal": self = .terminal
        default: return nil
        }
    }
}
