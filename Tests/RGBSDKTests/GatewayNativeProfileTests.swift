import Foundation
import Testing

@testable @_spi(Backend) import RGBSDK

// Untouched 2026-09-18 PR174 real-regtest preparations from gateway native
// @utexo/rgb-lib 0.3.0-beta.18 (capture commit 8eebc40a...). Public BIP39 vector;
// NEVER fund these keys. Historical opIds/expiry are not live service requests.
// These tests sign locally only; no HTTP, gateway complete, or broadcast.
enum GatewayNativeFixtures {
    static let btc =
        "cHNidP8BAIkCAAAAAcMFXrbZjpyhu3DXPxMJoKxc0EjQyGCKiWwyLKCWtwK2AAAAAAD9////AkCcAAAAAAAAIlEgkRunSgqf8plm7Wggw2TjfNFB+fwbPm8rlEsDCd4RonLLpA4AAAAAACJRIKCrRhP30zmYlO/WxZO7/hR08k5v5czT4mOgawdnU6IXaAAAAAABAStAQg8AAAAAACJRIDuCsrKpGFMV2m+A2l8G0EQNil4UV/qTOHwtkZyG7IeGIRZVNVyoPJc/HZfODjhDyF14kFrxa03FMbxIjlchLSMBFhkAc8XaClYAAIABAACAAAAAgAAAAAAAAAAAARcgVTVcqDyXPx2Xzg44Q8hdeJBa8WtNxTG8SI5XIS0jARYAAAEFIJlVJesfKWoH+6aDa4ZRRvstWF79+quWgN9F3OQFgH3yIQeZVSXrHylqB/umg2uGUUb7LVhe/fqrloDfRdzkBYB98hkAc8XaClYAAIABAACAAAAAgAAAAAADAAAAAA=="
    static let create =
        "cHNidP8BAP01AQIAAAABwwVettmOnKG7cNc/EwmgrFzQSNDIYIqJbDIsoJa3ArYAAAAAAP3///8GiBMAAAAAAAAiUSA/igS64ltEtpbXqB6AQ7FkKMoSb6xEciyL/f396kW6rIgTAAAAAAAAIlEgU5yAs09PjE5dCcbQBx4xn/156X9Ru/eZL7wciUjRvleIEwAAAAAAACJRIKSkGbHEFybBpTrY00ry+35zXDfzqPyi6MJ6iAEm/a6YiBMAAAAAAAAiUSBpR7J1dbw33J1gVx5w2hOjYTQ0e3g7ATHWBl7ign8swQveDgAAAAAAIlEg9QsIVm79ixnv8hhCquwNXjFM1TrkZkXkCqe9vRxk7B6IEwAAAAAAACJRIHICjNdhKSOZZA9deuT0zA8H1LEzh8O3OfplZ7AI47gVaAAAAAABAStAQg8AAAAAACJRIDuCsrKpGFMV2m+A2l8G0EQNil4UV/qTOHwtkZyG7IeGIRZVNVyoPJc/HZfODjhDyF14kFrxa03FMbxIjlchLSMBFhkAc8XaClYAAIABAACAAAAAgAAAAAAAAAAAARcgVTVcqDyXPx2Xzg44Q8hdeJBa8WtNxTG8SI5XIS0jARYAAQUg46FpuTh442cMVs/yjPTbwtYpcahIgc0oF4jiNZDHb5whB+Ohabk4eONnDFbP8oz028LWKXGoSIHNKBeI4jWQx2+cGQBzxdoKVgAAgB+fDIAAAACAAAAAAAYAAAAAAQUgCZXb2oj9JV4I/vwvLvRjw54lnniWCj2i0wvX3VZEhJQhBwmV29qI/SVeCP78Ly70Y8OeJZ54lgo9otML191WRISUGQBzxdoKVgAAgB+fDIAAAACAAAAAAAcAAAAAAQUgmg+wcdU7TZ5L/aU9Kp7xLCCsKqDIAP1wGgR1GszjgxQhB5oPsHHVO02eS/2lPSqe8SwgrCqgyAD9cBoEdRrM44MUGQBzxdoKVgAAgB+fDIAAAACAAAAAAAkAAAAAAQUgUblWS0XcV3cPxq5Ie7tWGwFoEY0bpkUoBUTrBY04O9shB1G5VktF3Fd3D8auSHu7VhsBaBGNG6ZFKAVE6wWNODvbGQBzxdoKVgAAgB+fDIAAAACAAAAAAAgAAAAAAQUg06Ogkx7uOjjnj4Jg5uTQah+odrSWqHgvH3TPFeR/OMMhB9OjoJMe7jo454+CYObk0GofqHa0lqh4Lx90zxXkfzjDGQBzxdoKVgAAgAEAAIAAAACAAAAAAAQAAAAAAQUgrf3UFMClmzhQAjFugNyfRbDtG1SCmLf654pe3p45tNkhB6391BTApZs4UAIxboDcn0Ww7RtUgpi3+ueKXt6eObTZGQBzxdoKVgAAgB+fDIAAAACAAAAAAAoAAAAA"
    static let rgb =
        "cHNidP8BAIkCAAAAAR2KIt3irReZSjrsrmaFFuJBMLiStfhMnAaDHJkPAjgKAQAAAAD9////AgAAAAAAAAAAImogWOMP2CVjHELnJNDiGdElV80VbJ60FWNWr44vDmGSPTJTEgAAAAAAACJRIK9e8Lw6jXMCVonmxCxaFAMIWyUXQGUjNavhKSbyO5ijbQAAACb8A1JHQgGjIrEHjg38PIc71XPXy6mj1p2M7HK+TvSSsUt+9Y9yD50AAPad2mVb0nvPOq7NO11g9r6rodBrrUHiuqOMXV9vYGBq//////////8QJwAAAQBURjmHG3H0GMbeHtk+FqFUkCMZxDv0+ur5zmfY7uR50aAPAAABAKAPAQIAAAABAAAAxleWMJ/0BPQIPAAAAAAAAAABrrenuOZqsm2KkQow+ksB+KESeK4vFN79kMAisuQX4q0IKAAAAAAAAAAABvwDUkdCAgEAJvwDUkdCBPad2mVb0nvPOq7NO11g9r6rodBrrUHiuqOMXV9vYGBqRFRGOYcbcfQYxt4e2T4WoVSQIxnEO/T66vnOZ9ju5HnRoA8AAKMisQeODfw8hzvVc9fLqaPWnYzscr5O9JKxS371j3IPAAEBK4gTAAAAAAAAIlEglDQtzOhDbJ7VOzv4Y4k9mxMnbtpTWTc4JflKEIatknohFrKktYEOznb4eBjUiZ0VT+4OTQuXE+WwX2RquXfXp+4jGQBzxdoKVgAAgB+fDIAAAACAAAAAAA4AAAABFyCypLWBDs52+HgY1ImdFU/uDk0LlxPlsF9karl316fuIwAm/ANNUEMA9p3aZVvSe886rs07XWD2vquh0GutQeK6o4xdX29gYGog1ms2Ftr8A/m78jaypYLnSFT/6M22JR8KStpu8sz5wxgG/ANNUEMBCH+0ZmLIWLl1BvwDTVBDECBY4w/YJWMcQuck0OIZ0SVXzRVsnrQVY1avji8OYZI9Mgb8A01QQxH9PwEDAAAIAAAAAAMr9jmqMScSweRgGnsjWoFUYMzsN0L+WL10RERdxSOiRAAD+Mz1T25F1gS5F9fOr7XIOEAOutZS4b6QqLPtEJ4OfbUAA0ozIuAdV13T0fH7Hqme4N8ThhajjeZW/Shzb6Z42U5JAAMjQdRTXA8HvKpgDpI6LyclyvTXWWaN1aj/vqG3KMu1BgADzljv6tTAD5bf4jgNPa5jr2YKmKDP8rQGd+APUUSVcikAA4OSQCPUFV+tC9THiaEi6IJnvCgJawo2neupANs0sXR5Afad2mVb0nvPOq7NO11g9r6rodBrrUHiuqOMXV9vYGBq1ms2Ftr8A/m78jaypYLnSFT/6M22JR8KStpu8sz5wxgAA/X+L1oUktp/Lx/F6/euyFAO4zqlS9J+0KOPliGHqRPdAX+0ZmLIWLl1CPwFT1BSRVQBIFjjD9glYxxC5yTQ4hnRJVfNFWyetBVjVq+OLw5hkj0yAAEFIEL9SeQDwrrpFk1sQ/15mHbwQ8BK0AhQqrT2i9zH5Xr4IQdC/UnkA8K66RZNbEP9eZh28EPAStAIUKq09ovcx+V6+BkAc8XaClYAAIAfnwyAAAAAgAAAAAAPAAAAAA=="
    static let rgbInvoice =
        "rgb:9p3aZVvS-e886rs0-7XWD2vq-uh0GutQ-eK6o4xd-X29gYGo/~/~/bcrt:utxob:rrenuOZq-sm2KkQo-w_ksB_K-ESeK4vF-N79kMAi-suQX4q2-J1tYQ?endpoints=rpc://proxy:3000/json-rpc"

