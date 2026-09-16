import Foundation
import Testing
@testable @_spi(Backend) import RGBSDK

@Test func gatewayConfigurationEnforcesTransportBoundaryAndRedactsToken() throws {
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

@Test func gatewayCompletionPreservesDefinitivePreBroadcastRejection() async throws {
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
        Issue.record("expected definitive PSBT rejection")
    } catch let error as SDKError {
        #expect(error.code == .backendRejected)
        #expect(error.operationID == operationID)
        #expect(error.details["backendCode"] == "PSBT_MISMATCH")
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

@Test func gatewayOperationKindMismatchIsAProtocolViolation() async throws {
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
        Issue.record("expected operation-kind protocol mismatch")
    } catch let error as SDKError {
        #expect(error.code == .backendProtocolMismatch)
        #expect(error.operationID == operationID)
        #expect(!error.message.contains("hostile detail"))
    }
}

@Test func gatewayKeepsMissingOperationStatusFailClosed() async throws {
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

private func gatewayConfiguration(token: String = "unit-token") throws -> GatewayBackendConfiguration {
    try GatewayBackendConfiguration(
        baseURL: #require(URL(string: "http://127.0.0.1:8480")),
        bearerToken: token,
        network: .regtest,
        allowInsecureLocalDevelopment: true
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

    init(responses: [GatewayHTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: GatewayHTTPRequest) async throws -> GatewayHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw SDKError.invariant("test transport has no queued response")
        }
        return responses.removeFirst()
    }

    func snapshot() -> [GatewayHTTPRequest] { requests }
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
