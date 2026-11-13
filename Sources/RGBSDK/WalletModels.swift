import Foundation

/// Watch-only identity registered with the backend. No private material is included.
public struct WalletIdentity: Hashable, Sendable {
    public let network: Network
    public let chainNetwork: String
    public let derivationProfile: String
    public let masterFingerprint: String
    public let xpub: String
    public let accountXpubVanilla: String
    public let accountXpubColored: String

    @_spi(Backend)
    public init(
        network: Network,
        chainNetwork: String,
        derivationProfile: String,
        masterFingerprint: String,
        xpub: String,
        accountXpubVanilla: String,
        accountXpubColored: String
    ) {
        self.network = network
        self.chainNetwork = chainNetwork
        self.derivationProfile = derivationProfile
        self.masterFingerprint = masterFingerprint
        self.xpub = xpub
        self.accountXpubVanilla = accountXpubVanilla
        self.accountXpubColored = accountXpubColored
    }
}

public struct Balance: Hashable, Sendable {
    public let settled: Satoshis
    public let future: Satoshis
    public let spendable: Satoshis

    public init(settled: Satoshis, future: Satoshis, spendable: Satoshis) {
        self.settled = settled
        self.future = future
        self.spendable = spendable
    }
}

public struct BTCBalance: Hashable, Sendable {
    public let vanilla: Balance
    public let colored: Balance

    public init(vanilla: Balance, colored: Balance) {
        self.vanilla = vanilla
        self.colored = colored
    }
}

public struct AssetBalance: Hashable, Sendable {
    public let settled: AssetAmount?
    public let future: AssetAmount?
    public let spendable: AssetAmount?
    public let offchainOutbound: AssetAmount?
    public let offchainInbound: AssetAmount?

    public init(
        settled: AssetAmount? = nil,
        future: AssetAmount? = nil,
        spendable: AssetAmount? = nil,
        offchainOutbound: AssetAmount? = nil,
        offchainInbound: AssetAmount? = nil
    ) {
        self.settled = settled
        self.future = future
        self.spendable = spendable
        self.offchainOutbound = offchainOutbound
        self.offchainInbound = offchainInbound
    }
}

public struct Outpoint: Hashable, Sendable {
    public let txid: TransactionID
    public let vout: UInt32

    public init(txid: TransactionID, vout: UInt32) {
        self.txid = txid
        self.vout = vout
    }
}

public struct UTXO: Hashable, Sendable {
    public let outpoint: Outpoint
    public let btcAmount: Satoshis
    public let colorable: Bool
    /// Authoritative backend state, or nil when the service does not expose it.
    /// Unknown must never be treated as proof that an output exists or is spendable.
    public let exists: Bool?

    public init(outpoint: Outpoint, btcAmount: Satoshis, colorable: Bool, exists: Bool? = nil) {
        self.outpoint = outpoint
        self.btcAmount = btcAmount
        self.colorable = colorable
        self.exists = exists
    }
}

public struct AssignmentType: Hashable, Sendable, CustomStringConvertible {
    public static let fungible = Self(unchecked: "Fungible")
    public static let nonFungible = Self(unchecked: "NonFungible")
    public static let inflationRight = Self(unchecked: "InflationRight")
    public static let replaceRight = Self(unchecked: "ReplaceRight")
    public static let any = Self(unchecked: "Any")

    public let rawValue: String
    public var description: String { rawValue }

    public init(_ value: String) throws {
        rawValue = try requireBoundedText(value, field: "assignmentType", maximumUTF8Bytes: 64)
    }

    private init(unchecked value: String) { rawValue = value }
}

public struct Assignment: Hashable, Sendable {
    public let type: AssignmentType
    public let amount: AssetAmount?

    public init(type: AssignmentType, amount: AssetAmount? = nil) {
        self.type = type
        self.amount = amount
    }
}

public struct RGBAllocation: Hashable, Sendable {
    public let assetID: AssetID?
    public let assignment: Assignment
    public let settled: Bool

    public init(assetID: AssetID? = nil, assignment: Assignment, settled: Bool) {
        self.assetID = assetID
        self.assignment = assignment
        self.settled = settled
    }
}

public struct Unspent: Hashable, Sendable {
    public let utxo: UTXO
    public let rgbAllocations: [RGBAllocation]
    public let pendingBlinded: UInt32

