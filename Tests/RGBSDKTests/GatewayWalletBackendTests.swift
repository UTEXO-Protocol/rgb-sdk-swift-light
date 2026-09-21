import CryptoKit
import Foundation
import Testing
@testable @_spi(Backend) import RGBSDK

@Test func gatewayReceiveMapsExactDefaultsAndValidatesLocalInvoice() async throws {
    for witness in [false, true] {
        let invoice = invoiceTestString(witness: witness)
        let decoded = try decodeRGBInvoiceLocally(RGBInvoice(invoice))
        let response = String(decoding: try JSONSerialization.data(withJSONObject: [
            "invoice": invoice, "recipientId": decoded.recipientID,
            "expirationTimestamp": 87_400, "mode": witness ? "witness" : "blind",
        ]), as: UTF8.self)
        let transport = GatewayStubTransport(responses: [
            gatewayResponse(#"{"userId":"receive-user","createdAt":1}"#),
            gatewayResponse(response, statusCode: 201),
        ])
        let (backend, context) = try await initializedGateway(transport: transport)
        let result = try await backend.onchainReceive(context: context, request: OnchainReceiveRequest(witness: witness))
        #expect(result.invoice.value == invoice)
        #expect(result.recipientID == decoded.recipientID)
        #expect(result.expirationTimestamp?.rawValue == 87_400)
        #expect(result.batchTransferIndex == nil)
        let requests = await transport.snapshot()
        #expect(requests.map(\.url.path) == ["/v1/me", "/v1/wallet/receive"])
        let requestBody = try #require(requests.last?.body)
        let body = try jsonObject(requestBody)
        #expect(body["mode"] as? String == (witness ? "witness" : "blind"))
        #expect(body["durationSeconds"] as? Int == 86_400)
        #expect(body["minConfirmations"] as? Int == 0)
        #expect(body["amount"] == nil && body["assetId"] == nil)
    }
}

@Test func gatewayReceiveRejectsUnrepresentableRequestsBeforeHTTP() async throws {
    let transport = GatewayStubTransport(responses: [gatewayResponse(#"{"userId":"receive-user","createdAt":1}"#)])
    let (backend, context) = try await initializedGateway(transport: transport)
    for request in [
        try OnchainReceiveRequest(amount: AssetAmount(9_007_199_254_740_992)),
        try OnchainReceiveRequest(duration: DurationSeconds(59)),
        try OnchainReceiveRequest(duration: DurationSeconds(2_592_001)),
        try OnchainReceiveRequest(minConfirmations: BlockCount(rawValue: 101)),
    ] {
        do { _ = try await backend.onchainReceive(context: context, request: request); Issue.record("expected local request rejection") }
        catch let error as SDKError { #expect(error.code == .invalidArgument) }
    }
    #expect(await transport.snapshot().count == 1)
}

@Test func gatewayReceivePreservesExplicitAmountAssetDurationAndConfirmations() async throws {
    let invoice = invoiceTestString(
        asset: invoiceTestAsset, schema: invoiceTestNiaSchema, assignment: "BF", expiry: 1_060
    )
    let decoded = try decodeRGBInvoiceLocally(RGBInvoice(invoice))
    let response = String(decoding: try JSONSerialization.data(withJSONObject: [
        "invoice": invoice, "recipientId": decoded.recipientID,
        "expirationTimestamp": 1_060, "mode": "blind",
    ]), as: UTF8.self)
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"receive-user","createdAt":1}"#),
        gatewayResponse(response, statusCode: 201),
    ])
    let (backend, context) = try await initializedGateway(transport: transport)
    let result = try await backend.onchainReceive(context: context, request: OnchainReceiveRequest(
        amount: AssetAmount(100), assetID: AssetID("rgb:\(invoiceTestAsset)"),
        minConfirmations: BlockCount(rawValue: 100), duration: DurationSeconds(60), witness: false
    ))
    #expect(result.invoice.value == invoice)
    let requests = await transport.snapshot()
    let requestBody = try #require(requests.last?.body)
    let body = try jsonObject(requestBody)
    #expect(body["amount"] as? Int == 100)
    #expect(body["assetId"] as? String == "rgb:\(invoiceTestAsset)")
    #expect(body["durationSeconds"] as? Int == 60)
    #expect(body["minConfirmations"] as? Int == 100)
}

@Test func gatewayReceiveRejectsTamperedOrIncompleteResponsesWithoutRetry() async throws {
    let invoice = invoiceTestString()
    let decoded = try decodeRGBInvoiceLocally(RGBInvoice(invoice))
    let original: [String: Any] = [
        "invoice": invoice, "recipientId": decoded.recipientID,
        "expirationTimestamp": 87_400, "mode": "blind",
    ]
    for (field, value) in [
        ("invoice", "rgb:private-payload"), ("recipientId", "other-recipient"),
        ("expirationTimestamp", 87_401),
        ("mode", "witness"), ("invoice", invoiceTestString(network: "bc")),
        ("invoice", invoiceTestString(assignment: "BF")),
    ] as [(String, Any)] {
        var changed = original
        changed[field] = value
        let response = String(decoding: try JSONSerialization.data(withJSONObject: changed), as: UTF8.self)
        let transport = GatewayStubTransport(responses: [
            gatewayResponse(#"{"userId":"receive-user","createdAt":1}"#),
            gatewayResponse(response, statusCode: 201),
        ])
        let (backend, context) = try await initializedGateway(transport: transport)
        do { _ = try await backend.onchainReceive(context: context, request: OnchainReceiveRequest(witness: false)); Issue.record("expected response rejection") }
        catch let error as SDKError {
            #expect(error.code == .backendProtocolMismatch)
            #expect(!error.message.contains("private-payload"))
        }
        #expect(await transport.snapshot().count == 2)
    }
}

@Test func gatewayReceiveAllowsExplicitNullExpiryButRequiresTheWireField() async throws {
    let invoice = invoiceTestString()
    let decoded = try decodeRGBInvoiceLocally(RGBInvoice(invoice))
    for includeExpiry in [true, false] {
        var body: [String: Any] = ["invoice": invoice, "recipientId": decoded.recipientID, "mode": "blind"]
        if includeExpiry { body["expirationTimestamp"] = NSNull() }
        let response = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        let transport = GatewayStubTransport(responses: [
            gatewayResponse(#"{"userId":"receive-user","createdAt":1}"#),
            gatewayResponse(response, statusCode: 201),
        ])
        let (backend, context) = try await initializedGateway(transport: transport)
        if includeExpiry {
            let result = try await backend.onchainReceive(context: context, request: OnchainReceiveRequest(witness: false))
            #expect(result.expirationTimestamp == nil)
            #expect(try decodeRGBInvoiceLocally(result.invoice).expirationTimestamp?.rawValue == 87_400)
        } else {
            await #expect(throws: SDKError.self) {
                _ = try await backend.onchainReceive(context: context, request: OnchainReceiveRequest(witness: false))
            }
        }
        #expect(await transport.snapshot().count == 2)
    }
}

@Test func gatewayReceiveNeverRetriesCancellationOrUnexpectedHTTPResponses() async throws {
    for response in [
        gatewayResponse("{}", statusCode: 200), gatewayResponse("{}", statusCode: 202),
        gatewayResponse("{}", statusCode: 302), gatewayResponse("{}", statusCode: 500),
        gatewayResponse("not-json", statusCode: 201, mimeType: "text/plain"),
    ] {
        let transport = GatewayStubTransport(responses: [
            gatewayResponse(#"{"userId":"receive-user","createdAt":1}"#), response,
        ])
        let (backend, context) = try await initializedGateway(transport: transport)
        await #expect(throws: SDKError.self) {
            _ = try await backend.onchainReceive(context: context, request: OnchainReceiveRequest())
        }
        #expect(await transport.snapshot().count == 2)
    }
    let transport = GatewayStubTransport(responses: [gatewayResponse(#"{"userId":"receive-user","createdAt":1}"#)])
    let (backend, context) = try await initializedGateway(transport: transport)
    await transport.cancelNextRequest()
    await #expect(throws: CancellationError.self) {
        _ = try await backend.onchainReceive(context: context, request: OnchainReceiveRequest())
    }
    #expect(await transport.snapshot().count == 2)
    try await backend.shutdown(session: context.session)
    await #expect(throws: SDKError.self) {
        _ = try await backend.onchainReceive(context: context, request: OnchainReceiveRequest())
    }
    #expect(await transport.snapshot().count == 2)
}

@Test func gatewaySyncAndRefreshReturnLocalObservationWithoutInventingChainTip() async throws {
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"u_sync","createdAt":1}"#),
        gatewayResponse(#"{"status":"ok"}"#),
        gatewayResponse(#"{"status":"ok","futureAdditiveField":true}"#),
    ])
    let (backend, context) = try await initializedGateway(transport: transport)
    let sync = try await backend.syncWallet(context: context)
    let refresh = try await backend.refreshWallet(context: context)
    #expect(sync.completedAt.rawValue == 1_000)
    #expect(refresh.completedAt.rawValue == 1_000)
    #expect(sync.tipHeight == nil && refresh.tipHeight == nil)
    let requests = await transport.snapshot()
    #expect(requests.map(\.url.path) == ["/v1/me", "/v1/wallet/sync", "/v1/wallet/sync"])
    #expect(requests.map(\.method) == [.get, .post, .post])
    #expect(requests[1].body == nil && requests[2].body == nil)
}

@Test func gatewaySyncRejectsNonCompletionResponsesWithoutAutomaticRetry() async throws {
    for response in [
        gatewayResponse(#"{"status":"queued"}"#),
        gatewayResponse(#"{"status":true}"#),
        gatewayResponse(#"{"status":null}"#),
        gatewayResponse("{}"), gatewayResponse("{malformed"),
        gatewayResponse(#"{"status":"ok"}"#, statusCode: 202),
        gatewayResponse(#"{"status":"ok"}"#, mimeType: "text/plain"),
    ] {
        let transport = GatewayStubTransport(responses: [
            gatewayResponse(#"{"userId":"u_sync","createdAt":1}"#), response,
        ])
        let (backend, context) = try await initializedGateway(transport: transport)
        do {
            _ = try await backend.syncWallet(context: context)
            Issue.record("expected invalid completion response rejection")
        } catch let error as SDKError { #expect(error.code == .backendProtocolMismatch) }
        #expect(await transport.snapshot().count == 2)
    }
}

@Test func gatewaySyncPreservesCancellationAndRejectsStaleSessionBeforeHTTP() async throws {
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"u_sync","createdAt":1}"#),
        gatewayResponse(#"{"status":"ok"}"#),
    ])
    let (backend, context) = try await initializedGateway(transport: transport)
    await transport.cancelNextRequest()
    await #expect(throws: CancellationError.self) { try await backend.refreshWallet(context: context) }
    #expect(await transport.snapshot().count == 2)
    try await backend.shutdown(session: context.session)
    await #expect(throws: SDKError.self) { try await backend.syncWallet(context: context) }
    #expect(await transport.snapshot().count == 2)
}

@Test func gatewaySyncRejectsOutOfDomainInjectedClock() async throws {
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"u_sync","createdAt":1}"#),
        gatewayResponse(#"{"status":"ok"}"#),
    ])
    let backend = GatewayWalletBackend(
        configuration: try gatewayConfiguration(), transport: transport,
        nowMilliseconds: { UInt64.max }
    )
    let walletID = try WalletID("sync-clock")
    let session = try await backend.initialize(.init(
        walletID: walletID, network: .regtest, minimumAPIVersion: 1, maximumAPIVersion: 1
    ))
    await #expect(throws: SDKError.self) {
        try await backend.syncWallet(context: .init(session: session, walletID: walletID, network: .regtest))
    }
    #expect(await transport.snapshot().count == 2)
}

@Test func gatewayReloadsRotatedCredentialAndBindsItToSameUserBeforeRequest() async throws {
    let credentials = RotatingTestAPIKeyProvider("first-key")
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"same-user","createdAt":1}"#),
        gatewayResponse(#"{"userId":"same-user","createdAt":1}"#),
        gatewayResponse(#"{"btc":{"vanilla":{"settled":1,"future":1,"spendable":1},"colored":{"settled":0,"future":0,"spendable":0}},"assets":[]}"#),
    ])
    let backend = GatewayWalletBackend(
        configuration: try GatewayBackendConfiguration(
            baseURL: URL(string: "https://gateway.example")!, apiKeyProvider: credentials, network: .regtest
        ), transport: transport
    )
    let walletID = try WalletID("rotation-wallet")
    let session = try await backend.initialize(.init(
        walletID: walletID, network: .regtest, minimumAPIVersion: 1, maximumAPIVersion: 1
    ))
    await credentials.rotate("second-key")
    let balance = try await backend.getBtcBalance(context: .init(session: session, walletID: walletID, network: .regtest))
    #expect(balance.vanilla.settled.value == 1)
    let requests = await transport.snapshot()
    #expect(requests.map(\.url.path) == ["/v1/me", "/v1/me", "/v1/wallet/balances"])
    #expect(requests.map { $0.headers["Authorization"] } == ["Bearer first-key", "Bearer second-key", "Bearer second-key"])
    #expect(await credentials.loadCount == 2)
}

@Test func gatewayRefusesCredentialRotationToAnotherUserBeforeWalletRequest() async throws {
    let credentials = RotatingTestAPIKeyProvider("first-key")
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"first-user","createdAt":1}"#),
        gatewayResponse(#"{"userId":"other-user","createdAt":1}"#),
    ])
    let backend = GatewayWalletBackend(
        configuration: try GatewayBackendConfiguration(
            baseURL: URL(string: "https://gateway.example")!, apiKeyProvider: credentials, network: .regtest
        ), transport: transport
    )
    let walletID = try WalletID("rotation-wallet")
    let session = try await backend.initialize(.init(
        walletID: walletID, network: .regtest, minimumAPIVersion: 1, maximumAPIVersion: 1
    ))
    await credentials.rotate("another-user-key")
    await #expect(throws: SDKError.self) {
        try await backend.getBtcBalance(context: .init(session: session, walletID: walletID, network: .regtest))
    }
    #expect(await transport.snapshot().map(\.url.path) == ["/v1/me", "/v1/me"])
}

@Test func gatewayPropagatesDurableIdentityBindingFailureBeforeOpeningSession() async throws {
    let transport = GatewayStubTransport(responses: [gatewayResponse(#"{"userId":"other-user","createdAt":1}"#)])
    let backend = GatewayWalletBackend(
        configuration: try gatewayConfiguration(), transport: transport,
        identityObserver: { _ in throw SDKError.operationJournalUnavailable }
    )
    await #expect(throws: SDKError.self) {
        try await backend.initialize(.init(
            walletID: WalletID("journal-bound-wallet"), network: .regtest, minimumAPIVersion: 1, maximumAPIVersion: 1
        ))
    }
}

private actor RotatingTestAPIKeyProvider: WalletAPIKeyProvider {
    private var token: String
    private(set) var loadCount = 0
    init(_ token: String) { self.token = token }
    func rotate(_ token: String) { self.token = token }
    func loadAPIKey() async throws -> WalletAPIKey {
        loadCount += 1
        return try WalletAPIKey(copyingUTF8: Array(token.utf8))
    }
}

@Test func gatewayConfigurationEnforcesTransportBoundaryAndRedactsToken() throws {
    let ipv6 = try GatewayBackendConfiguration(
        baseURL: #require(URL(string: "http://[::1]:8480")), bearerToken: "secret-token",
        network: .regtest, allowInsecureLocalDevelopment: true
    )
    #expect(ipv6.baseURL.absoluteString == "http://[::1]:8480")
    #expect(throws: SDKError.self) {
        try GatewayBackendConfiguration(
            baseURL: #require(URL(string: "http://127.0.0.1:8480")),
            bearerToken: "secret-token",
            network: .regtest
        )
    }
    #expect(throws: SDKError.self) {
        try GatewayBackendConfiguration(
            baseURL: #require(URL(string: "http://gateway.example")),
            bearerToken: "secret-token",
            network: .signet,
            allowInsecureLocalDevelopment: true
        )
    }
    #expect(throws: SDKError.self) {
        try GatewayBackendConfiguration(
            baseURL: #require(URL(string: "https://gateway.example/path")),
            bearerToken: "secret-token",
            network: .signet
        )
    }
    #expect(throws: SDKError.self) {
        try GatewayBackendConfiguration(
            baseURL: #require(URL(string: "https://gateway.example")),
            bearerToken: "secret\r\ntoken",
            network: .signet
        )
    }
    #expect(throws: SDKError.self) {
        try GatewayBackendConfiguration(
            baseURL: #require(URL(string: "https://gateway.example")),
            bearerToken: "secret-token",
            network: .testnet4
        )
    }
    #expect(throws: SDKError.self) {
        try GatewayBackendConfiguration(
            baseURL: #require(URL(string: "https://gateway.example")),
            bearerToken: "secret-token",
            network: .utexo
        )
    }

    let configuration = try gatewayConfiguration(token: "do-not-log-this-token")
    #expect(configuration.baseURL.absoluteString == "http://127.0.0.1:8480")
    #expect(!configuration.description.contains("do-not-log-this-token"))
    #expect(configuration.description.contains("[REDACTED]"))
    let reflectedValues = configuration.customMirror.children.map { String(describing: $0.value) }
    #expect(!reflectedValues.contains(where: { $0.contains("do-not-log-this-token") }))
}

