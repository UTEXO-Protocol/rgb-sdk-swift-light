import Foundation

/// Infrastructure-only service boundary used by `UTEXOWallet`.
///
/// Application code calls the wallet facade. This SPI is available only when
/// building the development sources; the facade-only binary distribution does
/// not export its declarations or private transport/signing implementation.
@_spi(Backend)
public protocol WalletBackend: Sendable {
    /// Side-effect-free authorization/capability check performed immediately
    /// before a workflow may prepare, sign, or submit an operation.
    ///
    /// This is required (with no default) so backend decorators cannot
    /// accidentally bypass a wrapped backend's money-movement gate.
    func preflightOperation(_ operation: OperationKind) async throws

    func initialize(_ request: BackendInitializeRequest) async throws -> BackendSession
    func registerWallet(_ request: RegisterWalletRequest) async throws
    func shutdown(session: BackendSession) async throws

    func getBtcBalance(context: BackendContext) async throws -> BTCBalance
    func reserveAddress(_ request: ReserveAddressRequest) async throws -> ReservedAddress
    func listUnspents(context: BackendContext) async throws -> [Unspent]
    func estimateFeeRate(context: BackendContext, targetBlocks: BlockCount) async throws -> FeeEstimate

    func listAssets(context: BackendContext) async throws -> ListAssets
    func getAssetBalance(context: BackendContext, assetID: AssetID) async throws -> AssetBalance
    func issueAssetNia(context: BackendContext, request: IssueAssetNiaRequest) async throws -> AssetNIA
    func issueAssetIfa(context: BackendContext, request: IssueAssetIfaRequest) async throws -> AssetIFA
    func blindReceive(context: BackendContext, request: InvoiceRequest) async throws -> InvoiceReceiveData
    func witnessReceive(context: BackendContext, request: InvoiceRequest) async throws -> InvoiceReceiveData
    func onchainReceive(
        context: BackendContext,
        request: OnchainReceiveRequest
    ) async throws -> OnchainReceiveResponse
    /// Complete wallet transaction snapshot with normal synchronization.
    /// A partial page or local operation journal is not a valid implementation.
    func listTransactions(context: BackendContext) async throws -> [Transaction]
    func listTransactions(
        context: BackendContext,
        txid: TransactionID,
        skipSync: Bool
    ) async throws -> [Transaction]
    /// Complete transfer list for `assetID`, or for the whole wallet when it is
    /// nil: every asset's transfers plus asset-less receives. A backend whose
    /// native nil filter means "asset-less only" (as the gateway's does) must
    /// merge per-asset results; see `GatewayWalletBackend`.
    func listTransfers(context: BackendContext, assetID: AssetID?) async throws -> [Transfer]
    /// By default filters the whole-wallet list from `listTransfers(context:assetID:)`
    /// with a nil asset, so it costs as much as that call.
    func listTransfers(context: BackendContext, txid: TransactionID) async throws -> [Transfer]
    func failTransfers(context: BackendContext, request: FailTransfersRequest) async throws -> FailTransfersResult
    func refreshWallet(context: BackendContext) async throws -> SyncResult
    func syncWallet(context: BackendContext) async throws -> SyncResult

    func prepareSendBtc(_ request: PrepareSendBtcRequest) async throws -> PreparedTransaction
    func prepareCreateUtxos(_ request: PrepareCreateUtxosRequest) async throws -> PreparedTransaction
    func prepareOnchainSend(_ request: PrepareOnchainSendRequest) async throws -> PreparedTransaction
    func submitSignedTransaction(_ request: SignedTransactionSubmission) async throws -> BackendOperationResult
    func getOperation(context: BackendContext, operationID: OperationID) async throws -> BackendOperationStatus
}