    public init(utxo: UTXO, rgbAllocations: [RGBAllocation], pendingBlinded: UInt32) {
        self.utxo = utxo
        self.rgbAllocations = rgbAllocations
        self.pendingBlinded = pendingBlinded
    }
}

public struct TransactionType: Hashable, Sendable, CustomStringConvertible {
    public static let rgbSend = Self(unchecked: "RgbSend")
    public static let drain = Self(unchecked: "Drain")
    public static let createUtxos = Self(unchecked: "CreateUtxos")
    public static let sendBtc = Self(unchecked: "SendBtc")
    public static let incoming = Self(unchecked: "Incoming")
    public static let user = Self(unchecked: "User")

    public let rawValue: String
    public var description: String { rawValue }

    public init(_ value: String) throws {
        rawValue = try requireBoundedText(value, field: "transactionType", maximumUTF8Bytes: 64)
    }

    private init(unchecked value: String) { rawValue = value }
}

public struct BlockTime: Hashable, Sendable {
    public let height: UInt32
    public let timestamp: UnixSeconds

    public init(height: UInt32, timestamp: UnixSeconds) {
        self.height = height
        self.timestamp = timestamp
    }
}

public struct Transaction: Hashable, Sendable {
    public let transactionType: TransactionType
    public let txid: TransactionID
    public let received: Satoshis
    public let sent: Satoshis
    public let fee: Satoshis
    public let confirmationTime: BlockTime?

    public init(
        transactionType: TransactionType,
        txid: TransactionID,
        received: Satoshis,
        sent: Satoshis,
        fee: Satoshis,
        confirmationTime: BlockTime? = nil
    ) {
        self.transactionType = transactionType
        self.txid = txid
        self.received = received
        self.sent = sent
        self.fee = fee
        self.confirmationTime = confirmationTime
    }
}

