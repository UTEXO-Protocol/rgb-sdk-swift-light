import Foundation
internal import UtexoRgbVerifierBindings

/// Pre-sign RGB verification through `utexo-rgb-verifier`. Spending a colored input
/// authorizes whatever RGB transition the transaction commits to, and the Bitcoin signer
/// cannot see that commitment. The verifier proves that every allocation the signature
/// moves goes to the invoice's beneficiary, in exactly the approved asset and amount, or
/// back to this wallet's colored account. It does not validate RGB history.
enum RGBSendVerification {
    /// The verdict format this SDK reads; a different library build is rejected.
    static let profile = "utexo.rgb-send.v1"

    /// Returns the evidence to verify, or nil only when `policy` explicitly allows signing
    /// an RGB send blind. Missing evidence is never a silent downgrade: a hostile backend
    /// could otherwise skip verification by leaving it out.
    static func requireEvidence(
        _ prepared: PreparedTransaction, policy: LocalSigningPolicy
    ) throws -> RGBSendEvidence? {
        if let evidence = prepared.rgbSendEvidence { return evidence }
        guard policy.allowUnverifiedRGBSends else {
            throw SDKError.policyRejected(
                "RGB send preparation has no RGB send evidence to verify", operationID: prepared.operationID)
        }
        return nil
    }

    /// Returns the unsigned txid the verdict covers. Call before any signature exists.
    ///
    /// `identity` must come from the device's own key derivation, and `invoice`, `assetID`
    /// and `amount` from what the caller approved, never from the backend's echo of them.
    static func verify(
        network: Network, identity: WalletIdentity, prepared: PreparedTransaction,
        evidence: RGBSendEvidence, invoice: String, assetID: String, amount: UInt64,
        policy: LocalSigningPolicy
    ) throws -> TransactionID {
        guard let fascia = Data(base64Encoded: evidence.fasciaBase64) else {
            throw SDKError.policyRejected("RGB fascia is not Base64", operationID: prepared.operationID)
        }
        let verdict: UtexoRgbVerifierBindings.RgbSendVerdict
        do {
            verdict = try UtexoRgbVerifierBindings.verifyRgbSend(
                request: .init(
                    network: network.verifierFFI,
                    accounts: .init(
                        masterFingerprint: identity.masterFingerprint,
                        accountXpubVanilla: identity.accountXpubVanilla,
                        accountXpubColored: identity.accountXpubColored),
                    psbtBase64: prepared.psbtBase64,
                    fascia: fascia,
                    mpcEntropy: evidence.mpcEntropy,
                    invoice: invoice,
                    assetId: assetID,
                    amount: amount,
                    existingOutputProofs: evidence.existingOutputProofs.map {
                        .init(
                            transaction: lowercaseHexBytes($0.transactionHex), vout: $0.vout,
                            derivationIndex: $0.derivationIndex)
                    },
                    maxDerivationIndex: policy.maximumChildIndex))
        } catch {
            throw mapVerifierError(error, operationID: prepared.operationID)
        }
        guard verdict.profile == profile else {
            throw SDKError.unsupported("RGB send verifier profile \(verdict.profile)")
        }
        guard let txid = try? TransactionID(verdict.txid) else {
            throw SDKError.invariant("native RGB send verifier returned a malformed transaction ID")
        }
        return txid
    }
}

/// Verifier reasons name output indexes, counts and asset ids only, never keys, PSBTs,
/// fascia bytes or invoices, so a rejection reason is safe to carry in the message.
func mapVerifierError(_ error: any Error, operationID: OperationID? = nil) -> SDKError {
    guard let verifierError = error as? UtexoRgbVerifierBindings.VerifierError else {
        // UniFFI's internal errors can quote panic text; never surface it.
        return .invariant("native RGB send verifier call failed")
    }
    switch verifierError {
    case .Rejected(let reason):
        return .policyRejected("RGB send verification failed: \(reason)", operationID: operationID)
    case .InvalidPsbt:
        return .policyRejected("transaction encoding is invalid", operationID: operationID)
    case .InvalidFascia(let reason):
        return .policyRejected("RGB fascia is invalid: \(reason)", operationID: operationID)
    case .InvalidRgbInvoice:
        return .invalidArgument("invoice", "is invalid or contradicts the request")
    case .InvalidArgument(let reason):
        // Also raised for malformed backend proofs, so it is a refusal to sign, not a local fault.
        return .policyRejected(
            "RGB send verification input is invalid: \(reason)", operationID: operationID)
    }
}

/// `RGBExistingOutputProof` admits only even-length lowercase hex, so every pair decodes.
private func lowercaseHexBytes(_ hex: String) -> Data {
    func nibble(_ byte: UInt8) -> UInt8 { byte <= UInt8(ascii: "9") ? byte - UInt8(ascii: "0") : byte - UInt8(ascii: "a") + 10 }
    var bytes = Data(capacity: hex.utf8.count / 2)
    var high: UInt8?
    for byte in hex.utf8 {
        if let first = high {
            bytes.append(nibble(first) << 4 | nibble(byte))
            high = nil
        } else {
            high = byte
        }
    }
    return bytes
}

private extension Network {
    var verifierFFI: UtexoRgbVerifierBindings.Network {
        switch self {
        case .mainnet: .mainnet
        case .testnet: .testnet
        case .testnet4: .testnet4
        case .signet: .signet
        case .regtest: .regtest
        case .utexo: .utexo
        }
    }
}
