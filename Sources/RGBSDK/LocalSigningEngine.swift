import Foundation
internal import UtexoLocalSignerBindings

protocol LocalSigningEngine: Sendable {
    func withGatewayContext(_ context: GatewaySigningContext) throws -> any LocalSigningEngine
    var capabilities: WalletCapabilities { get }
    func identity() throws -> WalletIdentity
    func verifyReservedAddress(_ reservation: ReservedAddress) throws
    func validateAndSign(
        prepared: PreparedTransaction,
        request: SendBtcRequest,
        policy: LocalSigningPolicy
    ) throws -> LocalSigningResult
    func validateBeforeSubmission(
        prepared: PreparedTransaction,
        request: SendBtcRequest,
        policy: LocalSigningPolicy,
        retainedValidation: LocalValidationReport
    ) throws
    func validateAndSignCreateUtxos(
        prepared: PreparedTransaction, request: CreateUtxosRequest, policy: LocalSigningPolicy
    ) throws -> LocalSigningResult
    func validateCreateUtxosBeforeSubmission(
        prepared: PreparedTransaction, request: CreateUtxosRequest, policy: LocalSigningPolicy,
        retainedValidation: LocalValidationReport) throws
    func validateAndSignOnchainSend(
        prepared: PreparedTransaction, request: OnchainSendRequest, policy: LocalSigningPolicy, now: UInt64
    ) throws -> LocalSigningResult
    func validateOnchainSendBeforeSubmission(
        prepared: PreparedTransaction, request: OnchainSendRequest, policy: LocalSigningPolicy,
        retainedValidation: LocalValidationReport, now: UInt64) throws
}

extension LocalSigningEngine {
    func withGatewayContext(_ context: GatewaySigningContext) throws -> any LocalSigningEngine {
        throw SDKError.unsupported("reviewed gateway signing profile")
    }
    func validateAndSignCreateUtxos(
        prepared: PreparedTransaction, request: CreateUtxosRequest, policy: LocalSigningPolicy
    ) throws -> LocalSigningResult { throw SDKError.unsupported("local create-UTXO authorization") }
    func validateCreateUtxosBeforeSubmission(
        prepared: PreparedTransaction, request: CreateUtxosRequest, policy: LocalSigningPolicy,
        retainedValidation: LocalValidationReport
    ) throws { throw SDKError.unsupported("local create-UTXO authorization") }
    func validateAndSignOnchainSend(
        prepared: PreparedTransaction, request: OnchainSendRequest, policy: LocalSigningPolicy, now: UInt64
    ) throws -> LocalSigningResult { throw SDKError.unsupported("local RGB Bitcoin authorization") }
    func validateOnchainSendBeforeSubmission(
        prepared: PreparedTransaction, request: OnchainSendRequest, policy: LocalSigningPolicy,
        retainedValidation: LocalValidationReport, now: UInt64
    ) throws { throw SDKError.unsupported("local RGB Bitcoin authorization") }
}

struct LocalSigningResult: Sendable {
    let signedPsbtBase64: String
    let validation: LocalValidationReport
}

protocol LocalSigningEngineFactory: Sendable {
    func open(network: Network, seed: SecretSeed) throws -> any LocalSigningEngine
}

/// Internal-only reviewed builder context. It is never inferred from a PSBT
/// or an untrusted gateway response.
struct GatewaySigningContext: Sendable {
    static let profile = "utexo.psbt.rgb-lib.v1"
    let maximumBlockHeight: UInt32

    init(maximumBlockHeight: UInt32) throws {
        guard maximumBlockHeight < 500_000_000 else {
            throw SDKError.invalidArgument(
                "maximumBlockHeight", "must be a Bitcoin block height, not a timestamp")
        }
        self.maximumBlockHeight = maximumBlockHeight
    }
}

struct UniFFILocalSigningEngineFactory: LocalSigningEngineFactory {
    var gatewayProfile = false
    var gatewaySigningAvailable = true
    func open(network: Network, seed: SecretSeed) throws -> any LocalSigningEngine {
        try open(network: network, seed: seed, gatewayContext: nil)
    }

    func openGateway(
        network: Network, seed: SecretSeed, context: GatewaySigningContext
    ) throws -> any LocalSigningEngine {
        try open(network: network, seed: seed, gatewayContext: context)
    }