    static func signer(height: UInt32 = 110, gateway: Bool = true) throws -> any LocalSigningEngine {
        let mnemonic = try SecretMnemonic(
            copyingUTF8: Array(
                "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
                    .utf8))
        defer { mnemonic.close() }
        let seed = try deriveSeedFromMnemonic(mnemonic: mnemonic)
        defer { seed.close() }
        let factory = UniFFILocalSigningEngineFactory()
        if gateway {
            return try factory.openGateway(
                network: .regtest, seed: seed, context: GatewaySigningContext(maximumBlockHeight: height))
        }
        return try factory.open(network: .regtest, seed: seed)
    }

    static func prepared(_ request: LocalOperationRequest, psbt: String, plan: CreateUtxosOutputPlan? = nil)
        throws -> PreparedTransaction
    {
        try .init(
            operationID: OperationID("gateway-fixture"), idempotencyKey: request.idempotencyKey,
            requestHash: request.hash(network: .regtest), network: .regtest, operation: request.kind,
            psbtBase64: psbt, expiresAt: .init(rawValue: 2_000_000_000), createUtxosOutputPlan: plan)
    }
}

@Test func packagedGatewayProfileSignsUntouchedBtcFixtureAndKeepsLegacyClosed() throws {
    let request = try SendBtcRequest(
        address: BitcoinAddress("bcrt1pjyd6wjs2nlefjehddqsvxe8r0ng5r70urvlx72u5fvpsnhs35feqsu7305"),
        amount: Satoshis(40_000), feeRate: FeeRate(satsPerVByte: 2),
        idempotencyKey: IdempotencyKey("gateway-btc"))
    let prepared = try GatewayNativeFixtures.prepared(.sendBtc(request), psbt: GatewayNativeFixtures.btc)
    let signer = try GatewayNativeFixtures.signer()
    #expect(signer.capabilities.signingProfile == "utexo.psbt.rgb-lib.v1")
    let signed = try signer.validateAndSign(prepared: prepared, request: request, policy: .default)
    #expect(
        signed.validation.unsignedTxid.hex
            == "c85326c4ef41a07740b0024b9ffd405ec0b114684b63833dd01653ad4df579fb")
    #expect(signed.validation.fee.value == 309 && signed.validation.estimatedVbytes == 154)
    #expect(signed.signedPsbtBase64 != prepared.psbtBase64)
    try signer.validateBeforeSubmission(
        prepared: prepared, request: request, policy: .default, retainedValidation: signed.validation)
    for rejected in try [
        GatewayNativeFixtures.signer(height: 103), GatewayNativeFixtures.signer(gateway: false),
    ] {
        #expect(throws: SDKError.self) {
            try rejected.validateAndSign(prepared: prepared, request: request, policy: .default)
        }
    }
    #expect(throws: SDKError.self) {
        try signer.validateAndSign(
            prepared: prepared, request: request,
            policy: LocalSigningPolicy(maximumAbsoluteFee: Satoshis(308)))
    }
    // A target's sub-satoshi rounding never raises the separate hard rate cap.
    #expect(throws: SDKError.self) {
        try signer.validateAndSign(
            prepared: prepared, request: request,
            policy: LocalSigningPolicy(maximumFeeRate: FeeRate(satsPerVByte: 2)))
    }
    #expect(throws: SDKError.self) { try GatewaySigningContext(maximumBlockHeight: 500_000_000) }
}

