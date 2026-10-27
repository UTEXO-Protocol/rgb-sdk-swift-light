import Foundation
import Testing
@testable @_spi(Backend) import RGBSDK

// Frozen, public test keys/PSBT only. Stub HTTP completion never broadcasts.
private let createOperationID = "c1111111-1111-4111-8111-111111111111"
private let createTxid = "9f4b8d594d577e5b73cd941db229870965f099bf0092df8cf9444cc309986967"

@Test func gatewayCreateUsesExistingContractAndLocallyDerivedPlan() async throws {
    let fixture = try await createTransportFixture(responses: [
        try createPrepareResponse(), try createWireResponse(["txid": createTxid, "utxosCreated": 5]),
    ])
    let result = try await fixture.coordinator.createUtxos(
        backendContext: fixture.context, signer: GatewayNativeFixtures.signer(), request: fixture.request)
    #expect(result.createdUtxoCount == 5 && result.txid.hex == createTxid)
    let requests = await fixture.transport.snapshot()
    #expect(requests.map(\.url.path) == ["/v1/me", "/v1/onchain/create-utxos/prepare", "/v1/onchain/create-utxos/complete"])
    let encoded = try #require(requests[1].body)
    let body = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(body["upTo"] as? Bool == true)
    #expect(body["num"] as? Int == 5 && body["size"] as? Int == 5_000)
    #expect(body["feeRateSatPerVb"] as? Int == 2)
    #expect(requests[1].headers["Idempotency-Key"] != requests[2].headers["Idempotency-Key"])
    let checkpoint = try #require(await fixture.journal.load(walletID: fixture.context.walletID, idempotencyKey: fixture.request.idempotencyKey))
    #expect(checkpoint.phase == .terminal)
    #expect(checkpoint.preparedTransaction?.createUtxosOutputPlan?.outputs.map(\.index) == [6, 7, 9, 8, 10])
    #expect(checkpoint.signedPsbtBase64 != checkpoint.preparedTransaction?.psbtBase64)
    let replay = try await fixture.coordinator.createUtxos(
        backendContext: fixture.context, signer: GatewayNativeFixtures.signer(), request: fixture.request)
    #expect(replay == result)
    #expect(await fixture.transport.snapshot().count == 3)
}

@Test func gatewayCreatePartialResultUsesActualPlanNotRequestedCount() async throws {
    let request = try CreateUtxosRequest(upTo: false, num: 7, size: Satoshis(5_000))
    let fixture = try await createTransportFixture(request: request, responses: [
        try createPrepareResponse(num: 7, upTo: false),
        try createWireResponse(["txid": createTxid, "utxosCreated": 5]),
    ])
    let result = try await fixture.coordinator.createUtxos(
        backendContext: fixture.context, signer: GatewayNativeFixtures.signer(), request: request)
    #expect(result.createdUtxoCount == 5)
}

@Test func gatewayCreateInvalidCompletionRetainsEvidenceAndRecoversOnlyMatchingCompletedStatus() async throws {
    for completion in [
        ["txid": NSNull(), "utxosCreated": 5],
        ["txid": createTxid, "utxosCreated": 4],
        ["txid": String(repeating: "a", count: 64), "utxosCreated": 5],
        ["utxosCreated": 5],
    ] as [[String: Any]] {
        let fixture = try await createTransportFixture(responses: [
            try createPrepareResponse(), try createWireResponse(completion),
            try createStatusResponse(state: "completed", txid: createTxid),
        ])
        let result = try await fixture.coordinator.createUtxos(
            backendContext: fixture.context, signer: GatewayNativeFixtures.signer(), request: fixture.request)
        #expect(result.createdUtxoCount == 5)
        #expect(await fixture.transport.snapshot().map(\.method) == [.get, .post, .post, .get])
    }
}