    private func open(
        network: Network, seed: SecretSeed, gatewayContext: GatewaySigningContext?
    ) throws -> any LocalSigningEngine {
        do {
            let signer: UtexoLocalSignerBindings.LocalSigner = try seed.withCopy { copy in
                var data = Data(copy)
                defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
                return try UtexoLocalSignerBindings.LocalSigner.fromSeed(
                    network: network.ffi,
                    seed: data
                )
            }
            return NativeLocalSigningEngine(network: network, signer: signer, gatewayContext: gatewayContext,
                gatewayProfile: gatewayProfile || gatewayContext != nil,
                gatewaySigningAvailable: gatewaySigningAvailable)
        } catch {
            throw mapSignerError(error)
        }
    }
}

private final class NativeLocalSigningEngine: LocalSigningEngine, @unchecked Sendable {
    var capabilities: WalletCapabilities {
        WalletCapabilities(
            localKeyDerivation: true,
            localTransactionValidation: true,
            localTransactionSigning: !gatewayProfile || gatewaySigningAvailable,
            localRGBInvoiceParsing: true,
            localRGBValidation: false,
            localSigningOperations: gatewayProfile
                ? (gatewaySigningAvailable ? [.sendBtc, .createUtxos, .onchainSend] : []) : [.sendBtc],
            derivationProfile: WalletCapabilities.derivationProfileV1,
            signingProfile: gatewayProfile ? GatewaySigningContext.profile : WalletCapabilities.signingProfileV1
        )
    }

    private let network: Network
    private let signer: UtexoLocalSignerBindings.LocalSigner
    private let gatewayContext: GatewaySigningContext?
    private let gatewayProfile: Bool
    private let gatewaySigningAvailable: Bool

    init(
        network: Network, signer: UtexoLocalSignerBindings.LocalSigner,
        gatewayContext: GatewaySigningContext? = nil,
        gatewayProfile: Bool = false, gatewaySigningAvailable: Bool = true
    ) {
        self.network = network
        self.signer = signer
        self.gatewayContext = gatewayContext
        self.gatewayProfile = gatewayProfile
        self.gatewaySigningAvailable = gatewaySigningAvailable
    }

    func withGatewayContext(_ context: GatewaySigningContext) throws -> any LocalSigningEngine {
        guard gatewayProfile else { throw SDKError.unsupported("reviewed gateway signing profile") }
        return NativeLocalSigningEngine(network: network, signer: signer, gatewayContext: context,
            gatewayProfile: true, gatewaySigningAvailable: true)
    }

    func identity() throws -> WalletIdentity {
        do {
            let value = try signer.identity()
            return WalletIdentity(
                network: try Network(ffi: value.network),
                chainNetwork: value.chainNetwork,
                derivationProfile: value.derivationProfile,
                masterFingerprint: value.masterFingerprint,
                xpub: value.xpub,
                accountXpubVanilla: value.accountXpubVanilla,
                accountXpubColored: value.accountXpubColored
            )
        } catch {
            throw mapSignerError(error)
        }
    }

    func verifyReservedAddress(_ reservation: ReservedAddress) throws {
        do {
            let derived = try signer.deriveAddress(
                account: reservation.account.ffi,
                keychain: reservation.keychain.ffi,
                index: reservation.index
            )
            guard derived.address == reservation.address.value,
                  reservation.scriptPubkeyHex.map({ $0 == derived.scriptPubkeyHex }) ?? true,
                  // rust-bitcoin Display omits the master "m/" prefix.
                  reservation.derivationPath.map({ $0 == "m/" + derived.derivationPath }) ?? true else {
                throw SDKError.backendProtocolMismatch(
                    "reserved address does not match local derivation"
                )
            }
        } catch let error as SDKError {
            throw error
        } catch {
            throw mapSignerError(error)
        }
    }

