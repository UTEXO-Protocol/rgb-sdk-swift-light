import Foundation

public struct SendBtcRequest: Hashable, Sendable {
    public let address: BitcoinAddress
    public let amount: Satoshis
    public let feeRate: FeeRate
    public let skipSync: Bool
    public let idempotencyKey: IdempotencyKey

    public init(
        address: BitcoinAddress,
        amount: Satoshis,
        feeRate: FeeRate = .default,
        skipSync: Bool = false,
        idempotencyKey: IdempotencyKey = .random()
    ) throws {
        self.address = address
        self.amount = try .positive(amount, field: "amount")
        self.feeRate = feeRate
        self.skipSync = skipSync
        self.idempotencyKey = idempotencyKey
    }
}

public struct CreateUtxosRequest: Hashable, Sendable {
    public let upTo: Bool
    public let num: UInt16?
    public let size: Satoshis?
    public let feeRate: FeeRate
    public let skipSync: Bool
    public let idempotencyKey: IdempotencyKey

    public init(
        upTo: Bool = true,
        num: UInt16? = nil,
        size: Satoshis? = nil,
        feeRate: FeeRate = .default,
        skipSync: Bool = false,
        idempotencyKey: IdempotencyKey = .random()
    ) throws {
        // The native RN reference accepts a u8 count. Keep the public UInt16
        // carrier source-compatible, but reject values that would wrap at FFI.
        if let num, !(1...255).contains(num) {
            throw SDKError.invalidArgument("num", "must be between 1 and 255")
        }
        if let size {
            _ = try Satoshis.positive(size, field: "size")
            guard size.value <= UInt64(UInt32.max) else {
                throw SDKError.invalidArgument("size", "must fit the native unsigned 32-bit satoshi amount")
            }
        }
        self.upTo = upTo
        self.num = num
        self.size = size
        self.feeRate = feeRate
        self.skipSync = skipSync
        self.idempotencyKey = idempotencyKey
    }
}

public struct CreateUtxosResult: Hashable, Sendable {
    public let txid: TransactionID
    /// Authoritative count returned after backend acceptance.
    public let createdUtxoCount: UInt16

    public init(txid: TransactionID, createdUtxoCount: UInt16) {
        self.txid = txid
        self.createdUtxoCount = createdUtxoCount
    }
}

public struct FeeEstimate: Hashable, Sendable {
    public let feeRate: FeeRate
    public let targetBlocks: BlockCount
    public let measuredAt: UnixSeconds?

    public init(feeRate: FeeRate, targetBlocks: BlockCount, measuredAt: UnixSeconds? = nil) {
        self.feeRate = feeRate
        self.targetBlocks = targetBlocks
        self.measuredAt = measuredAt
    }
}

public struct WitnessData: Hashable, Sendable {
    public let amountSat: Satoshis
    public let blinding: UInt64?

    public init(amountSat: Satoshis, blinding: UInt64? = nil) throws {
        self.amountSat = try .positive(amountSat, field: "witnessData.amountSat")
        self.blinding = blinding
    }
}

public struct InvoiceRequest: Hashable, Sendable {
    public let amount: AssetAmount?
    public let assetID: AssetID?
    public let minConfirmations: BlockCount
    public let duration: DurationSeconds?

    public init(
        amount: AssetAmount? = nil,
        assetID: AssetID? = nil,
        minConfirmations: BlockCount = .init(rawValue: 0),
        duration: DurationSeconds? = nil
    ) throws {
        if let amount { _ = try AssetAmount.positive(amount, field: "amount") }
        self.amount = amount
        self.assetID = assetID
        self.minConfirmations = minConfirmations
        self.duration = duration
    }
}

public struct OnchainReceiveRequest: Hashable, Sendable {
    public let amount: AssetAmount?
    public let assetID: AssetID?
    public let minConfirmations: BlockCount
    public let duration: DurationSeconds?
    public let witness: Bool

    public init(
        amount: AssetAmount? = nil,
        assetID: AssetID? = nil,
        minConfirmations: BlockCount = .init(rawValue: 0),
        duration: DurationSeconds? = nil,
        witness: Bool = true
    ) throws {
        if let amount { _ = try AssetAmount.positive(amount, field: "amount") }
        self.amount = amount
        self.assetID = assetID
        self.minConfirmations = minConfirmations
        self.duration = duration
        self.witness = witness
    }
}

public struct OnchainReceiveResponse: Hashable, Sendable {
    public let invoice: RGBInvoice
    public let recipientID: String?
    public let expirationTimestamp: UnixSeconds?
    public let batchTransferIndex: UInt64?

    public init(
        invoice: RGBInvoice,
        recipientID: String? = nil,
        expirationTimestamp: UnixSeconds? = nil,
        batchTransferIndex: UInt64? = nil
    ) throws {
        self.invoice = invoice
        self.recipientID = try recipientID.map {
            try requireBoundedText($0, field: "recipientId", maximumUTF8Bytes: 1_024)
        }
        self.expirationTimestamp = expirationTimestamp
        self.batchTransferIndex = batchTransferIndex
    }
}

public struct OnchainSendRequest: Hashable, Sendable {
    public let invoice: RGBInvoice
    public let amount: AssetAmount
    public let assetID: AssetID?
    public let witnessData: WitnessData?
    public let donation: Bool
    public let feeRate: FeeRate
    public let minConfirmations: BlockCount
    public let skipSync: Bool
    public let idempotencyKey: IdempotencyKey