@Test func gatewayUnverifiedPsbtProfileIsDefaultOffBeforeJournalAndHttp() async throws {
    let configuration = try GatewayBackendConfiguration(
        baseURL: #require(URL(string: "http://127.0.0.1:8480")),
        bearerToken: "unit-token",
        network: .regtest,
        allowInsecureLocalDevelopment: true
    )
    #expect(!configuration.allowUnverifiedPsbtProfile)

    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"u_profile_gate","createdAt":1}"#),
    ])
    let backend = GatewayWalletBackend(configuration: configuration, transport: transport)
    let walletID = try WalletID("wallet-profile-gate")
    let session = try await backend.initialize(
        .init(
            walletID: walletID,
            network: .regtest,
            minimumAPIVersion: 1,
            maximumAPIVersion: 1
        )
    )
    let backendContext = BackendContext(
        session: session,
        walletID: walletID,
        network: .regtest
    )
    let operationContext = try gatewayOperationContext(
        backend: backendContext,
        key: "profile-gate"
    )
    let send = try SendBtcRequest(
        address: BitcoinAddress("bcrt1pprofilegateaddress"),
        amount: Satoshis(10_000),
        feeRate: FeeRate(milliSatsPerVByte: 2_000),
        idempotencyKey: IdempotencyKey("profile-gate")
    )

    do {
        _ = try await backend.prepareSendBtc(.init(context: operationContext, request: send))
        Issue.record("expected the provisional PSBT profile gate")
    } catch let error as SDKError {
        #expect(error.code == .unsupported)
        #expect(
            error.details["feature"]
                == "spending requires an explicitly enabled, unverified gateway PSBT profile"
        )
    }

    let submission = try gatewaySignedSubmission(
        backend: backendContext,
        operationID: OperationID("12121212-1212-4212-8212-121212121212"),
        txid: String(repeating: "c", count: 64)
    )
    do {
        _ = try await backend.submitSignedTransaction(submission)
        Issue.record("expected completion to retain the provisional PSBT profile gate")
    } catch let error as SDKError {
        #expect(error.code == .unsupported)
    }

    let journal = InMemoryOperationJournal()
    let coordinator = OperationCoordinator(
        configuration: try WalletConfiguration(walletID: walletID, network: .regtest),
        backend: backend,
        journal: journal,
        now: { 1 }
    )
    do {
        _ = try await coordinator.sendBtc(
            backendContext: backendContext,
            signer: GatewayNeverSigner(),
            request: send
        )
        Issue.record("expected coordinator preflight to reject the provisional profile")
    } catch let error as SDKError {
        #expect(error.code == .unsupported)
    }
    #expect(await journal.load(walletID: walletID, idempotencyKey: send.idempotencyKey) == nil)
    #expect(await transport.snapshot().count == 1)
}

@Test func gatewayPreflightKeepsMissingResultContractsDisabled() async throws {
    let backend = GatewayWalletBackend(configuration: try gatewayConfiguration())
    try await backend.preflightOperation(.createUtxos)
    for operation in [OperationKind.onchainSend, .inflate] {
        do {
            try await backend.preflightOperation(operation)
            Issue.record("expected unsupported gateway profile for \(operation.rawValue)")
        } catch let error as SDKError {
            #expect(error.code == .unsupported)
            #expect(error.details["feature"]?.contains(operation.rawValue) == true)
        }
    }
}

@Test func gatewayTerminalSuccessReplaysAfterProfileAndFeePolicyChange() async throws {
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"u_terminal_replay","createdAt":1}"#),
    ])
    let configuration = try gatewayConfiguration(allowUnverifiedPsbtProfile: false)
    let backend = GatewayWalletBackend(configuration: configuration, transport: transport)
    let walletID = try WalletID("wallet-terminal-replay")
    let session = try await backend.initialize(
        .init(
            walletID: walletID,
            network: .regtest,
            minimumAPIVersion: 1,
            maximumAPIVersion: 1
        )
    )
    let context = BackendContext(session: session, walletID: walletID, network: .regtest)
    let request = try gatewayRecoveryRequest(key: "terminal-replay")
    let operationID = try OperationID("13131313-1313-4313-8313-131313131313")
    let txid = try TransactionID(String(repeating: "d", count: 64))
    let checkpoint = try gatewayRecoveryCheckpoint(
        phase: .terminal,
        walletID: walletID,
        request: request,
        operationID: operationID,
        txid: txid
    )
    let journal = InMemoryOperationJournal()
    try await journal.save(checkpoint)
    let tightenedPolicy = try LocalSigningPolicy(
        maximumFeeRate: FeeRate(milliSatsPerVByte: 1_000)
    )
    let coordinator = OperationCoordinator(
        configuration: try WalletConfiguration(
            walletID: walletID,
            network: .regtest,
            signingPolicy: tightenedPolicy
        ),
        backend: backend,
        journal: journal,
        now: { 1 }
    )

    let replayed = try await coordinator.sendBtc(
        backendContext: context,
        signer: GatewayNeverSigner(),
        request: request
    )

    #expect(replayed == txid)
    #expect(
        await journal.load(walletID: walletID, idempotencyKey: request.idempotencyKey)
            == checkpoint
    )
    #expect(await transport.snapshot().map(\.url.path) == ["/v1/me"])
}

