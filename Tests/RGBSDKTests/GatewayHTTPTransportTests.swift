import Foundation
import Testing
@testable @_spi(Backend) import RGBSDK

@Test func realHTTPStreamingEnforcesExactResponseByteLimit() async throws {
    let json = #"{"userId":"socket-user","createdAt":1}"#
    for chunked in [false, true] {
        for count in [1_024, 1_025] {
            let server = try LoopbackHTTPServer { _ in
                var response = LoopbackHTTPServer.Response.json(json + String(repeating: " ", count: count - json.utf8.count))
                response.chunked = chunked
                return response
            }
            defer { server.stop() }
            let backend = try socketBackend(url: await server.start(), maximumResponseBytes: 1_024)
            if count == 1_024 {
                let context = try await socketInitialize(backend)
                #expect(context.network == .regtest)
            } else {
                do { _ = try await socketInitialize(backend); Issue.record("oversized real response must fail") }
                catch let error as SDKError { #expect(error.code == .backendProtocolMismatch) }
            }
            #expect(server.snapshot().count == 1)
        }
    }
}

@Test func realHTTPMalformedAndUnexpectedResponsesFailWithoutLeakingBodies() async throws {
    for response in [
        LoopbackHTTPServer.Response.json("{private-malformed-response"),
        .json(String(repeating: "[", count: 100_000) + "0" + String(repeating: "]", count: 100_000)),
        .json(#"{"userId":"socket-user","createdAt":1}"#, status: 202),
        .init(headers: ["Content-Type": "text/plain"], body: Data("private-body".utf8)),
    ] {
        let server = try LoopbackHTTPServer { _ in response }
        defer { server.stop() }
        let backend = try socketBackend(url: await server.start())
        do { _ = try await socketInitialize(backend); Issue.record("invalid real response must fail") }
        catch let error as SDKError {
            #expect(error.code == .backendProtocolMismatch)
            #expect(!error.description.contains("private"))
        }
        #expect(server.snapshot().count == 1)
    }
}

@Test func realHTTPRedirectNeverDispatchesOrForwardsCredentialToTarget() async throws {
    let target = try LoopbackHTTPServer { _ in .json(#"{"userId":"other-user","createdAt":1}"#) }
    defer { target.stop() }
    let targetURL = try await target.start()
    let source = try LoopbackHTTPServer { _ in
        .init(status: 307, headers: ["Location": targetURL.appendingPathComponent("credential-sink").absoluteString])
    }
    defer { source.stop() }
    let backend = try socketBackend(url: await source.start())
    do { _ = try await socketInitialize(backend); Issue.record("redirect must fail") }
    catch let error as SDKError { #expect(error.code == .backendProtocolMismatch) }
    #expect(source.snapshot().count == 1)
    #expect(target.snapshot().isEmpty)
}

@Test func realHTTPTimeoutBoundsHeaderAndBodyWaits() async throws {
    for delayHeaders in [false, true] {
        let server = try LoopbackHTTPServer { _ in
            var response = LoopbackHTTPServer.Response.json(#"{"userId":"socket-user","createdAt":1}"#)
            if delayHeaders { response.beforeHeadersMilliseconds = 5_000 }
            else { response.beforeBodyMilliseconds = 5_000 }
            return response
        }
        defer { server.stop() }
        let backend = try socketBackend(url: await server.start(), requestTimeout: 1)
        let started = ContinuousClock.now
        do { _ = try await socketInitialize(backend); Issue.record("timeout must fail") }
        catch let error as SDKError { #expect(error.code == .backendUnavailable) }
        #expect(started.duration(to: .now) < .seconds(4))
        #expect(server.snapshot().count == 1)
    }
}

@Test func realHTTPCancellationDuringHeaderAndBodyWaitsDoesNotRetry() async throws {
    for delayHeaders in [false, true] {
        let server = try LoopbackHTTPServer { _ in
            var response = LoopbackHTTPServer.Response.json(#"{"userId":"socket-user","createdAt":1}"#)
            if delayHeaders { response.beforeHeadersMilliseconds = 5_000 }
            else { response.beforeBodyMilliseconds = 5_000 }
            return response
        }
        defer { server.stop() }
        let backend = try socketBackend(url: await server.start())
        let task = Task { try await socketInitialize(backend) }
        try await server.waitForRequests(1)
        task.cancel()
        do { _ = try await task.value; Issue.record("canceled socket request must not return a session") }
        catch is CancellationError {}
        #expect(server.snapshot().count == 1)
    }
}

@Test func realHTTPTruncatedResponseDoesNotBecomeSuccessfulJSON() async throws {
    let server = try LoopbackHTTPServer { _ in
        var response = LoopbackHTTPServer.Response.json(#"{"userId":"socket-user","createdAt":1}"#)
        response.declaredLength = response.body.count + 50
        return response
    }
    defer { server.stop() }
    let backend = try socketBackend(url: await server.start())
    do { _ = try await socketInitialize(backend); Issue.record("truncated response must fail") }
    catch let error as SDKError { #expect(error.code == .backendUnavailable) }
    #expect(server.snapshot().count == 1)
}

@Test func realHTTPRotatesCredentialsAndDoesNotPersistCookiesOrResponses() async throws {
    let provider = SocketCredentialProvider("first-key")
    let server = try LoopbackHTTPServer { request in
        if request.path == "/v1/me" {
            let user = request.headers["authorization"] == "Bearer foreign-key" ? "foreign-user" : "socket-user"
            var response = LoopbackHTTPServer.Response.json("{\"userId\":\"\(user)\",\"createdAt\":1}")
            response.headers["Set-Cookie"] = "wallet-cookie=private-test-value; Path=/"
            response.headers["Cache-Control"] = "public, max-age=86400"
            return response
        }
        return .json(socketBalanceJSON)
    }
    defer { server.stop() }
    let backend = GatewayWalletBackend(configuration: try GatewayBackendConfiguration(
        baseURL: await server.start(), apiKeyProvider: provider, network: .regtest,
        allowInsecureLocalDevelopment: true
    ))
    let context = try await socketInitialize(backend)
    #expect(try await backend.getBtcBalance(context: context).vanilla.settled.value == 42)
    await provider.set("second-key")
    #expect(try await backend.getBtcBalance(context: context).vanilla.settled.value == 42)
    await provider.set("foreign-key")
    do { _ = try await backend.getBtcBalance(context: context); Issue.record("foreign rotated user must fail") }
    catch let error as SDKError { #expect(error.code == .backendProtocolMismatch) }
    let requests = server.snapshot()
    #expect(requests.map(\.path) == ["/v1/me", "/v1/wallet/balances", "/v1/me", "/v1/wallet/balances", "/v1/me"])
    #expect(requests.map { $0.headers["authorization"] } == [
        "Bearer first-key", "Bearer first-key", "Bearer second-key", "Bearer second-key", "Bearer foreign-key",
    ])
    #expect(requests.allSatisfy { $0.headers["cookie"] == nil })
}

@Test func realHTTPReadsSyncAndReceivePreservePublicIntent() async throws {
    let server = try LoopbackHTTPServer { request in
        switch request.path {
        case "/v1/me": return .json(#"{"userId":"socket-user","createdAt":1}"#)
        case "/v1/wallet/balances": return .json(socketBalanceJSON)
        case "/v1/wallet/sync": return .json(#"{"status":"ok"}"#)
        case "/v1/wallet/receive":
            let expiry = UInt64(Date().timeIntervalSince1970) + 86_400
            let invoice = invoiceTestString(witness: true, expiry: expiry)
            let recipient = try decodeRGBInvoiceLocally(RGBInvoice(invoice)).recipientID
            return .json(String(decoding: try JSONSerialization.data(withJSONObject: [
                "invoice": invoice, "recipientId": recipient, "expirationTimestamp": expiry, "mode": "witness",
            ]), as: UTF8.self), status: 201)
        default: return .json("{}", status: 404)
        }
    }
    defer { server.stop() }
    let backend = try socketBackend(url: await server.start())
    let context = try await socketInitialize(backend)
    #expect(try await backend.getBtcBalance(context: context).vanilla.settled.value == 42)
    #expect(try await backend.syncWallet(context: context).tipHeight == nil)
    #expect(try await backend.refreshWallet(context: context).tipHeight == nil)
    let result = try await backend.onchainReceive(context: context, request: OnchainReceiveRequest())
    #expect(try decodeRGBInvoiceLocally(result.invoice).recipientID == result.recipientID)
    let request = try #require(server.snapshot().last)
    let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    #expect(body["mode"] as? String == "witness")
    #expect(body["durationSeconds"] as? Int == 86_400)
    #expect(body["minConfirmations"] as? Int == 0)
    #expect(body["amount"] == nil && body["assetId"] == nil)
    #expect(server.snapshot().map(\.method) == ["GET", "GET", "POST", "POST", "POST"])
}

private let socketBalanceJSON = #"{"btc":{"vanilla":{"settled":42,"future":42,"spendable":42},"colored":{"settled":0,"future":0,"spendable":0}},"assets":[]}"#

private func socketBackend(
    url: URL, maximumResponseBytes: Int = 1_048_576, requestTimeout: TimeInterval = 5
) throws -> GatewayWalletBackend {
    GatewayWalletBackend(configuration: try GatewayBackendConfiguration(
        baseURL: url, bearerToken: "socket-test-key", network: .regtest,
        allowInsecureLocalDevelopment: true, requestTimeout: requestTimeout,
        maximumResponseBytes: maximumResponseBytes
    ))
}

private func socketInitialize(_ backend: GatewayWalletBackend) async throws -> BackendContext {
    let walletID = try WalletID("socket-wallet")
    let session = try await backend.initialize(.init(
        walletID: walletID, network: .regtest, minimumAPIVersion: 1, maximumAPIVersion: 1
    ))
    return BackendContext(session: session, walletID: walletID, network: .regtest)
}

private actor SocketCredentialProvider: WalletAPIKeyProvider {
    private var key: String
    init(_ key: String) { self.key = key }
    func set(_ key: String) { self.key = key }
    func loadAPIKey() async throws -> WalletAPIKey { try WalletAPIKey(copyingUTF8: Array(key.utf8)) }
}
