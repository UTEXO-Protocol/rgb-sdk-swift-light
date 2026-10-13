import Foundation

// Dedicated strict wire types keep additional metadata from changing the older
// balance projection. Missing optional values stay unknown, never zero/false.
func gatewayMapped<T>(_ body: () throws -> T) throws -> T {
    do { return try body() }
    catch let error as SDKError where error.code == .backendProtocolMismatch { throw error }
    catch { throw SDKError.backendProtocolMismatch("gateway returned invalid wallet data") }
}

func gatewaySafeInteger(_ value: UInt64?) throws {
    guard value.map({ $0 <= GatewayWalletBackend.javascriptMaximumSafeInteger }) ?? true else {
        throw SDKError.backendProtocolMismatch("gateway integer exceeds the exact JSON range")
    }
}

private func gatewayText(_ value: String, field: String, limit: Int) throws -> String {
    let normalized = try requireBoundedText(value, field: field, maximumUTF8Bytes: limit)
    guard normalized == value else { throw SDKError.backendProtocolMismatch("gateway returned noncanonical text") }
    return normalized
}

private func gatewayAssetID(_ value: String) throws -> AssetID {
    let result = try AssetID(value)
    guard result.value == value else { throw SDKError.backendProtocolMismatch("gateway returned a noncanonical asset ID") }
    return result
}

private func gatewayTxid(_ value: String) throws -> TransactionID {
    let result = try TransactionID(value)
    guard result.hex == value else { throw SDKError.backendProtocolMismatch("gateway returned a noncanonical transaction ID") }
    return result
}

struct GatewayAddressWire: Decodable {
    let address: String
    let derivation: Derivation?
    struct Derivation: Decodable {
        let account: String
        let keychain: UInt32
        let index: UInt32
        let derivationPath: String
        let scriptHex: String
    }
}

struct GatewayFeeWire: Decodable {
    let blocks: UInt32
    let sourceBlocks: UInt32
    let feeRateSatPerVb: UInt64
}

struct GatewayAssignmentWire: Decodable {
    let kind: String
    let amount: UInt64?

    func model() throws -> Assignment {
        try gatewaySafeInteger(amount)
        let type = try AssignmentType(gatewayText(kind, field: "assignment", limit: 64))
        if type == .fungible || type == .inflationRight {
            guard amount != nil else { throw SDKError.backendProtocolMismatch("valued assignment has no amount") }
        } else if type == .any || type == .replaceRight || type == .nonFungible {
            guard amount == nil else { throw SDKError.backendProtocolMismatch("unit assignment has an amount") }
        }
        // Unknown variant names remain visible rather than being dropped.
        return Assignment(type: type, amount: amount.map(AssetAmount.init))
    }
}

struct GatewayUnspentsWire: Decodable { let unspents: [GatewayUnspentWire] }

struct GatewayUnspentWire: Decodable {
    let txid: String
    let vout: UInt32
    let amountSat: UInt64
    let colorable: Bool
    let exists: Bool?
    let pendingBlinded: UInt32
    let allocations: [Allocation]

    struct Allocation: Decodable {
        let assetId: String?
        let amount: UInt64?
        let assignment: GatewayAssignmentWire
        let settled: Bool
    }

    func model() throws -> Unspent {
        let txid = try gatewayTxid(txid)
        let allocations = try allocations.map { value in
            try gatewaySafeInteger(value.amount)
            let assignment = try value.assignment.model()
            // The legacy scalar is a fungible summary, not an assignment type.
            if assignment.type == .fungible {
                guard value.amount.map(AssetAmount.init) == assignment.amount else {
                    throw SDKError.backendProtocolMismatch("allocation amount conflicts with typed assignment")
                }
            } else if value.amount != nil {
                throw SDKError.backendProtocolMismatch("non-fungible allocation has a fungible summary")
            }
            return RGBAllocation(assetID: try value.assetId.map(gatewayAssetID),
                assignment: assignment, settled: value.settled)
        }
        return try Unspent(utxo: UTXO(outpoint: Outpoint(txid: txid, vout: vout),
            btcAmount: Satoshis(amountSat), colorable: colorable, exists: exists),
            rgbAllocations: allocations, pendingBlinded: pendingBlinded)
    }
}

private struct GatewayAssetBalanceWire: Decodable {
    let settled: UInt64
    let future: UInt64
    let spendable: UInt64

    func model() throws -> AssetBalance {
        try gatewaySafeInteger(settled)
        try gatewaySafeInteger(future)
        try gatewaySafeInteger(spendable)
        return AssetBalance(settled: AssetAmount(settled), future: AssetAmount(future), spendable: AssetAmount(spendable))
    }
}

struct GatewayAssetsWire: Decodable {
    let assets: [Asset]

    struct Asset: Decodable {
        let assetId: String
        let schema: String
        let ticker: String?
        let name: String
        let details: String?
        let precision: UInt8
        let issuedSupply: UInt64?
        let timestamp: UInt64
        let addedAt: UInt64
        fileprivate let balance: GatewayAssetBalanceWire
        let initialSupply: UInt64?
        let maxSupply: UInt64?
        let knownCirculatingSupply: UInt64?
    }