@Test func gatewaySignedRecoveryRemainsSignedWhenProfileIsDisabled() async throws {
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"u_signed_recovery","createdAt":1}"#),
    ])
    let configuration = try gatewayConfiguration(allowUnverifiedPsbtProfile: false)
    let backend = GatewayWalletBackend(configuration: configuration, transport: transport)
    let walletID = try WalletID("wallet-signed-recovery")
    let session = try await backend.initialize(
        .init(
            walletID: walletID,
            network: .regtest,
            minimumAPIVersion: 1,
            maximumAPIVersion: 1
        )
    )
    let context = BackendContext(session: session, walletID: walletID, network: .regtest)
    let request = try gatewayRecoveryRequest(key: "signed-recovery")
    let operationID = try OperationID("15151515-1515-4515-8515-151515151515")
    let checkpoint = try gatewayRecoveryCheckpoint(
        phase: .signed,
        walletID: walletID,
        request: request,
        operationID: operationID,
        txid: TransactionID(String(repeating: "f", count: 64))
    )
    let journal = InMemoryOperationJournal()
    try await journal.save(checkpoint)
    let coordinator = OperationCoordinator(
        configuration: try WalletConfiguration(walletID: walletID, network: .regtest),
        backend: backend,
        journal: journal,
        now: { 1 }
    )

    do {
        _ = try await coordinator.sendBtc(
            backendContext: context,
            signer: GatewayNeverSigner(),
            request: request
        )
        Issue.record("expected the disabled provisional profile to block submission")
    } catch let error as SDKError {
        #expect(error.code == .unsupported)
    }

    #expect(
        await journal.load(walletID: walletID, idempotencyKey: request.idempotencyKey)
            == checkpoint
    )
    #expect(await transport.snapshot().map(\.url.path) == ["/v1/me"])
}

@Test func gatewaySubmittingRecoveryRemainsAmbiguousAfterProfileIsDisabled() async throws {
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"u_submitting_recovery","createdAt":1}"#),
    ])
    let configuration = try gatewayConfiguration(allowUnverifiedPsbtProfile: false)
    let backend = GatewayWalletBackend(configuration: configuration, transport: transport)
    let walletID = try WalletID("wallet-submitting-recovery")
    let session = try await backend.initialize(
        .init(
            walletID: walletID,
            network: .regtest,
            minimumAPIVersion: 1,
            maximumAPIVersion: 1
        )
    )
    let context = BackendContext(session: session, walletID: walletID, network: .regtest)
    let request = try gatewayRecoveryRequest(key: "submitting-recovery")
    let operationID = try OperationID("14141414-1414-4414-8414-141414141414")
    let checkpoint = try gatewayRecoveryCheckpoint(
        phase: .submitting,
        walletID: walletID,
        request: request,
        operationID: operationID,
        txid: TransactionID(String(repeating: "e", count: 64))
    )
    let journal = InMemoryOperationJournal()
    try await journal.save(checkpoint)
    let coordinator = OperationCoordinator(
        configuration: try WalletConfiguration(walletID: walletID, network: .regtest),
        backend: backend,
        journal: journal,
        now: { 1 }
    )

    do {
        _ = try await coordinator.sendBtc(
            backendContext: context,
            signer: GatewayNeverSigner(),
            request: request
        )
        Issue.record("expected unavailable status recovery to remain ambiguous")
    } catch let error as SDKError {
        #expect(error.code == .operationAmbiguous)
        #expect(error.operationID == operationID)
    }

    #expect(
        await journal.load(walletID: walletID, idempotencyKey: request.idempotencyKey)
            == checkpoint
    )
    #expect(await transport.snapshot().map(\.url.path) == ["/v1/me", "/v1/onchain/operations/14141414-1414-4414-8414-141414141414"])
}

@Test func gatewayCredentialRemainsBoundToOneWalletAcrossSessions() async throws {
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"u_bound","createdAt":1}"#),
    ])
    let backend = GatewayWalletBackend(
        configuration: try gatewayConfiguration(),
        transport: transport
    )
    let firstWallet = try WalletID("wallet-first")
    let session = try await backend.initialize(
        .init(
            walletID: firstWallet,
            network: .regtest,
            minimumAPIVersion: 1,
            maximumAPIVersion: 1
        )
    )
    try await backend.shutdown(session: session)

    do {
        _ = try await backend.initialize(
            .init(
                walletID: WalletID("wallet-second"),
                network: .regtest,
                minimumAPIVersion: 1,
                maximumAPIVersion: 1
            )
        )
        Issue.record("expected permanent token-to-wallet binding")
    } catch let error as SDKError {
        #expect(error.code == .invalidState)
    }
    #expect(await transport.snapshot().count == 1)
}

@Test func concurrentGatewayInitializationCannotOverwriteWalletBinding() async throws {
    let transport = GatewayInitializeBarrierTransport()
    let backend = GatewayWalletBackend(
        configuration: try gatewayConfiguration(),
        transport: transport
    )
    let firstWallet = try WalletID("wallet-race-first")
    let secondWallet = try WalletID("wallet-race-second")
    let firstTask = Task {
        try await backend.initialize(
            .init(
                walletID: firstWallet,
                network: .regtest,
                minimumAPIVersion: 1,
                maximumAPIVersion: 1
            )
        )
    }
    let secondTask = Task {
        try await backend.initialize(
            .init(
                walletID: secondWallet,
                network: .regtest,
                minimumAPIVersion: 1,
                maximumAPIVersion: 1
            )
        )
    }

    let outcomes = [
        (firstWallet, await firstTask.result),
        (secondWallet, await secondTask.result),
    ]
    var winner: (walletID: WalletID, session: BackendSession)?
    var failures: [SDKError] = []
    for (walletID, outcome) in outcomes {
        switch outcome {
        case let .success(session):
            winner = (walletID, session)
        case let .failure(error as SDKError):
            failures.append(error)
        case .failure:
            Issue.record("expected an SDKError from losing initialization")
        }
    }

    let active = try #require(winner)
    #expect(failures.count == 1)
    #expect(failures.first?.code == .invalidState)
    let context = BackendContext(
        session: active.session,
        walletID: active.walletID,
        network: .regtest
    )
    let balance = try await backend.getBtcBalance(context: context)
    #expect(balance.vanilla.settled.value == 1)
    #expect(await transport.snapshot().count == 3)
}

@Test func gatewayReinitializePermanentlyInvalidatesPriorSessionContext() async throws {
    let balanceBody = #"{"btc":{"vanilla":{"settled":1,"future":2,"spendable":1},"colored":{"settled":3,"future":4,"spendable":3}},"assets":[]}"#
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"u_stable","createdAt":1}"#),
        gatewayResponse(#"{"userId":"u_stable","createdAt":1}"#),
        gatewayResponse(balanceBody),
    ])
    let backend = GatewayWalletBackend(
        configuration: try gatewayConfiguration(),
        transport: transport
    )
    let walletID = try WalletID("wallet-session-nonce")
    let initializeRequest = BackendInitializeRequest(
        walletID: walletID,
        network: .regtest,
        minimumAPIVersion: 1,
        maximumAPIVersion: 1
    )

    let priorSession = try await backend.initialize(initializeRequest)
    let staleContext = BackendContext(
        session: priorSession,
        walletID: walletID,
        network: .regtest
    )
    try await backend.shutdown(session: priorSession)

    let currentSession = try await backend.initialize(initializeRequest)
    let currentContext = BackendContext(
        session: currentSession,
        walletID: walletID,
        network: .regtest
    )
    #expect(priorSession.id.hasPrefix("gw."))
    #expect(currentSession.id.hasPrefix("gw."))
    #expect(priorSession != currentSession)

    do {
        _ = try await backend.getBtcBalance(context: staleContext)
        Issue.record("expected stale backend context rejection")
    } catch let error as SDKError {
        #expect(error.code == .backendProtocolMismatch)
    }

    do {
        try await backend.shutdown(session: priorSession)
        Issue.record("expected wrong-session shutdown rejection")
    } catch let error as SDKError {
        #expect(error.code == .backendProtocolMismatch)
    }

    let balance = try await backend.getBtcBalance(context: currentContext)
    #expect(balance.vanilla.settled.value == 1)
    #expect(balance.colored.future.value == 4)
    #expect(await transport.snapshot().count == 3)
}

@Test func gatewayInitializesAuthenticatedSessionAndRegistersOnlyWatchOnlyKeys() async throws {
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"u_0123456789abcdef","createdAt":1700000000000}"#),
        gatewayResponse(
            #"{"fingerprint":"deadbeef","address":"bcrt1pboundedresponseaddress"}"#,
            statusCode: 201
        ),
    ])
    let configuration = try gatewayConfiguration(token: "unit-test-token")
    let backend = GatewayWalletBackend(configuration: configuration, transport: transport)
    let walletID = try WalletID("wallet-1")
    let session = try await backend.initialize(
        .init(walletID: walletID, network: .regtest, minimumAPIVersion: 1, maximumAPIVersion: 1)
    )
    let context = BackendContext(session: session, walletID: walletID, network: .regtest)
    let identity = WalletIdentity(
        network: .regtest,
        chainNetwork: "regtest",
        derivationProfile: WalletCapabilities.derivationProfileV1,
        masterFingerprint: "deadbeef",
        xpub: "root-xpub-must-not-cross-the-wire",
        accountXpubVanilla: String(repeating: "v", count: 110),
        accountXpubColored: String(repeating: "c", count: 110)
    )
    try await backend.registerWallet(.init(context: context, identity: identity))

    #expect(session.id.hasPrefix("gw."))
    #expect(session.id != "u_0123456789abcdef")
    #expect(session.apiVersion == 1)
    #expect(session.network == .regtest)
    let requests = await transport.snapshot()
    #expect(requests.count == 2)
    #expect(requests[0].method == .get)
    #expect(requests[0].url.path == "/v1/me")
    #expect(requests[0].headers["Authorization"] == "Bearer unit-test-token")
    #expect(requests[0].body == nil)
    #expect(requests[1].method == .post)
    #expect(requests[1].url.path == "/v1/wallet/xpubs")

    let body = try jsonObject(try #require(requests[1].body))
    #expect(Set(body.keys) == Set(["vanilla", "colored", "fingerprint"]))
    #expect(body["fingerprint"] as? String == "deadbeef")
    #expect(!String(decoding: try #require(requests[1].body), as: UTF8.self).contains("root-xpub"))
}

@Test func gatewayMapsOnlyBalancesWithExactRepresentations() async throws {
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"u_balance","createdAt":1}"#),
        gatewayResponse(
            #"{"btc":{"vanilla":{"settled":2000,"future":2100,"spendable":1900},"colored":{"settled":3000,"future":3100,"spendable":2900}},"assets":[]}"#
        ),
        gatewayResponse(
            #"{"btc":{"vanilla":{"settled":0,"future":0,"spendable":0},"colored":{"settled":0,"future":0,"spendable":0}},"assets":[{"assetId":"rgb:asset-1","balance":{"settled":7,"future":9,"spendable":5}}]}"#
        ),
    ])
    let (backend, context) = try await initializedGateway(transport: transport)

    let btc = try await backend.getBtcBalance(context: context)
    #expect(btc.vanilla.settled.value == 2_000)
    #expect(btc.vanilla.spendable.value == 1_900)
    #expect(btc.colored.future.value == 3_100)

    let asset = try await backend.getAssetBalance(
        context: context,
        assetID: AssetID("rgb:asset-1")
    )
    #expect(asset.settled?.decimal == "7")
    #expect(asset.future?.decimal == "9")
    #expect(asset.spendable?.decimal == "5")
    #expect(asset.offchainInbound == nil)

    let requests = await transport.snapshot()
    #expect(requests.map(\.url.path) == [
        "/v1/me", "/v1/wallet/balances", "/v1/wallet/balances",
    ])
}

