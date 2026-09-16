import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Configuration for the reviewed PR #174 minimal-gateway contract.
///
/// This remains backend SPI: application code should keep calling
/// `UTEXOWallet`, never the prepare/complete routes directly.
@_spi(Backend)
public struct GatewayBackendConfiguration: Sendable, CustomStringConvertible, CustomReflectable {
    public let baseURL: URL
    public let network: Network
    public let allowInsecureLocalDevelopment: Bool
    public let requestTimeout: TimeInterval
    public let maximumPreparationTTL: TimeInterval
    public let maximumResponseBytes: Int

    fileprivate let bearerToken: String

    /// Creates a pinned gateway configuration.
    ///
    /// Plain HTTP is accepted only for an exact loopback host so local
    /// containers remain usable without weakening production transport.
    public init(
        baseURL: URL,
        bearerToken: String,
        network: Network,
        allowInsecureLocalDevelopment: Bool = false,
        requestTimeout: TimeInterval = 30,
        maximumPreparationTTL: TimeInterval = 3_600,
        maximumResponseBytes: Int = 1_048_576
    ) throws {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            throw SDKError.invalidArgument("baseURL", "must be an absolute HTTP(S) URL")
        }
        guard components.user == nil, components.password == nil else {
            throw SDKError.invalidArgument("baseURL", "must not contain credentials")
        }
        guard components.query == nil, components.fragment == nil else {
            throw SDKError.invalidArgument("baseURL", "must not contain a query or fragment")
        }
        guard components.path.isEmpty || components.path == "/" else {
            throw SDKError.invalidArgument("baseURL", "must not contain a path")
        }
        let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
        guard scheme == "https"
            || (allowInsecureLocalDevelopment && scheme == "http" && loopbackHosts.contains(host)) else {
            throw SDKError.invalidArgument(
                "baseURL",
                "must use HTTPS; loopback HTTP requires explicit local-development opt-in"
            )
        }
        guard requestTimeout.isFinite, (1...120).contains(requestTimeout) else {
            throw SDKError.invalidArgument("requestTimeout", "must be between 1 and 120 seconds")
        }
        guard maximumPreparationTTL.isFinite,
              (1...604_800).contains(maximumPreparationTTL) else {
            throw SDKError.invalidArgument(
                "maximumPreparationTTL",
                "must be between 1 second and 7 days"
            )
        }
        guard (1_024...5_500_000).contains(maximumResponseBytes) else {
            throw SDKError.invalidArgument(
                "maximumResponseBytes",
                "must be between 1024 and 5500000 bytes"
            )
        }
        guard !bearerToken.isEmpty, bearerToken.utf8.count <= 512,
              bearerToken.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f }) else {
            throw SDKError.invalidArgument(
                "bearerToken",
                "must be a non-empty bounded ASCII header value"
            )
        }
        guard network != .testnet4, network != .utexo else {
            throw SDKError.unsupported(
                "PR #174 gateway logical Testnet4/UTEXO network negotiation"
            )
        }

        var normalized = components
        normalized.scheme = scheme
        normalized.host = host
        normalized.path = ""
        guard let normalizedURL = normalized.url else {
            throw SDKError.invalidArgument("baseURL", "could not be normalized")
        }
        self.baseURL = normalizedURL
        self.bearerToken = bearerToken
        self.network = network
        self.allowInsecureLocalDevelopment = allowInsecureLocalDevelopment
        self.requestTimeout = requestTimeout
        self.maximumPreparationTTL = maximumPreparationTTL
        self.maximumResponseBytes = maximumResponseBytes
    }

    public var description: String {
        "GatewayBackendConfiguration(baseURL=\(baseURL.absoluteString), "
            + "network=\(network.rawValue), bearerToken=[REDACTED])"
    }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "baseURL": baseURL.absoluteString,
                "network": network.rawValue,
                "allowInsecureLocalDevelopment": allowInsecureLocalDevelopment,
                "bearerToken": "[REDACTED]",
            ],
            displayStyle: .struct
        )
    }
}

