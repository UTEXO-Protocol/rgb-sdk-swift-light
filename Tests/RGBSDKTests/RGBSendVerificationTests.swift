import Foundation
import Testing

@testable @_spi(Backend) import RGBSDK

/// The values of utexo-rgb-verifier's `tests/fixtures/ffi-smoke.json`: a synthetic blinded
/// RGB send built with `psrgbt::rgb_commit` for the public "abandon ... about" wallet on
/// regtest. `fasciaBase64` is that file's `fasciaHex` re-encoded. Never fund those keys.
enum RGBVerifierSmokeFixture {
    static let masterFingerprint = "73c5da0a"
    static let accountXpubVanilla =
        "tpubDDfvzhdVV4unsoKt5aE6dcsNsfeWbTgmLZPi8LQDYU2xixrYemMfWJ3BaVneH3u7DBQePdTwhpybaKRU95pi6PMUtLPBJLVQRpzEnjfjZzX"
    static let accountXpubColored =
        "tpubDCtpoJs6YJcjLnr9gq6jYriYNMuWEu8mSDvEQU5st3ZkJbFqqzwpHUiPvxqD2366ciFAfpehk1k2d7Tyk7AJEr8uZva7KfnX4RpsiVSoEcZ"
    static let assetID = "rgb:ERERERER-ERERERE-RERERER-ERERERE-RERERER-ERERERE"
    static let amount: UInt64 = 10
    static let invoice =
        "rgb:ERERERER-ERERERE-RERERER-ERERERE-RERERER-ERERERE/~/bk/bcrt:utxob:w9c4P2CZ-bdQ65zD-k~~ajTS-Mrf1T6a-2ci4fNv-q47q8ay-pKCj5"
    static let mpcEntropy: UInt64 = 72_623_859_790_382_856
    static let txid = "7a852f692a2ee029d24f997ff56ec8b43c0294dd07cc67be0edcc0256fe0ec24"
    static let psbtBase64 =
        "cHNidP8BALQCAAAAAVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVAAAAAAD9////AwAAAAAAAAAAImogkRDFqo6KaQuQkm+C3r1U6Gqab03mIz9+SEgBXkIvyMnoAwAAAAAAACJRIOYnawA0f/9fZGOn5dBuGgGsu2WZJBJvCkSsI2QmqVPnUMMAAAAAAAAiUSCrwA6etghvmjF4c04meZp3g6VjfAp0nT9pOEzbYYqtKAAAAAAm/ANSR0IBlzXph2bbc7CVh0C19NtMitx4KV+Op2EZmMIE1tQbASOdAAAREREREREREREREREREREREREREREREREREREREREREf//////////ECcAAAEAIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiKgDwAAAQCgDwECAAHD1zg/YJlt1DrnMOT/9qNNIyt/VPprZyLh82+rjurxrAgKAAAAAAAAAAAAAQAAAOkDAAAAAAAACFoAAAAAAAAAAAb8A1JHQgIBACb8A1JHQgQREREREREREREREREREREREREREREREREREREREREREUQiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIqAPAACXNemHZttzsJWHQLX020yK3HgpX46nYRmYwgTW1BsBIwEGAQAAACb8A01QQwARERERERERERERERERERERERERERERERERERERERERESD8u7Na103CjN81REhrk3paiNpS5ZFm+Rij6scLQS6vOQb8A01QQwEICAcGBQQDAgEG/ANNUEMQIJEQxaqOimkLkJJvgt69VOhqmm9N5iM/fkhIAV5CL8jJBvwDTVBDEf0/AQMAAAgAAAAAA10xx8UVM/TO4sy27XiSIejsdDNpPckXv57odwOJurVWARERERERERERERERERERERERERERERERERERERERERER/LuzWtdNwozfNURIa5N6WojaUuWRZvkYo+rHC0EurzkAA67wtJTngQwcKkCmroo/6PhLg2Lb2/clZX9cCxlwXSFeAAPGzP8hCIWV16XZjuE6/XvNJFa+VjE+SymMLjzzwB8CcQADa9vIsRVS6ScpJ/Q/q/RjnufU5rW5oNb5f/JU9zBpArEAA+NR8oIDFDsizzp98b+YpIsVD8KBa3CiuRK2yqjdoCPwAAMiWILi0eZbpNYzdtqHSKNIv0vXS6ORbrlTEG6yhe01uAADIItQxY8KMawmWL7+QWk78fJ4qB/SHDFqFhHO8H5fGmkBCAcGBQQDAgEI/AVPUFJFVAEgkRDFqo6KaQuQkm+C3r1U6Gqab03mIz9+SEgBXkIvyMkAAQUg4huX1+oLSiN/0Jb8jND80YHNEeLd/7qtLlYeh5T8yb4hB+Ibl9fqC0ojf9CW/IzQ/NGBzRHi3f+6rS5WHoeU/Mm+GQBzxdoKVgAAgB+fDIAAAACAAAAAAAEAAAAAAQUgto3zgsrVd9gwTVqOZAw8tC13wQAWq3VMqk1uaLbLKW0hB7aN84LK1XfYME1ajmQMPLQtd8EAFqt1TKpNbmi2yyltGQBzxdoKVgAAgAEAAIAAAACAAAAAAAIAAAAA"
    static let fasciaBase64 =
        "AgAAAAEAAABVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVQAAAAAAAAAA/f///wAAAAADAAAAAAAAAAAAAAAiAAAAaiCREMWqjoppC5CSb4LevVToappvTeYjP35ISAFeQi/IyegDAAAAAAAAIgAAAFEg5idrADR//19kY6fl0G4aAay7ZZkkEm8KRKwjZCapU+dQwwAAAAAAACIAAABRIKvADp62CG+aMXhzTiZ5mneDpWN8CnSdP2k4TNthiq0oAAAAAAMAAAgAAAAAA10xx8UVM/TO4sy27XiSIejsdDNpPckXv57odwOJurVWARERERERERERERERERERERERERERERERERERERERERER/LuzWtdNwozfNURIa5N6WojaUuWRZvkYo+rHC0EurzkAA67wtJTngQwcKkCmroo/6PhLg2Lb2/clZX9cCxlwXSFeAAPGzP8hCIWV16XZjuE6/XvNJFa+VjE+SymMLjzzwB8CcQADa9vIsRVS6ScpJ/Q/q/RjnufU5rW5oNb5f/JU9zBpArEAA+NR8oIDFDsizzp98b+YpIsVD8KBa3CiuRK2yqjdoCPwAAMiWILi0eZbpNYzdtqHSKNIv0vXS6ORbrlTEG6yhe01uAADIItQxY8KMawmWL7+QWk78fJ4qB/SHDFqFhHO8H5fGmkBCAcGBQQDAgECAAEAABERERERERERERERERERERERERERERERERERERERERERAQAiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIqAPAACXNemHZttzsJWHQLX020yK3HgpX46nYRmYwgTW1BsBIwEAlzXph2bbc7CVh0C19NtMitx4KV+Op2EZmMIE1tQbASMAABERERERERERERERERERERERERERERERERERERERERER//////////8QJwAAAQAiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIqAPAAABAKAPAQIAAcPXOD9gmW3UOucw5P/2o00jK39U+mtnIuHzb6uO6vGsCAoAAAAAAAAAAAABAAAA6QMAAAAAAAAIWgAAAAAAAAAA"

