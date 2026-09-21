import Foundation
import Security
import Testing
@testable @_spi(Backend) import RGBSDK

@Test func createUtxoCountMatchesNativeU8DomainWithoutWrapping() throws {
    #expect(try CreateUtxosRequest().num == nil)
    #expect(try CreateUtxosRequest(num: 1).num == 1)
    #expect(try CreateUtxosRequest(num: 255).num == 255)
    for count: UInt16 in [0, 256, .max] {
        #expect(throws: SDKError.self) { try CreateUtxosRequest(num: count) }
    }
    #expect(try CreateUtxosRequest(size: Satoshis(UInt64(UInt32.max))).size?.value == UInt64(UInt32.max))
    #expect(throws: SDKError.self) { try CreateUtxosRequest(size: Satoshis(UInt64(UInt32.max) + 1)) }
    #expect(throws: SDKError.self) { try CreateUtxosRequest(size: .zero) }
}

@Test func feeRateLiteralsAndTypedOverloadsAreUnambiguousAndChecked() throws {
    #expect(FeeRate.default.milliSatsPerVByte == 2_000)
    #expect(try CreateUtxosRequest().feeRate == FeeRate.default)
    #expect(try SendBtcRequest(address: BitcoinAddress("bcrt1ptestaddress"), amount: Satoshis(1)).feeRate == FeeRate.default)
    #expect(try FeeRate(satsPerVByte: 3).milliSatsPerVByte == 3_000)
    #expect(try FeeRate(satsPerVByte: 1.5).milliSatsPerVByte == 1_500)
    #expect(try FeeRate(satsPerVByte: Decimal(string: "1.001")!).milliSatsPerVByte == 1_001)
    #expect(try FeeRate(satsPerVByte: Double(3)).milliSatsPerVByte == 3_000)
    #expect(try FeeRate(satsPerVByte: 10_000) == FeeRate.maximumSupported)
    for value in [Int.min, -1, 0, 10_001, Int.max] {
        #expect(throws: SDKError.self) { try FeeRate(satsPerVByte: value) }
    }
}

@Test func assetIFASuppliesCannotExceedDeclaredMaximum() throws {
    #expect(throws: SDKError.self) {
        try AssetIFA(
            assetID: AssetID("rgb:asset"), ticker: "TEST", name: "Test", precision: 0,
            initialSupply: AssetAmount(101), maximumSupply: AssetAmount(100),
            knownCirculatingSupply: AssetAmount(100), timestamp: .init(rawValue: 1),
            addedAt: .init(rawValue: 1), balance: AssetBalance()
        )
    }
    #expect(throws: SDKError.self) {
        try AssetIFA(
            assetID: AssetID("rgb:asset"), ticker: "TEST", name: "Test", precision: 0,
            initialSupply: AssetAmount(100), maximumSupply: AssetAmount(100),
            knownCirculatingSupply: AssetAmount(101), timestamp: .init(rawValue: 1),
            addedAt: .init(rawValue: 1), balance: AssetBalance()
        )
    }
}

@Test func invoiceExplicitValueIsAvailableWhileDescriptionRemainsRedacted() throws {
    let invoice = try RGBInvoice("rgb:private-recipient")
    #expect(invoice.value == "rgb:private-recipient")
    #expect(!invoice.description.contains("private-recipient"))
    let received = try OnchainReceiveResponse(invoice: invoice, recipientID: "  recipient  ")
    #expect(received.recipientID == "recipient")
}

@Test func apiKeyIsBoundedRedactedAndCannotBeUsedAfterClose() throws {
    for bytes in [[], [UInt8(10)], Array("injected\r\nheader".utf8), Array(repeating: UInt8(65), count: 513)] {
        #expect(throws: SDKError.self) { try WalletAPIKey(copyingUTF8: bytes) }
    }
    let key = try WalletAPIKey(copyingUTF8: Array("private-credential".utf8))
    #expect(!String(describing: key).contains("private-credential"))
    #expect(!String(reflecting: key).contains("private-credential"))
    #expect(!key.customMirror.children.contains { String(describing: $0.value).contains("private-credential") })
    key.close()
    key.close()
    #expect(throws: SDKError.self) { try key.withBytes { $0.count } }
}