@Test func gatewayRejectsImpossibleBtcBalancesAsBackendProtocolFailures() async throws {
    for field in ["settled", "future", "spendable"] {
        for account in ["vanilla", "colored"] {
            var wire: [String: UInt64] = ["settled": 0, "future": 0, "spendable": 0]
            wire[field] = Satoshis.maximum + 1
            let zero: [String: UInt64] = ["settled": 0, "future": 0, "spendable": 0]
            let body: [String: Any] = ["btc": ["vanilla": account == "vanilla" ? wire : zero,
                                                "colored": account == "colored" ? wire : zero],
                                        "assets": []]
            let encoded = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
            let transport = GatewayStubTransport(responses: [
                gatewayResponse(#"{"userId":"u_balance_bound","createdAt":1}"#), gatewayResponse(encoded),
            ])
            let (backend, context) = try await initializedGateway(transport: transport)
            do {
                _ = try await backend.getBtcBalance(context: context)
                Issue.record("expected impossible BTC balance rejection")
            } catch let error as SDKError { #expect(error.code == .backendProtocolMismatch) }
        }
    }
}

@Test func gatewayRejectsAssetAmountsOutsideExactJavaScriptIntegerRange() async throws {
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"u_asset","createdAt":1}"#),
        gatewayResponse(
            #"{"btc":{"vanilla":{"settled":0,"future":0,"spendable":0},"colored":{"settled":0,"future":0,"spendable":0}},"assets":[{"assetId":"rgb:large","balance":{"settled":9007199254740992,"future":0,"spendable":0}}]}"#
        ),
    ])
    let (backend, context) = try await initializedGateway(transport: transport)

    do {
        _ = try await backend.getAssetBalance(context: context, assetID: AssetID("rgb:large"))
        Issue.record("expected an exact-integer range rejection")
    } catch let error as SDKError {
        #expect(error.code == .backendProtocolMismatch)
        #expect(!error.message.contains("9007199254740992"))
    }
}

@Test func gatewayPrepareBindsCallerIntentAndConvertsMillisecondsConservatively() async throws {
    let address = "bcrt1pintentaddress000000000000000000000000000000000000000000000"
    let psbt = Data(repeating: 0x42, count: 32).base64EncodedString()
    let opID = "11111111-1111-4111-8111-111111111111"
    let response = """
    {"opId":"\(opID)","psbt":"\(psbt)","intent":{"kind":"send_btc","feeRateSatPerVb":2,"recipients":[{"address":"\(address)","scriptHex":"0014","amountSat":10000}],"asset":null,"utxos":null},"expiresAt":2000999}
    """
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"u_prepare","createdAt":1}"#),
        gatewayResponse(response, statusCode: 201),
    ])
    let (backend, context) = try await initializedGateway(transport: transport)
    let operationContext = try gatewayOperationContext(backend: context, key: "idempotency-1")
    let send = try SendBtcRequest(
        address: BitcoinAddress(address),
        amount: Satoshis(10_000),
        feeRate: FeeRate(milliSatsPerVByte: 2_000),
        idempotencyKey: IdempotencyKey("idempotency-1")
    )

    let prepared = try await backend.prepareSendBtc(.init(context: operationContext, request: send))
    #expect(prepared.operationID.value == opID)
    #expect(prepared.idempotencyKey.value == "idempotency-1")
    #expect(prepared.requestHash == operationContext.requestHash)
    #expect(prepared.network == .regtest)
    #expect(prepared.operation == .sendBtc)
    #expect(prepared.psbtBase64 == psbt)
    #expect(prepared.expiresAt.rawValue == 2_000)

    let requests = await transport.snapshot()
    #expect(requests.count == 2)
    #expect(requests[1].url.path == "/v1/onchain/send-btc/prepare")
    #expect(
        requests[1].headers["Idempotency-Key"]
            == "4958bc464e91725845ab2c0403a94809b6628f2fcec1cba0ee8ac8ad96088223"
    )
    let requestBody = try jsonObject(try #require(requests[1].body))
    #expect((requestBody["amountSat"] as? NSNumber)?.uint64Value == 10_000)
    #expect((requestBody["feeRateSatPerVb"] as? NSNumber)?.uint64Value == 2)
    #expect(requestBody["address"] as? String == address)
}

@Test func gatewayRejectsFractionalFeesBeforePrepareRequest() async throws {
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"u_fractional","createdAt":1}"#),
    ])
    let (backend, context) = try await initializedGateway(transport: transport)
    let operationContext = try gatewayOperationContext(backend: context, key: "fractional")
    let send = try SendBtcRequest(
        address: BitcoinAddress("bcrt1pfractionaladdress"),
        amount: Satoshis(10_000),
        feeRate: FeeRate(milliSatsPerVByte: 1_500),
        idempotencyKey: IdempotencyKey("fractional")
    )

    do {
        _ = try await backend.prepareSendBtc(.init(context: operationContext, request: send))
        Issue.record("expected fractional fee rejection")
    } catch let error as SDKError {
        #expect(error.code == .invalidArgument)
    }
    #expect(await transport.snapshot().count == 1)
}

@Test func gatewayRejectsSkipSyncBeforePrepareRequest() async throws {
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"u_skip_sync","createdAt":1}"#),
    ])
    let (backend, context) = try await initializedGateway(transport: transport)
    let operationContext = try gatewayOperationContext(backend: context, key: "skip-sync")
    let send = try SendBtcRequest(
        address: BitcoinAddress("bcrt1pskipsyncaddress"),
        amount: Satoshis(10_000),
        feeRate: FeeRate(milliSatsPerVByte: 2_000),
        skipSync: true,
        idempotencyKey: IdempotencyKey("skip-sync")
    )

    do {
        _ = try await backend.prepareSendBtc(.init(context: operationContext, request: send))
        Issue.record("expected unsupported skipSync rejection")
    } catch let error as SDKError {
        #expect(error.code == .unsupported)
    }
    #expect(await transport.snapshot().count == 1)
}

@Test func gatewayRejectsPrepareIntentMismatchWithoutReturningPsbt() async throws {
    let address = "bcrt1pexpectedaddress"
    let psbt = Data(repeating: 0x23, count: 32).base64EncodedString()
    let response = """
    {"opId":"22222222-2222-4222-8222-222222222222","psbt":"\(psbt)","intent":{"kind":"send_btc","feeRateSatPerVb":2,"recipients":[{"address":"bcrt1pattackeraddress","scriptHex":"0014","amountSat":10000}],"asset":null,"utxos":null},"expiresAt":2000000}
    """
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"u_mismatch","createdAt":1}"#),
        gatewayResponse(response, statusCode: 201),
    ])
    let (backend, context) = try await initializedGateway(transport: transport)
    let operationContext = try gatewayOperationContext(backend: context, key: "mismatch")
    let send = try SendBtcRequest(
        address: BitcoinAddress(address),
        amount: Satoshis(10_000),
        feeRate: FeeRate(milliSatsPerVByte: 2_000),
        idempotencyKey: IdempotencyKey("mismatch")
    )

    do {
        _ = try await backend.prepareSendBtc(.init(context: operationContext, request: send))
        Issue.record("expected caller-intent mismatch")
    } catch let error as SDKError {
        #expect(error.code == .backendProtocolMismatch)
    }
}

@Test func gatewayRejectsStalePrepareExpiry() async throws {
    let address = "bcrt1pexpiredaddress"
    let psbt = Data(repeating: 0x31, count: 32).base64EncodedString()
    let response = """
    {"opId":"55555555-5555-4555-8555-555555555555","psbt":"\(psbt)","intent":{"kind":"send_btc","feeRateSatPerVb":2,"recipients":[{"address":"\(address)","scriptHex":"0014","amountSat":10000}],"asset":null,"utxos":null},"expiresAt":1000000}
    """
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"u_expired","createdAt":1}"#),
        gatewayResponse(response, statusCode: 201),
    ])
    let (backend, context) = try await initializedGateway(transport: transport)
    let operationContext = try gatewayOperationContext(backend: context, key: "expired")
    let send = try SendBtcRequest(
        address: BitcoinAddress(address),
        amount: Satoshis(10_000),
        feeRate: FeeRate(milliSatsPerVByte: 2_000),
        idempotencyKey: IdempotencyKey("expired")
    )

    do {
        _ = try await backend.prepareSendBtc(.init(context: operationContext, request: send))
        Issue.record("expected stale expiry rejection")
    } catch let error as SDKError {
        #expect(error.code == .backendProtocolMismatch)
    }
}

@Test func gatewayNeverCopiesBackendMessageIntoLogSafeError() async throws {
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"u_error","createdAt":1}"#),
        gatewayResponse(
            #"{"error":{"code":"BAD_REQUEST","message":"mnemonic=never expose this"}}"#,
            statusCode: 400
        ),
    ])
    let (backend, context) = try await initializedGateway(transport: transport)

    do {
        _ = try await backend.getBtcBalance(context: context)
        Issue.record("expected backend rejection")
    } catch let error as SDKError {
        #expect(error.code == .backendRejected)
        #expect(error.message == "The gateway rejected the request contract")
        #expect(!error.message.contains("mnemonic"))
        #expect(error.details["backendCode"] == "BAD_REQUEST")
    }
}

@Test func gatewayTreatsRedirectResponseAsProtocolViolation() async throws {
    let transport = GatewayStubTransport(responses: [
        gatewayResponse("redirect", statusCode: 302, mimeType: "text/plain"),
    ])
    let backend = GatewayWalletBackend(
        configuration: try gatewayConfiguration(),
        transport: transport
    )

    do {
        _ = try await backend.initialize(
            .init(
                walletID: WalletID("wallet-redirect"),
                network: .regtest,
                minimumAPIVersion: 1,
                maximumAPIVersion: 1
            )
        )
        Issue.record("expected redirect rejection")
    } catch let error as SDKError {
        #expect(error.code == .backendProtocolMismatch)
    }
    #expect(await transport.snapshot().count == 1)
}

@Test func gatewayRequiresExactReadSuccessStatus() async throws {
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"u_wrong_status","createdAt":1}"#, statusCode: 201),
    ])
    let backend = GatewayWalletBackend(
        configuration: try gatewayConfiguration(),
        transport: transport
    )

    do {
        _ = try await backend.initialize(
            .init(
                walletID: WalletID("wallet-wrong-status"),
                network: .regtest,
                minimumAPIVersion: 1,
                maximumAPIVersion: 1
            )
        )
        Issue.record("expected exact-status protocol rejection")
    } catch let error as SDKError {
        #expect(error.code == .backendProtocolMismatch)
    }
}

@Test func gatewayCompletionUsesDistinctDeterministicIdempotencyKey() async throws {
    let txid = String(repeating: "c", count: 64)
    let operationID = try OperationID("33333333-3333-4333-8333-333333333333")
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"u_complete","createdAt":1}"#),
        gatewayResponse("{\"txid\":\"\(txid)\"}"),
    ])
    let (backend, context) = try await initializedGateway(transport: transport)
    let operationContext = try gatewayOperationContext(backend: context, key: "idempotency-1")
    let signedPSBT = Data(repeating: 0x55, count: 40).base64EncodedString()
    let validation = try LocalValidationReport(
        psbtSHA256: String(repeating: "a", count: 64),
        intentSHA256: String(repeating: "b", count: 64),
        unsignedTxid: TransactionID(txid),
        totalInput: Satoshis(1_000),
        totalOutput: Satoshis(900),
        fee: Satoshis(100),
        estimatedVbytes: 100,
        feeRate: FeeRate(milliSatsPerVByte: 1_000),
        externalOutput: Satoshis(800),
        change: Satoshis(100),
        inputCount: 1,
        outputCount: 2,
        opReturnCount: 0
    )
    let submission = try SignedTransactionSubmission(
        context: operationContext,
        operationID: operationID,
        signedPsbtBase64: signedPSBT,
        validation: validation
    )

    let result = try await backend.submitSignedTransaction(submission)
    guard case let .sendBtc(returnedOperationID, returnedTxid) = result else {
        Issue.record("expected send-BTC result")
        return
    }
    #expect(returnedOperationID == operationID)
    #expect(returnedTxid.hex == txid)
    let request = try #require(await transport.snapshot().last)
    #expect(request.url.path == "/v1/onchain/send-btc/complete")
    #expect(
        request.headers["Idempotency-Key"]
            == "438d6a09d58b7f501b78ffca3f93dfd701a1b54a0e70038fddc923e984d96ff9"
    )
    #expect(request.headers["Idempotency-Key"] != "idempotency-1")
}

