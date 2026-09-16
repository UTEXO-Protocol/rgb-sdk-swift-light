import Foundation
internal import UtexoLocalSignerBindings

protocol LocalSigningEngine: Sendable {
    var capabilities: WalletCapabilities { get }
    func identity() throws -> WalletIdentity
    func verifyReservedAddress(_ reservation: ReservedAddress) throws
    func validateAndSign(
        prepared: PreparedTransaction,
        request: SendBtcRequest,
        policy: LocalSigningPolicy
    ) throws -> LocalSigningResult
}

struct LocalSigningResult: Sendable {
    let signedPsbtBase64: String
    let validation: LocalValidationReport
}

protocol LocalSigningEngineFactory: Sendable {
    func open(network: Network, seed: SecretSeed) throws -> any LocalSigningEngine
}

struct UniFFILocalSigningEngineFactory: LocalSigningEngineFactory {
    func open(network: Network, seed: SecretSeed) throws -> any LocalSigningEngine {
        do {
            let signer: UtexoLocalSignerBindings.LocalSigner = try seed.withCopy { copy in
                var data = Data(copy)
                defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
                return try UtexoLocalSignerBindings.LocalSigner.fromSeed(
                    network: network.ffi,
                    seed: data
                )
            }
            return NativeLocalSigningEngine(network: network, signer: signer)
        } catch {
            throw mapSignerError(error)
        }
    }
}

private final class NativeLocalSigningEngine: LocalSigningEngine, @unchecked Sendable {
    let capabilities = WalletCapabilities(
        localKeyDerivation: true,
        localTransactionValidation: true,
        localTransactionSigning: true,
        localRGBInvoiceParsing: false,
        localRGBValidation: false,
        localSigningOperations: [.sendBtc],
        derivationProfile: WalletCapabilities.derivationProfileV1,
        signingProfile: WalletCapabilities.signingProfileV1
    )

    private let network: Network
    private let signer: UtexoLocalSignerBindings.LocalSigner

    init(network: Network, signer: UtexoLocalSignerBindings.LocalSigner) {
        self.network = network
        self.signer = signer
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
            guard derived.address == reservation.address.value else {
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
        let intent = UtexoLocalSignerBindings.SigningIntent(
            operationId: prepared.operationID.value,
            idempotencyKey: request.idempotencyKey.value,
            network: network.ffi,
            operation: .sendBtc,
            recipients: [
                .init(address: request.address.value, amountSats: request.amount.value),
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
                    .init(account: .vanilla, keychain: .change),
                ]
            )
        )

        do {
            let result = try signer.signPsbt(psbtBase64: prepared.psbtBase64, intent: intent)
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
}

func authorizedFeeRateCap(appPolicy: LocalSigningPolicy, requested: FeeRate) -> UInt64 {
    min(appPolicy.maximumFeeRate.milliSatsPerVByte, requested.milliSatsPerVByte)
}

private extension UtexoLocalSignerBindings.ValidationReport {
    var sdk: LocalValidationReport {
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
        self = switch ffi {
        case .mainnet: .mainnet
        case .testnet: .testnet
        case .testnet4: .testnet4
        case .signet: .signet
        case .regtest: .regtest
        case .utexo: .utexo
        }
    }
}

private extension AccountKind {
    var ffi: UtexoLocalSignerBindings.AccountKind {
        switch self {
        case .vanilla: .vanilla
        case .colored: .colored
        }
    }
}

private extension Keychain {
    var ffi: UtexoLocalSignerBindings.Keychain {
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
    case let .InvalidArgument(reason):
        return .invalidArgument("nativeSigner", reason)
    case .InvalidMnemonic:
        return .invalidArgument("mnemonic", "checksum or word sequence is invalid")
    case .InvalidSeed:
        return .invalidArgument("seed", "must be an exact 64-byte BIP39 seed")
    case .EntropyUnavailable:
        return .entropyUnavailable
    case let .InvalidNetwork(reason):
        return .policyRejected("network mismatch: \(reason)", operationID: operationID)
    case let .InvalidPsbt(reason):
        return .policyRejected("malformed prepared transaction: \(reason)", operationID: operationID)
    case let .PolicyRejected(reason):
        return .policyRejected(reason, operationID: operationID)
    case .KeyDerivation:
        return .localSigningFailed("key derivation failed", operationID: operationID)
    case .SigningFailed:
        return .localSigningFailed("not every input could be signed", operationID: operationID)
    case .SignatureVerification:
        return .localSigningFailed("signature verification failed", operationID: operationID)
    }
}