public struct TransferKind: RawRepresentable, Hashable, Sendable {
    public static let issuance = Self(rawValue: "Issuance")
    public static let receiveBlind = Self(rawValue: "ReceiveBlind")
    public static let receiveWitness = Self(rawValue: "ReceiveWitness")
    public static let send = Self(rawValue: "Send")
    public static let inflation = Self(rawValue: "Inflation")
    public static let burn = Self(rawValue: "Burn")
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct TransferStatus: RawRepresentable, Hashable, Sendable {
    public static let waitingCounterparty = Self(rawValue: "WaitingCounterparty")
    public static let waitingSafeHeight = Self(rawValue: "WaitingSafeHeight")
    public static let waitingBroadcast = Self(rawValue: "WaitingBroadcast")
    public static let waitingConfirmations = Self(rawValue: "WaitingConfirmations")
    public static let settled = Self(rawValue: "Settled")
    public static let failed = Self(rawValue: "Failed")
    public static let initiated = Self(rawValue: "Initiated")
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct Transfer: Hashable, Sendable {
    public let index: UInt64
    /// Nil when the gateway cannot provide the native batch identity.
    public let batchTransferIndex: UInt64?
    public let assetID: AssetID?
    public let createdAt: UnixSeconds
    public let updatedAt: UnixSeconds
    public let status: TransferStatus
    public let requestedAssignment: Assignment?
    public let assignments: [Assignment]
    public let kind: TransferKind
    public let txid: TransactionID?
    public let recipientID: String?
    public let receiveUTXO: Outpoint?
    public let changeUTXO: Outpoint?
    public let expiration: UnixSeconds?
    /// Nil means unavailable; an empty array means the backend explicitly returned none.
    public let transportEndpoints: [TransferTransportEndpoint]?
    public let invoice: RGBInvoice?

    public init(
        index: UInt64,
        batchTransferIndex: UInt64?,
        createdAt: UnixSeconds,
        updatedAt: UnixSeconds,
        status: TransferStatus,
        requestedAssignment: Assignment? = nil,
        assignments: [Assignment],
        kind: TransferKind,
        txid: TransactionID? = nil,
        recipientID: String? = nil,
        receiveUTXO: Outpoint? = nil,
        changeUTXO: Outpoint? = nil,
        expiration: UnixSeconds? = nil,
        transportEndpoints: [TransferTransportEndpoint]? = nil,
        invoice: RGBInvoice? = nil,
        assetID: AssetID? = nil
    ) {
        self.index = index
        self.batchTransferIndex = batchTransferIndex
        self.assetID = assetID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.requestedAssignment = requestedAssignment
        self.assignments = assignments
        self.kind = kind
        self.txid = txid
        self.recipientID = recipientID
        self.receiveUTXO = receiveUTXO
        self.changeUTXO = changeUTXO
        self.expiration = expiration
        self.transportEndpoints = transportEndpoints
        self.invoice = invoice
    }
}

public struct TransferTransportEndpoint: Hashable, Sendable {
    public let endpoint: String
    public let transportType: String
    public let used: Bool

    public init(endpoint: String, transportType: String, used: Bool) throws {
        self.endpoint = try requireBoundedText(
            endpoint,
            field: "transportEndpoint",
            maximumUTF8Bytes: 2_048
        )
        self.transportType = try requireBoundedText(
            transportType,
            field: "transportType",
            maximumUTF8Bytes: 64
        )
        self.used = used
    }
}

public struct Media: Hashable, Sendable {
    public let reference: String?
    public let mimeType: String?
    public init(reference: String? = nil, mimeType: String? = nil) {
        self.reference = reference
        self.mimeType = mimeType
    }
}

public struct AssetNIA: Hashable, Sendable {
    public let assetID: AssetID
    public let ticker: String
    public let name: String
    public let precision: UInt8
    public let issuedSupply: AssetAmount
    public let timestamp: UnixSeconds
    public let addedAt: UnixSeconds
    public let balance: AssetBalance
    public let details: String?
    public let media: Media?

    public init(
        assetID: AssetID,
        ticker: String,
        name: String,
        precision: UInt8,
        issuedSupply: AssetAmount,
        timestamp: UnixSeconds,
        addedAt: UnixSeconds,
        balance: AssetBalance,
        details: String? = nil,
        media: Media? = nil
    ) throws {
        guard precision <= 18 else { throw SDKError.invalidArgument("precision", "must be between 0 and 18") }
        self.assetID = assetID
        self.ticker = try requireBoundedText(ticker, field: "ticker", maximumUTF8Bytes: 16)
        self.name = try requireBoundedDisplayText(name, field: "name", maximumUTF8Bytes: 256)
        self.precision = precision
        self.issuedSupply = issuedSupply
        self.timestamp = timestamp
        self.addedAt = addedAt
        self.balance = balance
        self.details = details
        self.media = media
    }
}

public struct AssetIFA: Hashable, Sendable {
    public let assetID: AssetID
    public let ticker: String
    public let name: String
    public let precision: UInt8
    /// Supply metadata is nil when it is not exposed by the gateway.
    public let initialSupply: AssetAmount?
    public let maximumSupply: AssetAmount?
    public let knownCirculatingSupply: AssetAmount?
    public let timestamp: UnixSeconds
    public let addedAt: UnixSeconds
    public let balance: AssetBalance
    public let details: String?
    public let media: Media?
    public let rejectListURL: URL?

    public init(
        assetID: AssetID,
        ticker: String,
        name: String,
        precision: UInt8,
        initialSupply: AssetAmount?,
        maximumSupply: AssetAmount?,
        knownCirculatingSupply: AssetAmount?,
        timestamp: UnixSeconds,
        addedAt: UnixSeconds,
        balance: AssetBalance,
        details: String? = nil,
        media: Media? = nil,
        rejectListURL: URL? = nil
    ) throws {
        guard precision <= 18 else { throw SDKError.invalidArgument("precision", "must be between 0 and 18") }
        if let maximumSupply {
            guard initialSupply.map({ $0 <= maximumSupply }) ?? true,
                  knownCirculatingSupply.map({ $0 <= maximumSupply }) ?? true else {
                throw SDKError.invalidArgument("supply", "must not exceed maximumSupply")
            }
        }
        self.assetID = assetID
        self.ticker = try requireBoundedText(ticker, field: "ticker", maximumUTF8Bytes: 16)
        self.name = try requireBoundedDisplayText(name, field: "name", maximumUTF8Bytes: 256)
        self.precision = precision
        self.initialSupply = initialSupply
        self.maximumSupply = maximumSupply
        self.knownCirculatingSupply = knownCirculatingSupply
        self.timestamp = timestamp
        self.addedAt = addedAt
        self.balance = balance
        self.details = details
        self.media = media
        self.rejectListURL = rejectListURL
    }
}

public struct AssetBFA: Hashable, Sendable {
    public let assetID: AssetID
    public let ticker: String
    public let name: String
    public let precision: UInt8
    /// Genesis supply, or nil when the wallet service reports none. rgb-lib-bfa from bfa.6 has no
    /// genesis supply for BFA: its known circulating supply is the amount locked on the bridge
    /// contract, a different quantity, so it is never reported here. Never inferred from the balance.
    public let issuedSupply: AssetAmount?
    public let timestamp: UnixSeconds
    public let addedAt: UnixSeconds
    public let balance: AssetBalance
    public let details: String?
    public let media: Media?
    public let rejectListURL: URL?

    public init(
        assetID: AssetID,
        ticker: String,
        name: String,
        precision: UInt8,
        issuedSupply: AssetAmount?,
        timestamp: UnixSeconds,
        addedAt: UnixSeconds,
        balance: AssetBalance,
        details: String? = nil,
        media: Media? = nil,
        rejectListURL: URL? = nil
    ) throws {
        guard precision <= 18 else { throw SDKError.invalidArgument("precision", "must be between 0 and 18") }
        self.assetID = assetID
        self.ticker = try requireBoundedText(ticker, field: "ticker", maximumUTF8Bytes: 16)
        self.name = try requireBoundedDisplayText(name, field: "name", maximumUTF8Bytes: 256)
        self.precision = precision
        self.issuedSupply = issuedSupply
        self.timestamp = timestamp
        self.addedAt = addedAt
        self.balance = balance
        self.details = details
        self.media = media
        self.rejectListURL = rejectListURL
    }
}

public struct AssetCFA: Hashable, Sendable {
    public let assetID: AssetID
    public let name: String
    public let precision: UInt8
    public let issuedSupply: AssetAmount
    public let timestamp: UnixSeconds
    public let addedAt: UnixSeconds
    public let balance: AssetBalance
    public let details: String?
    public let media: Media?

    public init(
        assetID: AssetID,
        name: String,
        precision: UInt8,
        issuedSupply: AssetAmount,
        timestamp: UnixSeconds,
        addedAt: UnixSeconds,
        balance: AssetBalance,
        details: String? = nil,
        media: Media? = nil
    ) throws {
        guard precision <= 18 else { throw SDKError.invalidArgument("precision", "must be between 0 and 18") }
        self.assetID = assetID
        self.name = try requireBoundedDisplayText(name, field: "name", maximumUTF8Bytes: 256)
        self.precision = precision
        self.issuedSupply = issuedSupply
        self.timestamp = timestamp
        self.addedAt = addedAt
        self.balance = balance
        self.details = details
        self.media = media
    }
}

public struct AssetUDA: Hashable, Sendable {
    public let assetID: AssetID
    public let ticker: String
    public let name: String
    public let precision: UInt8
    public let timestamp: UnixSeconds
    public let addedAt: UnixSeconds
    public let balance: AssetBalance
    public let details: String?

    public init(
        assetID: AssetID,
        ticker: String,
        name: String,
        precision: UInt8,
        timestamp: UnixSeconds,
        addedAt: UnixSeconds,
        balance: AssetBalance,
        details: String? = nil
    ) throws {
        guard precision <= 18 else { throw SDKError.invalidArgument("precision", "must be between 0 and 18") }
        self.assetID = assetID
        self.ticker = try requireBoundedText(ticker, field: "ticker", maximumUTF8Bytes: 16)
        self.name = try requireBoundedDisplayText(name, field: "name", maximumUTF8Bytes: 256)
        self.precision = precision
        self.timestamp = timestamp
        self.addedAt = addedAt
        self.balance = balance
        self.details = details
    }
}

public struct ListAssets: Hashable, Sendable {
    public let nia: [AssetNIA]
    public let uda: [AssetUDA]
    public let cfa: [AssetCFA]
    public let ifa: [AssetIFA]
    public let bfa: [AssetBFA]
    public init(
        nia: [AssetNIA] = [],
        uda: [AssetUDA] = [],
        cfa: [AssetCFA] = [],
        ifa: [AssetIFA] = [],
        bfa: [AssetBFA] = []
    ) {
        self.nia = nia
        self.uda = uda
        self.cfa = cfa
        self.ifa = ifa
        self.bfa = bfa
    }

    /// The initializer from before BFA, kept so code built against an earlier
    /// release still links.
    @_disfavoredOverload
    public init(
        nia: [AssetNIA] = [],
        uda: [AssetUDA] = [],
        cfa: [AssetCFA] = [],
        ifa: [AssetIFA] = []
    ) {
        self.init(nia: nia, uda: uda, cfa: cfa, ifa: ifa, bfa: [])
    }
}

public struct InvoiceReceiveData: Hashable, Sendable {
    public let invoice: RGBInvoice
    public let recipientID: String
    public let expirationTimestamp: UnixSeconds?
    public let batchTransferIndex: UInt64

    public init(
        invoice: RGBInvoice,
        recipientID: String,
        expirationTimestamp: UnixSeconds?,
        batchTransferIndex: UInt64
    ) throws {
        self.invoice = invoice
        self.recipientID = try requireBoundedText(
            recipientID,
            field: "recipientId",
            maximumUTF8Bytes: 1_024
        )
        self.expirationTimestamp = expirationTimestamp
        self.batchTransferIndex = batchTransferIndex
    }
}

public struct InvoiceData: Hashable, Sendable {
    public let invoice: RGBInvoice
    public let recipientID: String
    public let assetSchema: String?
    public let assetID: AssetID?
    public let network: Network
    public let assignment: Assignment
    public let assignmentName: String?
    public let expirationTimestamp: UnixSeconds?
    public let transportEndpoints: [String]
    /// Recipient's Ed25519 key (64 lowercase hex), the proxy protocol 1.0 `pk` parameter.
    public let publicKey: String?
    /// The proxy protocol 1.0 `enc` parameter; an invoice without it requires encryption.
    public let encryption: InvoiceEncryption

    public init(
        invoice: RGBInvoice,
        recipientID: String,
        assetSchema: String? = nil,
        assetID: AssetID? = nil,
        network: Network,
        assignment: Assignment,
        assignmentName: String? = nil,
        expirationTimestamp: UnixSeconds? = nil,
        transportEndpoints: [String] = [],
        publicKey: String? = nil,
        encryption: InvoiceEncryption = .required
    ) throws {
        self.invoice = invoice
        self.recipientID = try requireBoundedText(
            recipientID,
            field: "recipientId",
            maximumUTF8Bytes: 1_024
        )
        self.assetSchema = assetSchema
        self.assetID = assetID
        self.network = network
        self.assignment = assignment
        self.assignmentName = assignmentName
        self.expirationTimestamp = expirationTimestamp
        self.transportEndpoints = transportEndpoints
        if let publicKey, !isASCIIHex(publicKey, exactByteCount: 64, lowercaseOnly: true) {
            throw SDKError.invalidArgument("publicKey", "must be exactly 32 lowercase ASCII hex bytes")
        }
        self.publicKey = publicKey
        self.encryption = encryption
    }

    /// The initializer from before the proxy protocol 1.0 fields, kept so code
    /// built against an earlier release still links.
    @_disfavoredOverload
    public init(
        invoice: RGBInvoice,
        recipientID: String,
        assetSchema: String? = nil,
        assetID: AssetID? = nil,
        network: Network,
        assignment: Assignment,
        assignmentName: String? = nil,
        expirationTimestamp: UnixSeconds? = nil,
        transportEndpoints: [String] = []
    ) throws {
        try self.init(
            invoice: invoice, recipientID: recipientID, assetSchema: assetSchema, assetID: assetID,
            network: network, assignment: assignment, assignmentName: assignmentName,
            expirationTimestamp: expirationTimestamp, transportEndpoints: transportEndpoints,
            publicKey: nil, encryption: .required
        )
    }
}

/// Consignment encryption preference of an RGB invoice recipient (proxy protocol 1.0).
public enum InvoiceEncryption: String, Codable, CaseIterable, Sendable {
    case required
    case optional
    case unsupported
}

// Familiar aliases for teams sharing DTO terminology with Kotlin/RN.
public typealias BtcBalance = BTCBalance
public typealias RgbInvoice = RGBInvoice
public typealias RgbAllocation = RGBAllocation
public typealias Utxo = UTXO
public typealias AssetNia = AssetNIA
public typealias AssetIfa = AssetIFA
public typealias AssetBfa = AssetBFA
public typealias AssetCfa = AssetCFA
public typealias AssetUda = AssetUDA