@Test func sendBtcRequestHashMatchesCrossPlatformGolden() throws {
    let request = try SendBtcRequest(
        address: BitcoinAddress(
            "tb1ptestaddress000000000000000000000000000000000000000000000000000"
        ),
        amount: Satoshis(10_000),
        feeRate: FeeRate(milliSatsPerVByte: 1_500),
        skipSync: false,
        idempotencyKey: IdempotencyKey("request-hash-golden")
    )

    #expect(
        try RequestHasher.sendBtc(network: .signet, request: request).hex
            == "67ed2e4db80d3acd337d567eaf6bdacbcce196d9c9fe280816210751be3c6ba7"
    )
}

@Test func createAndRgbRequestHashesBindEveryOptionAcrossPlatforms() throws {
    let create = try CreateUtxosRequest(upTo: false, num: 5, size: Satoshis(5_000), feeRate: FeeRate(satsPerVByte: 2))
    #expect(try RequestHasher.createUtxos(network: .regtest, request: create).hex
        == "86f5dafa3faaacf0e084c64afde25b1fc907cd8933f96e1e9adcb28706424379")
    let rgb = try OnchainSendRequest(
        invoice: RGBInvoice("rgb:hash-fixture"), amount: AssetAmount(40), assetID: AssetID("rgb:asset"),
        witnessData: WitnessData(amountSat: Satoshis(1_000), blinding: 17), donation: true,
        feeRate: FeeRate(satsPerVByte: 2), minConfirmations: .init(rawValue: 2), skipSync: true
    )
    #expect(try RequestHasher.onchainSend(network: .regtest, request: rgb).hex
        == "d5ddecdf034f493b7e8d95b0167cd3ea34654c73bb298f36787e4d56bc9fabcc")
    let noBlinding = try OnchainSendRequest(
        invoice: rgb.invoice, amount: rgb.amount, assetID: rgb.assetID,
        witnessData: WitnessData(amountSat: Satoshis(1_000)), donation: true,
        feeRate: rgb.feeRate, minConfirmations: rgb.minConfirmations, skipSync: true
    )
    #expect(try RequestHasher.onchainSend(network: .regtest, request: noBlinding)
        != RequestHasher.onchainSend(network: .regtest, request: rgb))
}

@Test func identifiersRejectUnicodeAndWhitespace() throws {
    #expect(throws: SDKError.self) { try WalletID("wallet-é") }
    #expect(throws: SDKError.self) { try IdempotencyKey("has a space") }
    #expect(throws: SDKError.self) {
        try TransactionID(String(repeating: "ａ", count: 64))
    }
    #expect(throws: SDKError.self) {
        try RequestHash(validating: String(repeating: "Ａ", count: 64))
    }
    #expect(!isASCIIHex("deadbeeƒ", exactByteCount: 8))
    #expect(try WalletID("wallet_01").value == "wallet_01")
}

@Test func signingLimitsCannotExceedHardCeilings() throws {
    #expect(throws: SDKError.self) {
        try LocalSigningPolicy(maximumInputs: LocalSigningPolicy.hardMaximumInputs + 1)
    }
    #expect(throws: SDKError.self) {
        try LocalSigningPolicy(maximumFeeRate: FeeRate(satsPerVByte: 100.001))
    }
}

@Test func redactingSecretsDoNotPrintMaterial() throws {
    let phraseBytes = Array(
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about".utf8
    )
    let phrase = try SecretMnemonic(copyingUTF8: phraseBytes)
    #expect(String(describing: phrase) == "RecoveryPhrase([REDACTED])")

    let xpriv = try SecretExtendedPrivateKey(copyingUTF8: Array("tprv-secret".utf8))
    #expect(String(describing: xpriv) == "ExtendedPrivateKey([REDACTED])")
    #expect(phrase.customMirror.children.allSatisfy { String(describing: $0.value) == "[REDACTED]" })
    #expect(xpriv.customMirror.children.allSatisfy { String(describing: $0.value) == "[REDACTED]" })

    phrase.close()
    phrase.close()
    #expect(throws: SDKError.self) { try phrase.consume { $0.count } }
    xpriv.close()
    xpriv.close()
    #expect(throws: SDKError.self) { try xpriv.consume { $0.count } }
}