@Test func packagedGatewayProfileAuthorizesExactCreateOutputsFromUntouchedFixture() throws {
    let request = try CreateUtxosRequest(
        upTo: false, num: 5, size: Satoshis(5_000), feeRate: FeeRate(satsPerVByte: 2))
    let outputs = try [6, 7, 9, 8, 10].map {
        try ExpectedWalletOutput(
            account: .colored, keychain: .external, index: UInt32($0), amount: Satoshis(5_000))
    }
    let prepared = try GatewayNativeFixtures.prepared(
        .createUtxos(request), psbt: GatewayNativeFixtures.create,
        plan: CreateUtxosOutputPlan(outputs: outputs))
    let signer = try GatewayNativeFixtures.signer()
    let signed = try signer.validateAndSignCreateUtxos(prepared: prepared, request: request, policy: .default)
    #expect(
        signed.validation.unsignedTxid.hex
            == "9f4b8d594d577e5b73cd941db229870965f099bf0092df8cf9444cc309986967")
    #expect(signed.validation.fee.value == 653 && signed.validation.estimatedVbytes == 326)
    try signer.validateCreateUtxosBeforeSubmission(
        prepared: prepared, request: request, policy: .default, retainedValidation: signed.validation)
    let altered =
        try [ExpectedWalletOutput(account: .colored, keychain: .external, index: 20, amount: Satoshis(5_000))]
        + outputs.dropFirst()
    let wrongPlan = try GatewayNativeFixtures.prepared(
        .createUtxos(request), psbt: GatewayNativeFixtures.create,
        plan: CreateUtxosOutputPlan(outputs: altered))
    #expect(throws: SDKError.self) {
        try signer.validateAndSignCreateUtxos(prepared: wrongPlan, request: request, policy: .default)
    }
}