    static func evidence(
        entropy: UInt64 = mpcEntropy, fascia: String = fasciaBase64, proofs: [RGBExistingOutputProof] = []
    ) throws -> RGBSendEvidence {
        try RGBSendEvidence(fasciaBase64: fascia, mpcEntropy: entropy, existingOutputProofs: proofs)
    }

    /// The gateway signer also requires a transport endpoint, which the verifier ignores:
    /// the endpoint does not change the invoice's beneficiary.
    static func request() throws -> OnchainSendRequest {
        try OnchainSendRequest(
            invoice: RGBInvoice(invoice + "?endpoints=rpc://proxy:3000/json-rpc"),
            amount: AssetAmount(amount), assetID: AssetID(assetID), feeRate: FeeRate(satsPerVByte: 2),
            idempotencyKey: IdempotencyKey("rgb-verifier-smoke"))
    }

    static func prepared(
        _ evidence: RGBSendEvidence?, psbt: String = psbtBase64, request: OnchainSendRequest? = nil
    ) throws -> PreparedTransaction {
        let request = try request ?? self.request()
        return try PreparedTransaction(
            operationID: OperationID("rgb-verifier-smoke"), idempotencyKey: request.idempotencyKey,
            requestHash: RequestHasher.onchainSend(network: .regtest, request: request), network: .regtest,
            operation: .onchainSend, psbtBase64: psbt, expiresAt: .init(rawValue: 2_000_000_000),
            rgbSendEvidence: evidence)
    }