@Test func gatewayCompletionMalformedSuccessIsAmbiguous() async throws {
    let txid = String(repeating: "c", count: 64)
    let operationID = try OperationID("77777777-7777-4777-8777-777777777777")
    let responses = [
        (
            "malformed JSON",
            gatewayResponse(#"{"txid":"#, statusCode: 200)
        ),
        (
            "incorrect media type",
            gatewayResponse("{\"txid\":\"\(txid)\"}", statusCode: 200, mimeType: "text/plain")
        ),
    ]

    for (scenario, completionResponse) in responses {
        let transport = GatewayStubTransport(responses: [
            gatewayResponse(#"{"userId":"u_untrusted_success","createdAt":1}"#),
            completionResponse,
        ])
        let (backend, context) = try await initializedGateway(transport: transport)
        let submission = try gatewaySignedSubmission(
            backend: context,
            operationID: operationID,
            txid: txid
        )

        do {
            _ = try await backend.submitSignedTransaction(submission)
            Issue.record("expected ambiguous completion for \(scenario)")
        } catch let error as SDKError {
            #expect(error.code == .operationAmbiguous)
            #expect(error.operationID == operationID)
        }
    }
}

@Test func gatewayCompletionUnexpectedSuccessStatusIsAmbiguous() async throws {
    let txid = String(repeating: "c", count: 64)
    let operationID = try OperationID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"u_complete_status","createdAt":1}"#),
        gatewayResponse("{\"txid\":\"\(txid)\"}", statusCode: 201),
    ])
    let (backend, context) = try await initializedGateway(transport: transport)
    let submission = try gatewaySignedSubmission(
        backend: context,
        operationID: operationID,
        txid: txid
    )

    do {
        _ = try await backend.submitSignedTransaction(submission)
        Issue.record("expected ambiguous completion status")
    } catch let error as SDKError {
        #expect(error.code == .operationAmbiguous)
        #expect(error.operationID == operationID)
    }
}

@Test func gatewayCompletionInvalidOrMismatchingTxidIsAmbiguous() async throws {
    let expectedTxid = String(repeating: "c", count: 64)
    let operationID = try OperationID("88888888-8888-4888-8888-888888888888")
    let responses = [
        ("invalid transaction ID", gatewayResponse(#"{"txid":"not-a-txid"}"#)),
        ("noncanonical uppercase transaction ID", gatewayResponse("{\"txid\":\"\(expectedTxid.uppercased())\"}")),
        ("noncanonical whitespace transaction ID", gatewayResponse("{\"txid\":\" \(expectedTxid) \"}")),
        (
            "different transaction ID",
            gatewayResponse("{\"txid\":\"\(String(repeating: "d", count: 64))\"}")
        ),
    ]

    for (scenario, completionResponse) in responses {
        let transport = GatewayStubTransport(responses: [
            gatewayResponse(#"{"userId":"u_bad_txid","createdAt":1}"#),
            completionResponse,
        ])
        let (backend, context) = try await initializedGateway(transport: transport)
        let submission = try gatewaySignedSubmission(
            backend: context,
            operationID: operationID,
            txid: expectedTxid
        )

        do {
            _ = try await backend.submitSignedTransaction(submission)
            Issue.record("expected ambiguous completion for \(scenario)")
        } catch let error as SDKError {
            #expect(error.code == .operationAmbiguous)
            #expect(error.operationID == operationID)
        }
    }
}

@Test func gatewayCompletionDoesNotInventDefinitivePreBroadcastRejection() async throws {
    let txid = String(repeating: "c", count: 64)
    let operationID = try OperationID("99999999-9999-4999-8999-999999999999")
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"u_definite_rejection","createdAt":1}"#),
        gatewayResponse(
            #"{"error":{"code":"PSBT_MISMATCH","message":"hostile signed PSBT detail"}}"#,
            statusCode: 400
        ),
    ])
    let (backend, context) = try await initializedGateway(transport: transport)
    let submission = try gatewaySignedSubmission(
        backend: context,
        operationID: operationID,
        txid: txid
    )

    do {
        _ = try await backend.submitSignedTransaction(submission)
        Issue.record("expected ambiguous PSBT rejection")
    } catch let error as SDKError {
        #expect(error.code == .operationAmbiguous)
        #expect(error.operationID == operationID)
        #expect(!error.message.contains("hostile signed PSBT detail"))
    }
}

@Test func gatewayAlreadyCompletedNeverLooksLikeASafeRejection() async throws {
    let txid = String(repeating: "c", count: 64)
    let operationID = try OperationID("33333333-3333-4333-8333-333333333333")
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"u_complete_ambiguous","createdAt":1}"#),
        gatewayResponse(
            #"{"error":{"code":"OP_ALREADY_COMPLETED","message":"already completed"}}"#,
            statusCode: 409
        ),
    ])
    let (backend, context) = try await initializedGateway(transport: transport)
    let operationContext = try gatewayOperationContext(backend: context, key: "idempotency-1")
    let validation = try LocalValidationReport(
        psbtSHA256: String(repeating: "a", count: 64),
        intentSHA256: String(repeating: "b", count: 64),
        unsignedTxid: TransactionID(txid),
        totalInput: Satoshis(1_000),
        totalOutput: Satoshis(900),
        fee: Satoshis(100),
        estimatedVbytes: 100,
        feeRate: FeeRate(milliSatsPerVByte: 1_000),
        externalOutput: Satoshis(800),
        change: Satoshis(100),
        inputCount: 1,
        outputCount: 2,
        opReturnCount: 0
    )
    let submission = try SignedTransactionSubmission(
        context: operationContext,
        operationID: operationID,
        signedPsbtBase64: Data(repeating: 0x55, count: 40).base64EncodedString(),
        validation: validation
    )

    do {
        _ = try await backend.submitSignedTransaction(submission)
        Issue.record("expected an ambiguous completed operation")
    } catch let error as SDKError {
        #expect(error.code == .operationAmbiguous)
        #expect(error.operationID == operationID)
    }
}

@Test func gatewayFiveHundredCannotMasqueradeAsDefinitiveIdempotencyConflict() async throws {
    let txid = String(repeating: "c", count: 64)
    let operationID = try OperationID("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"u_false_conflict","createdAt":1}"#),
        gatewayResponse(
            #"{"error":{"code":"IDEMPOTENCY_KEY_REUSED","message":"misleading"}}"#,
            statusCode: 502
        ),
    ])
    let (backend, context) = try await initializedGateway(transport: transport)
    let submission = try gatewaySignedSubmission(
        backend: context,
        operationID: operationID,
        txid: txid
    )

    do {
        _ = try await backend.submitSignedTransaction(submission)
        Issue.record("expected transient completion failure")
    } catch let error as SDKError {
        // The coordinator reconciles backend-unavailable from SUBMITTING and,
        // without a status endpoint, reports operation.ambiguous.
        #expect(error.code == .backendUnavailable)
        #expect(error.code != .operationConflict)
    }
}

@Test func gatewayUnknownCompletionConflictIsAmbiguous() async throws {
    let txid = String(repeating: "c", count: 64)
    let operationID = try OperationID("cccccccc-cccc-4ccc-8ccc-cccccccccccc")
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"u_unknown_conflict","createdAt":1}"#),
        gatewayResponse(
            #"{"error":{"code":"malformed code","message":"untrusted"}}"#,
            statusCode: 409
        ),
    ])
    let (backend, context) = try await initializedGateway(transport: transport)
    let submission = try gatewaySignedSubmission(
        backend: context,
        operationID: operationID,
        txid: txid
    )

    do {
        _ = try await backend.submitSignedTransaction(submission)
        Issue.record("expected ambiguous unknown conflict")
    } catch let error as SDKError {
        #expect(error.code == .operationAmbiguous)
        #expect(error.operationID == operationID)
    }
}

@Test func gatewayCompletionOperationKindMismatchPreservesAmbiguity() async throws {
    let txid = String(repeating: "e", count: 64)
    let operationID = try OperationID("66666666-6666-4666-8666-666666666666")
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"u_kind_mismatch","createdAt":1}"#),
        gatewayResponse(
            #"{"error":{"code":"OP_KIND_MISMATCH","message":"hostile detail"}}"#,
            statusCode: 409
        ),
    ])
    let (backend, context) = try await initializedGateway(transport: transport)
    let submission = try gatewaySignedSubmission(
        backend: context,
        operationID: operationID,
        txid: txid
    )

    do {
        _ = try await backend.submitSignedTransaction(submission)
        Issue.record("expected ambiguous operation-kind completion response")
    } catch let error as SDKError {
        #expect(error.code == .operationAmbiguous)
        #expect(error.retryable)
        #expect(error.operationID == operationID)
        #expect(!error.message.contains("hostile detail"))
    }
}

@Test func gatewayStatusWithoutLocalSigningEvidenceFailsClosedBeforeHTTP() async throws {
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"u_status","createdAt":1}"#),
    ])
    let (backend, context) = try await initializedGateway(transport: transport)

    do {
        _ = try await backend.getOperation(
            context: context,
            operationID: OperationID("44444444-4444-4444-8444-444444444444")
        )
        Issue.record("expected unsupported reconciliation")
    } catch let error as SDKError {
        #expect(error.code == .unsupported)
    }
    #expect(await transport.snapshot().count == 1)
}

@Test func gatewayCompletedStatusRecoversAfterRestartWithProfileDisabledAndOldExpiry() async throws {
    let fixture = try await gatewayStatusFixture(
        response: gatewayResponse(try gatewayStatusJSON()), profileEnabled: false
    )
    let result = try await fixture.recover()
    #expect(result == fixture.checkpoint.validation?.unsignedTxid)
    let stored = try #require(await fixture.journal.load(
        walletID: fixture.context.walletID, idempotencyKey: fixture.request.idempotencyKey
    ))
    #expect(stored.phase == .terminal)
    #expect(stored.preparedTransaction == fixture.checkpoint.preparedTransaction)
    #expect(stored.signedPsbtBase64 == fixture.checkpoint.signedPsbtBase64)
    #expect(stored.validation == fixture.checkpoint.validation)
    // Terminal replay has no HTTP, signing, prepare, or complete side effect.
    #expect(try await fixture.recover() == result)
    let requests = await fixture.transport.snapshot()
    #expect(requests.map(\.method) == [.get, .get])
    #expect(requests.map(\.url.path) == ["/v1/me", "/v1/onchain/operations/17171717-1717-4717-8717-171717171717"])
    #expect(requests.last?.headers["Idempotency-Key"] == nil)
    #expect(requests.last?.body == nil)
}

@Test func gatewayNoncompletedStatusNeverAuthorizesRetryOrTerminalExpiry() async throws {
    for state in ["pending", "expired"] {
        for hasTxid in [false, true] {
            let body = try gatewayStatusJSON {
                $0["state"] = state
                $0["txid"] = hasTxid ? String(repeating: "e", count: 64) : NSNull()
                $0["mayHaveBroadcast"] = hasTxid
            }
            let fixture = try await gatewayStatusFixture(response: gatewayResponse(body))
            await fixture.expectAmbiguousAndUnchanged()
            #expect(await fixture.transport.snapshot().map(\.method) == [.get, .get])
        }
    }
}

