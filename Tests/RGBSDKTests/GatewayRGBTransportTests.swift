import Foundation
import Testing
@testable @_spi(Backend) import RGBSDK

private let rgbOperationID = "d1111111-1111-4111-8111-111111111111"
private let rgbTxid = "e41e4ebdc769b0575126a5d728394d4c01206110e7eaebf6446029d5acd0d814"

@Test func gatewayRGBUsesNativeSigningAndNullableBatchWithoutInventingMetadata() async throws {
    for batch: UInt64? in [nil, 42] {
        let fixture = try await rgbFixture(responses: [try rgbPrepare(), try rgbWire(
            batch.map { ["txid": rgbTxid, "batchTransferIdx": $0] } ?? ["txid": rgbTxid])])
        let result = try await fixture.perform()
        #expect(result.txid.hex == rgbTxid && result.batchTransferIndex == batch)
        let requests = await fixture.transport.snapshot()
        #expect(requests.map(\.url.path) == ["/v1/me", "/v1/onchain/send-asset/prepare", "/v1/onchain/send-asset/complete"])
        let encodedBody = try #require(requests[1].body)
        let body = try #require(JSONSerialization.jsonObject(with: encodedBody) as? [String: Any])
        #expect(body["amount"] as? Int == 40 && body["donation"] as? Bool == false)
        #expect(body["minConfirmations"] as? Int == 1)
        #expect(body["transportEndpoints"] as? [String] == ["rpc://proxy:3000/json-rpc"])
        #expect(body["witnessAmountSat"] == nil)
        #expect(requests[1].headers["Idempotency-Key"] != requests[2].headers["Idempotency-Key"])
        let checkpoint = try #require(try await fixture.checkpoint())
        #expect(checkpoint.phase == .terminal && checkpoint.signedPsbtBase64 != checkpoint.preparedTransaction?.psbtBase64)
        let encoded = try OperationCheckpointCodec.encode(checkpoint)
        #expect(try OperationCheckpointCodec.decode(encoded) == checkpoint)
        let compact = try checkpoint.compactTerminal
        #expect(try OperationCheckpointCodec.decode(OperationCheckpointCodec.encode(compact)) == compact)
        try await fixture.journal.save(compact)
        #expect(try await fixture.perform() == result)
        #expect(await fixture.transport.snapshot().count == 3)
    }
}