    func validateAndSign(
        prepared: PreparedTransaction,
        request: SendBtcRequest,
        policy: LocalSigningPolicy
    ) throws -> LocalSigningResult {
        try validateBtcPreparationIdentity(prepared, request: request)
        let intent = signingIntent(prepared: prepared, request: request, policy: policy)
        do {
            let result: UtexoLocalSignerBindings.SigningResult
            if let gatewayContext {
                result = try signer.signGatewayPsbt(
                    psbtBase64: prepared.psbtBase64,
                    intent: gatewayIntent(intent, request: request, policy: policy, context: gatewayContext)
                )
            } else if !gatewayProfile {
                result = try signer.signPsbt(psbtBase64: prepared.psbtBase64, intent: intent)
            } else {
                throw SDKError.unsupported("trusted chain context is required for gateway signing")
            }
            guard result.signedInputCount > 0 else {
                throw SDKError.invariant("native signer returned no signatures")
            }
            return LocalSigningResult(
                signedPsbtBase64: result.signedPsbtBase64,
                validation: try result.validation.sdk
            )
        } catch let error as SDKError {
            throw error
        } catch {
            throw mapSignerError(error, operationID: prepared.operationID)
        }
    }

    func validateBeforeSubmission(
        prepared: PreparedTransaction,
        request: SendBtcRequest,
        policy: LocalSigningPolicy,
        retainedValidation: LocalValidationReport
    ) throws {
        try validateBtcPreparationIdentity(prepared, request: request)
        do {
            // Validate the exact original unsigned preparation, including its
            // derivation metadata. Finalized PSBTs intentionally remove that
            // metadata and are not an alternative source of authorization.
            // No new signature or replacement payload is created here.
            let intent = signingIntent(prepared: prepared, request: request, policy: policy)
            let report: UtexoLocalSignerBindings.ValidationReport
            if let gatewayContext {
                report = try signer.validateGatewayPsbt(
                    psbtBase64: prepared.psbtBase64,
                    intent: gatewayIntent(intent, request: request, policy: policy, context: gatewayContext)
                )
            } else if !gatewayProfile {
                report = try signer.validatePsbt(psbtBase64: prepared.psbtBase64, intent: intent)
            } else {
                throw SDKError.unsupported("trusted chain context is required for gateway signing")
            }
            let current = try report.sdk
            guard current.matchesTransactionEvidence(retainedValidation) else {
                throw SDKError.invariant("retained signing evidence no longer matches preparation")
            }
        } catch let error as SDKError {
            throw error
        } catch {
            throw mapSignerError(error, operationID: prepared.operationID)
        }
    }

    private func validateBtcPreparationIdentity(_ prepared: PreparedTransaction, request: SendBtcRequest)
        throws
    {
        guard prepared.operation == .sendBtc, prepared.network == network,
            prepared.idempotencyKey == request.idempotencyKey,
            prepared.requestHash == (try RequestHasher.sendBtc(network: network, request: request)),
            prepared.createUtxosOutputPlan == nil
        else {
            throw SDKError.backendProtocolMismatch("preparation differs from local BTC request identity")
        }
    }

    private func signingIntent(
        prepared: PreparedTransaction,
        request: SendBtcRequest,
        policy: LocalSigningPolicy
    ) -> UtexoLocalSignerBindings.SigningIntent {
        UtexoLocalSignerBindings.SigningIntent(
            operationId: prepared.operationID.value,
            idempotencyKey: request.idempotencyKey.value,
            network: network.ffi,
            operation: .sendBtc,
            recipients: [
                .init(address: request.address.value, amountSats: request.amount.value)
            ],
            policy: .init(
                maxPsbtBytes: policy.maximumPSBTBytes,
                maxInputs: policy.maximumInputs,
                maxOutputs: policy.maximumOutputs,
                maxChildIndex: policy.maximumChildIndex,
                maxAbsoluteFeeSats: policy.maximumAbsoluteFee.value,
                // Bind the authorization to the caller's requested rate, not
                // merely the wider app safety ceiling. The backend may choose
                // a lower effective rate but can never silently exceed it.
                maxFeeRateMsatPerVbyte: authorizedFeeRateCap(
                    appPolicy: policy,
                    requested: request.feeRate
                ),
                rbf: .required,
                expectedLockTime: 0,
                expectedSequence: 0xffff_fffd,
                allowSighashAll: true,
                allowUnknownFields: false,
                allowedProprietaryPrefixes: [],
                maxOpReturnOutputs: 0,
                maxOpReturnScriptBytes: 83,
                allowedInputScopes: [
                    .init(account: .vanilla, keychain: .external),
                    .init(account: .vanilla, keychain: .change),
                ],
                allowedChangeScopes: [
                    .init(account: .vanilla, keychain: .change)
                ]
            )
        )

    }