    /// Runs the shipped verifier directly, with the device-derived identity of the fixture wallet.
    static func verify(
        evidence: RGBSendEvidence, psbt: String = psbtBase64, invoice: String = invoice,
        assetID: String = assetID, amount: UInt64 = amount, network: Network = .regtest
    ) throws -> TransactionID {
        try RGBSendVerification.verify(
            network: network, identity: GatewayNativeFixtures.signer().identity(),
            prepared: prepared(evidence, psbt: psbt), evidence: evidence, invoice: invoice,
            assetID: assetID, amount: amount, policy: .default)
    }
}

private func expectSDKError(
    _ code: SDKErrorCode, containing fragment: String, sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () throws -> Void
) {
    do {
        try body()
        Issue.record("expected \(code.rawValue)", sourceLocation: sourceLocation)
    } catch let error as SDKError {
        #expect(error.code == code, sourceLocation: sourceLocation)
        #expect(error.message.contains(fragment), "\(error.message)", sourceLocation: sourceLocation)
    } catch {
        Issue.record("unexpected error type", sourceLocation: sourceLocation)
    }
}

@Test func rgbSendWithoutEvidenceIsRefusedUnlessThePolicyExplicitlyAllowsBlindSigning() throws {
    let blind = try RGBVerifierSmokeFixture.prepared(nil)
    expectSDKError(.policyRejected, containing: "no RGB send evidence") {
        _ = try RGBSendVerification.requireEvidence(blind, policy: .default)
    }
    let allowed = try LocalSigningPolicy(allowUnverifiedRGBSends: true)
    #expect(try RGBSendVerification.requireEvidence(blind, policy: allowed) == nil)
    #expect(!LocalSigningPolicy.default.allowUnverifiedRGBSends)
    #expect(try !LocalSigningPolicy().allowUnverifiedRGBSends)
    // Evidence that arrives is verified whatever the policy allows.
    let evidence = try RGBVerifierSmokeFixture.evidence()
    #expect(
        try RGBSendVerification.requireEvidence(RGBVerifierSmokeFixture.prepared(evidence), policy: allowed)
            == evidence)
}

@Test func rgbSendEvidenceIsConfinedToRGBSendsBoundedAndRedactedFromDescriptions() throws {
    let fascia = "ZmFzY2lhLWJ5dGVzLWZvci10ZXN0cw=="
    let proof = try RGBExistingOutputProof(transactionHex: "02000000", vout: 1, derivationIndex: 7)
    let evidence = try RGBSendEvidence(fasciaBase64: fascia, mpcEntropy: 7, existingOutputProofs: [proof])
    #expect(throws: SDKError.self) {
        try PreparedTransaction(
            operationID: OperationID("operation-1"), idempotencyKey: IdempotencyKey("idempotency-1"),
            requestHash: RequestHash(validating: String(repeating: "d", count: 64)), network: .signet,
            operation: .sendBtc, psbtBase64: "prepared-psbt", expiresAt: .init(rawValue: 2_000),
            rgbSendEvidence: evidence)
    }
    #expect(!"\(evidence)".contains(fascia) && !String(reflecting: evidence).contains(fascia))
    #expect(!"\(proof)".contains("02000000") && !String(reflecting: proof).contains("02000000"))
    #expect(try RGBExistingOutputProof(
        transactionHex: "02", vout: UInt32(Int32.max), derivationIndex: UInt32(Int32.max)).vout == 2_147_483_647)
    let invalid: [() throws -> Void] = [
        { _ = try RGBExistingOutputProof(transactionHex: "02AB", vout: 0, derivationIndex: 0) },
        { _ = try RGBExistingOutputProof(transactionHex: "020", vout: 0, derivationIndex: 0) },
        { _ = try RGBExistingOutputProof(transactionHex: "", vout: 0, derivationIndex: 0) },
        { _ = try RGBExistingOutputProof(transactionHex: "0g", vout: 0, derivationIndex: 0) },
        { _ = try RGBExistingOutputProof(transactionHex: "02", vout: 2_147_483_648, derivationIndex: 0) },
        { _ = try RGBExistingOutputProof(transactionHex: "02", vout: 0, derivationIndex: 2_147_483_648) },
        { _ = try RGBExistingOutputProof(
            transactionHex: String(repeating: "0", count: RGBExistingOutputProof.maximumTransactionHexCharacters + 2),
            vout: 0, derivationIndex: 0) },
        { _ = try RGBSendEvidence(fasciaBase64: " " + fascia, mpcEntropy: 7) },
        { _ = try RGBSendEvidence(fasciaBase64: "", mpcEntropy: 7) },
        { _ = try RGBSendEvidence(
            fasciaBase64: fascia, mpcEntropy: 7,
            existingOutputProofs: Array(repeating: proof, count: RGBSendEvidence.maximumExistingOutputProofs + 1)) },
    ]
    for (index, make) in invalid.enumerated() {
        do {
            try make()
            Issue.record("invalid RGB send evidence \(index) was accepted")
        } catch let error as SDKError { #expect(error.code == .invalidArgument, "case \(index)") }
    }
}