@Test func nativeKeyDerivationMatchesFrozenRNCompatibilityVector() throws {
    let phrase = try SecretMnemonic(copyingUTF8: Array(
        "flight seminar tray bulb level embody switch enhance august deny scene dismiss".utf8
    ))
    defer { phrase.close() }
    let keys = try deriveKeysFromMnemonic(network: .testnet, mnemonic: phrase)
    defer { keys.close() }

    #expect(
        keys.xpub
            == "tpubD6NzVbkrYhZ4WLw9njYmLvMEWp5nqVmjfkgAZfj7uivNXCFS7Ls9DyDZM82P4cDpobCDGAZpNsR9Gs9wuvv5yYCNFsqxcbsDn6VU4nU3ZcW"
    )
    #expect(
        keys.accountXpubVanilla
            == "tpubDDTg3fRGqAvEvshRUUwuS8brXkewNsE6y6Jbb9xZcuzBbmxAWa3UCmwyQG4peM9RwjgY8BDwuRVRU5KGtvRby5kiv1dk13YHU8z39o18QJK"
    )
    #expect(
        keys.accountXpubColored
            == "tpubDDqoEexZxewBLjXmZ7kxSHgZgmdAtej6DrXLBMiSSuPCdGQqjkTvyETLLVY7qNpxNRGUivvxDj8sswHHihT5effNNDmsbMUX2Lrpy4zjRcS"
    )
}

@Test func bip39PassphraseUsesNFKDNormalization() throws {
    let phrase = try SecretMnemonic(copyingUTF8: Array(
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about".utf8
    ))
    defer { phrase.close() }
    let composed = try deriveKeysFromMnemonic(
        network: .signet,
        mnemonic: phrase,
        passphraseUTF8: Array("é".utf8)
    )
    let decomposed = try deriveKeysFromMnemonic(
        network: .signet,
        mnemonic: phrase,
        passphraseUTF8: Array("e\u{301}".utf8)
    )
    defer {
        composed.close()
        decomposed.close()
    }
    #expect(composed.accountXpubs == decomposed.accountXpubs)
}

@Test func derivesOfficialBip39SeedForKeychainProvisioning() throws {
    let phrase = try SecretMnemonic(copyingUTF8: Array(
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about".utf8
    ))
    defer { phrase.close() }
    let seed = try deriveSeedFromMnemonic(
        mnemonic: phrase,
        passphraseUTF8: Array("TREZOR".utf8)
    )
    defer { seed.close() }
    let hex = try seed.withCopy { bytes in
        bytes.map { String(format: "%02x", $0) }.joined()
    }
    #expect(
        hex
            == "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04"
    )
}

@Test func keychainQueriesAreDeviceBoundAndNeverSynchronize() throws {
    let query = try KeychainQueryBuilder.seedWrite(
        service: "com.utexo.tests",
        account: "wallet",
        data: Data(repeating: 7, count: 64),
        policy: .whenUnlocked
    )
    #expect((query[kSecClass] as? String) == (kSecClassGenericPassword as String))
    #expect(
        (query[kSecAttrAccessible] as? String)
            == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    )
    #expect(query[kSecAttrSynchronizable] as? Bool == false)
    #expect(query[kSecUseDataProtectionKeychain] as? Bool == true)
}

@Test func seedReadUsesInstalledACLAndDoesNotPretendToChangeProvisioningPolicy() {
    let query = KeychainQueryBuilder.seedRead(service: "com.utexo.tests", account: "wallet")
    #expect(query[kSecAttrAccessControl] == nil)
    #expect(query[kSecAttrAccessible] == nil)
    #expect(query[kSecReturnData] as? Bool == true)
    #expect(query[kSecAttrSynchronizable] as? Bool == false)
}

@Test func localClockConversionRejectsInvalidFloatingPointValuesWithoutTrapping() throws {
    #expect(try checkedUnixMilliseconds(1_234.567) == 1_234_567)
    #expect(try checkedUnixMilliseconds(0) == 0)
    for value in [-1.0, .nan, .infinity, -.infinity, Double.greatestFiniteMagnitude] {
        #expect(throws: SDKError.self) { try checkedUnixMilliseconds(value) }
    }
}
