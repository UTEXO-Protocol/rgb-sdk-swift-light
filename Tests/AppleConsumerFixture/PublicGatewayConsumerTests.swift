import Foundation
import RGBSDK
import Security
import XCTest

/// Executes ordinary import/create/lifecycle using the distributed SDK product,
/// actual URLSession sockets, and real OS Keychain storage. The loopback peer
/// supplies synthetic read/receive data; no funded gateway or wallet is used.
final class PublicGatewayConsumerTests: XCTestCase {
    func testOrdinaryFactoryHTTPWorkflowRotationAndReopen() async throws {
        let namespace = "org.utexo.public-gateway-consumer.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(namespace, isDirectory: true)
        let walletID = try WalletID("public-consumer-wallet")
        let seedStore = try KeychainSeedStore(service: namespace, walletID: walletID)
        let credentials = try KeychainAPIKeyStore(service: namespace, account: "gateway")
        let seed = try SecretSeed(copying: Array(repeating: UInt8(42), count: 64))
        defer { seed.close() }
        let keys = try deriveKeysFromSeed(network: .regtest, seed: seed)
        defer { keys.close() }
        let server = try LoopbackHTTPServer { request in
            switch request.path {
            case "/v1/me":
                let user = request.headers["authorization"] == "Bearer consumer-foreign-key" ? "foreign-user" : "consumer-user"
                return .json("{\"userId\":\"\(user)\",\"createdAt\":1}")
            case "/v1/wallet/xpubs":
                let fields = try JSONSerialization.jsonObject(with: request.body) as? [String: String]
                guard fields?["vanilla"] == keys.accountXpubVanilla,
                      fields?["colored"] == keys.accountXpubColored,
                      fields?["fingerprint"] == keys.masterFingerprint,
                      fields?.count == 3 else { return .json("{}", status: 400) }
                return .json("{\"fingerprint\":\"\(keys.masterFingerprint)\",\"address\":\"bcrt1pbounded-registration-fixture\"}", status: 201)
            case "/v1/wallet/balances":
                return .json(#"{"btc":{"vanilla":{"settled":42,"future":42,"spendable":42},"colored":{"settled":0,"future":0,"spendable":0}},"assets":[]}"#)
            case "/v1/wallet/sync": return .json(#"{"status":"ok"}"#)
            case "/v1/wallet/receive":
                let expiry = UInt64(Date().timeIntervalSince1970) + 86_400
                let recipient = "bcrt:wvout:A8cJ7Ww3-NIzADo3-Tzp_5aD-7CTBWmA-AAAAAAA-AAAAAAA-ALSQkcw"
                let invoice = "rgb:~/~/~/\(recipient)?expiry=\(expiry)&endpoints=rpc://proxy.example"
                return .json(String(decoding: try JSONSerialization.data(withJSONObject: [
                    "invoice": invoice, "recipientId": recipient, "expirationTimestamp": expiry, "mode": "witness",
                ]), as: UTF8.self), status: 201)
            default: return .json("{}", status: 404)
            }
        }
        defer {
            server.stop()
            // Only this test's UUID-namespaced custody records and directory.
            for service in [namespace, namespace + ".utexo-seed-marker", namespace + ".utexo-api-key", namespace + ".utexo-journal"] {
                SecItemDelete([
                    kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                    kSecAttrSynchronizable: false, kSecUseDataProtectionKeychain: true,
                ] as CFDictionary)
            }
            try? FileManager.default.removeItem(at: directory)
        }
        try await seedStore.storeNew(seed: seed)
        try await storeCredential("consumer-first-key", in: credentials, replacing: false)
        let service = try WalletServiceConfiguration(
            baseURL: await server.start(), apiKeyProvider: credentials,
            allowInsecureLocalDevelopment: true, requestTimeout: 5
        )
        let configuration = try WalletConfiguration(walletID: walletID, network: .regtest)
        let storage = try WalletStorageConfiguration(directory: directory, keychainService: namespace)
        let wallet = try await UTEXOWallet.create(configuration: configuration, service: service, storage: storage)
        do {
            try await wallet.initialize()
            try await wallet.unlock()
            let balance = try await wallet.getBtcBalance()
            XCTAssertEqual(balance.vanilla.settled.value, 42)
            let sync = try await wallet.syncWallet()
            let refresh = try await wallet.refreshWallet()
            XCTAssertNil(sync.tipHeight)
            XCTAssertNil(refresh.tipHeight)
            let received = try await wallet.onchainReceive(OnchainReceiveRequest())
            let beforeDecode = server.snapshot().count
            let decoded = try await wallet.decodeRGBInvoice(received.invoice)
            XCTAssertEqual(decoded.recipientID, received.recipientID)
            XCTAssertEqual(server.snapshot().count, beforeDecode)

            try await storeCredential("consumer-second-key", in: credentials, replacing: true)
            _ = try await wallet.getBtcBalance()
            XCTAssertEqual(server.snapshot().suffix(2).map(\.path), ["/v1/me", "/v1/wallet/balances"])
            try await storeCredential("consumer-foreign-key", in: credentials, replacing: true)
            let beforeForeign = server.snapshot().count
            do { _ = try await wallet.getBtcBalance(); XCTFail("foreign-user rotation must fail") }
            catch let error as SDKError { XCTAssertEqual(error.code, .backendProtocolMismatch) }
            XCTAssertEqual(server.snapshot().count, beforeForeign + 1)
            XCTAssertEqual(server.snapshot().last?.path, "/v1/me")
            try await storeCredential("consumer-second-key", in: credentials, replacing: true)

            // A normal app still cannot opt into the unverified payment profile.
            let beforeSend = server.snapshot().count
            do {
                _ = try await wallet.sendBtc(
                    address: BitcoinAddress("bcrt1pbounded-payment-fixture"), amount: Satoshis(10_000),
                    feeRate: FeeRate(satsPerVByte: 2), idempotencyKey: IdempotencyKey("public-gated-payment")
                )
                XCTFail("ordinary factory must retain the payment gate")
            } catch let error as SDKError { XCTAssertEqual(error.code, .unsupported) }
            XCTAssertEqual(server.snapshot().count, beforeSend)
            try await wallet.destroy()
        } catch {
            try? await wallet.destroy()
            throw error
        }
        let reopened = try await UTEXOWallet.create(configuration: configuration, service: service, storage: storage)
        do {
            try await reopened.initialize()
            try await reopened.unlock()
            let balance = try await reopened.getBtcBalance()
            XCTAssertEqual(balance.vanilla.settled.value, 42)
            try await reopened.destroy()
        } catch {
            try? await reopened.destroy()
            throw error
        }
        let requests = server.snapshot()
        XCTAssertTrue(requests.allSatisfy { $0.headers["cookie"] == nil })
        XCTAssertFalse(requests.contains { $0.path.contains("prepare") || $0.path.contains("complete") })
        let receiveRequest = try XCTUnwrap(requests.first { $0.path == "/v1/wallet/receive" })
        let receiveBody = try XCTUnwrap(JSONSerialization.jsonObject(with: receiveRequest.body) as? [String: Any])
        XCTAssertEqual(receiveBody["durationSeconds"] as? Int, 86_400)
        XCTAssertEqual(receiveBody["minConfirmations"] as? Int, 0)
        XCTAssertEqual(receiveBody["mode"] as? String, "witness")
    }

    private func storeCredential(_ value: String, in store: KeychainAPIKeyStore, replacing: Bool) async throws {
        let credential = try WalletAPIKey(copyingUTF8: Array(value.utf8))
        defer { credential.close() }
        if replacing { try await store.replace(apiKey: credential) }
        else { try await store.storeNew(apiKey: credential) }
    }
}