    func model() throws -> ListAssets {
        var nia: [AssetNIA] = [], ifa: [AssetIFA] = [], cfa: [AssetCFA] = [], uda: [AssetUDA] = []
        var ids = Set<AssetID>()
        for asset in assets {
            let id = try gatewayAssetID(asset.assetId)
            guard ids.insert(id).inserted else { throw SDKError.backendProtocolMismatch("gateway repeated an asset identity") }
            let name = try requireBoundedDisplayText(asset.name, field: "name", maximumUTF8Bytes: 256)
            let ticker = try asset.ticker.map { try gatewayText($0, field: "ticker", limit: 16) }
            if let details = asset.details {
                _ = try requireBoundedDisplayText(details, field: "details", maximumUTF8Bytes: 65_535)
            }
            try gatewaySafeInteger(asset.timestamp)
            try gatewaySafeInteger(asset.addedAt)
            for supply in [asset.issuedSupply, asset.initialSupply, asset.maxSupply, asset.knownCirculatingSupply] {
                try gatewaySafeInteger(supply)
            }
            let balance = try asset.balance.model()
            let timestamp = UnixSeconds(rawValue: asset.timestamp), addedAt = UnixSeconds(rawValue: asset.addedAt)
            // Native schema groups are lower-case; do not guess aliases or drop unknown assets.
            switch asset.schema {
            case "nia":
                guard let ticker, let supply = asset.issuedSupply else {
                    throw SDKError.backendProtocolMismatch("NIA asset lacks required ticker or supply")
                }
                nia.append(try AssetNIA(assetID: id, ticker: ticker, name: name, precision: asset.precision,
                    issuedSupply: AssetAmount(supply), timestamp: timestamp, addedAt: addedAt,
                    balance: balance, details: asset.details))
            case "cfa":
                guard let supply = asset.issuedSupply else { throw SDKError.backendProtocolMismatch("CFA asset lacks issued supply") }
                cfa.append(try AssetCFA(assetID: id, name: name, precision: asset.precision,
                    issuedSupply: AssetAmount(supply), timestamp: timestamp, addedAt: addedAt,
                    balance: balance, details: asset.details))
            case "ifa":
                guard let ticker else { throw SDKError.backendProtocolMismatch("IFA asset lacks ticker") }
                ifa.append(try AssetIFA(assetID: id, ticker: ticker, name: name, precision: asset.precision,
                    initialSupply: asset.initialSupply.map(AssetAmount.init),
                    maximumSupply: asset.maxSupply.map(AssetAmount.init),
                    knownCirculatingSupply: asset.knownCirculatingSupply.map(AssetAmount.init),
                    timestamp: timestamp, addedAt: addedAt, balance: balance, details: asset.details))
            case "uda":
                guard let ticker else { throw SDKError.backendProtocolMismatch("UDA asset lacks ticker") }
                uda.append(try AssetUDA(assetID: id, ticker: ticker, name: name, precision: asset.precision,
                    timestamp: timestamp, addedAt: addedAt, balance: balance, details: asset.details))
            default:
                throw SDKError.backendProtocolMismatch("gateway returned an unsupported asset schema")
            }
        }
        return ListAssets(nia: nia, uda: uda, cfa: cfa, ifa: ifa)
    }
}

struct GatewayTransfersWire: Decodable { let transfers: [GatewayTransferWire] }

struct GatewayTransferWire: Decodable {
    let idx: UInt64
    let batchTransferIdx: UInt64?
    let assetId: String?
    let amount: UInt64?
    let assignments: [GatewayAssignmentWire]
    let kind: String
    let status: String
    let txid: String?
    let recipientId: String?
    let expiration: UInt64?
    let expirationTimestamp: UInt64?
    let createdAt: UInt64
    let updatedAt: UInt64
    let receiveUtxo: Output?
    let changeUtxo: Output?
    let transportEndpoints: [Transport]?

    struct Output: Decodable {
        let txid: String
        let vout: UInt32
        func model() throws -> Outpoint { try Outpoint(txid: gatewayTxid(txid), vout: vout) }
    }

    struct Transport: Decodable {
        let endpoint: String
        let transportType: String
        let used: Bool
        func model() throws -> TransferTransportEndpoint {
            try TransferTransportEndpoint(endpoint: gatewayText(endpoint, field: "endpoint", limit: 2_048),
                transportType: gatewayText(transportType, field: "transportType", limit: 64), used: used)
        }
    }

    func model() throws -> Transfer {
        for number in [idx, batchTransferIdx, amount, expiration, expirationTimestamp, createdAt, updatedAt] {
            try gatewaySafeInteger(number)
        }
        guard createdAt <= updatedAt else { throw SDKError.backendProtocolMismatch("transfer update predates creation") }
        if let expiration, let expirationTimestamp, expiration != expirationTimestamp {
            throw SDKError.backendProtocolMismatch("transfer expiration aliases conflict")
        }
        let kind = try gatewayText(kind, field: "kind", limit: 64)
        let status = try gatewayText(status, field: "status", limit: 64)
        let recipient = try recipientId.map { try gatewayText($0, field: "recipientId", limit: 1_024) }
        // The scalar amount can describe a requested amount OR a summary. It
        // cannot establish the requested assignment; preserve actual assignments.
        return try Transfer(index: idx, batchTransferIndex: batchTransferIdx,
            createdAt: UnixSeconds(rawValue: createdAt), updatedAt: UnixSeconds(rawValue: updatedAt),
            status: TransferStatus(rawValue: status), requestedAssignment: nil,
            assignments: assignments.map { try $0.model() }, kind: TransferKind(rawValue: kind),
            txid: txid.map(gatewayTxid), recipientID: recipient,
            receiveUTXO: receiveUtxo.map { try $0.model() }, changeUTXO: changeUtxo.map { try $0.model() },
            expiration: (expirationTimestamp ?? expiration).map(UnixSeconds.init(rawValue:)),
            transportEndpoints: transportEndpoints.map { try $0.map { try $0.model() } },
            assetID: assetId.map(gatewayAssetID))
    }
}