@_spi(Backend)
public extension WalletBackend {
    func getBtcBalance(context: BackendContext) async throws -> BTCBalance { throw unsupported(#function) }
    func reserveAddress(_ request: ReserveAddressRequest) async throws -> ReservedAddress { throw unsupported(#function) }
    func listUnspents(context: BackendContext) async throws -> [Unspent] { throw unsupported(#function) }
    func estimateFeeRate(context: BackendContext, targetBlocks: BlockCount) async throws -> FeeEstimate {
        throw unsupported(#function)
    }
    func listAssets(context: BackendContext) async throws -> ListAssets { throw unsupported(#function) }
    func getAssetBalance(context: BackendContext, assetID: AssetID) async throws -> AssetBalance {
        throw unsupported(#function)
    }
    func issueAssetNia(context: BackendContext, request: IssueAssetNiaRequest) async throws -> AssetNIA {
        throw unsupported(#function)
    }
    func issueAssetIfa(context: BackendContext, request: IssueAssetIfaRequest) async throws -> AssetIFA {
        throw unsupported(#function)
    }
    func blindReceive(context: BackendContext, request: InvoiceRequest) async throws -> InvoiceReceiveData {
        throw unsupported(#function)
    }
    func witnessReceive(context: BackendContext, request: InvoiceRequest) async throws -> InvoiceReceiveData {
        throw unsupported(#function)
    }
    func onchainReceive(
        context: BackendContext,
        request: OnchainReceiveRequest
    ) async throws -> OnchainReceiveResponse { throw unsupported(#function) }
    func listTransactions(context: BackendContext) async throws -> [Transaction] { throw unsupported(#function) }
    func listTransactions(
        context: BackendContext,
        txid: TransactionID,
        skipSync: Bool
    ) async throws -> [Transaction] {
        // A dedicated filtering endpoint is not necessary when the backend
        // supplies the complete snapshot. Its normal sync cannot honor an
        // explicit skipSync request, so adapters must override that variant.
        guard !skipSync else { throw unsupported(#function) }
        let transactions = try await listTransactions(context: context)
        try Task.checkCancellation()
        return transactions.filter { $0.txid == txid }
    }
    func listTransfers(context: BackendContext, assetID: AssetID?) async throws -> [Transfer] {
        throw unsupported(#function)
    }
    func listTransfers(context: BackendContext, txid: TransactionID) async throws -> [Transfer] {
        // nil means the whole wallet (all assets plus asset-less), per the protocol contract.
        let transfers = try await listTransfers(context: context, assetID: nil)
        try Task.checkCancellation()
        return transfers.filter { $0.txid == txid }
    }
    func failTransfers(context: BackendContext, request: FailTransfersRequest) async throws -> FailTransfersResult {
        throw unsupported(#function)
    }
    func refreshWallet(context: BackendContext) async throws -> SyncResult { throw unsupported(#function) }
    func syncWallet(context: BackendContext) async throws -> SyncResult { throw unsupported(#function) }
    func prepareSendBtc(_ request: PrepareSendBtcRequest) async throws -> PreparedTransaction {
        throw unsupported(#function)
    }
    func prepareCreateUtxos(_ request: PrepareCreateUtxosRequest) async throws -> PreparedTransaction {
        throw unsupported(#function)
    }
    func prepareOnchainSend(_ request: PrepareOnchainSendRequest) async throws -> PreparedTransaction {
        throw unsupported(#function)
    }
    func submitSignedTransaction(_ request: SignedTransactionSubmission) async throws -> BackendOperationResult {
        throw unsupported(#function)
    }
    func getOperation(context: BackendContext, operationID: OperationID) async throws -> BackendOperationStatus {
        throw unsupported(#function)
    }

    private func unsupported(_ method: String) -> SDKError {
        .unsupported("WalletBackend.\(method)")
    }
}

@_spi(Backend)
public struct BackendInitializeRequest: Hashable, Sendable {
    public let walletID: WalletID
    public let network: Network
    public let minimumAPIVersion: UInt32
    public let maximumAPIVersion: UInt32

    public init(
        walletID: WalletID,
        network: Network,
        minimumAPIVersion: UInt32,
        maximumAPIVersion: UInt32
    ) {
        self.walletID = walletID
        self.network = network
        self.minimumAPIVersion = minimumAPIVersion
        self.maximumAPIVersion = maximumAPIVersion
    }
}

@_spi(Backend)
public struct BackendSession: Hashable, Sendable, CustomStringConvertible {
    public let id: String
    public let apiVersion: UInt32
    public let network: Network
    public let backendVersion: String?
    public let correlationID: String?

    public init(
        id: String,
        apiVersion: UInt32,
        network: Network,
        backendVersion: String? = nil,
        correlationID: String? = nil
    ) throws {
        self.id = try requireProtocolIdentifier(id, field: "backendSessionId")
        guard apiVersion > 0 else { throw SDKError.invalidArgument("apiVersion", "must be positive") }
        self.apiVersion = apiVersion
        self.network = network
        self.backendVersion = backendVersion
        self.correlationID = correlationID
    }

    public var description: String {
        "BackendSession(id=[REDACTED], apiVersion=\(apiVersion), network=\(network.rawValue))"
    }
}

@_spi(Backend)
public struct BackendContext: Hashable, Sendable {
    public let session: BackendSession
    public let walletID: WalletID
    public let network: Network

    public init(session: BackendSession, walletID: WalletID, network: Network) {
        self.session = session
        self.walletID = walletID
        self.network = network
    }
}

@_spi(Backend)
public struct RegisterWalletRequest: Hashable, Sendable {
    public let context: BackendContext
    public let identity: WalletIdentity

    public init(context: BackendContext, identity: WalletIdentity) {
        self.context = context
        self.identity = identity
    }
}

@_spi(Backend)
public struct ReserveAddressRequest: Hashable, Sendable {
    public let context: BackendContext
    public let account: AccountKind
    public let rotate: Bool

    public init(context: BackendContext, account: AccountKind = .vanilla, rotate: Bool) {
        self.context = context
        self.account = account
        self.rotate = rotate
    }
}

@_spi(Backend)
public struct ReservedAddress: Hashable, Sendable {
    public let address: BitcoinAddress
    public let account: AccountKind
    public let keychain: Keychain
    public let index: UInt32
    public let scriptPubkeyHex: String?
    public let derivationPath: String?

    public init(address: BitcoinAddress, account: AccountKind, keychain: Keychain, index: UInt32,
                scriptPubkeyHex: String? = nil, derivationPath: String? = nil) {
        self.address = address
        self.account = account
        self.keychain = keychain
        self.index = index
        self.scriptPubkeyHex = scriptPubkeyHex
        self.derivationPath = derivationPath
    }
}

@_spi(Backend)
public struct OperationRequestContext: Hashable, Sendable {
    public let backend: BackendContext
    public let idempotencyKey: IdempotencyKey
    public let requestHash: RequestHash

    public init(backend: BackendContext, idempotencyKey: IdempotencyKey, requestHash: RequestHash) {
        self.backend = backend
        self.idempotencyKey = idempotencyKey
        self.requestHash = requestHash
    }
}

@_spi(Backend)
public struct PrepareSendBtcRequest: Hashable, Sendable {
    public let context: OperationRequestContext
    public let request: SendBtcRequest
    public init(context: OperationRequestContext, request: SendBtcRequest) {
        self.context = context
        self.request = request
    }
}

@_spi(Backend)
public struct PrepareCreateUtxosRequest: Hashable, Sendable {
    public let context: OperationRequestContext
    public let request: CreateUtxosRequest
    public init(context: OperationRequestContext, request: CreateUtxosRequest) {
        self.context = context
        self.request = request
    }
}

@_spi(Backend)
public struct PrepareOnchainSendRequest: Hashable, Sendable {
    public let context: OperationRequestContext
    public let request: OnchainSendRequest
    public init(context: OperationRequestContext, request: OnchainSendRequest) {
        self.context = context
        self.request = request
    }
}

@_spi(Backend)
public struct ExpectedWalletOutput: Hashable, Sendable {
    public let account: AccountKind
    public let keychain: Keychain
    public let index: UInt32
    public let amount: Satoshis

    public init(account: AccountKind, keychain: Keychain, index: UInt32, amount: Satoshis) throws {
        self.account = account
        self.keychain = keychain
        self.index = index
        self.amount = try .positive(amount, field: "outputAmount")
    }
}

@_spi(Backend)
public struct CreateUtxosOutputPlan: Hashable, Sendable {
    public let outputs: [ExpectedWalletOutput]
    public init(outputs: [ExpectedWalletOutput]) throws {
        guard !outputs.isEmpty else { throw SDKError.invalidArgument("outputs", "must not be empty") }
        self.outputs = outputs
    }
}

/// Infrastructure-only carrier. Its description deliberately redacts the PSBT.
@_spi(Backend)
public struct PreparedTransaction: Hashable, Sendable, CustomStringConvertible {
    public let operationID: OperationID
    public let idempotencyKey: IdempotencyKey
    public let requestHash: RequestHash
    public let network: Network
    public let operation: OperationKind
    public let psbtBase64: String
    public let expiresAt: UnixSeconds
    public let createUtxosOutputPlan: CreateUtxosOutputPlan?
    public let correlationID: String?

    public init(
        operationID: OperationID,
        idempotencyKey: IdempotencyKey,
        requestHash: RequestHash,
        network: Network,
        operation: OperationKind,
        psbtBase64: String,
        expiresAt: UnixSeconds,
        createUtxosOutputPlan: CreateUtxosOutputPlan? = nil,
        correlationID: String? = nil
    ) throws {
        self.operationID = operationID
        self.idempotencyKey = idempotencyKey
        self.requestHash = requestHash
        self.network = network
        self.operation = operation
        self.psbtBase64 = try requireBoundedText(psbtBase64, field: "psbt", maximumUTF8Bytes: 5_400_000)
        self.expiresAt = expiresAt
        self.createUtxosOutputPlan = createUtxosOutputPlan
        self.correlationID = correlationID
        guard (operation == .createUtxos) == (createUtxosOutputPlan != nil) else {
            throw SDKError.invalidArgument(
                "createUtxosOutputPlan",
                "must be present only for createUtxos operations"
            )
        }
    }

    public var description: String {
        "PreparedTransaction(operationID=\(operationID), operation=\(operation.rawValue), psbt=[REDACTED])"
    }
}

@_spi(Backend)
public struct LocalValidationReport: Hashable, Sendable {
    public let psbtSHA256: String
    public let intentSHA256: String
    public let unsignedTxid: TransactionID
    public let totalInput: Satoshis
    public let totalOutput: Satoshis
    public let fee: Satoshis
    public let estimatedVbytes: UInt64
    public let feeRate: FeeRate
    public let externalOutput: Satoshis
    public let change: Satoshis
    public let inputCount: UInt32
    public let outputCount: UInt32
    public let opReturnCount: UInt32

    public init(
        psbtSHA256: String,
        intentSHA256: String,
        unsignedTxid: TransactionID,
        totalInput: Satoshis,
        totalOutput: Satoshis,
        fee: Satoshis,
        estimatedVbytes: UInt64,
        feeRate: FeeRate,
        externalOutput: Satoshis,
        change: Satoshis,
        inputCount: UInt32,
        outputCount: UInt32,
        opReturnCount: UInt32
    ) throws {
        self.psbtSHA256 = try requireLowercaseSHA256(psbtSHA256, field: "psbtSHA256")
        self.intentSHA256 = try requireLowercaseSHA256(intentSHA256, field: "intentSHA256")
        guard estimatedVbytes > 0 else {
            throw SDKError.invalidArgument("estimatedVbytes", "must be greater than zero")
        }
        guard inputCount > 0 else {
            throw SDKError.invalidArgument("inputCount", "must be greater than zero")
        }
        guard outputCount > 0 else {
            throw SDKError.invalidArgument("outputCount", "must be greater than zero")
        }
        guard totalInput.value >= totalOutput.value,
              totalInput.value - totalOutput.value == fee.value else {
            throw SDKError.invalidArgument("fee", "must equal total input minus total output")
        }
        guard externalOutput.value <= totalOutput.value,
              change.value <= totalOutput.value,
              externalOutput.value <= totalOutput.value - change.value else {
            throw SDKError.invalidArgument(
                "externalOutput",
                "external output and change must fit within total output"
            )
        }
        self.unsignedTxid = unsignedTxid
        self.totalInput = totalInput
        self.totalOutput = totalOutput
        self.fee = fee
        self.estimatedVbytes = estimatedVbytes
        self.feeRate = feeRate
        self.externalOutput = externalOutput
        self.change = change
        self.inputCount = inputCount
        self.outputCount = outputCount
        self.opReturnCount = opReturnCount
    }
}

@_spi(Backend)
public struct SignedTransactionSubmission: Sendable, CustomStringConvertible {
    public let context: OperationRequestContext
    public let operationID: OperationID
    public let signedPsbtBase64: String
    public let validation: LocalValidationReport

    public init(
        context: OperationRequestContext,
        operationID: OperationID,
        signedPsbtBase64: String,
        validation: LocalValidationReport
    ) throws {
        self.context = context
        self.operationID = operationID
        self.signedPsbtBase64 = try requireBoundedText(
            signedPsbtBase64,
            field: "signedPsbt",
            maximumUTF8Bytes: 5_400_000
        )
        self.validation = validation
    }

    public var description: String {
        "SignedTransactionSubmission(operationID=\(operationID), signedPsbt=[REDACTED])"
    }
}

@_spi(Backend)
public enum BackendOperationResult: Hashable, Sendable {
    case sendBtc(operationID: OperationID, txid: TransactionID)
    case createUtxos(operationID: OperationID, result: CreateUtxosResult)
    case onchainSend(operationID: OperationID, result: OnchainSendResponse)

    public var operationID: OperationID {
        switch self {
        case let .sendBtc(operationID, _), let .createUtxos(operationID, _), let .onchainSend(operationID, _):
            operationID
        }
    }

    var operationKind: OperationKind {
        switch self {
        case .sendBtc: .sendBtc
        case .createUtxos: .createUtxos
        case .onchainSend: .onchainSend
        }
    }

    var transactionID: TransactionID {
        switch self {
        case let .sendBtc(_, txid): txid
        case let .createUtxos(_, result): result.txid
        case let .onchainSend(_, result): result.txid
        }
    }
}

@_spi(Backend)
public enum BackendOperationStatus: Hashable, Sendable {
    case pending(operationID: OperationID, phase: String)
    case succeeded(operationID: OperationID, result: BackendOperationResult)
    case failed(
        operationID: OperationID,
        safeMessage: String,
        retryable: Bool,
        backendCode: String?,
        correlationID: String?
    )
    case expired(operationID: OperationID)

    public var operationID: OperationID {
        switch self {
        case let .pending(id, _), let .succeeded(id, _), let .failed(id, _, _, _, _), let .expired(id): id
        }
    }
}