@Test func gatewayRecoveryRejectsEveryMalformedOrUnboundStatus() async throws {
    let mutations: [(String, (inout [String: Any]) -> Void)] = [
        ("different operation", { $0["opId"] = "18181818-1818-4818-8818-181818181818" }),
        ("malformed operation", { $0["opId"] = "../wallet/balances" }),
        ("wrong kind", { $0["kind"] = "create_utxos" }),
        ("unknown lifecycle", { $0["state"] = "failed" }),
        ("missing txid", { $0.removeValue(forKey: "txid") }),
        ("null completed txid", { $0["txid"] = NSNull() }),
        ("wrong txid", { $0["txid"] = String(repeating: "f", count: 64) }),
        ("uppercase txid", { $0["txid"] = String(repeating: "E", count: 64) }),
        ("malformed txid", { $0["txid"] = "untrusted backend error" }),
        ("contradictory completed flag", { $0["mayHaveBroadcast"] = true }),
        ("missing flag", { $0.removeValue(forKey: "mayHaveBroadcast") }),
        ("wrong flag type", { $0["mayHaveBroadcast"] = "false" }),
        ("zero creation", { $0["createdAt"] = 0 }),
        ("negative creation", { $0["createdAt"] = -1 }),
        ("fractional creation", { $0["createdAt"] = 1.5 }),
        ("inverted timestamps", { $0["createdAt"] = 1_001_999 }),
        ("changed expiry", { $0["expiresAt"] = 1_002_000 }),
        ("unsafe JSON timestamp", { $0["expiresAt"] = 9_007_199_254_740_992 as UInt64 }),
        ("wrong intent kind", { var i = $0["intent"] as! [String: Any]; i["kind"] = "send_asset"; $0["intent"] = i }),
        ("different fee", { var i = $0["intent"] as! [String: Any]; i["feeRateSatPerVb"] = 3; $0["intent"] = i }),
        ("smuggled RGB allowance", { var i = $0["intent"] as! [String: Any]; i["asset"] = [:] as [String: Any]; $0["intent"] = i }),
        ("smuggled UTXO allowance", { var i = $0["intent"] as! [String: Any]; i["utxos"] = [:] as [String: Any]; $0["intent"] = i }),
        ("missing intent field", { var i = $0["intent"] as! [String: Any]; i.removeValue(forKey: "asset"); $0["intent"] = i }),
        ("extra recipient", { var i = $0["intent"] as! [String: Any]; let r = i["recipients"] as! [[String: Any]]; i["recipients"] = r + r; $0["intent"] = i }),
    ]
    for (name, mutate) in mutations {
        let fixture = try await gatewayStatusFixture(response: gatewayResponse(try gatewayStatusJSON(mutate)))
        await fixture.expectAmbiguousAndUnchanged()
        #expect(await fixture.transport.snapshot().count == 2, "\(name)")
    }
    for (field, value) in [("address", "bcrt1pattackeraddress" as Any), ("amountSat", 10_001 as Any), ("scriptHex", "GG" as Any), ("scriptHex", "AA" as Any), ("scriptHex", "" as Any)] {
        let fixture = try await gatewayStatusFixture(response: gatewayResponse(try gatewayStatusJSON {
            var intent = $0["intent"] as! [String: Any]
            var recipients = intent["recipients"] as! [[String: Any]]
            recipients[0][field] = value
            intent["recipients"] = recipients
            $0["intent"] = intent
        }))
        await fixture.expectAmbiguousAndUnchanged()
    }
}