    public init(
        invoice: RGBInvoice,
        amount: AssetAmount,
        assetID: AssetID? = nil,
        witnessData: WitnessData? = nil,
        donation: Bool = false,
        feeRate: FeeRate = .default,
        minConfirmations: BlockCount = .init(rawValue: 1),
        skipSync: Bool = false,
        idempotencyKey: IdempotencyKey = .random()
    ) throws {
        self.invoice = invoice
        self.amount = try .positive(amount, field: "amount")
        self.assetID = assetID
        self.witnessData = witnessData
        self.donation = donation
        self.feeRate = feeRate
        self.minConfirmations = minConfirmations
        self.skipSync = skipSync
        self.idempotencyKey = idempotencyKey
    }
}

public struct OnchainSendResponse: Hashable, Sendable {
    public let txid: TransactionID
    /// Nil when the gateway does not expose the native batch identifier.
    public let batchTransferIndex: UInt64?

    public init(txid: TransactionID, batchTransferIndex: UInt64? = nil) {
        self.txid = txid
        self.batchTransferIndex = batchTransferIndex
    }
}

public struct IssueAssetNiaRequest: Hashable, Sendable {
    public let ticker: String
    public let name: String
    public let amounts: [AssetAmount]
    public let precision: UInt8

    public init(ticker: String, name: String, amounts: [AssetAmount], precision: UInt8) throws {
        self.ticker = try requireBoundedText(ticker, field: "ticker", maximumUTF8Bytes: 16)
        self.name = try requireBoundedText(name, field: "name", maximumUTF8Bytes: 256)
        guard !amounts.isEmpty else { throw SDKError.invalidArgument("amounts", "must not be empty") }
        for amount in amounts { _ = try AssetAmount.positive(amount, field: "amounts") }
        guard precision <= 18 else {
            throw SDKError.invalidArgument("precision", "must be between 0 and 18")
        }
        self.amounts = amounts
        self.precision = precision
    }
}

public struct IssueAssetIfaRequest: Hashable, Sendable {
    public let ticker: String
    public let name: String
    public let precision: UInt8
    public let amounts: [AssetAmount]
    public let inflationAmounts: [AssetAmount]
    public let rejectListURL: URL?

    public init(
        ticker: String,
        name: String,
        precision: UInt8,
        amounts: [AssetAmount],
        inflationAmounts: [AssetAmount],
        rejectListURL: URL? = nil
    ) throws {
        self.ticker = try requireBoundedText(ticker, field: "ticker", maximumUTF8Bytes: 16)
        self.name = try requireBoundedText(name, field: "name", maximumUTF8Bytes: 256)
        guard precision <= 18 else {
            throw SDKError.invalidArgument("precision", "must be between 0 and 18")
        }
        guard !amounts.isEmpty else { throw SDKError.invalidArgument("amounts", "must not be empty") }
        for amount in amounts { _ = try AssetAmount.positive(amount, field: "amounts") }
        for amount in inflationAmounts {
            _ = try AssetAmount.positive(amount, field: "inflationAmounts")
        }
        if let rejectListURL {
            _ = try requireBoundedText(
                rejectListURL.absoluteString,
                field: "rejectListURL",
                maximumUTF8Bytes: 2_048
            )
        }
        self.precision = precision
        self.amounts = amounts
        self.inflationAmounts = inflationAmounts
        self.rejectListURL = rejectListURL
    }
}

public struct InflateRequest: Hashable, Sendable {
    public let assetID: AssetID
    public let inflationAmounts: [AssetAmount]
    public let feeRate: FeeRate
    public let minConfirmations: BlockCount
    public let idempotencyKey: IdempotencyKey

    public init(
        assetID: AssetID,
        inflationAmounts: [AssetAmount],
        feeRate: FeeRate = .default,
        minConfirmations: BlockCount = .init(rawValue: 1),
        idempotencyKey: IdempotencyKey = .random()
    ) throws {
        guard !inflationAmounts.isEmpty else {
            throw SDKError.invalidArgument("inflationAmounts", "must not be empty")
        }
        for amount in inflationAmounts {
            _ = try AssetAmount.positive(amount, field: "inflationAmounts")
        }
        self.assetID = assetID
        self.inflationAmounts = inflationAmounts
        self.feeRate = feeRate
        self.minConfirmations = minConfirmations
        self.idempotencyKey = idempotencyKey
    }
}

public struct FailTransfersRequest: Hashable, Sendable {
    public let batchTransferIndex: UInt64?
    public let noAssetOnly: Bool
    public let skipSync: Bool

    public init(batchTransferIndex: UInt64? = nil, noAssetOnly: Bool = false, skipSync: Bool = false) {
        self.batchTransferIndex = batchTransferIndex
        self.noAssetOnly = noAssetOnly
        self.skipSync = skipSync
    }
}

public struct FailTransfersResult: Hashable, Sendable {
    public let transfersChanged: Bool
    public init(transfersChanged: Bool) { self.transfersChanged = transfersChanged }
}

public struct SyncResult: Hashable, Sendable {
    /// Client-observed successful completion time, using the local wall clock.
    /// Not a server timestamp, block timestamp, or proof of chain freshness.
    public let completedAt: UnixSeconds
    /// Authoritative synchronized tip, only when the implementation can supply it.
    public let tipHeight: UInt32?
    public init(completedAt: UnixSeconds, tipHeight: UInt32? = nil) {
        self.completedAt = completedAt
        self.tipHeight = tipHeight
    }
}