/// Offline qualification of the linked `utexo-rgb-verifier` library through its Swift binding.
@Test func packagedVerifierAcceptsTheFixtureAndRejectsACommitmentToOtherBundles() throws {
    let identity = try GatewayNativeFixtures.signer().identity()
    #expect(identity.masterFingerprint == RGBVerifierSmokeFixture.masterFingerprint)
    #expect(identity.accountXpubVanilla == RGBVerifierSmokeFixture.accountXpubVanilla)
    #expect(identity.accountXpubColored == RGBVerifierSmokeFixture.accountXpubColored)

    let txid = try RGBVerifierSmokeFixture.verify(evidence: RGBVerifierSmokeFixture.evidence())
    #expect(txid.hex == RGBVerifierSmokeFixture.txid)

    expectSDKError(.policyRejected, containing: "does not commit") {
        _ = try RGBVerifierSmokeFixture.verify(
            evidence: RGBVerifierSmokeFixture.evidence(entropy: RGBVerifierSmokeFixture.mpcEntropy ^ 1))
    }
}

@Test func verifierFailuresRefuseSigningAndKeepOnlyTheVerifiersSafeReason() throws {
    let evidence = try RGBVerifierSmokeFixture.evidence()
    // Rejected: the transaction's commitment does not cover exactly the disclosed bundles.
    expectSDKError(.policyRejected, containing: "RGB send verification failed: ") {
        _ = try RGBVerifierSmokeFixture.verify(
            evidence: RGBVerifierSmokeFixture.evidence(entropy: RGBVerifierSmokeFixture.mpcEntropy ^ 1))
    }
    // InvalidRgbInvoice: the invoice names another amount or asset than the caller approved.
    expectSDKError(.invalidArgument, containing: "invoice: is invalid or contradicts the request") {
        _ = try RGBVerifierSmokeFixture.verify(evidence: evidence, amount: 11)
    }
    expectSDKError(.invalidArgument, containing: "invoice: is invalid or contradicts the request") {
        _ = try RGBVerifierSmokeFixture.verify(
            evidence: evidence, assetID: "rgb:IiIiIiIi-IiIiIiI-iIiIiIi-IiIiIiI-iIiIiIi-IiIiIiI")
    }
    // InvalidFascia: well-formed Base64 that is not a strict-encoded fascia.
    expectSDKError(.policyRejected, containing: "RGB fascia is invalid: ") {
        _ = try RGBVerifierSmokeFixture.verify(
            evidence: RGBVerifierSmokeFixture.evidence(fascia: "ZmFzY2lhLWJ5dGVzLWZvci10ZXN0cw=="))
    }
    // A fascia that is not Base64 never reaches the native library.
    expectSDKError(.policyRejected, containing: "RGB fascia is not Base64") {
        _ = try RGBVerifierSmokeFixture.verify(evidence: RGBVerifierSmokeFixture.evidence(fascia: "not base64!"))
    }
    // InvalidArgument: a malformed backend proof is a refusal to sign, not a local fault.
    let malformedProof = try RGBExistingOutputProof(transactionHex: "02000000", vout: 0, derivationIndex: 0)
    expectSDKError(.policyRejected, containing: "RGB send verification input is invalid: ") {
        _ = try RGBVerifierSmokeFixture.verify(
            evidence: RGBVerifierSmokeFixture.evidence(proofs: [malformedProof]))
    }
    // InvalidPsbt: the reason is dropped, as for the Bitcoin signer.
    expectSDKError(.policyRejected, containing: "transaction encoding is invalid") {
        _ = try RGBVerifierSmokeFixture.verify(evidence: evidence, psbt: "cHNidP8=")
    }
    // Keys for another network are refused without echoing them.
    do {
        _ = try RGBVerifierSmokeFixture.verify(evidence: evidence, network: .mainnet)
        Issue.record("expected a refusal for another network")
    } catch let error as SDKError {
        #expect(error.code == .policyRejected)
        #expect(error.message.contains("RGB send verification input is invalid: "), "\(error.message)")
        #expect(!error.message.contains("tpub") && !error.message.contains("utxob"))
    }
    #expect(mapVerifierError(CancellationError()).code == .internalInvariantViolation)
}