    private func gatewayIntent(
        _ legacyIntent: UtexoLocalSignerBindings.SigningIntent,
        request: SendBtcRequest,
        policy: LocalSigningPolicy,
        context: GatewaySigningContext
    ) throws -> UtexoLocalSignerBindings.GatewaySigningIntent {
        guard policy.rbf == .required else { throw SDKError.policyRejected("gateway profile requires RBF") }
        var intent = legacyIntent
        // Defaults establish the immutable native branch-0/v2/RBF profile.
        // Only app-owned resource/fee ceilings are copied into that policy.
        var nativePolicy = UtexoLocalSignerBindings.gatewaySigningPolicy(operation: .sendBtc)
        nativePolicy.maxPsbtBytes = policy.maximumPSBTBytes
        nativePolicy.maxInputs = policy.maximumInputs
        nativePolicy.maxOutputs = policy.maximumOutputs
        nativePolicy.maxChildIndex = policy.maximumChildIndex
        nativePolicy.maxAbsoluteFeeSats = policy.maximumAbsoluteFee.value
        nativePolicy.maxFeeRateMsatPerVbyte = policy.maximumFeeRate.milliSatsPerVByte
        intent.policy = nativePolicy
        return .init(
            intent: intent,
            maxBlockHeight: context.maximumBlockHeight,
            targetFeeRateMsatPerVbyte: request.feeRate.milliSatsPerVByte,
            createUtxos: nil, rgb: nil
        )
    }

    func validateAndSignCreateUtxos(
        prepared: PreparedTransaction, request: CreateUtxosRequest, policy: LocalSigningPolicy
    ) throws -> LocalSigningResult {
        try signGatewayOperation(
            prepared: prepared, intent: createIntent(prepared: prepared, request: request, policy: policy))
    }

    func validateCreateUtxosBeforeSubmission(
        prepared: PreparedTransaction, request: CreateUtxosRequest, policy: LocalSigningPolicy,
        retainedValidation: LocalValidationReport
    ) throws {
        try validateGatewayOperation(
            prepared: prepared, intent: createIntent(prepared: prepared, request: request, policy: policy),
            retained: retainedValidation)
    }

    func validateAndSignOnchainSend(
        prepared: PreparedTransaction, request: OnchainSendRequest, policy: LocalSigningPolicy, now: UInt64
    ) throws -> LocalSigningResult {
        try signGatewayOperation(
            prepared: prepared,
            intent: rgbIntent(prepared: prepared, request: request, policy: policy, now: now))
    }

    func validateOnchainSendBeforeSubmission(
        prepared: PreparedTransaction, request: OnchainSendRequest, policy: LocalSigningPolicy,
        retainedValidation: LocalValidationReport, now: UInt64
    ) throws {
        try validateGatewayOperation(
            prepared: prepared,
            intent: rgbIntent(prepared: prepared, request: request, policy: policy, now: now),
            retained: retainedValidation)
    }

    private func createIntent(
        prepared: PreparedTransaction, request: CreateUtxosRequest, policy: LocalSigningPolicy
    ) throws -> UtexoLocalSignerBindings.GatewaySigningIntent {
        guard prepared.requestHash == (try RequestHasher.createUtxos(network: network, request: request))
        else {
            throw SDKError.backendProtocolMismatch("preparation differs from local create request identity")
        }
        try LocalOperationRequest.createUtxos(request).verifyPreparedPlan(prepared, policy: policy)
        var intent = try operationIntent(
            prepared: prepared, operation: .createUtxos, key: request.idempotencyKey, fee: request.feeRate,
            policy: policy)
        intent.createUtxos = .init(
            minCount: 1, maxCount: UInt32(request.num ?? 5),
            sizeSats: request.size?.value ?? 1_000,
            exactOutputs: prepared.createUtxosOutputPlan?.outputs.map {
                .init(
                    account: $0.account.ffi, keychain: $0.keychain.ffi, index: $0.index,
                    amountSats: $0.amount.value)
            }
        )
        return intent
    }