@Test func gatewayRGBIntentChangesFailBeforeSigningOrCompletion() async throws {
    let mutations: [(inout [String: Any]) -> Void] = [
        { $0["kind"] = "send_btc" }, { $0["feeRateSatPerVb"] = 3 },
        { $0["utxos"] = ["num": 1, "size": 1_000, "upTo": false] },
        { $0["recipients"] = [["address": "bcrt1pother", "scriptHex": "00", "amountSat": 1]] },
        { $0["asset"] = NSNull() },
        { var asset = $0["asset"] as! [String: Any]; asset["amount"] = 41; $0["asset"] = asset },
        { var asset = $0["asset"] as! [String: Any]; asset["witnessAmountSat"] = 1_000; $0["asset"] = asset },
        { var asset = $0["asset"] as! [String: Any]; asset["transportEndpoints"] = ["rpc://other"]; $0["asset"] = asset },
        { var asset = $0["asset"] as! [String: Any]; asset.removeValue(forKey: "witnessAmountSat"); $0["asset"] = asset },
    ]
    for mutate in mutations {
        var intent = try rgbIntent(); mutate(&intent)
        let fixture = try await rgbFixture(responses: [try rgbPrepare(intent: intent)])
        do { _ = try await fixture.perform(); Issue.record("changed RGB intent accepted") }
        catch let error as SDKError { #expect(error.code == .backendProtocolMismatch) }
        #expect(try await fixture.checkpoint()?.phase == .created)
        #expect(await fixture.transport.snapshot().count == 2)
    }
}

@Test func gatewayRGBUncertainCompletionRemainsStatusOnlyAfterExpiryWithoutChainProvider() async throws {
    let fixture = try await rgbFixture(responses: [try rgbPrepare(),
        try rgbWire(["txid": String(repeating: "a", count: 64)]), try rgbStatus(state: "pending")])
    do { _ = try await fixture.perform(); Issue.record("invalid completion accepted") }
    catch let error as SDKError { #expect(error.code == .operationAmbiguous) }
    let before = try #require(try await fixture.checkpoint())
    #expect(before.phase == .submitting)
    let recovered = try await rgbFixture(journal: fixture.journal, request: fixture.request,
        requireProvider: true, enabled: false, now: 3_000,
        responses: [try rgbStatus(state: "completed", txid: rgbTxid)])
    let result = try await recovered.perform()
    #expect(result.txid.hex == rgbTxid && result.batchTransferIndex == nil)
    #expect(await recovered.transport.snapshot().map(\.method) == [.get, .get])
    #expect(try await recovered.checkpoint()?.signedPsbtBase64 == before.signedPsbtBase64)
}

@Test func gatewayChainContextValidatesNetworkFreshnessAndRechecksBeforeSubmission() async throws {
    for (network, observed, expected) in [
        (Network.regtest, UInt64(700), true), (.regtest, 1_030, true),
        (.regtest, 699, false), (.regtest, 1_031, false), (.regtest, UInt64.max, false),
        (.signet, 1_000, false),
    ] {
        let provider = RGBTestChainProvider(contexts: [try .init(network: network, tipHeight: 110,
            observedAt: .init(rawValue: observed))])
        let fixture = try await rgbFixture(provider: provider, requireProvider: true,
            responses: expected ? [try rgbPrepare(), try rgbWire(["txid": rgbTxid])] : [])
        if expected { #expect(try await fixture.perform().txid.hex == rgbTxid); #expect(await provider.calls == 3) }
        else {
            do { _ = try await fixture.perform(); Issue.record("invalid chain context accepted") }
            catch let error as SDKError { #expect(error.code == .policyRejected || error.code == .wrongNetwork) }
            #expect(try await fixture.checkpoint() == nil)
            #expect(await fixture.transport.snapshot().count == 1)
        }
    }
    let provider = RGBTestChainProvider(contexts: try [110, 110, 100].map {
        try .init(network: .regtest, tipHeight: UInt32($0), observedAt: .init(rawValue: 1_000)) })
    let fixture = try await rgbFixture(provider: provider, requireProvider: true, responses: [try rgbPrepare()])
    do { _ = try await fixture.perform(); Issue.record("chain-context change bypassed revalidation") }
    catch let error as SDKError { #expect(error.code == .policyRejected) }
    #expect(try await fixture.checkpoint()?.phase == .signed)
    #expect(await fixture.transport.snapshot().count == 2)
}

@Test func gatewayRGBUnsupportedOptionsFailBeforeJournalOrHTTP() async throws {
    let base = try rgbRequest()
    for request in try [
        OnchainSendRequest(invoice: base.invoice, amount: base.amount, skipSync: true),
        OnchainSendRequest(invoice: base.invoice, amount: AssetAmount(9_007_199_254_740_992)),
        OnchainSendRequest(invoice: base.invoice, amount: base.amount, minConfirmations: .init(rawValue: 101)),
        OnchainSendRequest(invoice: base.invoice, amount: base.amount,
            witnessData: WitnessData(amountSat: Satoshis(1_000), blinding: 5)),
    ] {
        let fixture = try await rgbFixture(request: request, responses: [])
        do { _ = try await fixture.perform(); Issue.record("unsupported RGB option accepted") }
        catch let error as SDKError { #expect(error.code == .unsupported || error.code == .invalidArgument) }
        #expect(try await fixture.checkpoint() == nil)
        #expect(await fixture.transport.snapshot().count == 1)
    }
}

@Test func gatewayRGBWitnessTransportForwardsSatoshisAndRejectsChangedAmount() async throws {
    let invoice = try RGBInvoice(invoiceTestString(witness: true, asset: invoiceTestAsset))
    let decoded = try decodeRGBInvoiceLocally(invoice)
    let request = try OnchainSendRequest(invoice: invoice, amount: AssetAmount(40),
        witnessData: WitnessData(amountSat: Satoshis(1_000)), donation: true,
        minConfirmations: .init(rawValue: 6))
    for witnessAmount in [1_000, 999] {
        var intent = try rgbIntent()
        intent["asset"] = ["assetId": decoded.assetID!.value, "amount": 40,
            "recipientId": decoded.recipientID, "witnessAmountSat": witnessAmount,
            "transportEndpoints": decoded.transportEndpoints]
        let fixture = try await rgbFixture(request: request, responses: [try rgbPrepare(intent: intent)])
        let context = OperationRequestContext(backend: fixture.context,
            idempotencyKey: request.idempotencyKey,
            requestHash: try RequestHasher.onchainSend(network: .regtest, request: request))
        // Wire-only witness coverage: the returned blind fixture is deliberately
        // never signed, and is not claimed as a native witness preparation.
        if witnessAmount == 1_000 {
            _ = try await fixture.backend.prepareOnchainSend(.init(context: context, request: request))
        } else {
            do {
                _ = try await fixture.backend.prepareOnchainSend(.init(context: context, request: request))
                Issue.record("changed witness amount accepted")
            } catch let error as SDKError { #expect(error.code == .backendProtocolMismatch) }
        }
        let requests = await fixture.transport.snapshot()
        let data = try #require(requests.last?.body)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["witnessAmountSat"] as? Int == 1_000)
        #expect(body["donation"] as? Bool == true && body["minConfirmations"] as? Int == 6)
        #expect(body["recipientId"] as? String == decoded.recipientID)
        #expect(requests.count == 2 && requests.last?.url.path == "/v1/onchain/send-asset/prepare")
    }
}

private actor RGBTestChainProvider: WalletChainContextProvider {
    let contexts: [WalletChainContext]
    private(set) var calls = 0
    init(contexts: [WalletChainContext]) { self.contexts = contexts }
    func loadChainContext(network: Network) async throws -> WalletChainContext {
        defer { calls += 1 }
        return contexts[min(calls, contexts.count - 1)]
    }
}

private struct RGBTransportFixture {
    let backend: GatewayWalletBackend
    let coordinator: OperationCoordinator
    let context: BackendContext
    let request: OnchainSendRequest
    let journal: InMemoryOperationJournal
    let transport: RGBTestTransport
    func perform() async throws -> OnchainSendResponse {
        try await coordinator.onchainSend(backendContext: context, signer: GatewayNativeFixtures.signer(), request: request)
    }
    func checkpoint() async throws -> OperationCheckpoint? {
        await journal.load(walletID: context.walletID, idempotencyKey: request.idempotencyKey)
    }
}

private func rgbRequest() throws -> OnchainSendRequest {
    try .init(invoice: RGBInvoice(GatewayNativeFixtures.rgbInvoice), amount: AssetAmount(40),
        idempotencyKey: IdempotencyKey("gateway-rgb-transport"))
}

private func rgbFixture(journal: InMemoryOperationJournal = .init(), request: OnchainSendRequest? = nil,
    provider: (any WalletChainContextProvider)? = nil, requireProvider: Bool = false,
    enabled: Bool = true, now: UInt64 = 1_000, responses: [GatewayHTTPResponse]) async throws -> RGBTransportFixture {
    let transport = RGBTestTransport(responses: try [rgbWire(["userId": "rgb-user", "createdAt": 1])] + responses)
    let backend = GatewayWalletBackend(configuration: try GatewayBackendConfiguration(
        baseURL: URL(string: "https://gateway.example")!, bearerToken: "synthetic-key", network: .regtest,
        allowUnverifiedPsbtProfile: enabled, chainContextProvider: provider,
        requiresApplicationChainContext: requireProvider), transport: transport, nowMilliseconds: { now * 1_000 })
    let walletID = try WalletID("rgb-transport")
    let session = try await backend.initialize(.init(walletID: walletID, network: .regtest, minimumAPIVersion: 1, maximumAPIVersion: 1))
    return .init(backend: backend, coordinator: .init(configuration: try .init(walletID: walletID, network: .regtest),
        backend: backend, journal: journal, now: { now }),
        context: .init(session: session, walletID: walletID, network: .regtest),
        request: try request ?? rgbRequest(), journal: journal, transport: transport)
}

private func rgbIntent() throws -> [String: Any] {
    let invoice = try decodeRGBInvoiceLocally(RGBInvoice(GatewayNativeFixtures.rgbInvoice))
    return ["kind": "send_asset", "feeRateSatPerVb": 2, "recipients": [], "utxos": NSNull(),
        "asset": ["assetId": invoice.assetID!.value, "amount": 40, "recipientId": invoice.recipientID,
            "witnessAmountSat": NSNull(), "transportEndpoints": invoice.transportEndpoints]]
}

private func rgbPrepare(intent: [String: Any]? = nil) throws -> GatewayHTTPResponse {
    try rgbWire(["opId": rgbOperationID, "psbt": GatewayNativeFixtures.rgb,
        "intent": intent ?? rgbIntent(), "expiresAt": 2_000_000], status: 201)
}

private func rgbStatus(state: String, txid: String? = nil) throws -> GatewayHTTPResponse {
    try rgbWire(["opId": rgbOperationID, "kind": "send_asset", "state": state,
        "txid": txid as Any? ?? NSNull(), "mayHaveBroadcast": state != "completed" && txid != nil,
        "intent": rgbIntent(), "createdAt": 1_000_000, "expiresAt": 2_000_000])
}

private func rgbWire(_ body: [String: Any], status: Int = 200) throws -> GatewayHTTPResponse {
    .init(statusCode: status, mimeType: "application/json", correlationID: nil,
        body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
}

private actor RGBTestTransport: GatewayHTTPTransport {
    var responses: [GatewayHTTPResponse]
    var requests: [GatewayHTTPRequest] = []
    init(responses: [GatewayHTTPResponse]) { self.responses = responses }
    func send(_ request: GatewayHTTPRequest) async throws -> GatewayHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw SDKError.invariant("unexpected RGB transport request") }
        return responses.removeFirst()
    }
    func snapshot() -> [GatewayHTTPRequest] { requests }
}