@Test func gatewayCreateUnresolvedCompletionNeverRetriesAndRecoversAfterExpiryWithGateOff() async throws {
    let fixture = try await createTransportFixture(responses: [
        try createPrepareResponse(), try createWireResponse(["error": ["code": "COMPLETE_AMBIGUOUS"]], status: 502),
        try createStatusResponse(state: "pending", txid: nil),
    ])
    do {
        _ = try await fixture.coordinator.createUtxos(
            backendContext: fixture.context, signer: GatewayNativeFixtures.signer(), request: fixture.request)
        Issue.record("unresolved completion must not become success")
    } catch let error as SDKError { #expect(error.code == .operationAmbiguous) }
    let original = try #require(await fixture.journal.load(walletID: fixture.context.walletID, idempotencyKey: fixture.request.idempotencyKey))
    #expect(original.phase == .submitting)
    let recovered = try await createTransportFixture(
        request: fixture.request, journal: fixture.journal, enabled: false, now: 5_000,
        responses: [try createStatusResponse(state: "completed", txid: createTxid)]
    )
    let result = try await recovered.coordinator.createUtxos(
        backendContext: recovered.context, signer: GatewayNativeFixtures.signer(gateway: false), request: fixture.request)
    #expect(result.createdUtxoCount == 5)
    #expect(await recovered.transport.snapshot().map(\.method) == [.get, .get])
    let terminal = try #require(await fixture.journal.load(walletID: fixture.context.walletID, idempotencyKey: fixture.request.idempotencyKey))
    #expect(terminal.phase == .terminal && terminal.signedPsbtBase64 == original.signedPsbtBase64)
}

@Test func gatewayCreateContractRejectsChangedIntentAndMalformedPsbtBeforeSigning() async throws {
    let mutations: [(inout [String: Any]) -> Void] = [
        { $0["kind"] = "send_btc" }, { $0["feeRateSatPerVb"] = 3 },
        { $0["utxos"] = ["num": 4, "size": 5_000, "upTo": true] },
        { $0["utxos"] = ["num": 5, "size": 5_000, "upTo": false] },
        { $0["utxos"] = ["num": 5, "size": 999, "upTo": true] },
        { $0.removeValue(forKey: "utxos") }, { $0["asset"] = [:] },
        { $0["recipients"] = [["address": "bcrt1pother", "scriptHex": "00", "amountSat": 1]] },
    ]
    for mutation in mutations {
        var intent = createIntentJSON()
        mutation(&intent)
        let fixture = try await createTransportFixture(responses: [try createPrepareResponse(intent: intent)])
        do {
            _ = try await fixture.coordinator.createUtxos(
                backendContext: fixture.context, signer: GatewayNativeFixtures.signer(), request: fixture.request)
            Issue.record("modified create intent accepted")
        } catch let error as SDKError { #expect(error.code == .backendProtocolMismatch) }
        #expect(await fixture.transport.snapshot().count == 2)
        #expect(await fixture.journal.load(walletID: fixture.context.walletID, idempotencyKey: fixture.request.idempotencyKey)?.phase == .created)
    }
    for psbt in [Data("not-psbt".utf8).base64EncodedString(), GatewayNativeFixtures.rgb, "%%%"] {
        let fixture = try await createTransportFixture(responses: [try createPrepareResponse(psbt: psbt)])
        do {
            _ = try await fixture.coordinator.createUtxos(
                backendContext: fixture.context, signer: GatewayNativeFixtures.signer(), request: fixture.request)
            Issue.record("invalid create PSBT accepted")
        } catch let error as SDKError { #expect(error.code == .backendProtocolMismatch) }
        #expect(await fixture.transport.snapshot().count == 2)
    }
}

@Test func gatewayCreateRejectsOversizedPsbtBeforePlanExtractionOrJournaling() async throws {
    let psbt = Data(repeating: 0x42, count: 36_867).base64EncodedString()
    #expect(psbt.utf8.count > GatewayWalletBackend.maximumPreparedPsbtCharacters)
    let fixture = try await createTransportFixture(responses: [try createPrepareResponse(psbt: psbt)])
    do {
        _ = try await fixture.coordinator.createUtxos(
            backendContext: fixture.context, signer: GatewayNativeFixtures.signer(), request: fixture.request)
        Issue.record("oversized create PSBT accepted")
    } catch let error as SDKError {
        #expect(error.code == .backendProtocolMismatch && !error.retryable)
        // The size cap, not native plan extraction, must reject it.
        #expect(error.message.hasSuffix("prepared PSBT exceeds the gateway completion size limit"))
    }
    #expect(await fixture.transport.snapshot().count == 2)
    #expect(await fixture.journal.load(walletID: fixture.context.walletID, idempotencyKey: fixture.request.idempotencyKey)?.phase == .created)
}

@Test func gatewayCreateUnsupportedArgumentsFailBeforeNewCheckpointAndHTTP() async throws {
    for request in try [
        CreateUtxosRequest(num: 51), CreateUtxosRequest(size: Satoshis(329)),
        CreateUtxosRequest(feeRate: FeeRate(satsPerVByte: 1.5)), CreateUtxosRequest(skipSync: true),
    ] {
        let fixture = try await createTransportFixture(request: request, responses: [])
        do {
            _ = try await fixture.coordinator.createUtxos(
                backendContext: fixture.context, signer: GatewayNativeFixtures.signer(), request: request)
            Issue.record("unsupported create request accepted")
        } catch let error as SDKError { #expect(error.code == .invalidArgument || error.code == .unsupported) }
        #expect(await fixture.transport.snapshot().count == 1)
        #expect(await fixture.journal.load(walletID: fixture.context.walletID, idempotencyKey: request.idempotencyKey) == nil)
    }
}

@Test func gatewayCreateOrdinaryConfigurationCannotPrepareOrCreateJournalEntry() async throws {
    let fixture = try await createTransportFixture(enabled: false, responses: [])
    do {
        _ = try await fixture.coordinator.createUtxos(
            backendContext: fixture.context, signer: GatewayNativeFixtures.signer(), request: fixture.request)
        Issue.record("ordinary gateway must retain fresh-spending gate")
    } catch let error as SDKError { #expect(error.code == .unsupported) }
    #expect(await fixture.transport.snapshot().count == 1)
    #expect(await fixture.journal.load(walletID: fixture.context.walletID, idempotencyKey: fixture.request.idempotencyKey) == nil)
}

private struct CreateTransportFixture {
    let coordinator: OperationCoordinator
    let context: BackendContext
    let request: CreateUtxosRequest
    let journal: InMemoryOperationJournal
    let transport: CreateTransport
}

private func createTransportFixture(
    request: CreateUtxosRequest? = nil, journal: InMemoryOperationJournal = .init(),
    enabled: Bool = true, now: UInt64 = 1_000, responses: [GatewayHTTPResponse]
) async throws -> CreateTransportFixture {
    let request = try request ?? CreateUtxosRequest(size: Satoshis(5_000))
    let transport = try CreateTransport(responses: [createWireResponse(["userId": "create-user", "createdAt": 1])] + responses)
    let backend = GatewayWalletBackend(
        configuration: try GatewayBackendConfiguration(
            baseURL: URL(string: "https://gateway.example")!, bearerToken: "test-token", network: .regtest,
            allowUnverifiedPsbtProfile: enabled
        ), transport: transport, nowMilliseconds: { now * 1_000 }
    )
    let walletID = try WalletID("gateway-create-transport")
    let session = try await backend.initialize(.init(walletID: walletID, network: .regtest, minimumAPIVersion: 1, maximumAPIVersion: 1))
    let context = BackendContext(session: session, walletID: walletID, network: .regtest)
    return .init(coordinator: OperationCoordinator(
        configuration: try WalletConfiguration(walletID: walletID, network: .regtest),
        backend: backend, journal: journal, now: { now }
    ), context: context, request: request, journal: journal, transport: transport)
}

private func createIntentJSON(num: Int = 5, upTo: Bool = true) -> [String: Any] {
    ["kind": "create_utxos", "feeRateSatPerVb": 2, "recipients": [], "asset": NSNull(),
     "utxos": ["num": num, "size": 5_000, "upTo": upTo]]
}

private func createPrepareResponse(
    num: Int = 5, upTo: Bool = true, intent: [String: Any]? = nil, psbt: String = GatewayNativeFixtures.create
) throws -> GatewayHTTPResponse {
    try createWireResponse(["opId": createOperationID, "psbt": psbt,
        "intent": intent ?? createIntentJSON(num: num, upTo: upTo), "expiresAt": 2_000_000], status: 201)
}

private func createStatusResponse(state: String, txid: String?) throws -> GatewayHTTPResponse {
    try createWireResponse(["opId": createOperationID, "kind": "create_utxos", "state": state,
        "txid": txid as Any? ?? NSNull(), "mayHaveBroadcast": state != "completed" && txid != nil,
        "intent": createIntentJSON(), "createdAt": 1_000_000, "expiresAt": 2_000_000])
}

private func createWireResponse(_ body: [String: Any], status: Int = 200) throws -> GatewayHTTPResponse {
    .init(statusCode: status, mimeType: "application/json", correlationID: nil,
          body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
}

private actor CreateTransport: GatewayHTTPTransport {
    private var responses: [GatewayHTTPResponse]
    private var requests: [GatewayHTTPRequest] = []
    init(responses: [GatewayHTTPResponse]) { self.responses = responses }
    func send(_ request: GatewayHTTPRequest) async throws -> GatewayHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw SDKError.invariant("unexpected create request") }
        return responses.removeFirst()
    }
    func snapshot() -> [GatewayHTTPRequest] { requests }
}
