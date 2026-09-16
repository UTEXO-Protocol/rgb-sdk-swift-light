import Foundation
import Security
import Testing
@testable @_spi(Backend) import RGBSDK

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