@Test func gatewayRecoveryHTTPFailuresDoNotLoseSignedEvidence() async throws {
    for response in [
        gatewayResponse(#"{"error":{"code":"OP_NOT_FOUND"}}"#, statusCode: 404),
        gatewayResponse(#"{"error":{"code":"UNAUTHORIZED"}}"#, statusCode: 401),
        gatewayResponse(#"{"error":{"code":"OP_EXPIRED"}}"#, statusCode: 410),
        gatewayResponse(#"{"error":{"code":"INTERNAL"}}"#, statusCode: 502),
        gatewayResponse("{}", statusCode: 302),
        gatewayResponse("{malformed"),
        gatewayResponse(try gatewayStatusJSON(), statusCode: 201),
        gatewayResponse(try gatewayStatusJSON(), mimeType: "text/plain"),
    ] {
        let fixture = try await gatewayStatusFixture(response: response)
        await fixture.expectAmbiguousAndUnchanged()
        #expect(await fixture.transport.snapshot().map(\.method) == [.get, .get])
    }
}

@Test func gatewayAmbiguousCompletionImmediatelyPerformsOneReadOnlyReconciliation() async throws {
    for response in [
        gatewayResponse("<html>proxy error</html>", statusCode: 400, mimeType: "text/html"),
        gatewayResponse(#"{"error":{"code":"UNREVIEWED_ERROR"}}"#, statusCode: 400),
        gatewayResponse(#"{"error":{"code":"PSBT_MISMATCH"}}"#, statusCode: 400),
        gatewayResponse(#"{"error":{"code":"FORBIDDEN"}}"#, statusCode: 403),
        gatewayResponse(#"{"error":{"code":"OP_NOT_FOUND"}}"#, statusCode: 404),
        gatewayResponse(#"{"error":{"code":"OP_ALREADY_COMPLETED"}}"#, statusCode: 409),
        gatewayResponse(#"{"error":{"code":"IDEMPOTENCY_KEY_REUSED"}}"#, statusCode: 409),
        gatewayResponse(#"{"error":{"code":"OP_KIND_MISMATCH"}}"#, statusCode: 409),
        gatewayResponse(#"{"error":{"code":"OP_EXPIRED"}}"#, statusCode: 410),
        gatewayResponse(#"{"error":{"code":"COMPLETE_AMBIGUOUS"}}"#, statusCode: 502),
        gatewayResponse(#"{"txid":"malformed"}"#),
    ] {
        let fixture = try await gatewayStatusFixture(
            response: response, phase: .signed, followingResponses: [gatewayResponse(try gatewayStatusJSON())]
        )
        #expect(try await fixture.recover() == fixture.checkpoint.validation?.unsignedTxid)
        let requests = await fixture.transport.snapshot()
        #expect(requests.map(\.method) == [.get, .post, .get])
        #expect(requests[1].url.path == "/v1/onchain/send-btc/complete")
        #expect(requests[2].url.path == "/v1/onchain/operations/17171717-1717-4717-8717-171717171717")
    }
}

@Test func gatewayCompletionExpiryWithExpiredNullStatusRemainsSubmitting() async throws {
    let body = try gatewayStatusJSON {
        $0["state"] = "expired"; $0["txid"] = NSNull(); $0["mayHaveBroadcast"] = false
    }
    let fixture = try await gatewayStatusFixture(
        response: gatewayResponse(#"{"error":{"code":"OP_EXPIRED"}}"#, statusCode: 410),
        phase: .signed, followingResponses: [gatewayResponse(body)]
    )
    do { _ = try await fixture.recover(); Issue.record("expected ambiguity") }
    catch let error as SDKError { #expect(error.code == .operationAmbiguous) }
    let stored = try #require(await fixture.journal.load(walletID: fixture.context.walletID, idempotencyKey: fixture.request.idempotencyKey))
    #expect(stored.phase == .submitting)
    #expect(stored.terminalOutcome == nil)
    #expect(stored.signedPsbtBase64 == fixture.checkpoint.signedPsbtBase64)
    #expect(await fixture.transport.snapshot().map(\.method) == [.get, .post, .get])
}

@Test func unknownCompletionRejectionRetainsSignedEvidenceAndNextCallOnlyPolls() async throws {
    let pending = try gatewayStatusJSON {
        $0["state"] = "pending"; $0["txid"] = NSNull(); $0["mayHaveBroadcast"] = false
    }
    for response in [
        gatewayResponse("<html>upstream rejected</html>", statusCode: 400, mimeType: "text/html"),
        gatewayResponse(#"{"error":{"code":"UNREVIEWED_ERROR"}}"#, statusCode: 422),
        gatewayResponse(#"{"error":{"code":"PSBT_MISMATCH"}}"#, statusCode: 400),
        gatewayResponse(#"{"error":{"code":"IDEMPOTENCY_KEY_REUSED"}}"#, statusCode: 409),
        gatewayResponse(#"{"error":{"code":"OP_KIND_MISMATCH"}}"#, statusCode: 409),
    ] {
        let fixture = try await gatewayStatusFixture(
            response: response, phase: .signed,
            followingResponses: [gatewayResponse(pending), gatewayResponse(try gatewayStatusJSON())]
        )
        do { _ = try await fixture.recover(); Issue.record("expected ambiguity") }
        catch let error as SDKError { #expect(error.code == .operationAmbiguous) }
        let stored = try #require(await fixture.journal.load(
            walletID: fixture.context.walletID, idempotencyKey: fixture.request.idempotencyKey
        ))
        #expect(stored.phase == .submitting && stored.terminalOutcome == nil)
        #expect(stored.signedPsbtBase64 == fixture.checkpoint.signedPsbtBase64)
        #expect(try await fixture.recover() == fixture.checkpoint.validation?.unsignedTxid)
        #expect(await fixture.transport.snapshot().map(\.method) == [.get, .post, .get, .get])
    }
}

@Test func knownCompletionConflictsRetainIdentityThroughFailedReconciliation() async throws {
    for code in ["IDEMPOTENCY_KEY_REUSED", "OP_KIND_MISMATCH"] {
        for status in [401, 404, 500] {
            let fixture = try await gatewayStatusFixture(
                response: gatewayResponse("{\"error\":{\"code\":\"\(code)\"}}", statusCode: 409),
                phase: .signed,
                followingResponses: [gatewayResponse("{}", statusCode: status), gatewayResponse(try gatewayStatusJSON())]
            )
            do { _ = try await fixture.recover(); Issue.record("expected ambiguity") }
            catch let error as SDKError {
                #expect(error.code == .operationAmbiguous)
                #expect(error.retryable)
                #expect(error.operationID == fixture.checkpoint.operationID)
            }
            let retained = try #require(await fixture.journal.load(
                walletID: fixture.context.walletID, idempotencyKey: fixture.request.idempotencyKey
            ))
            #expect(retained.phase == .submitting && retained.terminalOutcome == nil)
            #expect(retained.signedPsbtBase64 == fixture.checkpoint.signedPsbtBase64)
            #expect(retained.validation == fixture.checkpoint.validation)
            #expect(await fixture.transport.snapshot().map(\.method) == [.get, .post, .get])
            #expect(try await fixture.recover() == fixture.checkpoint.validation?.unsignedTxid)
            #expect(await fixture.transport.snapshot().map(\.method) == [.get, .post, .get, .get])
        }
    }
}

@Test func prepareIdempotencyConflictRemainsAConflictBeforeSigning() async throws {
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"prepare-conflict","createdAt":1}"#),
        gatewayResponse(#"{"error":{"code":"IDEMPOTENCY_KEY_REUSED"}}"#, statusCode: 409),
    ])
    let (backend, context) = try await initializedGateway(transport: transport)
    let request = try gatewayRecoveryRequest(key: "prepare-conflict")
    let journal = InMemoryOperationJournal()
    let coordinator = OperationCoordinator(
        configuration: try WalletConfiguration(walletID: context.walletID, network: .regtest),
        backend: backend, journal: journal, now: { 1 }
    )
    do {
        _ = try await coordinator.sendBtc(backendContext: context, signer: GatewayNeverSigner(), request: request)
        Issue.record("expected prepare conflict")
    } catch let error as SDKError {
        #expect(error.code == .operationConflict && !error.retryable)
        #expect(error.details["idempotencyKey"] == request.idempotencyKey.value)
    }
    #expect(await transport.snapshot().map(\.url.path) == ["/v1/me", "/v1/onchain/send-btc/prepare"])
    #expect(await journal.load(walletID: context.walletID, idempotencyKey: request.idempotencyKey)?.phase == .created)
}

@Test func prepareOperationKindMismatchRemainsProtocolFailureBeforeSigning() async throws {
    let transport = GatewayStubTransport(responses: [
        gatewayResponse(#"{"userId":"prepare-kind-conflict","createdAt":1}"#),
        gatewayResponse(#"{"error":{"code":"OP_KIND_MISMATCH","message":"private-backend-detail"}}"#, statusCode: 409),
    ])
    let (backend, context) = try await initializedGateway(transport: transport)
    let request = try gatewayRecoveryRequest(key: "prepare-kind-conflict")
    let journal = InMemoryOperationJournal()
    let coordinator = OperationCoordinator(
        configuration: try WalletConfiguration(walletID: context.walletID, network: .regtest),
        backend: backend, journal: journal, now: { 1 }
    )
    do {
        _ = try await coordinator.sendBtc(backendContext: context, signer: GatewayNeverSigner(), request: request)
        Issue.record("expected prepare protocol failure")
    } catch let error as SDKError {
        #expect(error.code == .backendProtocolMismatch && !error.retryable)
        #expect(error.operationID == nil)
        #expect(!error.message.contains("private-backend-detail"))
    }
    #expect(await transport.snapshot().map(\.url.path) == ["/v1/me", "/v1/onchain/send-btc/prepare"])
    #expect(await journal.load(walletID: context.walletID, idempotencyKey: request.idempotencyKey)?.phase == .created)
}

@Test func completionConflictReconciliationCancellationPreservesEvidenceAndResumesReadOnly() async throws {
    for code in ["IDEMPOTENCY_KEY_REUSED", "OP_KIND_MISMATCH"] {
        let fixture = try await gatewayStatusFixture(
            response: gatewayResponse("{\"error\":{\"code\":\"\(code)\"}}", statusCode: 409),
            phase: .signed, followingResponses: [gatewayResponse(try gatewayStatusJSON())]
        )
        // GET me has already finished. Complete receives its 409; only the
        // immediately following status GET reports transport cancellation.
        await fixture.transport.cancelRequest(atOrdinal: 3)
        await #expect(throws: CancellationError.self) { try await fixture.recover() }
        let retained = try #require(await fixture.journal.load(
            walletID: fixture.context.walletID, idempotencyKey: fixture.request.idempotencyKey
        ))
        #expect(retained.phase == .submitting && retained.terminalOutcome == nil)
        #expect(retained.operationID == fixture.checkpoint.operationID)
        #expect(retained.requestHash == fixture.checkpoint.requestHash)
        #expect(retained.preparedTransaction == fixture.checkpoint.preparedTransaction)
        #expect(retained.signedPsbtBase64 == fixture.checkpoint.signedPsbtBase64)
        #expect(retained.validation == fixture.checkpoint.validation)
        #expect(await fixture.transport.snapshot().map(\.method) == [.get, .post, .get])
        #expect(try await fixture.recover() == fixture.checkpoint.validation?.unsignedTxid)
        #expect(await fixture.transport.snapshot().map(\.method) == [.get, .post, .get, .get])
    }
}

@Test func gatewayRecoveryRequiresOriginalRequestAndSignedJournalBeforeHTTP() async throws {
    let fixture = try await gatewayStatusFixture(response: gatewayResponse(try gatewayStatusJSON()))
    let changed = try SendBtcRequest(
        address: fixture.request.address, amount: Satoshis(10_001), feeRate: fixture.request.feeRate,
        idempotencyKey: fixture.request.idempotencyKey
    )
    await #expect(throws: SDKError.self) {
        try await fixture.backend.getOperationForRecovery(context: fixture.context, checkpoint: fixture.checkpoint, request: changed)
    }
    let unsigned = try gatewayRecoveryCheckpoint(
        phase: .signed, walletID: fixture.context.walletID, request: fixture.request,
        operationID: #require(fixture.checkpoint.operationID), txid: #require(fixture.checkpoint.validation?.unsignedTxid)
    )
    await #expect(throws: SDKError.self) {
        try await fixture.backend.getOperationForRecovery(context: fixture.context, checkpoint: unsigned, request: fixture.request)
    }
    #expect(await fixture.transport.snapshot().map(\.url.path) == ["/v1/me"])
}

@Test func gatewayRecoveryCancellationPreservesSubmittingAndCanResumeReadOnly() async throws {
    let fixture = try await gatewayStatusFixture(response: gatewayResponse(try gatewayStatusJSON()), profileEnabled: false)
    await fixture.transport.cancelNextRequest()
    await #expect(throws: CancellationError.self) { try await fixture.recover() }
    #expect(await fixture.journal.load(walletID: fixture.context.walletID, idempotencyKey: fixture.request.idempotencyKey) == fixture.checkpoint)
    #expect(try await fixture.recover() == fixture.checkpoint.validation?.unsignedTxid)
    #expect(await fixture.transport.snapshot().map(\.method) == [.get, .get, .get])
}

@Test func gatewayRecoveryRejectsCorruptedRetainedEvidenceBeforeHTTP() async throws {
    let fixture = try await gatewayStatusFixture(response: gatewayResponse(try gatewayStatusJSON()))
    for (prepared, signed, hash, operation) in [
        (nil, nil, String(repeating: "0", count: 64), nil),
        ("YQ", nil, nil, nil),
        (nil, "YQ", nil, nil),
        (nil, nil, nil, "not-a-gateway-uuid"),
    ] as [(String?, String?, String?, String?)] {
        let checkpoint = try gatewayRecoveryCheckpoint(
            phase: .submitting, walletID: fixture.context.walletID, request: fixture.request,
            operationID: operation.map { try OperationID($0) } ?? #require(fixture.checkpoint.operationID),
            txid: #require(fixture.checkpoint.validation?.unsignedTxid),
            preparedBase64: prepared, signedBase64: signed, validationPSBTHash: hash
        )
        await #expect(throws: SDKError.self) {
            try await fixture.backend.getOperationForRecovery(context: fixture.context, checkpoint: checkpoint, request: fixture.request)
        }
    }
    #expect(await fixture.transport.snapshot().map(\.url.path) == ["/v1/me"])
}

@Test func gatewayUnrelatedAmbiguousSubmissionErrorDoesNotTriggerStatusLookup() async throws {
    let fixture = try await gatewayStatusFixture(response: gatewayResponse(try gatewayStatusJSON()), phase: .signed)
    let otherID = try OperationID("18181818-1818-4818-8818-181818181818")
    await fixture.transport.failNextRequest(.operationAmbiguous(otherID))
    do { _ = try await fixture.recover(); Issue.record("expected unrelated ambiguity") }
    catch let error as SDKError {
        #expect(error.code == .operationAmbiguous)
        #expect(error.operationID == otherID)
    }
    #expect(await fixture.transport.snapshot().map(\.method) == [.get, .post])
    let stored = await fixture.journal.load(walletID: fixture.context.walletID, idempotencyKey: fixture.request.idempotencyKey)
    #expect(stored?.phase == .submitting)
    #expect(stored?.signedPsbtBase64 == fixture.checkpoint.signedPsbtBase64)
}

private struct GatewayStatusFixture {
    let backend: GatewayWalletBackend
    let context: BackendContext
    let checkpoint: OperationCheckpoint
    let request: SendBtcRequest
    let journal: InMemoryOperationJournal
    let coordinator: OperationCoordinator
    let transport: GatewayStubTransport

    func recover() async throws -> TransactionID {
        try await coordinator.sendBtc(backendContext: context, signer: GatewayNeverSigner(), request: request)
    }

    func expectAmbiguousAndUnchanged() async {
        do { _ = try await recover(); Issue.record("expected an ambiguous operation") }
        catch let error as SDKError {
            #expect(error.code == .operationAmbiguous)
            #expect(error.operationID == checkpoint.operationID)
        } catch { Issue.record("unexpected error type") }
        #expect(await journal.load(walletID: context.walletID, idempotencyKey: request.idempotencyKey) == checkpoint)
    }
}

private func gatewayStatusFixture(
    response: GatewayHTTPResponse,
    profileEnabled: Bool = true,
    phase: OperationPhase = .submitting,
    followingResponses: [GatewayHTTPResponse] = []
) async throws -> GatewayStatusFixture {
    let transport = GatewayStubTransport(responses: [gatewayResponse(#"{"userId":"recovery-user","createdAt":1}"#), response] + followingResponses)
    let backend = GatewayWalletBackend(configuration: try gatewayConfiguration(allowUnverifiedPsbtProfile: profileEnabled), transport: transport)
    let walletID = try WalletID("status-wallet")
    let session = try await backend.initialize(.init(walletID: walletID, network: .regtest, minimumAPIVersion: 1, maximumAPIVersion: 1))
    let context = BackendContext(session: session, walletID: walletID, network: .regtest)
    let request = try gatewayRecoveryRequest(key: "status-key")
    let checkpoint = try gatewayRecoveryCheckpoint(
        phase: phase, walletID: walletID, request: request,
        operationID: OperationID("17171717-1717-4717-8717-171717171717"),
        txid: TransactionID(String(repeating: "e", count: 64))
    )
    let journal = InMemoryOperationJournal()
    try await journal.save(checkpoint)
    let coordinator = OperationCoordinator(
        configuration: try WalletConfiguration(walletID: walletID, network: .regtest),
        backend: backend, journal: journal, now: { 1 }
    )
    return .init(backend: backend, context: context, checkpoint: checkpoint, request: request, journal: journal, coordinator: coordinator, transport: transport)
}

private func gatewayStatusJSON(_ mutate: (inout [String: Any]) -> Void = { _ in }) throws -> String {
    var value: [String: Any] = [
        "opId": "17171717-1717-4717-8717-171717171717", "kind": "send_btc", "state": "completed",
        "txid": String(repeating: "e", count: 64), "mayHaveBroadcast": false,
        "createdAt": 1_000_000, "expiresAt": 1_001_999,
        "intent": ["kind": "send_btc", "feeRateSatPerVb": 2, "asset": NSNull(), "utxos": NSNull(),
                   "recipients": [["address": "bcrt1precoveryaddress", "amountSat": 10_000, "scriptHex": "0014"]]],
    ]
    mutate(&value)
    return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
}

private func gatewayConfiguration(
    token: String = "unit-token",
    allowUnverifiedPsbtProfile: Bool = true
) throws -> GatewayBackendConfiguration {
    try GatewayBackendConfiguration(
        baseURL: #require(URL(string: "http://127.0.0.1:8480")),
        bearerToken: token,
        network: .regtest,
        allowInsecureLocalDevelopment: true,
        allowUnverifiedPsbtProfile: allowUnverifiedPsbtProfile
    )
}

private func gatewayRecoveryRequest(key: String) throws -> SendBtcRequest {
    try SendBtcRequest(
        address: BitcoinAddress("bcrt1precoveryaddress"),
        amount: Satoshis(10_000),
        feeRate: FeeRate(milliSatsPerVByte: 2_000),
        idempotencyKey: IdempotencyKey(key)
    )
}

private func gatewayRecoveryCheckpoint(
    phase: OperationPhase,
    walletID: WalletID,
    request: SendBtcRequest,
    operationID: OperationID,
    txid: TransactionID,
    preparedBase64: String? = nil,
    signedBase64: String? = nil,
    validationPSBTHash: String? = nil
) throws -> OperationCheckpoint {
    let requestHash = try RequestHasher.sendBtc(network: .regtest, request: request)
    let prepared = try PreparedTransaction(
        operationID: operationID,
        idempotencyKey: request.idempotencyKey,
        requestHash: requestHash,
        network: .regtest,
        operation: .sendBtc,
        psbtBase64: preparedBase64 ?? Data("prepared-psbt".utf8).base64EncodedString(),
        expiresAt: .init(rawValue: 1_001)
    )
    let validation = try LocalValidationReport(
        psbtSHA256: validationPSBTHash ?? SHA256.hash(data: Data("prepared-psbt".utf8)).map { String(format: "%02x", $0) }.joined(),
        intentSHA256: String(repeating: "b", count: 64),
        unsignedTxid: txid,
        totalInput: Satoshis(20_000),
        totalOutput: Satoshis(19_000),
        fee: Satoshis(1_000),
        estimatedVbytes: 100,
        feeRate: FeeRate(milliSatsPerVByte: 10_000),
        externalOutput: Satoshis(10_000),
        change: Satoshis(9_000),
        inputCount: 1,
        outputCount: 2,
        opReturnCount: 0
    )
    return try OperationCheckpoint(
        walletID: walletID,
        idempotencyKey: request.idempotencyKey,
        requestHash: requestHash,
        operationKind: .sendBtc,
        phase: phase,
        operationID: operationID,
        preparedTransaction: prepared,
        signedPsbtBase64: signedBase64 ?? Data("signed-psbt".utf8).base64EncodedString(),
        validation: validation,
        terminalOutcome: phase == .terminal
            ? .succeeded(.sendBtc(operationID: operationID, txid: txid))
            : nil
    )
}

private func initializedGateway(
    transport: GatewayStubTransport
) async throws -> (GatewayWalletBackend, BackendContext) {
    let configuration = try gatewayConfiguration()
    let backend = GatewayWalletBackend(
        configuration: configuration,
        transport: transport,
        nowMilliseconds: { 1_000_000 }
    )
    let walletID = try WalletID("wallet-test")
    let session = try await backend.initialize(
        .init(walletID: walletID, network: .regtest, minimumAPIVersion: 1, maximumAPIVersion: 1)
    )
    return (backend, .init(session: session, walletID: walletID, network: .regtest))
}

private func gatewayOperationContext(
    backend: BackendContext,
    key: String
) throws -> OperationRequestContext {
    .init(
        backend: backend,
        idempotencyKey: try IdempotencyKey(key),
        requestHash: try RequestHash(validating: String(repeating: "d", count: 64))
    )
}

private func gatewaySignedSubmission(
    backend: BackendContext,
    operationID: OperationID,
    txid: String
) throws -> SignedTransactionSubmission {
    let operationContext = try gatewayOperationContext(backend: backend, key: "idempotency-1")
    let validation = try LocalValidationReport(
        psbtSHA256: String(repeating: "a", count: 64),
        intentSHA256: String(repeating: "b", count: 64),
        unsignedTxid: TransactionID(txid),
        totalInput: Satoshis(1_000),
        totalOutput: Satoshis(900),
        fee: Satoshis(100),
        estimatedVbytes: 100,
        feeRate: FeeRate(milliSatsPerVByte: 1_000),
        externalOutput: Satoshis(800),
        change: Satoshis(100),
        inputCount: 1,
        outputCount: 2,
        opReturnCount: 0
    )
    return try SignedTransactionSubmission(
        context: operationContext,
        operationID: operationID,
        signedPsbtBase64: Data(repeating: 0x55, count: 40).base64EncodedString(),
        validation: validation
    )
}

private func gatewayResponse(
    _ body: String,
    statusCode: Int = 200,
    mimeType: String? = "application/json"
) -> GatewayHTTPResponse {
    .init(
        statusCode: statusCode,
        mimeType: mimeType,
        correlationID: nil,
        body: Data(body.utf8)
    )
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw SDKError.invariant("test request body was not a JSON object")
    }
    return object
}

private actor GatewayStubTransport: GatewayHTTPTransport {
    private var responses: [GatewayHTTPResponse]
    private var requests: [GatewayHTTPRequest] = []
    private var cancelNext = false
    private var cancellationOrdinal: Int?
    private var nextError: SDKError?

    init(responses: [GatewayHTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: GatewayHTTPRequest) async throws -> GatewayHTTPResponse {
        requests.append(request)
        if cancelNext || cancellationOrdinal == requests.count {
            cancelNext = false; cancellationOrdinal = nil
            throw CancellationError()
        }
        if let error = nextError { nextError = nil; throw error }
        guard !responses.isEmpty else {
            throw SDKError.invariant("test transport has no queued response")
        }
        return responses.removeFirst()
    }

    func snapshot() -> [GatewayHTTPRequest] { requests }
    func cancelNextRequest() { cancelNext = true }
    func cancelRequest(atOrdinal ordinal: Int) { cancellationOrdinal = ordinal }
    func failNextRequest(_ error: SDKError) { nextError = error }
}

private struct GatewayNeverSigner: LocalSigningEngine {
    let capabilities = WalletCapabilities.locked

    func identity() throws -> WalletIdentity {
        throw SDKError.invariant("unexpected identity")
    }

    func verifyReservedAddress(_ reservation: ReservedAddress) throws {
        throw SDKError.invariant("unexpected address verification")
    }

    func validateBeforeSubmission(
        prepared: PreparedTransaction, request: SendBtcRequest,
        policy: LocalSigningPolicy, retainedValidation: LocalValidationReport
    ) throws {
        // Transport/recovery fixtures intentionally contain synthetic PSBTs.
        // The packaged signer suite independently enforces current policy.
    }

    func validateAndSign(
        prepared: PreparedTransaction,
        request: SendBtcRequest,
        policy: LocalSigningPolicy
    ) throws -> LocalSigningResult {
        throw SDKError.invariant("unexpected signing")
    }
}

private actor GatewayInitializeBarrierTransport: GatewayHTTPTransport {
    private var requests: [GatewayHTTPRequest] = []
    private var initializeWaiters: [CheckedContinuation<GatewayHTTPResponse, Never>] = []

    func send(_ request: GatewayHTTPRequest) async throws -> GatewayHTTPResponse {
        requests.append(request)
        guard request.url.path == "/v1/me" else {
            return gatewayResponse(
                #"{"btc":{"vanilla":{"settled":1,"future":1,"spendable":1},"colored":{"settled":0,"future":0,"spendable":0}},"assets":[]}"#
            )
        }

        return await withCheckedContinuation { continuation in
            initializeWaiters.append(continuation)
            guard initializeWaiters.count == 2 else { return }
            let response = gatewayResponse(#"{"userId":"u_race","createdAt":1}"#)
            let waiters = initializeWaiters
            initializeWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters { waiter.resume(returning: response) }
        }
    }

    func snapshot() -> [GatewayHTTPRequest] { requests }
}

@Test func gatewayBalanceCannotReturnIntoAShutDownSession() async throws {
    for asset in [false, true] {
        let transport = GatewayBalanceBarrierTransport()
        let backend = GatewayWalletBackend(configuration: try gatewayConfiguration(), transport: transport)
        let walletID = try WalletID("session-balance-race")
        let session = try await backend.initialize(.init(
            walletID: walletID, network: .regtest, minimumAPIVersion: 1, maximumAPIVersion: 1))
        let context = BackendContext(session: session, walletID: walletID, network: .regtest)
        let read = Task {
            if asset { _ = try await backend.getAssetBalance(context: context, assetID: AssetID("rgb:test")) }
            else { _ = try await backend.getBtcBalance(context: context) }
        }
        await transport.waitUntilRequested()
        try await backend.shutdown(session: session)
        await transport.finish()
        do { try await read.value; Issue.record("stale balance escaped its session") }
        catch let error as SDKError { #expect(error.code == .invalidState) }
    }
}

private actor GatewayBalanceBarrierTransport: GatewayHTTPTransport {
    private var pending: CheckedContinuation<GatewayHTTPResponse, Never>?
    private var requested: CheckedContinuation<Void, Never>?
    func send(_ request: GatewayHTTPRequest) async throws -> GatewayHTTPResponse {
        if request.url.path == "/v1/me" { return gatewayResponse(#"{"userId":"balance-race","createdAt":1}"#) }
        return await withCheckedContinuation { continuation in
            pending = continuation
            requested?.resume()
            requested = nil
        }
    }
    func waitUntilRequested() async {
        if pending != nil { return }
        await withCheckedContinuation { requested = $0 }
    }
    func finish() {
        pending?.resume(returning: gatewayResponse(
            #"{"btc":{"vanilla":{"settled":1,"future":1,"spendable":1},"colored":{"settled":0,"future":0,"spendable":0}},"assets":[{"assetId":"rgb:test","balance":{"settled":1,"future":1,"spendable":1}}]}"#))
        pending = nil
    }
}

@Test func gatewayCancelledCredentialValidationCannotDispatchPreparation() async throws {
    let provider = RotatingTestAPIKeyProvider("first-credential")
    let transport = GatewayCredentialBarrierTransport()
    let backend = GatewayWalletBackend(configuration: try GatewayBackendConfiguration(
        baseURL: URL(string: "https://gateway.example")!, apiKeyProvider: provider, network: .regtest,
        allowUnverifiedPsbtProfile: true
    ), transport: transport)
    let walletID = try WalletID("credential-cancellation")
    let session = try await backend.initialize(.init(
        walletID: walletID, network: .regtest, minimumAPIVersion: 1, maximumAPIVersion: 1))
    let context = BackendContext(session: session, walletID: walletID, network: .regtest)
    await provider.rotate("next-credential")
    let request = try SendBtcRequest(address: BitcoinAddress("bcrt1pboundedaddress"), amount: Satoshis(1_000))
    let prepare = Task {
        try await backend.prepareSendBtc(.init(
            context: OperationRequestContext(backend: context, idempotencyKey: request.idempotencyKey,
                                            requestHash: RequestHasher.sendBtc(network: .regtest, request: request)),
            request: request))
    }
    await transport.waitUntilValidation()
    prepare.cancel()
    await transport.finish()
    do { _ = try await prepare.value; Issue.record("cancelled preparation returned a result") }
    catch is CancellationError { }
    #expect(await transport.paths() == ["/v1/me", "/v1/me"])
}

private actor GatewayCredentialBarrierTransport: GatewayHTTPTransport {
    private var requests: [GatewayHTTPRequest] = []
    private var pending: CheckedContinuation<GatewayHTTPResponse, Never>?
    private var requested: CheckedContinuation<Void, Never>?
    func send(_ request: GatewayHTTPRequest) async throws -> GatewayHTTPResponse {
        requests.append(request)
        guard request.url.path == "/v1/me" else { throw SDKError.invariant("unexpected cancelled effect") }
        if requests.count == 1 { return gatewayResponse(#"{"userId":"credential-cancel","createdAt":1}"#) }
        return await withCheckedContinuation { continuation in
            pending = continuation
            requested?.resume()
            requested = nil
        }
    }
    func waitUntilValidation() async {
        if pending != nil { return }
        await withCheckedContinuation { requested = $0 }
    }
    func finish() {
        pending?.resume(returning: gatewayResponse(#"{"userId":"credential-cancel","createdAt":1}"#))
        pending = nil
    }
    func paths() -> [String] { requests.map(\.url.path) }
}
