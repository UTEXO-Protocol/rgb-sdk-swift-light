import Foundation
import RGBSDK
import XCTest

final class SDKConsumerTests: XCTestCase {
    func testPublicNativeDerivationAndLiteralCompatibility() throws {
        let mnemonic = try SecretMnemonic(copyingUTF8: Array(
            "flight seminar tray bulb level embody switch enhance august deny scene dismiss".utf8
        ))
        defer { mnemonic.close() }
        let keys = try deriveKeysFromMnemonic(network: .testnet, mnemonic: mnemonic)
        defer { keys.close() }
        XCTAssertEqual(keys.xpub, "tpubD6NzVbkrYhZ4WLw9njYmLvMEWp5nqVmjfkgAZfj7uivNXCFS7Ls9DyDZM82P4cDpobCDGAZpNsR9Gs9wuvv5yYCNFsqxcbsDn6VU4nU3ZcW")
        XCTAssertEqual(try FeeRate(satsPerVByte: 3).milliSatsPerVByte, 3_000)
        XCTAssertEqual(try FeeRate(satsPerVByte: 1.5).milliSatsPerVByte, 1_500)
    }

    func testRealKeychainRoundTripDuplicateAndExplicitDeletion() async throws {
        let namespace = "org.utexo.sdk-consumer-test.\(UUID().uuidString)"
        let store = try KeychainSeedStore(service: namespace, walletID: WalletID("test-wallet"))
        let seed = try SecretSeed(copying: Array(repeating: UInt8(42), count: 64))
        defer { seed.close() }
        let expected = try deriveKeysFromSeed(network: .regtest, seed: seed)
        defer { expected.close() }
        do {
            try await store.storeNew(seed: seed)
            do { try await store.storeNew(seed: seed); XCTFail("must not overwrite an existing seed") }
            catch let error as SDKError { XCTAssertEqual(error.code, .invalidState) }
            let parameters = WalletUnlockParameters.none()
            defer { parameters.close() }
            let restored = try await store.loadSeed(parameters: parameters)
            defer { restored.close() }
            let actual = try deriveKeysFromSeed(network: .regtest, seed: restored)
            defer { actual.close() }
            XCTAssertEqual(actual.accountXpubs, expected.accountXpubs)
            try await store.delete()
            do { _ = try await store.loadSeed(parameters: parameters); XCTFail("deleted seed must be absent") }
            catch let error as SDKError { XCTAssertEqual(error.code, .keyAccessFailed) }
        } catch {
            // Deletes only this test's unique Keychain service/account.
            try? await store.delete()
            throw error
        }
    }
}
