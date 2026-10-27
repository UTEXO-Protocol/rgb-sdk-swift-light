import Foundation
import Testing
import UtexoLocalSignerBindings
@testable @_spi(Backend) import RGBSDK

private let readTxid = String(repeating: "a", count: 64)

@Test func gatewayReadFacadeUsesNativeAddressOwnershipAndFreshRotation() async throws {
    let seed = try SecretSeed(copying: Array(repeating: 7, count: 64))
    defer { seed.close() }
    let native = try UtexoLocalSignerBindings.LocalSigner.fromSeed(network: .regtest, seed: Data(repeating: 7, count: 64))
    let identity = try UniFFILocalSigningEngineFactory().open(network: .regtest, seed: seed).identity()
    let first = try native.deriveAddress(account: .vanilla, keychain: .external, index: 0)
    let second = try native.deriveAddress(account: .vanilla, keychain: .external, index: 1)
    let badScript = String(repeating: "0", count: 64)
    let responses = try [
        readJSON(["fingerprint": identity.masterFingerprint, "address": first.address], status: 201),
        readAddress(first.address, script: first.scriptPubkeyHex, index: 0),
        readAddress(second.address, script: second.scriptPubkeyHex, index: 1),
        readAddress(first.address, script: "5120" + badScript, index: 0),
        readAddress(second.address, script: first.scriptPubkeyHex, index: 0),
        readJSON(["address": first.address, "derivation": NSNull()]),
        readAddress(first.address, script: first.scriptPubkeyHex, index: 0, path: "m/86'/1'/0'/1/0"),
    ]
    let (backend, _, transport) = try await readBackend(responses)
    let wallet = UTEXOWallet(configuration: try WalletConfiguration(walletID: WalletID("read-test"), network: .regtest),
        backend: backend, keyProvider: ReadKeys(), operationJournal: InMemoryOperationJournal())
    try await wallet.initialize()
    try await wallet.unlock()
    #expect(try await wallet.getAddress().value == first.address)
    #expect(try await wallet.rotateVanillaAddress().value == second.address)
    for _ in 0..<4 {
        do { _ = try await wallet.getAddress(); Issue.record("unverified address must fail") }
        catch let error as SDKError { #expect(error.code == .backendProtocolMismatch) }
    }
    #expect(await transport.snapshot().filter { $0.url.path == "/v1/wallet/address" }.count == 6)
    try await wallet.destroy()
}

@Test func gatewayReadFacadeRetainsReceiveBatchesAndValidatesBothModes() async throws {
    let seed = try SecretSeed(copying: Array(repeating: 7, count: 64))
    defer { seed.close() }
    let identity = try UniFFILocalSigningEngineFactory().open(network: .regtest, seed: seed).identity()
    let expiry = UInt64(Date().timeIntervalSince1970) + 86_400
    var responses = [try readJSON(["fingerprint": identity.masterFingerprint, "address": "bcrt1pregistration"], status: 201)]
    for witness in [false, true, false] {
        let invoice = invoiceTestString(witness: witness, expiry: expiry)
        let decoded = try decodeRGBInvoiceLocally(RGBInvoice(invoice))
        responses.append(try readJSON(["invoice": invoice, "recipientId": decoded.recipientID,
            "expirationTimestamp": expiry, "mode": witness ? "witness" : "blind", "batchTransferIdx": 42], status: 201))
    }
    let (backend, _, _) = try await readBackend(responses, now: nil, refreshReceiveClock: true)
    let wallet = UTEXOWallet(configuration: try WalletConfiguration(walletID: WalletID("read-test"), network: .regtest),
        backend: backend, keyProvider: ReadKeys(), operationJournal: InMemoryOperationJournal())
    try await wallet.initialize()
    try await wallet.unlock()
    #expect(try await wallet.blindReceive(InvoiceRequest()).batchTransferIndex == 42)
    #expect(try await wallet.witnessReceive(InvoiceRequest()).batchTransferIndex == 42)
    #expect(try await wallet.onchainReceive(OnchainReceiveRequest(witness: false)).batchTransferIndex == 42)
    try await wallet.destroy()
}

@Test func gatewayStrictReceiveRejectsMissingInvalidBatchWithoutRetry() async throws {
    for value in [NSNull(), -1, 9_007_199_254_740_992, "42"] as [Any] {
        let invoice = invoiceTestString()
        let decoded = try decodeRGBInvoiceLocally(RGBInvoice(invoice))
        let (backend, context, transport) = try await readBackend([readJSON([
            "invoice": invoice, "recipientId": decoded.recipientID,
            "expirationTimestamp": 87_400, "mode": "blind", "batchTransferIdx": value,
        ], status: 201)])
        do { _ = try await backend.blindReceive(context: context, request: InvoiceRequest()); Issue.record("invalid batch must fail") }
        catch let error as SDKError { #expect(error.code == .backendProtocolMismatch) }
        #expect(await transport.snapshot().count == 2)
    }
}

@Test func gatewayFeeEstimatePreservesTargetAndRejectsSlowerOrCappedEvidence() async throws {
    let cases: [(String, SDKErrorCode?)] = [
        (#"{"blocks":6,"sourceBlocks":3,"feeRateSatPerVb":12}"#, nil),
        (#"{"blocks":6,"sourceBlocks":7,"feeRateSatPerVb":12}"#, .unsupported),
        (#"{"blocks":6,"sourceBlocks":3,"feeRateSatPerVb":1000}"#, .unsupported),
        (#"{"blocks":1,"sourceBlocks":1,"feeRateSatPerVb":12}"#, .backendProtocolMismatch),
        (#"{"blocks":6,"sourceBlocks":0,"feeRateSatPerVb":12}"#, .backendProtocolMismatch),
        (#"{"blocks":6,"sourceBlocks":3,"feeRateSatPerVb":1.5}"#, .backendProtocolMismatch),
        (#"{"blocks":6,"sourceBlocks":3,"feeRateSatPerVb":0}"#, .backendProtocolMismatch),
    ]
    for (response, code) in cases {
        let (backend, context, transport) = try await readBackend([readRaw(response)])
        do {
            let value = try await backend.estimateFeeRate(context: context, targetBlocks: .init(rawValue: 6))
            #expect(code == nil && value.feeRate.milliSatsPerVByte == 12_000)
            #expect(value.targetBlocks.rawValue == 6 && value.measuredAt == nil)
        } catch let error as SDKError { #expect(error.code == code) }
        #expect(await transport.snapshot().last?.url.query == "blocks=6")
    }
    let (backend, context, transport) = try await readBackend([])
    for target in [UInt32(0), 1_009] {
        await #expect(throws: SDKError.self) { _ = try await backend.estimateFeeRate(context: context, targetBlocks: .init(rawValue: target)) }
    }
    #expect(await transport.snapshot().count == 1)
}

@Test func gatewayUnspentsPreserveUnknownExistsAndTypedAssignments() async throws {
    let (backend, context, _) = try await readBackend([readJSON(["unspents": [readUnspent()]])])
    let result = try await backend.listUnspents(context: context)
    #expect(result.count == 1 && result[0].utxo.exists == nil)
    #expect(result[0].utxo.btcAmount.value == 1_000 && result[0].pendingBlinded == 2)
    #expect(result[0].rgbAllocations.map(\.assignment.type) == [.fungible, .inflationRight, .nonFungible])
    #expect(result[0].rgbAllocations[0].assignment.amount == AssetAmount(12))
    #expect(result[0].rgbAllocations[1].assignment.amount == AssetAmount(9))
    #expect(result[0].rgbAllocations[2].assignment.amount == nil)
}

@Test func gatewayUnspentParserRejectsMalformedAndContradictoryValues() async throws {
    for (field, value) in [
        ("txid", readTxid.uppercased()), ("txid", " " + readTxid), ("vout", -1),
        ("amountSat", 2_100_000_000_000_001), ("amountSat", "1000"),
        ("colorable", 1), ("pendingBlinded", -1), ("allocations", NSNull()), ("exists", "true"),
    ] as [(String, Any)] {
        var record = readUnspent(); record[field] = value
        let (backend, context, _) = try await readBackend([readJSON(["unspents": [record]])])
        do { _ = try await backend.listUnspents(context: context); Issue.record("invalid unspent must fail") }
        catch let error as SDKError { #expect(error.code == .backendProtocolMismatch) }
    }
    for assignment in [
        ["kind": "Fungible", "amount": NSNull()], ["kind": "NonFungible", "amount": 1],
        ["kind": "ReplaceRight", "amount": 1], ["kind": "InflationRight", "amount": NSNull()],
        ["kind": "Fungible", "amount": 9_007_199_254_740_992],
    ] as [[String: Any]] {
        var record = readUnspent()
        record["allocations"] = [["assetId": "asset", "amount": NSNull(), "assignment": assignment, "settled": false]]
        let (backend, context, _) = try await readBackend([readJSON(["unspents": [record]])])
        await #expect(throws: SDKError.self) { _ = try await backend.listUnspents(context: context) }
    }
    let (backend, context, _) = try await readBackend([readJSON(["unspents": [readUnspent(), readUnspent()]])])
    await #expect(throws: SDKError.self) { _ = try await backend.listUnspents(context: context) }
}

@Test func gatewayAssetsSupportAllSchemasWithAbsentIfaSupplies() async throws {
    let (backend, context, _) = try await readBackend([readJSON(["assets": ["nia", "cfa", "ifa", "uda"].map(readAsset)])])
    let result = try await backend.listAssets(context: context)
    #expect(result.nia.count == 1 && result.cfa.count == 1 && result.ifa.count == 1 && result.uda.count == 1)
    #expect(result.nia[0].issuedSupply == AssetAmount(100))
    #expect(result.ifa[0].initialSupply == nil && result.ifa[0].maximumSupply == nil && result.ifa[0].knownCirculatingSupply == nil)
    #expect(result.ifa[0].balance.settled == AssetAmount(3) && result.ifa[0].media == nil)
}

@Test func gatewayAssetsRejectInvalidRequiredMetadataAndDoNotDropUnknownSchemas() async throws {
    for (field, value) in [
        ("schema", "future-schema"), ("ticker", NSNull()), ("issuedSupply", NSNull()),
        ("precision", 19), ("timestamp", -1), ("addedAt", 9_007_199_254_740_992),
        ("assetId", " nia-asset "), ("name", ""), ("balance", NSNull()),
    ] as [(String, Any)] {
        var record = readAsset("nia"); record[field] = value
        let (backend, context, _) = try await readBackend([readJSON(["assets": [record]])])
        do { _ = try await backend.listAssets(context: context); Issue.record("invalid asset must fail") }
        catch let error as SDKError { #expect(error.code == .backendProtocolMismatch) }
    }
    var ifa = readAsset("ifa"); ifa["initialSupply"] = 101; ifa["maxSupply"] = 100
    let (backend, context, _) = try await readBackend([readJSON(["assets": [ifa]])])
    await #expect(throws: SDKError.self) { _ = try await backend.listAssets(context: context) }
}

@Test func gatewayAssetDisplayMetadataPreservesNativeWhitespaceAndUnicode() async throws {
    var asset = readAsset("nia")
    asset["name"] = " Display name "
    asset["details"] = " Description ü\n"
    let (backend, context, _) = try await readBackend([readJSON(["assets": [asset]])])
    let result = try await backend.listAssets(context: context)
    #expect(result.nia[0].name == " Display name ")
    #expect(result.nia[0].details == " Description ü\n")
}

@Test func gatewayTransfersPreserveActualAssignmentsAndUnknownMetadata() async throws {
    var asset = readAsset("nia"); asset["assetId"] = "asset+&?#%="
    let (backend, context, transport) = try await readBackend([
        readJSON(["transfers": [readTransfer()]]),
        // The txid filter walks the whole wallet: asset-less page, asset list, then each asset.
        readJSON(["transfers": [Any]()]), readJSON(["assets": [asset]]), readJSON(["transfers": [readTransfer()]]),
    ])
    let records = try await backend.listTransfers(context: context, assetID: AssetID("asset+&?#%="))
    let record = try #require(records.first)
    #expect(record.batchTransferIndex == nil && record.assetID?.value == "asset+&?#%=")
    #expect(record.assignments == [Assignment(type: .fungible, amount: AssetAmount(7))])
    #expect(record.requestedAssignment == nil && record.expiration == nil)
    #expect(record.receiveUTXO == nil && record.changeUTXO == nil && record.transportEndpoints == nil)
    let filtered = try await backend.listTransfers(context: context, txid: TransactionID(readTxid))
    #expect(filtered == records)
    let query = try #require(await transport.snapshot()[1].url.query)
    #expect(query.contains("%2B") && query.contains("%26") && query.contains("%23"))
    let components = try #require(URLComponents(string: "https://gateway.example/?" + query))
    #expect(components.queryItems?.first?.value == "asset+&?#%=")
    #expect(await transport.snapshot().map(\.url.query) == [nil, query, nil, nil, query])
}

@Test func gatewayWholeWalletTransfersMergeAssetLessAndPerAssetPagesAcrossSchemas() async throws {
    let other = String(repeating: "b", count: 64)
    let (backend, context, transport) = try await readBackend([
        readJSON(["transfers": [readTransfer(index: 5, assetID: nil, txid: nil, status: "WaitingCounterparty")]]),
        readJSON(["assets": ["nia", "ifa", "cfa", "uda"].map(readAsset)]),
        readJSON(["transfers": [readTransfer(index: 3, assetID: "nia-asset")]]),
        readJSON(["transfers": [Any]()]),
        readJSON(["transfers": [readTransfer(index: 1, assetID: "ifa-asset", txid: other)]]),
        readJSON(["transfers": [readTransfer(index: 2, assetID: "uda-asset", txid: other)]]),
    ])
    let result = try await backend.listTransfers(context: context, assetID: nil)
    #expect(result.map(\.index) == [1, 2, 3, 5])
    #expect(result.map(\.assetID?.value) == ["ifa-asset", "uda-asset", "nia-asset", nil])
    #expect(result.last?.status == .waitingCounterparty)
    let requests = await transport.snapshot()
    #expect(requests.map(\.url.path) == ["/v1/me", "/v1/wallet/transfers", "/v1/wallet/balances",
        "/v1/wallet/transfers", "/v1/wallet/transfers", "/v1/wallet/transfers", "/v1/wallet/transfers"])
    #expect(requests.map(\.url.query) == [nil, nil, nil,
        "assetId=nia-asset", "assetId=cfa-asset", "assetId=ifa-asset", "assetId=uda-asset"])
}

@Test func gatewayTransfersByTxidFindAnAssetSendThatTheAssetLessPageOmits() async throws {
    let (backend, context, transport) = try await readBackend([
        readJSON(["transfers": [Any]()]),
        readJSON(["assets": ["nia", "ifa"].map(readAsset)]),
        readJSON(["transfers": [readTransfer(index: 4, assetID: "nia-asset", kind: "Send", status: "WaitingConfirmations")]]),
        readJSON(["transfers": [readTransfer(index: 6, assetID: "ifa-asset", txid: String(repeating: "b", count: 64))]]),
    ])
    let sent = try await backend.listTransfers(context: context, txid: TransactionID(readTxid))
    #expect(sent.count == 1)
    let record = try #require(sent.first)
    #expect(record.index == 4 && record.assetID?.value == "nia-asset" && record.kind == .send)
    #expect(await transport.snapshot().count == 5)
}

@Test func gatewayWholeWalletTransfersDedupeRepeatedIndexAndRejectOneIndexUnderTwoAssets() async throws {
    let txid = try TransactionID(readTxid)
    // Index 7 was asset-less on the first page and gained its asset before the per-asset page.
    let (backend, context, _) = try await readBackend([
        readJSON(["transfers": [readTransfer(index: 8, assetID: nil, txid: nil), readTransfer(index: 7, assetID: nil, txid: nil)]]),
        readJSON(["assets": ["nia", "ifa"].map(readAsset)]),
        readJSON(["transfers": [readTransfer(index: 7, assetID: "nia-asset")]]),
        readJSON(["transfers": [Any]()]),
    ])
    let result = try await backend.listTransfers(context: context, assetID: nil)
    #expect(result.map(\.index) == [7, 8])
    #expect(result.first?.assetID?.value == "nia-asset" && result.first?.txid == txid)
    #expect(result.last?.assetID == nil)

    let (conflicting, conflictingContext, _) = try await readBackend([
        readJSON(["transfers": [Any]()]), readJSON(["assets": ["nia", "ifa"].map(readAsset)]),
        readJSON(["transfers": [readTransfer(index: 7, assetID: "nia-asset")]]),
        readJSON(["transfers": [readTransfer(index: 7, assetID: "ifa-asset")]]),
    ])
    do { _ = try await conflicting.listTransfers(context: conflictingContext, assetID: nil); Issue.record("one index under two assets must fail") }
    catch let error as SDKError { #expect(error.code == .backendProtocolMismatch) }

    // A failed per-asset page fails the whole listing instead of returning a partial list.
    let (failing, failingContext, _) = try await readBackend([
        readJSON(["transfers": [Any]()]), readJSON(["assets": ["nia", "ifa"].map(readAsset)]),
        readJSON(["error": ["code": "UNAVAILABLE"]], status: 503),
    ])
    do { _ = try await failing.listTransfers(context: failingContext, txid: txid); Issue.record("a failed page must fail") }
    catch let error as SDKError { #expect(error.code == .backendUnavailable) }
}

@Test func gatewayTransfersForOneAssetRemainASingleRequest() async throws {
    let (backend, context, transport) = try await readBackend([
        readJSON(["transfers": [readTransfer(index: 1, assetID: "nia-asset")]]),
    ])
    let result = try await backend.listTransfers(context: context, assetID: AssetID("nia-asset"))
    #expect(result.map(\.assetID?.value) == ["nia-asset"])
    let requests = await transport.snapshot()
    #expect(requests.map(\.url.path) == ["/v1/me", "/v1/wallet/transfers"])
    #expect(requests.last?.url.query == "assetId=nia-asset")
}

@Test func gatewayTransfersRejectInvalidMetadataAndCrossAssetResults() async throws {
    for (field, value) in [
        ("idx", -1), ("batchTransferIdx", 9_007_199_254_740_992), ("txid", readTxid.uppercased()),
        ("createdAt", 3), ("assignments", NSNull()), ("status", " Settled"), ("assetId", " asset+&?#%="),
    ] as [(String, Any)] {
        var record = readTransfer(); record[field] = value
        let (backend, context, _) = try await readBackend([readJSON(["transfers": [record]])])
        do { _ = try await backend.listTransfers(context: context, assetID: nil); Issue.record("invalid transfer must fail") }
        catch let error as SDKError { #expect(error.code == .backendProtocolMismatch) }
    }
    let (backend, context, _) = try await readBackend([readJSON(["transfers": [readTransfer()]])])
    await #expect(throws: SDKError.self) { _ = try await backend.listTransfers(context: context, assetID: AssetID("other")) }
}

@Test func gatewayNewReadMethodsRejectStaleSessionsWithoutHTTP() async throws {
    let (backend, context, transport) = try await readBackend([])
    try await backend.shutdown(session: context.session)
    await #expect(throws: SDKError.self) { _ = try await backend.listUnspents(context: context) }
    await #expect(throws: SDKError.self) { _ = try await backend.listAssets(context: context) }
    await #expect(throws: SDKError.self) { _ = try await backend.listTransfers(context: context, assetID: nil) }
    await #expect(throws: SDKError.self) { _ = try await backend.estimateFeeRate(context: context, targetBlocks: .init(rawValue: 6)) }
    await #expect(throws: SDKError.self) { _ = try await backend.reserveAddress(.init(context: context, rotate: false)) }
    #expect(await transport.snapshot().count == 1)
}

private func readUnspent() -> [String: Any] {
    ["txid": readTxid, "vout": 0, "amountSat": 1_000, "colorable": true, "pendingBlinded": 2,
     "allocations": [
        ["assetId": "asset", "amount": 12, "assignment": ["kind": "Fungible", "amount": 12], "settled": true],
        ["assetId": NSNull(), "amount": NSNull(), "assignment": ["kind": "InflationRight", "amount": 9], "settled": false],
        ["assetId": "uda", "amount": NSNull(), "assignment": ["kind": "NonFungible", "amount": NSNull()], "settled": false],
     ]]
}

private func readAsset(_ schema: String) -> [String: Any] {
    ["assetId": schema + "-asset", "schema": schema, "ticker": "TEST", "name": "Test",
     "precision": 0, "issuedSupply": schema == "nia" || schema == "cfa" ? 100 : NSNull(),
     "timestamp": 1, "addedAt": 2, "details": NSNull(),
     "balance": ["settled": 3, "future": 4, "spendable": 2]]
}

private func readTransfer(index: Int = 1, assetID: String? = "asset+&?#%=", txid: String? = readTxid,
                          kind: String = "ReceiveBlind", status: String = "Settled") -> [String: Any] {
    var record: [String: Any] = ["idx": index, "batchTransferIdx": NSNull(), "amount": 100,
     "assignments": [["kind": "Fungible", "amount": 7]], "kind": kind, "status": status,
     "recipientId": NSNull(), "expiration": NSNull(), "createdAt": 1, "updatedAt": 2]
    record["assetId"] = readNullable(assetID)
    record["txid"] = readNullable(txid)
    return record
}

private func readNullable(_ value: String?) -> Any {
    guard let value else { return NSNull() }
    return value
}

private func readAddress(_ address: String, script: String, index: UInt32, path: String? = nil) throws -> GatewayHTTPResponse {
    try readJSON(["address": address, "derivation": ["account": "vanilla", "keychain": 0, "index": index,
        "derivationPath": path ?? "m/86'/1'/0'/0/\(index)", "scriptHex": script]])
}

private func readJSON(_ value: [String: Any], status: Int = 200) throws -> GatewayHTTPResponse {
    .init(statusCode: status, mimeType: "application/json", correlationID: nil,
        body: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
}

private func readRaw(_ value: String) -> GatewayHTTPResponse {
    .init(statusCode: 200, mimeType: "application/json", correlationID: nil, body: Data(value.utf8))
}

private func readBackend(_ responses: [GatewayHTTPResponse], now: UInt64? = 1_000_000,
                         refreshReceiveClock: Bool = false) async throws -> (GatewayWalletBackend, BackendContext, ReadTransport) {
    let transport = ReadTransport([readRaw(#"{"userId":"read-user","createdAt":1}"#)] + responses,
        refreshReceiveClock: refreshReceiveClock)
    let backend = GatewayWalletBackend(configuration: try GatewayBackendConfiguration(
        baseURL: #require(URL(string: "http://127.0.0.1:8480")), bearerToken: "test-only-key", network: .regtest,
        allowInsecureLocalDevelopment: true), transport: transport,
        nowMilliseconds: { now ?? UInt64(Date().timeIntervalSince1970 * 1_000) })
    let walletID = try WalletID("read-test")
    let session = try await backend.initialize(.init(walletID: walletID, network: .regtest, minimumAPIVersion: 1, maximumAPIVersion: 1))
    return (backend, BackendContext(session: session, walletID: walletID, network: .regtest), transport)
}

private actor ReadTransport: GatewayHTTPTransport {
    private var responses: [GatewayHTTPResponse]
    private var requests: [GatewayHTTPRequest] = []
    private let refreshReceiveClock: Bool
    init(_ responses: [GatewayHTTPResponse], refreshReceiveClock: Bool = false) {
        self.responses = responses
        self.refreshReceiveClock = refreshReceiveClock
    }
    func send(_ request: GatewayHTTPRequest) async throws -> GatewayHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw SDKError.invariant("no test response") }
        let response = responses.removeFirst()
        if refreshReceiveClock, request.url.path == "/v1/wallet/receive" {
            var body = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
            let expiry = UInt64(Date().timeIntervalSince1970) + 86_400
            body["invoice"] = invoiceTestString(witness: body["mode"] as? String == "witness", expiry: expiry)
            body["expirationTimestamp"] = expiry
            return try readJSON(body, status: response.statusCode)
        }
        return response
    }
    func snapshot() -> [GatewayHTTPRequest] { requests }
}

private struct ReadKeys: WalletKeyProvider {
    func loadSeed(parameters: WalletUnlockParameters) async throws -> SecretSeed {
        try SecretSeed(copying: Array(repeating: 7, count: 64))
    }
}