@Test func gatewaySignerRunsRGBVerificationBeforeSigningAndBeforeResubmission() throws {
    let signer = try GatewayNativeFixtures.signer()
    let request = try RGBVerifierSmokeFixture.request()
    let evidence = try RGBVerifierSmokeFixture.evidence()
    let wrongEntropy = try RGBVerifierSmokeFixture.evidence(entropy: RGBVerifierSmokeFixture.mpcEntropy ^ 1)
    let retained = try LocalValidationReport(
        psbtSHA256: String(repeating: "b", count: 64), intentSHA256: String(repeating: "c", count: 64),
        unsignedTxid: TransactionID(RGBVerifierSmokeFixture.txid), totalInput: Satoshis(20_000),
        totalOutput: Satoshis(19_000), fee: Satoshis(1_000), estimatedVbytes: 200,
        feeRate: FeeRate(satsPerVByte: 5), externalOutput: Satoshis(10_000), change: Satoshis(9_000),
        inputCount: 1, outputCount: 3, opReturnCount: 1)
    func sign(_ evidence: RGBSendEvidence?, _ policy: LocalSigningPolicy = .default) throws {
        _ = try signer.validateAndSignOnchainSend(
            prepared: RGBVerifierSmokeFixture.prepared(evidence), request: request, policy: policy,
            now: 1_800_000_000)
    }

    expectSDKError(.policyRejected, containing: "no RGB send evidence") { try sign(nil) }
    expectSDKError(.policyRejected, containing: "RGB send verification failed") { try sign(wrongEntropy) }
    // The opt-in covers missing evidence only: evidence that arrives is always verified.
    expectSDKError(.policyRejected, containing: "RGB send verification failed") {
        try sign(wrongEntropy, LocalSigningPolicy(allowUnverifiedRGBSends: true))
    }
    expectSDKError(.policyRejected, containing: "RGB send verification failed") {
        try signer.validateOnchainSendBeforeSubmission(
            prepared: RGBVerifierSmokeFixture.prepared(wrongEntropy), request: request, policy: .default,
            retainedValidation: retained, now: 1_800_000_000)
    }
    expectSDKError(.policyRejected, containing: "no RGB send evidence") {
        try signer.validateOnchainSendBeforeSubmission(
            prepared: RGBVerifierSmokeFixture.prepared(nil), request: request, policy: .default,
            retainedValidation: retained, now: 1_800_000_000)
    }

    // With the right evidence the RGB check passes and the Bitcoin signer decides. The
    // synthetic fixture carries no Bitcoin input metadata, so that signer refuses it.
    do {
        try sign(evidence)
        Issue.record("the synthetic fixture has no signable Bitcoin inputs")
    } catch let error as SDKError {
        #expect(error.code == .policyRejected)
        // The refusal is the Bitcoin signer's own, not an RGB verification failure.
        #expect(!error.message.contains("RGB "), "\(error.message)")
        #expect(error.message.contains("PSBT"), "\(error.message)")
    }
}