@Test func packagedGatewayProfileValidatesRgbBitcoinIntentWithoutClaimingRgbStateValidation() throws {
    let request = try OnchainSendRequest(
        invoice: RGBInvoice(GatewayNativeFixtures.rgbInvoice), amount: AssetAmount(40),
        feeRate: FeeRate(satsPerVByte: 2))
    let prepared = try GatewayNativeFixtures.prepared(.onchainSend(request), psbt: GatewayNativeFixtures.rgb)
    let signer = try GatewayNativeFixtures.signer()
    let signed = try signer.validateAndSignOnchainSend(
        prepared: prepared, request: request, policy: .default, now: 1_800_000_000)
    #expect(
        signed.validation.unsignedTxid.hex
            == "e41e4ebdc769b0575126a5d728394d4c01206110e7eaebf6446029d5acd0d814")
    #expect(signed.validation.fee.value == 309 && signed.validation.opReturnCount == 1)
    #expect(!signer.capabilities.localRGBValidation)
    try signer.validateOnchainSendBeforeSubmission(
        prepared: prepared, request: request, policy: .default, retainedValidation: signed.validation,
        now: 1_800_000_001)
    let changed = try OnchainSendRequest(
        invoice: request.invoice, amount: AssetAmount(41), feeRate: request.feeRate)
    #expect(throws: SDKError.self) {
        try signer.validateAndSignOnchainSend(
            prepared: prepared, request: changed, policy: .default, now: 1_800_000_000)
    }
    // An RGB commitment cannot enter the ordinary BTC operation path.
    let btc = try SendBtcRequest(
        address: BitcoinAddress("bcrt1pjyd6wjs2nlefjehddqsvxe8r0ng5r70urvlx72u5fvpsnhs35feqsu7305"),
        amount: Satoshis(1), feeRate: FeeRate(satsPerVByte: 2))
    #expect(throws: SDKError.self) {
        try signer.validateAndSign(prepared: prepared, request: btc, policy: .default)
    }
}