    private func rgbIntent(
        prepared: PreparedTransaction, request: OnchainSendRequest, policy: LocalSigningPolicy, now: UInt64
    ) throws -> UtexoLocalSignerBindings.GatewaySigningIntent {
        guard prepared.requestHash == (try RequestHasher.onchainSend(network: network, request: request)),
            prepared.createUtxosOutputPlan == nil
        else {
            throw SDKError.backendProtocolMismatch("preparation differs from local RGB request identity")
        }
        let decoded = try validateOutgoingRGBInvoice(request, network: network, now: now)
        guard let asset = request.assetID ?? decoded.assetID, let amount = UInt64(request.amount.decimal)
        else {
            throw SDKError.invalidArgument("assetID", "requires a supported fungible asset and amount")
        }
        var intent = try operationIntent(
            prepared: prepared, operation: .onchainSend, key: request.idempotencyKey, fee: request.feeRate,
            policy: policy)
        intent.rgb = .init(
            invoice: request.invoice.value, assetId: asset.value, amount: amount,
            witnessAmountSats: request.witnessData?.amountSat.value,
            witnessBlinding: request.witnessData?.blinding, donation: request.donation,
            minConfirmations: request.minConfirmations.rawValue, skipSync: request.skipSync,
            validationTimeUnixSeconds: now
        )
        if let witness = request.witnessData {
            do {
                intent.intent.recipients = [
                    try UtexoLocalSignerBindings.rgbInvoiceWitnessRecipient(
                        invoice: request.invoice.value, network: network.ffi,
                        amountSats: witness.amountSat.value
                    )
                ]
            } catch { throw mapSignerError(error, operationID: prepared.operationID) }
        }
        return intent
    }

    private func operationIntent(
        prepared: PreparedTransaction, operation: OperationKind, key: IdempotencyKey, fee: FeeRate,
        policy: LocalSigningPolicy
    ) throws -> UtexoLocalSignerBindings.GatewaySigningIntent {
        guard policy.rbf == .required else { throw SDKError.policyRejected("gateway profile requires RBF") }
        guard let gatewayContext else { throw SDKError.unsupported("reviewed RGB-lib signing context") }
        guard prepared.operation == operation, prepared.network == network, prepared.idempotencyKey == key
        else {
            throw SDKError.backendProtocolMismatch("preparation differs from local operation identity")
        }
        let nativeOperation: UtexoLocalSignerBindings.OperationKind =
            operation == .createUtxos ? .createUtxos : .onchainSend
        var nativePolicy = UtexoLocalSignerBindings.gatewaySigningPolicy(operation: nativeOperation)
        nativePolicy.maxPsbtBytes = policy.maximumPSBTBytes
        nativePolicy.maxInputs = policy.maximumInputs
        nativePolicy.maxOutputs = policy.maximumOutputs
        nativePolicy.maxChildIndex = policy.maximumChildIndex
        nativePolicy.maxAbsoluteFeeSats = policy.maximumAbsoluteFee.value
        nativePolicy.maxFeeRateMsatPerVbyte = policy.maximumFeeRate.milliSatsPerVByte
        return .init(
            intent: .init(
                operationId: prepared.operationID.value, idempotencyKey: key.value, network: network.ffi,
                operation: nativeOperation, recipients: [], policy: nativePolicy
            ), maxBlockHeight: gatewayContext.maximumBlockHeight,
            targetFeeRateMsatPerVbyte: fee.milliSatsPerVByte,
            createUtxos: nil, rgb: nil)
    }

    private func signGatewayOperation(
        prepared: PreparedTransaction, intent: UtexoLocalSignerBindings.GatewaySigningIntent
    ) throws -> LocalSigningResult {
        do {
            let signed = try signer.signGatewayPsbt(psbtBase64: prepared.psbtBase64, intent: intent)
            guard signed.signedInputCount > 0 else {
                throw SDKError.invariant("native signer returned no signatures")
            }
            return .init(signedPsbtBase64: signed.signedPsbtBase64, validation: try signed.validation.sdk)
        } catch let error as SDKError { throw error } catch {
            throw mapSignerError(error, operationID: prepared.operationID)
        }
    }

    private func validateGatewayOperation(
        prepared: PreparedTransaction, intent: UtexoLocalSignerBindings.GatewaySigningIntent,
        retained: LocalValidationReport
    ) throws {
        do {
            let report = try signer.validateGatewayPsbt(psbtBase64: prepared.psbtBase64, intent: intent).sdk
            guard report.matchesTransactionEvidence(retained) else {
                throw SDKError.invariant("retained signing evidence no longer matches preparation")
            }
        } catch let error as SDKError { throw error } catch {
            throw mapSignerError(error, operationID: prepared.operationID)
        }
    }
}

