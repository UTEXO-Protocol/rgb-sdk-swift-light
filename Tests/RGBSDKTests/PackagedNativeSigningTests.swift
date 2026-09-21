import Foundation
import Testing
@testable @_spi(Backend) import RGBSDK

@Test func packagedRetainedPolicyValidationRechecksInputCountAndChildIndex() throws {
    let mnemonic = try SecretMnemonic(copyingUTF8: Array(
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about".utf8
    ))
    defer { mnemonic.close() }
    let seed = try deriveSeedFromMnemonic(mnemonic: mnemonic)
    defer { seed.close() }
    let signer = try UniFFILocalSigningEngineFactory().open(network: .mainnet, seed: seed)
    // Shared core native-signing-multi-smoke fixture: two nonexistent vanilla
    // prevouts, externally derived at child 2 and child 3. Never fund these keys.
    let psbt = "cHNidP8BALICAAAAAgcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHAAAAAAD9////CAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgAAAAAAP3///8CMHUAAAAAAAAiUSCoLymUTWW4aua15cx14pTq1sWTkaHtxeAW40mMZ/x7uxyWAgAAAAAAIlEgiC105dBXLVqBbO8AQalrbB3oMvb5Z22WBcRNXpqX09wAAAAAAAEBK6CGAQAAAAAAIlEge147kJMD+u6XZ8AHgZ00mYBo9corqj5Thdkjd8EkRMUhFqcwojzotHJIpd37Mu73UmLZHwtVsITdH/DS+eAy4OUzGQBzxdoKVgAAgAAAAIAAAACAAAAAAAIAAAABFyCnMKI86LRySKXd+zLu91Ji2R8LVbCE3R/w0vngMuDlMwABASughgEAAAAAACJRICPYMlj9ByAtUILnGkChDIOFbAXL7w4Hwlt8F4W7gXm+IRYG7UNK4A2OS0yJ3Uuv4IH6G7xtsKvxfGBrGoZcpQMJoxkAc8XaClYAAIAAAACAAAAAgAAAAAADAAAAARcgBu1DSuANjktMid1Lr+CB+hu8bbCr8XxgaxqGXKUDCaMAAAEFIDmfGy9Dk/KaGMk3hZxd2KdzUBAxV+uIDwLowIIUJ3zvIQc5nxsvQ5PymhjJN4WcXdinc1AQMVfriA8C6MCCFCd87xkAc8XaClYAAIAAAACAAAAAgAEAAAAAAAAAAA=="
    let request = try SendBtcRequest(
        address: BitcoinAddress("bc1p4qhjn9zdvkux4e44uhx8tc55attvtyu358kutcqkudyccelu0was9fqzwh"),
        amount: Satoshis(30_000), feeRate: FeeRate(milliSatsPerVByte: 100_000),
        idempotencyKey: IdempotencyKey("idem_test_001")
    )
    let prepared = try PreparedTransaction(
        operationID: OperationID("op_test_001"), idempotencyKey: request.idempotencyKey,
        requestHash: RequestHasher.sendBtc(network: .mainnet, request: request),
        network: .mainnet, operation: .sendBtc, psbtBase64: psbt, expiresAt: .init(rawValue: 1_001)
    )
    let signed = try signer.validateAndSign(prepared: prepared, request: request, policy: .default)
    #expect(signed.validation.inputCount == 2)
    #expect(signed.validation.estimatedVbytes == 212)
    #expect(signed.validation.fee.value == 500)
    #expect(signed.validation.unsignedTxid.hex == "3487ab7ad4f305d0e2adab22afc48b850aba1728276c55dfc1dc748cdd3b60a6")
    try signer.validateBeforeSubmission(
        prepared: prepared, request: request,
        policy: LocalSigningPolicy(maximumInputs: 2, maximumChildIndex: 3),
        retainedValidation: signed.validation
    )
    for policy in try [LocalSigningPolicy(maximumInputs: 1), LocalSigningPolicy(maximumChildIndex: 1)] {
        do {
            try signer.validateBeforeSubmission(
                prepared: prepared, request: request, policy: policy,
                retainedValidation: signed.validation
            )
            Issue.record("expected retained input/derivation ceiling rejection")
        } catch let error as SDKError { #expect(error.code == .policyRejected) }
    }
}

/// Public BIP86 test mnemonic and synthetic nonexistent prevout. Never fund these keys.
/// This checks the actual shipped XCFramework, not a mock or a gateway PSBT profile.
@Test func packagedSignerProducesFinalWitnessAndPreservesAuthorizedTransaction() throws {
    let mnemonic = try SecretMnemonic(copyingUTF8: Array(
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about".utf8
    ))
    defer { mnemonic.close() }
    let seed = try deriveSeedFromMnemonic(mnemonic: mnemonic)
    defer { seed.close() }
    let signer = try UniFFILocalSigningEngineFactory().open(network: .mainnet, seed: seed)
    let psbt = "cHNidP8BAIkCAAAAAQcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHAAAAAAD9////AjB1AAAAAAAAIlEgqC8plE1luGrmteXMdeKU6tbFk5Gh7cXgFuNJjGf8e7t8DwEAAAAAACJRIIgtdOXQVy1agWzvAEGpa2wd6DL2+WdtlgXETV6al9PcAAAAAAABASughgEAAAAAACJRIKYIafDbzx3GWcnOy6+AUBNeqejNxIcFPx3GiAlJ3GhMIRbMikvGTYl73cX7wvZw96i6CzhneRBs8SI8b8XXzW/BFRkAc8XaClYAAIAAAACAAAAAgAAAAAAAAAAAARcgzIpLxk2Je93F+8L2cPeougs4Z3kQbPEiPG/F181vwRUAAAEFIDmfGy9Dk/KaGMk3hZxd2KdzUBAxV+uIDwLowIIUJ3zvIQc5nxsvQ5PymhjJN4WcXdinc1AQMVfriA8C6MCCFCd87xkAc8XaClYAAIAAAACAAAAAgAEAAAAAAAAAAA=="
    let request = try SendBtcRequest(
        address: BitcoinAddress("bc1p4qhjn9zdvkux4e44uhx8tc55attvtyu358kutcqkudyccelu0was9fqzwh"),
        amount: Satoshis(30_000), feeRate: FeeRate(milliSatsPerVByte: 100_000),
        idempotencyKey: IdempotencyKey("idem_test_001")
    )
    let prepared = try PreparedTransaction(
        operationID: OperationID("op_test_001"), idempotencyKey: request.idempotencyKey,
        requestHash: RequestHasher.sendBtc(network: .mainnet, request: request),
        network: .mainnet, operation: .sendBtc, psbtBase64: psbt, expiresAt: .init(rawValue: 1_001)
    )
    let signed = try signer.validateAndSign(prepared: prepared, request: request, policy: .default)
    #expect(signed.validation.unsignedTxid.hex == "ec75ccb05c23b9be0b1f487b704071066e62550072ce1b36fee0576177ce336a")
    #expect(signed.validation.fee.value == 500)
    #expect(signed.validation.estimatedVbytes == 154)

    // Reopening with a different policy must validate without creating another
    // signature. A changed intent digest alone is expected and is not a change
    // in the authorized transaction evidence.
    try signer.validateBeforeSubmission(
        prepared: prepared, request: request,
        policy: LocalSigningPolicy(maximumAbsoluteFee: Satoshis(500)),
        retainedValidation: signed.validation
    )
    let rejectingPolicies = try [
        LocalSigningPolicy(maximumAbsoluteFee: Satoshis(499)),
        LocalSigningPolicy(maximumOutputs: 1),
        LocalSigningPolicy(maximumPSBTBytes: 100),
        LocalSigningPolicy(maximumFeeRate: FeeRate(satsPerVByte: 3)),
    ]
    for policy in rejectingPolicies {
        do {
            try signer.validateBeforeSubmission(
                prepared: prepared, request: request, policy: policy,
                retainedValidation: signed.validation
            )
            Issue.record("expected current-policy rejection")
        } catch let error as SDKError { #expect(error.code == .policyRejected) }
    }

    let before = try smokePSBTMaps(psbt)
    let after = try smokePSBTMaps(signed.signedPsbtBase64)
    #expect(before.count == 4 && after.count == 4) // global, one input, two outputs
    #expect(before[0] == after[0])
    #expect(before[2] == after[2] && before[3] == after[3])
    let witness = try #require(after[1][Data([0x08])])
    #expect(witness.count == 66 && witness[0] == 1 && witness[1] == 64)
    #expect(after[1][Data([0x01])] == before[1][Data([0x01])]) // witness UTXO retained
    #expect(!after[1].keys.contains { [UInt8(0x03), 0x13, 0x16, 0x17, 0x18].contains($0.first!) })
}

private func smokePSBTMaps(_ base64: String) throws -> [[Data: Data]] {
    let bytes = Array(try #require(Data(base64Encoded: base64)))
    #expect(Array(bytes.prefix(5)) == [0x70, 0x73, 0x62, 0x74, 0xff])
    var offset = 5
    func take(_ count: Int) throws -> Data {
        guard count >= 0, offset <= bytes.count - count else { throw SDKError.operationJournalUnavailable }
        defer { offset += count }
        return Data(bytes[offset..<(offset + count)])
    }
    func compactSize() throws -> Int {
        let first = try #require(take(1).first)
        if first < 0xfd { return Int(first) }
        guard first == 0xfd else { throw SDKError.operationJournalUnavailable }
        let value = Array(try take(2))
        return Int(value[0]) | Int(value[1]) << 8
    }
    var maps: [[Data: Data]] = []
    while offset < bytes.count {
        var map: [Data: Data] = [:]
        while true {
            let keyLength = try compactSize()
            if keyLength == 0 { break }
            let key = try take(keyLength)
            let value = try take(compactSize())
            guard map.updateValue(value, forKey: key) == nil else { throw SDKError.operationJournalUnavailable }
        }
        maps.append(map)
    }
    return maps
}
