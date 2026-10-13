import CryptoKit
import Foundation
internal import UtexoLocalSignerBindings
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
    /// Explicit development-only opt-in for the provisional gateway PSBT
    /// profile. This defaults off until backend fixtures and the exact
    /// idempotency/reconciliation contract are frozen.
    public let allowUnverifiedPsbtProfile: Bool
    public let requestTimeout: TimeInterval
    public let maximumPreparationTTL: TimeInterval
    public let maximumResponseBytes: Int

    fileprivate let apiKeyProvider: any WalletAPIKeyProvider
    fileprivate let chainContextProvider: (any WalletChainContextProvider)?
    fileprivate let requiresApplicationChainContext: Bool

    /// Creates a pinned gateway configuration.
    ///
    /// Plain HTTP is accepted only for an exact loopback host so local
    /// containers remain usable without weakening production transport.
    public init(
        baseURL: URL,
        bearerToken: String,
        network: Network,
        allowInsecureLocalDevelopment: Bool = false,
        allowUnverifiedPsbtProfile: Bool = false,
        requestTimeout: TimeInterval = 30,
        maximumPreparationTTL: TimeInterval = 3_600,
        maximumResponseBytes: Int = 1_048_576,
        chainContextProvider: (any WalletChainContextProvider)? = nil,
        requiresApplicationChainContext: Bool = false
    ) throws {
        guard !bearerToken.isEmpty, bearerToken.utf8.count <= 512,
              bearerToken.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f }) else {
            throw SDKError.invalidArgument("bearerToken", "must be a non-empty bounded ASCII header value")
        }
        try self.init(
            baseURL: baseURL, apiKeyProvider: LegacyStaticAPIKeyProvider(token: bearerToken),
            network: network, allowInsecureLocalDevelopment: allowInsecureLocalDevelopment,
            allowUnverifiedPsbtProfile: allowUnverifiedPsbtProfile, requestTimeout: requestTimeout,
            maximumPreparationTTL: maximumPreparationTTL, maximumResponseBytes: maximumResponseBytes,
            chainContextProvider: chainContextProvider,
            requiresApplicationChainContext: requiresApplicationChainContext
        )
    }

    init(
        baseURL: URL,
        apiKeyProvider: any WalletAPIKeyProvider,
        network: Network,
        allowInsecureLocalDevelopment: Bool = false,
        allowUnverifiedPsbtProfile: Bool = false,
        requestTimeout: TimeInterval = 30,
        maximumPreparationTTL: TimeInterval = 3_600,
        maximumResponseBytes: Int = 1_048_576,
        chainContextProvider: (any WalletChainContextProvider)? = nil,
        requiresApplicationChainContext: Bool = false
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
        // Foundation retains brackets in URLComponents.host for an IPv6 literal.
        let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]
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
        self.apiKeyProvider = apiKeyProvider
        self.network = network
        self.allowInsecureLocalDevelopment = allowInsecureLocalDevelopment
        self.allowUnverifiedPsbtProfile = allowUnverifiedPsbtProfile
        self.requestTimeout = requestTimeout
        self.maximumPreparationTTL = maximumPreparationTTL
        self.maximumResponseBytes = maximumResponseBytes
        self.chainContextProvider = chainContextProvider
        self.requiresApplicationChainContext = requiresApplicationChainContext
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
                "allowUnverifiedPsbtProfile": allowUnverifiedPsbtProfile,
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
    static let javascriptMaximumSafeInteger: UInt64 = 9_007_199_254_740_991

    private let configuration: GatewayBackendConfiguration
    private let transport: any GatewayHTTPTransport
    private let nowMilliseconds: @Sendable () throws -> UInt64
    private let identityObserver: (@Sendable (String) async throws -> Void)?
    private var activeSession: BackendSession?
    private var activeWalletID: WalletID?
    private var boundWalletID: WalletID?
    private var boundGatewayUserID: String?
    private var validatedCredentialDigest: Data?

    nonisolated var hasApplicationChainContextProvider: Bool {
        configuration.chainContextProvider != nil
    }

    func signingEngineWithFreshContext(_ signer: any LocalSigningEngine) async throws -> any LocalSigningEngine {
        guard configuration.requiresApplicationChainContext else { return signer }
        guard let provider = configuration.chainContextProvider else {
            throw SDKError.unsupported("configure chainContextProvider for local gateway signing")
        }
        let context: WalletChainContext
        do { context = try await provider.loadChainContext(network: configuration.network) }
        catch is CancellationError { throw CancellationError() }
        catch { throw SDKError.policyRejected("trusted chain context is unavailable") }
        try Task.checkCancellation()
        let now = try nowMilliseconds() / 1_000
        guard context.network == configuration.network else {
            throw SDKError.wrongNetwork(expected: configuration.network, actual: context.network)
        }
        guard context.tipHeight < 500_000_000,
              context.observedAt.rawValue <= now || context.observedAt.rawValue - now <= 30,
              context.observedAt.rawValue >= now || now - context.observedAt.rawValue <= 300 else {
            throw SDKError.policyRejected("trusted chain context has the wrong network or is not fresh")
        }
        return try signer.withGatewayContext(.init(maximumBlockHeight: context.tipHeight))
    }

    public init(configuration: GatewayBackendConfiguration) {
        self.configuration = configuration
        transport = URLSessionGatewayTransport(
            requestTimeout: configuration.requestTimeout,
            maximumResponseBytes: configuration.maximumResponseBytes
        )
        nowMilliseconds = { try checkedUnixMilliseconds() }
        identityObserver = nil
    }

    init(
        configuration: GatewayBackendConfiguration,
        identityObserver: @escaping @Sendable (String) async throws -> Void
    ) {
        self.configuration = configuration
        transport = URLSessionGatewayTransport(
            requestTimeout: configuration.requestTimeout,
            maximumResponseBytes: configuration.maximumResponseBytes
        )
        nowMilliseconds = { try checkedUnixMilliseconds() }
        self.identityObserver = identityObserver
    }

    init(
        configuration: GatewayBackendConfiguration,
        transport: any GatewayHTTPTransport,
        identityObserver: (@Sendable (String) async throws -> Void)? = nil,
        nowMilliseconds: @escaping @Sendable () throws -> UInt64 = {
            try checkedUnixMilliseconds()
        }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.nowMilliseconds = nowMilliseconds
        self.identityObserver = identityObserver
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
            guard gatewayUserID == response.userId else { throw SDKError.operationJournalUnavailable }
        } catch {
            throw SDKError.backendProtocolMismatch("gateway returned a malformed user identity")
        }
        try await identityObserver?(gatewayUserID)

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
        try Task.checkCancellation()
        try requireContext(request.context)
        guard response.fingerprint == request.identity.masterFingerprint else {
            throw SDKError.backendProtocolMismatch("xpub registration returned the wrong fingerprint")
        }
        // PR #174 does not return the derivation index for this address, so it
        // cannot become a ReservedAddress. Parse it only as a bounded response
        // field; getAddress remains fail-closed below.
        do {
            let address = try BitcoinAddress(response.address)
            guard address.value == response.address else {
                throw SDKError.backendProtocolMismatch("registration returned a noncanonical address")
            }
        } catch {
            throw SDKError.backendProtocolMismatch("registration returned a malformed address")
        }
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
        try Task.checkCancellation()
        try requireContext(context)
        return BTCBalance(
            vanilla: try response.btc.vanilla.satoshis,
            colored: try response.btc.colored.satoshis
        )
    }

    public func getAssetBalance(context: BackendContext, assetID: AssetID) async throws -> AssetBalance {
        try requireContext(context)
        let response: WalletBalancesResponse = try await get(path: "/v1/wallet/balances")
        try Task.checkCancellation()
        try requireContext(context)
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

    public func reserveAddress(_ request: ReserveAddressRequest) async throws -> ReservedAddress {
        try requireContext(request.context)
        guard request.account == .vanilla else {
            throw SDKError.unsupported("gateway address allocation supports the vanilla account only")
        }
        // Both methods allocate fresh addresses in the lightweight gateway.
        // Never synthesize a persistent pin/reuse policy on this client.
        let wire: GatewayAddressWire = try await get(path: "/v1/wallet/address")
        try Task.checkCancellation()
        try requireContext(request.context)
        return try gatewayMapped {
            guard let derivation = wire.derivation,
                  derivation.account == "vanilla", derivation.keychain == 0,
                  derivation.index < 0x8000_0000,
                  derivation.scriptHex.count == 68, derivation.scriptHex.hasPrefix("5120"),
                  derivation.scriptHex == derivation.scriptHex.lowercased(),
                  isBoundedEvenHex(derivation.scriptHex, maximumBytes: 34) else {
                throw SDKError.backendProtocolMismatch("gateway address has no valid derivation evidence")
            }
            let coin = configuration.network == .mainnet ? 0 : 1
            guard derivation.derivationPath == "m/86'/\(coin)'/0'/0/\(derivation.index)" else {
                throw SDKError.backendProtocolMismatch("gateway address derivation path differs from the wallet profile")
            }
            let address = try BitcoinAddress(wire.address)
            guard address.value == wire.address else {
                throw SDKError.backendProtocolMismatch("gateway returned a noncanonical address")
            }
            // UTEXOWallet independently derives this address AND script locally.
            return ReservedAddress(address: address, account: .vanilla, keychain: .external,
                index: derivation.index, scriptPubkeyHex: derivation.scriptHex,
                derivationPath: derivation.derivationPath)
        }
    }

    public func estimateFeeRate(context: BackendContext, targetBlocks: BlockCount) async throws -> FeeEstimate {
        try requireContext(context)
        guard (1...1_008).contains(targetBlocks.rawValue) else {
            throw SDKError.invalidArgument("blocks", "must be between 1 and 1008")
        }
        let wire: GatewayFeeWire = try await get(path: "/v1/onchain/fee-estimate?blocks=\(targetBlocks.rawValue)")
        try Task.checkCancellation()
        try requireContext(context)
        guard wire.blocks == targetBlocks.rawValue, (1...1_008).contains(wire.sourceBlocks),
              (1...1_000).contains(wire.feeRateSatPerVb) else {
            throw SDKError.backendProtocolMismatch("gateway returned an invalid fee estimate")
        }
        guard wire.sourceBlocks <= wire.blocks else {
            throw SDKError.unsupported("gateway cannot estimate the requested confirmation target")
        }
        // 1000 is also the service's silent cap. Without the uncapped value we
        // cannot label it as an adequate estimate for the requested target.
        guard wire.feeRateSatPerVb < 1_000 else {
            throw SDKError.unsupported("gateway fee estimate may have been capped at 1000 sat/vB")
        }
        return try FeeEstimate(feeRate: FeeRate(milliSatsPerVByte: wire.feeRateSatPerVb * 1_000),
            targetBlocks: targetBlocks, measuredAt: nil)
    }

    public func listUnspents(context: BackendContext) async throws -> [Unspent] {
        try requireContext(context)
        let wire: GatewayUnspentsWire = try await get(path: "/v1/wallet/unspents")
        try Task.checkCancellation()
        try requireContext(context)
        return try gatewayMapped {
            let result = try wire.unspents.map { try $0.model() }
            guard Set(result.map(\.utxo.outpoint)).count == result.count else {
                throw SDKError.backendProtocolMismatch("gateway repeated an unspent outpoint")
            }
            return result
        }
    }

    public func listAssets(context: BackendContext) async throws -> ListAssets {
        try requireContext(context)
        let wire: GatewayAssetsWire = try await get(path: "/v1/wallet/balances")
        try Task.checkCancellation()
        try requireContext(context)
        return try gatewayMapped { try wire.model() }
    }

    public func listTransfers(context: BackendContext, assetID: AssetID?) async throws -> [Transfer] {
        try requireContext(context)
        var route = URLComponents()
        route.path = "/v1/wallet/transfers"
        if let assetID { route.queryItems = [URLQueryItem(name: "assetId", value: assetID.value)] }
        // Fastify treats '+' as a form-encoded space; URLComponents does not.
        route.percentEncodedQuery = route.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let path = route.string else { throw SDKError.invariant("invalid transfer route") }
        let wire: GatewayTransfersWire = try await get(path: path)
        try Task.checkCancellation()
        try requireContext(context)
        return try gatewayMapped {
            let result = try wire.transfers.map { try $0.model() }
            guard assetID == nil || result.allSatisfy({ $0.assetID == assetID }) else {
                throw SDKError.backendProtocolMismatch("gateway returned transfers for another asset")
            }
            guard Set(result.map(\.index)).count == result.count else {
                throw SDKError.backendProtocolMismatch("gateway repeated a transfer index")
            }
            return result
        }
    }

    public func blindReceive(context: BackendContext, request: InvoiceRequest) async throws -> InvoiceReceiveData {
        try await receiveWithBatch(context: context, request: request, witness: false)
    }

    public func witnessReceive(context: BackendContext, request: InvoiceRequest) async throws -> InvoiceReceiveData {
        try await receiveWithBatch(context: context, request: request, witness: true)
    }

    private func receiveWithBatch(context: BackendContext, request: InvoiceRequest, witness: Bool) async throws -> InvoiceReceiveData {
        let result = try await onchainReceive(context: context, request: OnchainReceiveRequest(
            amount: request.amount, assetID: request.assetID, minConfirmations: request.minConfirmations,
            duration: request.duration, witness: witness))
        guard let batch = result.batchTransferIndex, let recipient = result.recipientID else {
            throw SDKError.backendProtocolMismatch("gateway receive omitted native batch identity; do not automatically retry receive creation")
        }
        return try InvoiceReceiveData(invoice: result.invoice, recipientID: recipient,
            expirationTimestamp: result.expirationTimestamp, batchTransferIndex: batch)
    }

    public func syncWallet(context: BackendContext) async throws -> SyncResult {
        try requireContext(context)
        // The gateway awaits BTC sync AND RGB refresh before returning this
        // acknowledgment. It does not expose an authoritative chain tip/time.
        let response: WalletSyncResponse = try await request(
            method: .post, path: "/v1/wallet/sync", body: nil,
            expectedStatusCode: 200, context: .init()
        )
        guard response.status == "ok" else {
            throw SDKError.backendProtocolMismatch("wallet sync did not acknowledge completion")
        }
        try Task.checkCancellation()
        // A legacy SPI adapter may be accessed directly while shutdown runs;
        // never hand its result into a replacement local session.
        try requireContext(context)
        let observed = try nowMilliseconds()
        guard observed <= Self.javascriptMaximumSafeInteger else {
            throw SDKError.invalidState(operation: "read local clock", state: "outside supported Unix time range")
        }
        return SyncResult(completedAt: .init(rawValue: observed / 1_000), tipHeight: nil)
    }

    public func refreshWallet(context: BackendContext) async throws -> SyncResult {
        try await syncWallet(context: context)
    }

    public func onchainReceive(
        context: BackendContext,
        request: OnchainReceiveRequest
    ) async throws -> OnchainReceiveResponse {
        try requireContext(context)
        let duration = request.duration?.value ?? 86_400
        guard (60...2_592_000).contains(duration) else {
            throw SDKError.invalidArgument("durationSeconds", "gateway supports 60 through 2592000 seconds")
        }
        guard request.minConfirmations.rawValue <= 100 else {
            throw SDKError.invalidArgument("minConfirmations", "gateway supports 0 through 100")
        }
        let amount = request.amount.flatMap { UInt64($0.decimal) }
        guard request.amount == nil || (amount != nil && amount! <= Self.javascriptMaximumSafeInteger) else {
            throw SDKError.invalidArgument("amount", "exceeds the gateway's exact JSON integer range")
        }
        let startedAt = try receiveClockSeconds()
        let wire: WalletReceiveResponse = try await post(
            path: "/v1/wallet/receive",
            body: WalletReceiveBody(
                mode: request.witness ? "witness" : "blind", assetId: request.assetID?.value,
                amount: amount, durationSeconds: duration,
                minConfirmations: request.minConfirmations.rawValue
            ),
            expectedStatusCode: 201
        )
        try Task.checkCancellation()
        try requireContext(context)
        let completedAt = try receiveClockSeconds()
        guard completedAt >= startedAt else {
            throw SDKError.backendProtocolMismatch("local clock changed during receive creation")
        }
        guard wire.mode == (request.witness ? "witness" : "blind") else {
            throw SDKError.backendProtocolMismatch("gateway changed the requested receive mode")
        }
        do {
            let invoice = try RGBInvoice(wire.invoice)
            guard invoice.value == wire.invoice else {
                throw SDKError.backendProtocolMismatch("gateway returned a noncanonical invoice envelope")
            }
            let response = try OnchainReceiveResponse(
                invoice: invoice, recipientID: wire.recipientId,
                expirationTimestamp: wire.expirationTimestamp.map { .init(rawValue: $0) },
                batchTransferIndex: wire.batchTransferIdx
            )
            try gatewaySafeInteger(wire.expirationTimestamp)
            try gatewaySafeInteger(wire.batchTransferIdx)
            guard response.recipientID == wire.recipientId else {
                throw SDKError.backendProtocolMismatch("gateway returned a noncanonical recipient")
            }
            try validateReceivedRGBInvoice(
                response, request: request, network: configuration.network,
                startedAt: startedAt, completedAt: completedAt, duration: duration
            )
            return response
        } catch {
            // Backend-controlled invoice/parser text is never copied into errors.
            throw SDKError.backendProtocolMismatch("gateway receive invoice does not match local intent")
        }
    }

    private func receiveClockSeconds() throws -> UInt64 {
        let milliseconds = try nowMilliseconds()
        guard milliseconds <= Self.javascriptMaximumSafeInteger else {
            throw SDKError.invalidState(operation: "read local clock", state: "outside supported Unix time range")
        }
        return milliseconds / 1_000
    }

    public func prepareSendBtc(_ request: PrepareSendBtcRequest) async throws -> PreparedTransaction {
        try requireUnverifiedPsbtProfileOptIn()
        try requireContext(request.context.backend)
        try validateRequest(.sendBtc(request.request))
        let wholeSatsPerVByte = try gatewayFeeRate(request.request.feeRate)

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
        try Task.checkCancellation()
        try requireContext(request.context.backend)
        try validateSendBtcIntent(response.intent, request: body)
        return try makePrepared(response, context: request.context, operation: .sendBtc)
    }

    /// Validate the current wire domain before journaling a new logical operation
    /// or asking the credential provider to perform any network work.
    func validateRequest(_ request: LocalOperationRequest) throws {
        _ = try gatewayFeeRate(request.feeRate)
        switch request {
        case .sendBtc(let value):
            guard value.amount.value >= 294 else {
                throw SDKError.invalidArgument("amount", "gateway requires at least 294 satoshis")
            }
            guard !value.skipSync else {
                throw SDKError.unsupported("PR #174 gateway sendBtc skipSync=true")
            }
        case .createUtxos(let value):
            guard (1...50).contains(value.num ?? 5) else {
                throw SDKError.invalidArgument("num", "gateway supports 1 through 50")
            }
            guard (value.size?.value ?? 1_000) >= 330 else {
                throw SDKError.invalidArgument("size", "gateway Taproot outputs require at least 330 satoshis")
            }
            guard !value.skipSync else {
                throw SDKError.unsupported("PR #174 gateway createUtxos skipSync=true")
            }
        case .onchainSend(let value):
            guard let amount = UInt64(value.amount.decimal), amount <= Self.javascriptMaximumSafeInteger else {
                throw SDKError.invalidArgument("amount", "exceeds the gateway exact integer range")
            }
            guard !value.skipSync else { throw SDKError.unsupported("PR #174 gateway onchainSend skipSync=true") }
            guard value.witnessData?.blinding == nil else {
                throw SDKError.unsupported("PR #174 gateway witness blinding")
            }
            guard value.minConfirmations.rawValue <= 100 else {
                throw SDKError.invalidArgument("minConfirmations", "gateway supports at most 100")
            }
            if let witness = value.witnessData, witness.amountSat.value < 294 {
                throw SDKError.invalidArgument("witnessData", "gateway requires at least 294 satoshis")
            }
        }
    }

    private func gatewayFeeRate(_ rate: FeeRate) throws -> UInt64 {
        let feeRate = rate.milliSatsPerVByte
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
        return wholeSatsPerVByte
    }

    private func makePrepared(
        _ response: PreparedResponse, context: OperationRequestContext,
        operation: OperationKind, outputPlan: CreateUtxosOutputPlan? = nil
    ) throws -> PreparedTransaction {
        try validateCanonicalBase64(response.psbt, field: "prepared PSBT")
        let currentTime = try nowMilliseconds()
        let maximumTTLMilliseconds = UInt64(configuration.maximumPreparationTTL * 1_000)
        guard currentTime <= Self.javascriptMaximumSafeInteger,
              response.expiresAt <= Self.javascriptMaximumSafeInteger,
              response.expiresAt > currentTime,
              response.expiresAt - currentTime <= maximumTTLMilliseconds else {
            throw SDKError.backendProtocolMismatch(
                "prepare expiry is stale or exceeds the configured TTL limit"
            )
        }
        let operationID = try gatewayOperationID(response.opId)
        return try PreparedTransaction(
            operationID: operationID,
            idempotencyKey: context.idempotencyKey,
            requestHash: context.requestHash,
            network: configuration.network,
            operation: operation,
            psbtBase64: response.psbt,
            // Flooring is conservative: the client may consider the operation
            // expired up to 999 ms before the gateway does, never after it.
            expiresAt: .init(rawValue: response.expiresAt / 1_000),
            createUtxosOutputPlan: outputPlan
        )
    }

    public func prepareCreateUtxos(_ request: PrepareCreateUtxosRequest) async throws -> PreparedTransaction {
        try requireUnverifiedPsbtProfileOptIn()
        try requireContext(request.context.backend)
        try validateRequest(.createUtxos(request.request))
        let body = try createBody(request.request)
        let response: PreparedResponse = try await post(
            path: "/v1/onchain/create-utxos/prepare", body: body,
            expectedStatusCode: 201,
            idempotency: .init(logicalKey: request.context.idempotencyKey, stage: .prepare)
        )
        try Task.checkCancellation()
        try requireContext(request.context.backend)
        try validateCreateIntent(response.intent, request: body)
        let plan = try extractCreateOutputPlan(response.psbt)
        // This is only a bounded, untrusted origin projection. Before signing,
        // the native signer independently derives every script from local keys
        // and verifies amounts/count, inputs, fees and all transaction policy.
        return try makePrepared(response, context: request.context, operation: .createUtxos, outputPlan: plan)
    }

    private func createBody(_ request: CreateUtxosRequest) throws -> PrepareCreateUtxosBody {
        .init(num: request.num ?? 5, size: request.size?.value ?? 1_000,
              upTo: request.upTo, feeRateSatPerVb: try gatewayFeeRate(request.feeRate))
    }

    public func prepareOnchainSend(_ request: PrepareOnchainSendRequest) async throws -> PreparedTransaction {
        try requireUnverifiedPsbtProfileOptIn()
        try requireContext(request.context.backend)
        try validateRequest(.onchainSend(request.request))
        let body = try assetBody(request.request, validateExpiry: true)
        let response: PreparedResponse = try await post(
            path: "/v1/onchain/send-asset/prepare", body: body, expectedStatusCode: 201,
            idempotency: .init(logicalKey: request.context.idempotencyKey, stage: .prepare))
        try Task.checkCancellation()
        try requireContext(request.context.backend)
        try validateAssetIntent(response.intent, request: body)
        return try makePrepared(response, context: request.context, operation: .onchainSend)
    }

    private func assetBody(_ request: OnchainSendRequest, validateExpiry: Bool) throws -> PrepareSendAssetBody {
        // Recovery must not reject the original intent simply because its
        // invoice has expired since the already-signed submission.
        let invoice = try validateOutgoingRGBInvoice(request, network: configuration.network,
            now: validateExpiry ? nowMilliseconds() / 1_000 : 0)
        guard let assetID = request.assetID ?? invoice.assetID,
              let amount = UInt64(request.amount.decimal), amount <= Self.javascriptMaximumSafeInteger,
              (1...4).contains(invoice.transportEndpoints.count),
              invoice.transportEndpoints.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2_048 }) else {
            throw SDKError.invalidArgument("invoice", "exceeds the gateway asset or transport domain")
        }
        return .init(assetId: assetID.value, amount: amount, recipientId: invoice.recipientID,
            witnessAmountSat: request.witnessData?.amountSat.value,
            transportEndpoints: invoice.transportEndpoints, donation: request.donation,
            minConfirmations: request.minConfirmations.rawValue,
            feeRateSatPerVb: try gatewayFeeRate(request.feeRate))
    }

    private func validateAssetIntent(_ intent: PreparedIntent, request: PrepareSendAssetBody) throws {
        guard intent.kind == "send_asset", intent.recipients.isEmpty, intent.utxos == nil,
              intent.feeRateSatPerVb == request.feeRateSatPerVb, let asset = intent.asset,
              asset.assetId == request.assetId, asset.amount == request.amount,
              asset.recipientId == request.recipientId, asset.witnessAmountSat == request.witnessAmountSat,
              asset.transportEndpoints == request.transportEndpoints else {
            throw SDKError.backendProtocolMismatch("prepare intent changed the requested RGB recipient, asset or amount")
        }
    }

    func submitOnchainSend(
        _ request: SignedTransactionSubmission, prepared: PreparedTransaction
    ) async throws -> BackendOperationResult {
        try requireUnverifiedPsbtProfileOptIn()
        try requireContext(request.context.backend)
        guard prepared.operation == .onchainSend, prepared.operationID == request.operationID,
              prepared.idempotencyKey == request.context.idempotencyKey,
              prepared.requestHash == request.context.requestHash,
              prepared.network == request.context.backend.network,
              prepared.createUtxosOutputPlan == nil else {
            throw SDKError.backendProtocolMismatch("RGB submission differs from retained preparation")
        }
        try validateCanonicalBase64(request.signedPsbtBase64, field: "signed PSBT")
        let response: CompleteResponse = try await post(
            path: "/v1/onchain/send-asset/complete",
            body: CompleteBody(opId: request.operationID.value, signedPsbt: request.signedPsbtBase64),
            expectedStatusCode: 200,
            idempotency: .init(logicalKey: request.context.idempotencyKey, stage: .complete),
            phase: .submit(request.operationID))
        guard let txid = try? TransactionID(response.txid), response.txid == txid.hex,
              txid == request.validation.unsignedTxid,
              response.batchTransferIdx.map({ $0 <= Self.javascriptMaximumSafeInteger }) ?? true else {
            throw SDKError.operationAmbiguous(request.operationID)
        }
        return .onchainSend(operationID: request.operationID,
            result: .init(txid: txid, batchTransferIndex: response.batchTransferIdx))
    }

    private func extractCreateOutputPlan(_ psbt: String) throws -> CreateUtxosOutputPlan {
        try validateCanonicalBase64(psbt, field: "prepared PSBT")
        do {
            let projected = try UtexoLocalSignerBindings.extractGatewayCreateUtxosOutputs(
                psbtBase64: psbt, network: configuration.network.ffi
            )
            return try CreateUtxosOutputPlan(outputs: projected.map { output in
                guard output.account == .colored, output.keychain == .external else {
                    throw SDKError.backendProtocolMismatch("create projection contains an unexpected origin")
                }
                return try ExpectedWalletOutput(
                    account: .colored, keychain: .external, index: output.index,
                    amount: Satoshis(output.amountSats)
                )
            })
        } catch {
            throw SDKError.backendProtocolMismatch("gateway create PSBT has no valid bounded output plan")
        }
    }

    private func validateCreateIntent(_ intent: PreparedIntent, request: PrepareCreateUtxosBody) throws {
        guard intent.kind == "create_utxos", intent.feeRateSatPerVb == request.feeRateSatPerVb,
              intent.recipients.isEmpty, let utxos = intent.utxos,
              utxos.num == request.num, utxos.size == request.size, utxos.upTo == request.upTo else {
            throw SDKError.backendProtocolMismatch("prepare intent changed the requested create options")
        }
        guard intent.asset == nil else {
            throw SDKError.backendProtocolMismatch("create intent contains RGB allowances")
        }
    }

    func submitCreateUtxos(
        _ request: SignedTransactionSubmission, prepared: PreparedTransaction
    ) async throws -> BackendOperationResult {
        try requireUnverifiedPsbtProfileOptIn()
        try requireContext(request.context.backend)
        guard prepared.operation == .createUtxos, prepared.operationID == request.operationID,
              prepared.idempotencyKey == request.context.idempotencyKey,
              prepared.requestHash == request.context.requestHash,
              prepared.network == request.context.backend.network,
              let plan = prepared.createUtxosOutputPlan, (1...50).contains(plan.outputs.count) else {
            throw SDKError.backendProtocolMismatch("create submission differs from retained preparation")
        }
        try validateCanonicalBase64(request.signedPsbtBase64, field: "signed PSBT")
        let response: CreateCompleteResponse = try await post(
            path: "/v1/onchain/create-utxos/complete",
            body: CompleteBody(opId: request.operationID.value, signedPsbt: request.signedPsbtBase64),
            expectedStatusCode: 200,
            idempotency: .init(logicalKey: request.context.idempotencyKey, stage: .complete),
            phase: .submit(request.operationID)
        )
        guard let value = response.txid, let txid = try? TransactionID(value),
              value == txid.hex, txid == request.validation.unsignedTxid,
              response.utxosCreated == UInt64(plan.outputs.count) else {
            throw SDKError.operationAmbiguous(request.operationID)
        }
        return .createUtxos(operationID: request.operationID,
                            result: .init(txid: txid, createdUtxoCount: UInt16(plan.outputs.count)))
    }

    public func submitSignedTransaction(
        _ request: SignedTransactionSubmission
    ) async throws -> BackendOperationResult {
        try requireUnverifiedPsbtProfileOptIn()
        try requireContext(request.context.backend)
        try validateCanonicalBase64(request.signedPsbtBase64, field: "signed PSBT")
        let body = CompleteBody(
            opId: request.operationID.value,
            signedPsbt: request.signedPsbtBase64
        )
        // The updated backend README confirms distinct stable phase keys.
        // Domain separation preserves one public logical key across Swift and
        // Kotlin while avoiding the server's cross-route key collision. Atomic
        // prepare persistence and completion recovery still need backend work.
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
        guard response.txid == txid.hex, txid == request.validation.unsignedTxid else {
            throw SDKError.operationAmbiguous(request.operationID)
        }
        return .sendBtc(
            operationID: request.operationID,
            txid: txid
        )
    }

    /// A status lookup without retained local signing evidence cannot establish
    /// the caller's outcome. The coordinator uses the private checkpoint-aware
    /// lookup below; this compatibility SPI never guesses the missing evidence.
    public func getOperation(
        context: BackendContext,
        operationID: OperationID
    ) async throws -> BackendOperationStatus {
        try requireContext(context)
        throw SDKError.unsupported("gateway reconciliation requires a retained local signed checkpoint")
    }

    /// Read-only recovery for the status contract added in PR #174 (7f318a8).
    /// Never signs, retries complete, prepares a replacement, or weakens the
    /// new-operation profile gate. Only a matching completed BTC/create/RGB result can
    /// advance the journal to terminal state.
    func getOperationForRecovery(
        context: BackendContext,
        checkpoint: OperationCheckpoint,
        request: SendBtcRequest
    ) async throws -> BackendOperationStatus {
        try await recoverOperation(context: context, checkpoint: checkpoint, request: .sendBtc(request))
    }

    func getOperationForRecovery(
        context: BackendContext,
        checkpoint: OperationCheckpoint,
        request: CreateUtxosRequest
    ) async throws -> BackendOperationStatus {
        try await recoverOperation(context: context, checkpoint: checkpoint, request: .createUtxos(request))
    }

    func getOperationForRecovery(
        context: BackendContext, checkpoint: OperationCheckpoint, request: OnchainSendRequest
    ) async throws -> BackendOperationStatus {
        try await recoverOperation(context: context, checkpoint: checkpoint, request: .onchainSend(request))
    }

    private func recoverOperation(
        context: BackendContext,
        checkpoint: OperationCheckpoint,
        request: LocalOperationRequest
    ) async throws -> BackendOperationStatus {
        try requireContext(context)
        guard checkpoint.phase == .submitting,
              checkpoint.walletID == context.walletID,
              checkpoint.operationKind == request.kind,
              checkpoint.idempotencyKey == request.idempotencyKey,
              checkpoint.requestHash == (try request.hash(network: context.network)),
              let operationID = checkpoint.operationID,
              let prepared = checkpoint.preparedTransaction,
              prepared.network == context.network,
              let signedPSBT = checkpoint.signedPsbtBase64,
              let validation = checkpoint.validation else {
            throw SDKError.backendProtocolMismatch("operation recovery lacks matching local signing evidence")
        }
        _ = try gatewayOperationID(operationID.value)
        try validateCanonicalBase64(prepared.psbtBase64, field: "retained prepared PSBT")
        try validateCanonicalBase64(signedPSBT, field: "retained signed PSBT")
        guard let preparedBytes = Data(base64Encoded: prepared.psbtBase64),
              SHA256.hash(data: preparedBytes).map({ String(format: "%02x", $0) }).joined()
                == validation.psbtSHA256 else {
            throw SDKError.backendProtocolMismatch("operation recovery validation does not bind the retained PSBT")
        }
        try validateRequest(request)

        let response: OperationStatusResponse = try await get(
            path: "/v1/onchain/operations/\(operationID.value)"
        )
        try Task.checkCancellation()
        try requireContext(context)
        let wireKind = request.kind == .sendBtc ? "send_btc" : request.kind == .createUtxos ? "create_utxos" : "send_asset"
        guard try gatewayOperationID(response.opId) == operationID, response.kind == wireKind else {
            throw SDKError.backendProtocolMismatch("operation status changed its identity or kind")
        }
        switch request {
        case .sendBtc(let value):
            try validateSendBtcIntent(response.intent, request: .init(
                address: value.address.value, amountSat: value.amount.value,
                feeRateSatPerVb: value.feeRate.milliSatsPerVByte / 1_000
            ))
        case .createUtxos(let value):
            try validateCreateIntent(response.intent, request: createBody(value))
            // Re-extract from the exact retained PSBT rather than accepting a
            // mutable server count or a different output plan during recovery.
            guard try extractCreateOutputPlan(prepared.psbtBase64) == prepared.createUtxosOutputPlan else {
                throw SDKError.backendProtocolMismatch("retained create plan differs from its PSBT")
            }
            try request.verifyPreparedPlan(prepared, policy: .default)
        case .onchainSend(let value):
            try validateAssetIntent(response.intent, request: assetBody(value, validateExpiry: false))
        }
        // These are JS millisecond integers, not local seconds. Compare the
        // stored conservative floor, without imposing current expiry: an old
        // completed operation must remain recoverable after its prepare TTL.
        guard response.createdAt > 0,
              response.createdAt < response.expiresAt,
              response.expiresAt <= Self.javascriptMaximumSafeInteger,
              response.expiresAt - response.createdAt <= UInt64(configuration.maximumPreparationTTL * 1_000),
              response.expiresAt / 1_000 == prepared.expiresAt.rawValue else {
            throw SDKError.backendProtocolMismatch("operation status changed its preparation timestamps")
        }
        let txid: TransactionID?
        if let value = response.txid {
            guard isASCIIHex(value, exactByteCount: 64, lowercaseOnly: true),
                  let parsed = try? TransactionID(value), parsed == validation.unsignedTxid else {
                throw SDKError.backendProtocolMismatch("operation status differs from the locally signed transaction")
            }
            txid = parsed
        } else {
            txid = nil
        }
        guard response.mayHaveBroadcast == (response.state != .completed && txid != nil) else {
            throw SDKError.backendProtocolMismatch("operation status has contradictory broadcast metadata")
        }
        if response.state == .completed {
            guard let txid else {
                throw SDKError.backendProtocolMismatch("completed Bitcoin operation has no transaction ID")
            }
            let result: BackendOperationResult
            if request.kind == .createUtxos {
                guard let count = prepared.createUtxosOutputPlan?.outputs.count, (1...50).contains(count) else {
                    throw SDKError.backendProtocolMismatch("completed create operation has no retained output plan")
                }
                // Status currently omits the count. A matching completed txid
                // authenticates which transaction succeeded; its locally
                // validated retained plan supplies the exact count.
                result = .createUtxos(operationID: operationID,
                    result: .init(txid: txid, createdUtxoCount: UInt16(count)))
            } else if request.kind == .onchainSend {
                guard response.batchTransferIdx.map({ $0 <= Self.javascriptMaximumSafeInteger }) ?? true else {
                    throw SDKError.backendProtocolMismatch("operation status contains an invalid batch index")
                }
                result = .onchainSend(operationID: operationID,
                    result: .init(txid: txid, batchTransferIndex: response.batchTransferIdx))
            } else {
                result = .sendBtc(operationID: operationID, txid: txid)
            }
            return .succeeded(operationID: operationID, result: result)
        }
        // GET is intentionally not queued behind complete. Even expired +
        // txid:null can race an in-flight broadcast or observe a crash before
        // the gateway persists txid. Neither proves failure/non-broadcast.
        return .pending(operationID: operationID, phase: "gateway_\(response.state.rawValue)")
    }

    public func preflightOperation(_ operation: OperationKind) async throws {
        switch operation {
        case .sendBtc, .createUtxos, .onchainSend:
            try requireUnverifiedPsbtProfileOptIn()
        case .inflate:
            throw SDKError.unsupported(
                "PR #174 gateway \(operation.rawValue) operation profile"
            )
        }
    }

    private func requireUnverifiedPsbtProfileOptIn() throws {
        guard configuration.allowUnverifiedPsbtProfile else {
            throw SDKError.unsupported(
                "spending requires an explicitly enabled, unverified gateway PSBT profile"
            )
        }
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
        guard intent.asset == nil else {
            throw SDKError.backendProtocolMismatch("Bitcoin intent contains RGB allowances")
        }
        guard intent.utxos == nil else {
            throw SDKError.backendProtocolMismatch("Bitcoin intent contains create output allowances")
        }
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
              let url = URL(string: path, relativeTo: configuration.baseURL)?.absoluteURL,
              url.scheme == configuration.baseURL.scheme, url.host == configuration.baseURL.host,
              url.port == configuration.baseURL.port, url.user == nil, url.password == nil,
              url.fragment == nil else {
            throw SDKError.invariant("gateway route is invalid")
        }
        let credential: WalletAPIKey
        do {
            credential = try await configuration.apiKeyProvider.loadAPIKey()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A user-supplied provider may include credentials in its error text.
            throw SDKError.keyAccessFailed
        }
        defer { credential.close() }
        let authorization = try credential.withBytes { "Bearer " + String(decoding: $0, as: UTF8.self) }
        let credentialDigest = Data(SHA256.hash(data: Data(authorization.utf8)))
        try Task.checkCancellation()
        if path != "/v1/me", credentialDigest != validatedCredentialDigest,
           let boundGatewayUserID {
            try await validateRotatedCredential(authorization: authorization, expectedUserID: boundGatewayUserID)
            validatedCredentialDigest = credentialDigest
        }
        // Identity validation may suspend and an injected/custom transport can
        // return despite cancellation. Never start the requested wallet effect
        // after cancellation while waiting for that read-only preflight.
        try Task.checkCancellation()
        var headers = [
            "Accept": "application/json",
            "Authorization": authorization,
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
            let result = try JSONDecoder().decode(Response.self, from: response.body)
            if path == "/v1/me" { validatedCredentialDigest = credentialDigest }
            return result
        } catch {
            throw context.responseContractFailure(
                "successful response does not match the gateway contract",
                correlationID: correlationID
            )
        }
    }

    private func validateRotatedCredential(authorization: String, expectedUserID: String) async throws {
        let response: GatewayHTTPResponse
        do {
            response = try await transport.send(.init(
                method: .get,
                url: configuration.baseURL.appendingPathComponent("v1/me"),
                headers: ["Accept": "application/json", "Authorization": authorization],
                body: nil
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SDKError.backendUnavailable()
        }
        guard response.statusCode == 200, response.mimeType?.lowercased() == "application/json",
              let identity = try? JSONDecoder().decode(MeResponse.self, from: response.body),
              identity.userId == expectedUserID else {
            throw SDKError.backendProtocolMismatch("rotated credential could not be bound to the existing wallet user")
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
            // A complete response only describes this HTTP attempt. It cannot
            // prove that an earlier/in-flight attempt did not broadcast. Keep
            // the submitted identity so the coordinator can reconcile once.
            if let operationID = context.submittedOperationID {
                return .operationAmbiguous(operationID)
            }
            return .operationConflict(idempotency.logicalKey)
        }
        if statusCode == 410, backendCode == "OP_EXPIRED", let operationID = context.operationID {
            // The gateway checks TTL before inspecting a prior possibly-
            // broadcast txid. Expiry after dispatch is not proof of failure.
            return .operationAmbiguous(operationID)
        }
        // The gateway persists that this operation completed but omits the
        // transaction ID from this response. Treating it as rejection could
        // cause an application to initiate a second spend. The coordinator
        // resolves this only via a read bound to its retained signed evidence.
        if statusCode == 409, backendCode == "OP_ALREADY_COMPLETED",
           let operationID = context.operationID {
            return .operationAmbiguous(operationID)
        }
        if statusCode == 409, backendCode == "OP_KIND_MISMATCH" {
            if let operationID = context.submittedOperationID {
                return .operationAmbiguous(operationID)
            }
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
        // No current completion error envelope contains durable, authoritative
        // proof of a pre-broadcast outcome bound to our operation. In particular,
        // an unknown/proxy/malformed 4xx is not safe to persist as rejection.
        // Even PSBT_MISMATCH proves only what this attempt rejected, not whether
        // an earlier timed-out attempt broadcast. Retain signed evidence and
        // reconcile read-only until the backend supplies that stronger contract.
        if let operationID = context.submittedOperationID {
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
    private static let provisionalDomain = "utexo.gateway.idempotency.v1"

    let logicalKey: IdempotencyKey
    let stage: GatewayOperationStage

    var wireValue: String {
        var hasher = SHA256()
        for field in [Self.provisionalDomain, stage.rawValue, logicalKey.value] {
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

private struct WalletSyncResponse: Decodable {
    let status: String
}

private struct WalletReceiveBody: Encodable {
    let mode: String
    let assetId: String?
    let amount: UInt64?
    let durationSeconds: UInt64
    let minConfirmations: UInt32
}

private struct WalletReceiveResponse: Decodable {
    let invoice: String
    let recipientId: String
    let expirationTimestamp: UInt64?
    let mode: String
    let batchTransferIdx: UInt64?

    private enum CodingKeys: String, CodingKey { case invoice, recipientId, expirationTimestamp, mode, batchTransferIdx }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        invoice = try container.decode(String.self, forKey: .invoice)
        recipientId = try container.decode(String.self, forKey: .recipientId)
        mode = try container.decode(String.self, forKey: .mode)
        batchTransferIdx = try container.decodeIfPresent(UInt64.self, forKey: .batchTransferIdx)
        // The gateway schema requires this key, but permits an explicit null.
        // The invoice's independently decoded expiry remains mandatory.
        guard container.contains(.expirationTimestamp) else {
            throw DecodingError.keyNotFound(CodingKeys.expirationTimestamp, .init(
                codingPath: decoder.codingPath, debugDescription: "required receive expiry field is absent"
            ))
        }
        expirationTimestamp = try container.decodeIfPresent(UInt64.self, forKey: .expirationTimestamp)
    }
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
            // Values originate at the backend, not in caller arguments. Keep
            // a corrupt/native-defaulted response distinct from app misuse.
            guard settled <= Satoshis.maximum,
                  future <= Satoshis.maximum,
                  spendable <= Satoshis.maximum else {
                throw SDKError.backendProtocolMismatch("BTC balance exceeds the Bitcoin supply bound")
            }
            return try Balance(
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

private struct PrepareCreateUtxosBody: Encodable {
    let num: UInt16
    let size: UInt64
    let upTo: Bool
    let feeRateSatPerVb: UInt64
}

private struct PrepareSendAssetBody: Encodable {
    let assetId: String
    let amount: UInt64
    let recipientId: String
    let witnessAmountSat: UInt64?
    let transportEndpoints: [String]
    let donation: Bool
    let minConfirmations: UInt32
    let feeRateSatPerVb: UInt64
}

private struct PreparedResponse: Decodable {
    let opId: String
    let psbt: String
    let intent: PreparedIntent
    let expiresAt: UInt64
}

private struct OperationStatusResponse: Decodable {
    enum State: String, Decodable { case pending, completed, expired }
    let opId: String
    let kind: String
    let state: State
    let txid: String?
    let mayHaveBroadcast: Bool
    let intent: PreparedIntent
    let createdAt: UInt64
    let expiresAt: UInt64
    let batchTransferIdx: UInt64?

    private enum CodingKeys: String, CodingKey {
        case opId, kind, state, txid, mayHaveBroadcast, intent, createdAt, expiresAt, batchTransferIdx
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        opId = try container.decode(String.self, forKey: .opId)
        kind = try container.decode(String.self, forKey: .kind)
        state = try container.decode(State.self, forKey: .state)
        // Missing is malformed; only an explicit JSON null is a valid absence.
        txid = try container.decode(String?.self, forKey: .txid)
        mayHaveBroadcast = try container.decode(Bool.self, forKey: .mayHaveBroadcast)
        intent = try container.decode(PreparedIntent.self, forKey: .intent)
        createdAt = try container.decode(UInt64.self, forKey: .createdAt)
        expiresAt = try container.decode(UInt64.self, forKey: .expiresAt)
        batchTransferIdx = try container.decodeIfPresent(UInt64.self, forKey: .batchTransferIdx)
    }
}

private struct PreparedIntent: Decodable {
    let kind: String
    let feeRateSatPerVb: UInt64
    let recipients: [PreparedRecipient]
    let asset: AssetIntent?
    let utxos: CreateIntent?

    private enum CodingKeys: String, CodingKey { case kind, feeRateSatPerVb, recipients, asset, utxos }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        feeRateSatPerVb = try container.decode(UInt64.self, forKey: .feeRateSatPerVb)
        recipients = try container.decode([PreparedRecipient].self, forKey: .recipients)
        asset = try container.decode(AssetIntent?.self, forKey: .asset)
        // A missing required field is not equivalent to explicit null.
        utxos = try container.decode(CreateIntent?.self, forKey: .utxos)
    }
}

private struct AssetIntent: Decodable {
    let assetId: String
    let amount: UInt64
    let recipientId: String
    let witnessAmountSat: UInt64?
    let transportEndpoints: [String]
    private enum CodingKeys: String, CodingKey {
        case assetId, amount, recipientId, witnessAmountSat, transportEndpoints
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assetId = try container.decode(String.self, forKey: .assetId)
        amount = try container.decode(UInt64.self, forKey: .amount)
        recipientId = try container.decode(String.self, forKey: .recipientId)
        witnessAmountSat = try container.decode(UInt64?.self, forKey: .witnessAmountSat)
        transportEndpoints = try container.decode([String].self, forKey: .transportEndpoints)
    }
}

private struct CreateIntent: Decodable {
    let num: UInt16
    let size: UInt64
    let upTo: Bool
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
    let batchTransferIdx: UInt64?
}

private struct CreateCompleteResponse: Decodable {
    let txid: String?
    let utxosCreated: UInt64

    private enum CodingKeys: String, CodingKey { case txid, utxosCreated }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        txid = try container.decode(String?.self, forKey: .txid)
        utxosCreated = try container.decode(UInt64.self, forKey: .utxosCreated)
    }
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