extension LocalValidationReport {
    /// Policy changes affect the intent digest, but must not affect a single
    /// transaction-derived fact. The original digest remains in the journal.
    func matchesTransactionEvidence(_ other: LocalValidationReport) -> Bool {
        psbtSHA256 == other.psbtSHA256 && unsignedTxid == other.unsignedTxid
            && totalInput == other.totalInput && totalOutput == other.totalOutput
            && fee == other.fee && estimatedVbytes == other.estimatedVbytes
            && feeRate == other.feeRate && externalOutput == other.externalOutput
            && change == other.change && inputCount == other.inputCount
            && outputCount == other.outputCount && opReturnCount == other.opReturnCount
    }
}

func authorizedFeeRateCap(appPolicy: LocalSigningPolicy, requested: FeeRate) -> UInt64 {
    min(appPolicy.maximumFeeRate.milliSatsPerVByte, requested.milliSatsPerVByte)
}

extension UtexoLocalSignerBindings.ValidationReport {
    fileprivate var sdk: LocalValidationReport {
        get throws {
            try LocalValidationReport(
                psbtSHA256: psbtSha256,
                intentSHA256: intentSha256,
                unsignedTxid: TransactionID(unsignedTxid),
                totalInput: Satoshis(totalInputSats),
                totalOutput: Satoshis(totalOutputSats),
                fee: Satoshis(feeSats),
                estimatedVbytes: estimatedVbytes,
                feeRate: FeeRate(milliSatsPerVByte: feeRateMsatPerVbyte),
                externalOutput: Satoshis(externalOutputSats),
                change: Satoshis(changeSats),
                inputCount: inputCount,
                outputCount: outputCount,
                opReturnCount: opReturnCount
            )
        }
    }
}

extension Network {
    var ffi: UtexoLocalSignerBindings.Network {
        switch self {
        case .mainnet: .mainnet
        case .testnet: .testnet
        case .testnet4: .testnet4
        case .signet: .signet
        case .regtest: .regtest
        case .utexo: .utexo
        }
    }

    init(ffi: UtexoLocalSignerBindings.Network) throws {
        self =
            switch ffi {
            case .mainnet: .mainnet
            case .testnet: .testnet
            case .testnet4: .testnet4
            case .signet: .signet
            case .regtest: .regtest
            case .utexo: .utexo
            }
    }
}

extension AccountKind {
    fileprivate var ffi: UtexoLocalSignerBindings.AccountKind {
        switch self {
        case .vanilla: .vanilla
        case .colored: .colored
        }
    }
}

extension Keychain {
    fileprivate var ffi: UtexoLocalSignerBindings.Keychain {
        switch self {
        case .external: .external
        case .change: .change
        }
    }
}

func mapSignerError(_ error: Error, operationID: OperationID? = nil) -> SDKError {
    guard let signerError = error as? UtexoLocalSignerBindings.SignerError else {
        return .invariant("native signer failed unexpectedly")
    }
    switch signerError {
    case .InvalidArgument(let reason):
        return .invalidArgument("nativeSigner", reason)
    case .InvalidMnemonic:
        return .invalidArgument("mnemonic", "checksum or word sequence is invalid")
    case .InvalidSeed:
        return .invalidArgument("seed", "must be an exact 64-byte BIP39 seed")
    case .InvalidRgbInvoice:
        return .invalidArgument("invoice", "is invalid or outside the supported RGB invoice profile")
    case .EntropyUnavailable:
        return .entropyUnavailable
    case .InvalidNetwork(let reason):
        return .policyRejected("network mismatch: \(reason)", operationID: operationID)
    case .InvalidPsbt(let reason):
        return .policyRejected("malformed prepared transaction: \(reason)", operationID: operationID)
    case .PolicyRejected(let reason):
        return .policyRejected(reason, operationID: operationID)
    case .KeyDerivation:
        return .localSigningFailed("key derivation failed", operationID: operationID)
    case .SigningFailed:
        return .localSigningFailed("not every input could be signed", operationID: operationID)
    case .SignatureVerification:
        return .localSigningFailed("signature verification failed", operationID: operationID)
    }
}