/// HTTP adapter for the minimal gateway added by rgb-lightning-node PR #174.
///
/// It intentionally implements only wire mappings with exact semantics. In
/// particular, raw PSBTs remain behind `WalletBackend`; `UTEXOWallet.sendBtc`
/// still performs local intent validation and signing before completion.
@_spi(Backend)
public actor GatewayWalletBackend: WalletBackend {
    private static let apiVersion: UInt32 = 1
    private static let maximumRequestBytes = 64 * 1_024
    fileprivate static let javascriptMaximumSafeInteger: UInt64 = 9_007_199_254_740_991

    private let configuration: GatewayBackendConfiguration
    private let transport: any GatewayHTTPTransport
    private let nowMilliseconds: @Sendable () -> UInt64
    private var activeSession: BackendSession?
    private var activeWalletID: WalletID?
    private var boundWalletID: WalletID?
    private var boundGatewayUserID: String?

    public init(configuration: GatewayBackendConfiguration) {
        self.configuration = configuration
        transport = URLSessionGatewayTransport(
            requestTimeout: configuration.requestTimeout,
            maximumResponseBytes: configuration.maximumResponseBytes
        )
        nowMilliseconds = { UInt64(Date().timeIntervalSince1970 * 1_000) }
    }

    init(
        configuration: GatewayBackendConfiguration,
        transport: any GatewayHTTPTransport,
        nowMilliseconds: @escaping @Sendable () -> UInt64 = {
            UInt64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.nowMilliseconds = nowMilliseconds
    }

    public func initialize(_ request: BackendInitializeRequest) async throws -> BackendSession {
        guard request.network == configuration.network else {
            throw SDKError.wrongNetwork(expected: configuration.network, actual: request.network)
        }
        guard (request.minimumAPIVersion...request.maximumAPIVersion).contains(Self.apiVersion) else {
            throw SDKError.backendProtocolMismatch(
                "PR #174 gateway supports only API version \(Self.apiVersion)"
            )
        }
        if let boundWalletID, boundWalletID != request.walletID {
            throw SDKError.invalidState(
                operation: "initialize",
                state: "gateway credential is bound to another wallet"
            )
        }
        if let activeSession {
            guard activeWalletID == request.walletID else {
                throw SDKError.invalidState(operation: "initialize", state: "another wallet is active")
            }
            return activeSession
        }

        let response: MeResponse = try await get(path: "/v1/me")
        let gatewayUserID: String
        do {
            gatewayUserID = try requireProtocolIdentifier(response.userId, field: "gatewayUserId")
        } catch {
            throw SDKError.backendProtocolMismatch("gateway returned a malformed user identity")
        }

        // `initialize` crosses an actor-reentrancy boundary while `/v1/me` is
        // in flight. Re-check every binding before committing: another caller
        // may have initialized this backend while this call was suspended.
        if let boundWalletID, boundWalletID != request.walletID {
            throw SDKError.invalidState(
                operation: "initialize",
                state: "gateway credential is bound to another wallet"
            )
        }
        if let boundGatewayUserID, boundGatewayUserID != gatewayUserID {
            throw SDKError.backendProtocolMismatch(
                "gateway credential resolved to a different user identity"
            )
        }
        if let activeSession {
            guard activeWalletID == request.walletID else {
                throw SDKError.invalidState(operation: "initialize", state: "another wallet is active")
            }
            return activeSession
        }
        let session = try BackendSession(
            // The gateway user ID is stable and therefore cannot serve as a
            // session capability. A fresh local nonce ensures that a context
            // retained across shutdown/reinitialize never becomes valid again.
            id: "gw.\(UUID().uuidString.lowercased())",
            apiVersion: Self.apiVersion,
            network: configuration.network
        )
        activeSession = session
        activeWalletID = request.walletID
        boundWalletID = request.walletID
        boundGatewayUserID = gatewayUserID
        return session
    }

    public func registerWallet(_ request: RegisterWalletRequest) async throws {
        try requireContext(request.context)
        guard request.identity.network == configuration.network else {
            throw SDKError.wrongNetwork(
                expected: configuration.network,
                actual: request.identity.network
            )
        }
        guard request.identity.chainNetwork == configuration.network.chainNetwork else {
            throw SDKError.backendProtocolMismatch("watch-only identity has the wrong chain network")
        }
        guard request.identity.derivationProfile == WalletCapabilities.derivationProfileV1 else {
            throw SDKError.backendProtocolMismatch("watch-only identity has an unsupported profile")
        }
        guard request.identity.masterFingerprint == request.identity.masterFingerprint.lowercased(),
              isASCIIHex(request.identity.masterFingerprint, exactByteCount: 8, lowercaseOnly: true) else {
            throw SDKError.invalidArgument(
                "masterFingerprint",
                "must be exactly 4 lowercase hexadecimal bytes"
            )
        }

        let body = RegisterXpubsBody(
            vanilla: request.identity.accountXpubVanilla,
            colored: request.identity.accountXpubColored,
            fingerprint: request.identity.masterFingerprint
        )
        let response: RegisterXpubsResponse = try await post(
            path: "/v1/wallet/xpubs",
            body: body,
            expectedStatusCode: 201
        )
        guard response.fingerprint == request.identity.masterFingerprint else {
            throw SDKError.backendProtocolMismatch("xpub registration returned the wrong fingerprint")
        }
        // PR #174 does not return the derivation index for this address, so it
        // cannot become a ReservedAddress. Parse it only as a bounded response
        // field; getAddress remains fail-closed below.
        _ = try BitcoinAddress(response.address)
    }

    public func shutdown(session: BackendSession) async throws {
        guard let activeSession else { return }
        guard session == activeSession else {
            throw SDKError.backendProtocolMismatch("shutdown used a different backend session")
        }
        self.activeSession = nil
        activeWalletID = nil
    }

    public func getBtcBalance(context: BackendContext) async throws -> BTCBalance {
        try requireContext(context)
        let response: WalletBalancesResponse = try await get(path: "/v1/wallet/balances")
        return BTCBalance(
            vanilla: try response.btc.vanilla.satoshis,
            colored: try response.btc.colored.satoshis
        )
    }

    public func getAssetBalance(context: BackendContext, assetID: AssetID) async throws -> AssetBalance {
        try requireContext(context)
        let response: WalletBalancesResponse = try await get(path: "/v1/wallet/balances")
        let matches = response.assets.filter { $0.assetId == assetID.value }
        guard matches.count <= 1 else {
            throw SDKError.backendProtocolMismatch("balance response contains a duplicate asset ID")
        }
        guard let match = matches.first else {
            throw SDKError(
                code: .backendRejected,
                retryable: false,
                message: "The asset is not known to this wallet",
                details: ["backendCode": "ASSET_NOT_FOUND"]
            )
        }
        return try match.balance.asset
    }

    public func prepareSendBtc(_ request: PrepareSendBtcRequest) async throws -> PreparedTransaction {
        try requireContext(request.context.backend)
        guard !request.request.skipSync else {
            throw SDKError.unsupported("PR #174 gateway sendBtc skipSync=true")
        }
        let feeRate = request.request.feeRate.milliSatsPerVByte
        guard feeRate.isMultiple(of: 1_000) else {
            throw SDKError.invalidArgument(
                "feeRate",
                "PR #174 gateway accepts only whole sat/vB values"
            )
        }
        let wholeSatsPerVByte = feeRate / 1_000
        guard (1...1_000).contains(wholeSatsPerVByte) else {
            throw SDKError.invalidArgument(
                "feeRate",
                "PR #174 gateway accepts values from 1 through 1000 sat/vB"
            )
        }

        let body = PrepareSendBtcBody(
            address: request.request.address.value,
            amountSat: request.request.amount.value,
            feeRateSatPerVb: wholeSatsPerVByte
        )
        let response: PreparedResponse = try await post(
            path: "/v1/onchain/send-btc/prepare",
            body: body,
            expectedStatusCode: 201,
            idempotency: .init(logicalKey: request.context.idempotencyKey, stage: .prepare)
        )
        try validateSendBtcIntent(response.intent, request: body)
        try validateCanonicalBase64(response.psbt, field: "prepared PSBT")
        let currentTime = nowMilliseconds()
        let maximumTTLMilliseconds = UInt64(configuration.maximumPreparationTTL * 1_000)
        guard response.expiresAt > currentTime,
              response.expiresAt - currentTime <= maximumTTLMilliseconds else {
            throw SDKError.backendProtocolMismatch(
                "prepare expiry is stale or exceeds the configured TTL limit"
            )
        }
        let operationID = try gatewayOperationID(response.opId)
        return try PreparedTransaction(
            operationID: operationID,
            idempotencyKey: request.context.idempotencyKey,
            requestHash: request.context.requestHash,
            network: configuration.network,
            operation: .sendBtc,
            psbtBase64: response.psbt,
            // Flooring is conservative: the client may consider the operation
            // expired up to 999 ms before the gateway does, never after it.
            expiresAt: .init(rawValue: response.expiresAt / 1_000)
        )
    }

    public func submitSignedTransaction(
        _ request: SignedTransactionSubmission
    ) async throws -> BackendOperationResult {
        try requireContext(request.context.backend)
        try validateCanonicalBase64(request.signedPsbtBase64, field: "signed PSBT")
        let body = CompleteBody(
            opId: request.operationID.value,
            signedPsbt: request.signedPsbtBase64
        )
        // The gateway's idempotency scope is global per user, not per route.
        // Domain-separated stage keys avoid prepare/complete conflicts while
        // preserving one public logical idempotency key across Swift/Kotlin.
        let response: CompleteResponse = try await post(
            path: "/v1/onchain/send-btc/complete",
            body: body,
            expectedStatusCode: 200,
            idempotency: .init(logicalKey: request.context.idempotencyKey, stage: .complete),
            phase: .submit(request.operationID)
        )
        let txid: TransactionID
        do {
            txid = try TransactionID(response.txid)
        } catch {
            // A 2xx response proves only that the gateway claims completion.
            // Once the request reached this route, an invalid result cannot
            // prove whether the transaction was broadcast.
            throw SDKError.operationAmbiguous(request.operationID)
        }
        guard txid == request.validation.unsignedTxid else {
            throw SDKError.operationAmbiguous(request.operationID)
        }
        return .sendBtc(
            operationID: request.operationID,
            txid: txid
        )
    }

    /// PR #174 has no operation-status route. Reconciliation must stay
    /// unsupported so the coordinator reports an ambiguous outcome and never
    /// performs a blind complete/broadcast retry.
    public func getOperation(
        context: BackendContext,
        operationID: OperationID
    ) async throws -> BackendOperationStatus {
        try requireContext(context)
        throw SDKError.unsupported("PR #174 gateway operation-status reconciliation")
    }

    private func requireContext(_ context: BackendContext) throws {
        guard let activeSession, let activeWalletID else {
            throw SDKError.invalidState(operation: "backend request", state: "not initialized")
        }
        guard context.session == activeSession, context.walletID == activeWalletID else {
            throw SDKError.backendProtocolMismatch("request used a different backend session")
        }
        guard context.network == configuration.network else {
            throw SDKError.wrongNetwork(expected: configuration.network, actual: context.network)
        }
    }

    private func validateSendBtcIntent(
        _ intent: PreparedIntent,
        request: PrepareSendBtcBody
    ) throws {
        guard intent.kind == "send_btc" else {
            throw SDKError.backendProtocolMismatch("prepare intent has the wrong operation kind")
        }
        guard intent.feeRateSatPerVb == request.feeRateSatPerVb else {
            throw SDKError.backendProtocolMismatch("prepare intent changed the requested fee rate")
        }
        guard intent.recipients.count == 1, let recipient = intent.recipients.first else {
            throw SDKError.backendProtocolMismatch("prepare intent must contain exactly one recipient")
        }
        guard recipient.address == request.address, recipient.amountSat == request.amountSat else {
            throw SDKError.backendProtocolMismatch("prepare intent changed the recipient or amount")
        }
        guard isBoundedEvenHex(recipient.scriptHex, maximumBytes: 10_000) else {
            throw SDKError.backendProtocolMismatch("prepare intent contains an invalid recipient script")
        }
        // Required NullOnly fields prove the server did not smuggle an RGB or
        // create-utxos allowance into a send-BTC intent.
        _ = intent.asset
        _ = intent.utxos
    }

    private func gatewayOperationID(_ value: String) throws -> OperationID {
        guard value.utf8.count == 36,
              value == value.lowercased(),
              let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value else {
            throw SDKError.backendProtocolMismatch("prepare returned a malformed operation ID")
        }
        return try OperationID(value)
    }

    private func validateCanonicalBase64(_ value: String, field: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= configuration.maximumResponseBytes,
              let decoded = Data(base64Encoded: value),
              decoded.base64EncodedString() == value else {
            throw SDKError.backendProtocolMismatch("\(field) is not canonical bounded Base64")
        }
    }

    private func get<Response: Decodable>(path: String) async throws -> Response {
        try await request(
            method: .get,
            path: path,
            body: nil,
            expectedStatusCode: 200,
            context: .init()
        )
    }

    private func post<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body,
        expectedStatusCode: Int,
        idempotency: GatewayIdempotency? = nil,
        phase: GatewayRequestPhase = .nonBroadcast
    ) async throws -> Response {
        let encoded: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            encoded = try encoder.encode(body)
        } catch {
            throw SDKError.invariant("gateway request encoding failed")
        }
        guard encoded.count <= Self.maximumRequestBytes else {
            throw SDKError.invalidArgument(
                "requestBody",
                "exceeds the PR #174 gateway 65536-byte limit"
            )
        }
        return try await request(
            method: .post,
            path: path,
            body: encoded,
            expectedStatusCode: expectedStatusCode,
            context: .init(idempotency: idempotency, phase: phase)
        )
    }

    private func request<Response: Decodable>(
        method: GatewayHTTPMethod,
        path: String,
        body: Data?,
        expectedStatusCode: Int,
        context: GatewayFailureContext
    ) async throws -> Response {
        guard path.hasPrefix("/"),
              let url = URL(string: path, relativeTo: configuration.baseURL)?.absoluteURL else {
            throw SDKError.invariant("gateway route is invalid")
        }
        var headers = [
            "Accept": "application/json",
            "Authorization": "Bearer \(configuration.bearerToken)",
        ]
        if body != nil { headers["Content-Type"] = "application/json" }
        if let idempotency = context.idempotency {
            headers["Idempotency-Key"] = idempotency.wireValue
        }

        let response: GatewayHTTPResponse
        do {
            response = try await transport.send(
                .init(method: method, url: url, headers: headers, body: body)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SDKError {
            // URLSession transport contract failures (non-HTTP response,
            // oversized body) happen only after dispatch. During completion,
            // the gateway may already have broadcast before that failure was
            // observable, so a protocol error is not a definitive outcome.
            if error.code == .backendProtocolMismatch,
               let operationID = context.submittedOperationID {
                throw SDKError.operationAmbiguous(operationID)
            }
            throw error
        } catch {
            throw SDKError.backendUnavailable()
        }

        let correlationID = validatedCorrelationID(response.correlationID)
        if (300..<400).contains(response.statusCode) {
            throw context.responseContractFailure(
                "gateway redirects are not permitted",
                correlationID: correlationID
            )
        }
        guard (200..<300).contains(response.statusCode) else {
            throw mapGatewayFailure(
                statusCode: response.statusCode,
                body: response.body,
                context: context,
                correlationID: correlationID
            )
        }
        guard response.statusCode == expectedStatusCode else {
            throw context.responseContractFailure(
                "successful response has the wrong HTTP status",
                correlationID: correlationID
            )
        }
        guard response.mimeType?.lowercased() == "application/json" else {
            throw context.responseContractFailure(
                "successful response is not JSON",
                correlationID: correlationID
            )
        }
        do {
            return try JSONDecoder().decode(Response.self, from: response.body)
        } catch {
            throw context.responseContractFailure(
                "successful response does not match the gateway contract",
                correlationID: correlationID
            )
        }
    }

    private func mapGatewayFailure(
        statusCode: Int,
        body: Data,
        context: GatewayFailureContext,
        correlationID: String?
    ) -> SDKError {
        let wire = try? JSONDecoder().decode(GatewayErrorResponse.self, from: body)
        let backendCode = validatedBackendCode(wire?.error.code)

        if statusCode == 409, backendCode == "IDEMPOTENCY_KEY_REUSED",
           let idempotency = context.idempotency {
            return .operationConflict(idempotency.logicalKey)
        }
        if statusCode == 410, backendCode == "OP_EXPIRED", let operationID = context.operationID {
            return .operationExpired(operationID)
        }
        // The gateway persists that this operation completed but omits the
        // transaction ID from this response. Treating it as rejection could
        // cause an application to initiate a second spend. Until an operation
        // status endpoint can return the stored result, the only safe state is
        // ambiguous.
        if statusCode == 409, backendCode == "OP_ALREADY_COMPLETED",
           let operationID = context.operationID {
            return .operationAmbiguous(operationID)
        }
        if statusCode == 409, backendCode == "OP_KIND_MISMATCH" {
            return .backendProtocolMismatch(
                "prepared operation kind differs from the completion route",
                operationID: context.operationID,
                correlationID: correlationID
            )
        }
        if statusCode == 408 || statusCode == 425 || statusCode == 429 || statusCode >= 500
            || backendCode == "IDEMPOTENCY_IN_FLIGHT" {
            return .backendUnavailable(correlationID: correlationID)
        }
        // PR #174 also uses 409 for OP_ALREADY_COMPLETED. If a completion
        // response loses or corrupts its code, the status alone cannot
        // distinguish a pre-broadcast conflict from an already-broadcast op.
        if statusCode == 409, let operationID = context.submittedOperationID {
            return .operationAmbiguous(operationID)
        }
        return SDKError(
            code: .backendRejected,
            retryable: false,
            message: fixedGatewayMessage(for: backendCode),
            operationID: context.operationID,
            correlationID: correlationID,
            details: backendCode.map { ["backendCode": $0] } ?? [:]
        )
    }

    private func validatedBackendCode(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 128,
              !value.isEmpty,
              value.utf8.allSatisfy({ byte in
                  (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                      || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                      || byte == UInt8(ascii: "_")
              }) else { return nil }
        return value
    }

    private func validatedCorrelationID(_ value: String?) -> String? {
        guard let value,
              (try? requireProtocolIdentifier(value, field: "correlationId")) == value else {
            return nil
        }
        return value
    }

}

private struct GatewayFailureContext: Sendable {
    let idempotency: GatewayIdempotency?
    let phase: GatewayRequestPhase

    init(
        idempotency: GatewayIdempotency? = nil,
        phase: GatewayRequestPhase = .nonBroadcast
    ) {
        self.idempotency = idempotency
        self.phase = phase
    }

    var operationID: OperationID? { phase.operationID }
    var submittedOperationID: OperationID? { phase.operationID }

    func responseContractFailure(_ reason: String, correlationID: String?) -> SDKError {
        if let operationID = submittedOperationID {
            return .operationAmbiguous(operationID)
        }
        return .backendProtocolMismatch(reason, correlationID: correlationID)
    }
}

private enum GatewayRequestPhase: Sendable {
    case nonBroadcast
    case submit(OperationID)

    var operationID: OperationID? {
        switch self {
        case .nonBroadcast: nil
        case let .submit(operationID): operationID
        }
    }
}

private enum GatewayOperationStage: String, Sendable {
    case prepare
    case complete
}

private struct GatewayIdempotency: Sendable {
    private static let domain = "utexo.gateway.idempotency.v1"

    let logicalKey: IdempotencyKey
    let stage: GatewayOperationStage

    var wireValue: String {
        var hasher = SHA256()
        for field in [Self.domain, stage.rawValue, logicalKey.value] {
            let bytes = Array(field.utf8)
            var length = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
            hasher.update(data: Data(bytes))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct MeResponse: Decodable {
    let userId: String
    let createdAt: UInt64
}

private struct RegisterXpubsBody: Encodable {
    let vanilla: String
    let colored: String
    let fingerprint: String
}

private struct RegisterXpubsResponse: Decodable {
    let fingerprint: String
    let address: String
}

private struct WalletBalancesResponse: Decodable {
    let btc: BTCBalancesWire
    let assets: [WalletAssetWire]
}

private struct BTCBalancesWire: Decodable {
    let vanilla: BalanceWire
    let colored: BalanceWire
}

private struct WalletAssetWire: Decodable {
    let assetId: String
    let balance: BalanceWire
}

private struct BalanceWire: Decodable {
    let settled: UInt64
    let future: UInt64
    let spendable: UInt64

    var satoshis: Balance {
        get throws {
            try Balance(
                settled: Satoshis(settled),
                future: Satoshis(future),
                spendable: Satoshis(spendable)
            )
        }
    }

    var asset: AssetBalance {
        get throws {
            guard settled <= GatewayWalletBackend.javascriptMaximumSafeInteger,
                  future <= GatewayWalletBackend.javascriptMaximumSafeInteger,
                  spendable <= GatewayWalletBackend.javascriptMaximumSafeInteger else {
                throw SDKError.backendProtocolMismatch(
                    "asset balance exceeds the gateway's exact JSON-integer range"
                )
            }
            return AssetBalance(
                settled: AssetAmount(settled),
                future: AssetAmount(future),
                spendable: AssetAmount(spendable)
            )
        }
    }
}

private struct PrepareSendBtcBody: Encodable {
    let address: String
    let amountSat: UInt64
    let feeRateSatPerVb: UInt64
}

private struct PreparedResponse: Decodable {
    let opId: String
    let psbt: String
    let intent: PreparedIntent
    let expiresAt: UInt64
}

private struct PreparedIntent: Decodable {
    let kind: String
    let feeRateSatPerVb: UInt64
    let recipients: [PreparedRecipient]
    let asset: NullOnly
    let utxos: NullOnly
}

private struct PreparedRecipient: Decodable {
    let address: String
    let scriptHex: String
    let amountSat: UInt64
}

private struct NullOnly: Decodable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard container.decodeNil() else {
            throw DecodingError.typeMismatch(
                NullOnly.self,
                .init(codingPath: decoder.codingPath, debugDescription: "expected null")
            )
        }
    }
}

private struct CompleteBody: Encodable {
    let opId: String
    let signedPsbt: String
}

private struct CompleteResponse: Decodable {
    let txid: String
}

private struct GatewayErrorResponse: Decodable {
    struct Body: Decodable {
        let code: String
    }
    let error: Body
}

private func fixedGatewayMessage(for code: String?) -> String {
    switch code {
    case "UNAUTHORIZED":
        "The gateway credential is invalid"
    case "WALLET_NOT_REGISTERED":
        "No watch-only wallet is registered for this credential"
    case "XPUBS_MISMATCH":
        "Different watch-only keys are already registered for this credential"
    case "INVALID_XPUBS":
        "The gateway rejected the watch-only keys"
    case "INVALID_ADDRESS":
        "The gateway rejected the recipient address"
    case "INSUFFICIENT_FUNDS":
        "The wallet has insufficient funds for this operation"
    case "PSBT_REJECTED", "PSBT_MISMATCH":
        "The gateway rejected the locally signed transaction"
    case "OP_NOT_FOUND":
        "The prepared operation was not found"
    case "OP_KIND_MISMATCH":
        "The prepared operation has a different type"
    case "OP_ALREADY_COMPLETED":
        "The prepared operation was already completed"
    case "BAD_REQUEST", "IDEMPOTENCY_KEY_REQUIRED":
        "The gateway rejected the request contract"
    default:
        "The wallet backend rejected the request"
    }
}

private func isBoundedEvenHex(_ value: String, maximumBytes: Int) -> Bool {
    guard !value.isEmpty, value.utf8.count.isMultiple(of: 2),
          value.utf8.count / 2 <= maximumBytes else { return false }
    return value.utf8.allSatisfy { byte in
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
    }
}

enum GatewayHTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
}

struct GatewayHTTPRequest: Sendable {
    let method: GatewayHTTPMethod
    let url: URL
    let headers: [String: String]
    let body: Data?
}

struct GatewayHTTPResponse: Sendable {
    let statusCode: Int
    let mimeType: String?
    let correlationID: String?
    let body: Data
}

protocol GatewayHTTPTransport: Sendable {
    func send(_ request: GatewayHTTPRequest) async throws -> GatewayHTTPResponse
}

private final class URLSessionGatewayTransport: GatewayHTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let maximumResponseBytes: Int

    init(requestTimeout: TimeInterval, maximumResponseBytes: Int) {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.urlCredentialStorage = nil
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.timeoutIntervalForRequest = requestTimeout
        sessionConfiguration.timeoutIntervalForResource = requestTimeout
        session = URLSession(
            configuration: sessionConfiguration,
            delegate: RejectRedirectsDelegate(),
            delegateQueue: nil
        )
        self.maximumResponseBytes = maximumResponseBytes
    }

    func send(_ request: GatewayHTTPRequest) async throws -> GatewayHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = request.body

        do {
            let (bytes, rawResponse) = try await session.bytes(for: urlRequest)
            guard let response = rawResponse as? HTTPURLResponse else {
                bytes.task.cancel()
                throw SDKError.backendProtocolMismatch("gateway returned a non-HTTP response")
            }
            if response.expectedContentLength > Int64(maximumResponseBytes) {
                bytes.task.cancel()
                throw SDKError.backendProtocolMismatch("gateway response exceeds the configured limit")
            }
            var body = Data()
            if response.expectedContentLength > 0 {
                body.reserveCapacity(min(Int(response.expectedContentLength), maximumResponseBytes))
            }
            for try await byte in bytes {
                guard body.count < maximumResponseBytes else {
                    bytes.task.cancel()
                    throw SDKError.backendProtocolMismatch(
                        "gateway response exceeds the configured limit"
                    )
                }
                body.append(byte)
            }
            return GatewayHTTPResponse(
                statusCode: response.statusCode,
                mimeType: response.mimeType,
                correlationID: response.value(forHTTPHeaderField: "x-correlation-id")
                    ?? response.value(forHTTPHeaderField: "x-request-id"),
                body: body
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SDKError {
            throw error
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch {
            // Never include URLRequest, URLSession errors, response bodies, or
            // headers here: they may contain the bearer token or signed PSBT.
            throw SDKError.backendUnavailable()
        }
    }
}

private final class RejectRedirectsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
