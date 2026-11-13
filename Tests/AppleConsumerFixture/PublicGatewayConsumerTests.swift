import Foundation
import RGBSDK
import Security
import XCTest

// Frozen public BIP39 test-vector preparations; never fund these keys.
private enum PublicSpendingFixtures {
    static let btc =
        "cHNidP8BAIkCAAAAAcMFXrbZjpyhu3DXPxMJoKxc0EjQyGCKiWwyLKCWtwK2AAAAAAD9////AkCcAAAAAAAAIlEgkRunSgqf8plm7Wggw2TjfNFB+fwbPm8rlEsDCd4RonLLpA4AAAAAACJRIKCrRhP30zmYlO/WxZO7/hR08k5v5czT4mOgawdnU6IXaAAAAAABAStAQg8AAAAAACJRIDuCsrKpGFMV2m+A2l8G0EQNil4UV/qTOHwtkZyG7IeGIRZVNVyoPJc/HZfODjhDyF14kFrxa03FMbxIjlchLSMBFhkAc8XaClYAAIABAACAAAAAgAAAAAAAAAAAARcgVTVcqDyXPx2Xzg44Q8hdeJBa8WtNxTG8SI5XIS0jARYAAAEFIJlVJesfKWoH+6aDa4ZRRvstWF79+quWgN9F3OQFgH3yIQeZVSXrHylqB/umg2uGUUb7LVhe/fqrloDfRdzkBYB98hkAc8XaClYAAIABAACAAAAAgAAAAAADAAAAAA=="
    static let create =
        "cHNidP8BAP01AQIAAAABwwVettmOnKG7cNc/EwmgrFzQSNDIYIqJbDIsoJa3ArYAAAAAAP3///8GiBMAAAAAAAAiUSA/igS64ltEtpbXqB6AQ7FkKMoSb6xEciyL/f396kW6rIgTAAAAAAAAIlEgU5yAs09PjE5dCcbQBx4xn/156X9Ru/eZL7wciUjRvleIEwAAAAAAACJRIKSkGbHEFybBpTrY00ry+35zXDfzqPyi6MJ6iAEm/a6YiBMAAAAAAAAiUSBpR7J1dbw33J1gVx5w2hOjYTQ0e3g7ATHWBl7ign8swQveDgAAAAAAIlEg9QsIVm79ixnv8hhCquwNXjFM1TrkZkXkCqe9vRxk7B6IEwAAAAAAACJRIHICjNdhKSOZZA9deuT0zA8H1LEzh8O3OfplZ7AI47gVaAAAAAABAStAQg8AAAAAACJRIDuCsrKpGFMV2m+A2l8G0EQNil4UV/qTOHwtkZyG7IeGIRZVNVyoPJc/HZfODjhDyF14kFrxa03FMbxIjlchLSMBFhkAc8XaClYAAIABAACAAAAAgAAAAAAAAAAAARcgVTVcqDyXPx2Xzg44Q8hdeJBa8WtNxTG8SI5XIS0jARYAAQUg46FpuTh442cMVs/yjPTbwtYpcahIgc0oF4jiNZDHb5whB+Ohabk4eONnDFbP8oz028LWKXGoSIHNKBeI4jWQx2+cGQBzxdoKVgAAgB+fDIAAAACAAAAAAAYAAAAAAQUgCZXb2oj9JV4I/vwvLvRjw54lnniWCj2i0wvX3VZEhJQhBwmV29qI/SVeCP78Ly70Y8OeJZ54lgo9otML191WRISUGQBzxdoKVgAAgB+fDIAAAACAAAAAAAcAAAAAAQUgmg+wcdU7TZ5L/aU9Kp7xLCCsKqDIAP1wGgR1GszjgxQhB5oPsHHVO02eS/2lPSqe8SwgrCqgyAD9cBoEdRrM44MUGQBzxdoKVgAAgB+fDIAAAACAAAAAAAkAAAAAAQUgUblWS0XcV3cPxq5Ie7tWGwFoEY0bpkUoBUTrBY04O9shB1G5VktF3Fd3D8auSHu7VhsBaBGNG6ZFKAVE6wWNODvbGQBzxdoKVgAAgB+fDIAAAACAAAAAAAgAAAAAAQUg06Ogkx7uOjjnj4Jg5uTQah+odrSWqHgvH3TPFeR/OMMhB9OjoJMe7jo454+CYObk0GofqHa0lqh4Lx90zxXkfzjDGQBzxdoKVgAAgAEAAIAAAACAAAAAAAQAAAAAAQUgrf3UFMClmzhQAjFugNyfRbDtG1SCmLf654pe3p45tNkhB6391BTApZs4UAIxboDcn0Ww7RtUgpi3+ueKXt6eObTZGQBzxdoKVgAAgB+fDIAAAACAAAAAAAoAAAAA"
    static let rgb =
        "cHNidP8BAIkCAAAAAR2KIt3irReZSjrsrmaFFuJBMLiStfhMnAaDHJkPAjgKAQAAAAD9////AgAAAAAAAAAAImogWOMP2CVjHELnJNDiGdElV80VbJ60FWNWr44vDmGSPTJTEgAAAAAAACJRIK9e8Lw6jXMCVonmxCxaFAMIWyUXQGUjNavhKSbyO5ijbQAAACb8A1JHQgGjIrEHjg38PIc71XPXy6mj1p2M7HK+TvSSsUt+9Y9yD50AAPad2mVb0nvPOq7NO11g9r6rodBrrUHiuqOMXV9vYGBq//////////8QJwAAAQBURjmHG3H0GMbeHtk+FqFUkCMZxDv0+ur5zmfY7uR50aAPAAABAKAPAQIAAAABAAAAxleWMJ/0BPQIPAAAAAAAAAABrrenuOZqsm2KkQow+ksB+KESeK4vFN79kMAisuQX4q0IKAAAAAAAAAAABvwDUkdCAgEAJvwDUkdCBPad2mVb0nvPOq7NO11g9r6rodBrrUHiuqOMXV9vYGBqRFRGOYcbcfQYxt4e2T4WoVSQIxnEO/T66vnOZ9ju5HnRoA8AAKMisQeODfw8hzvVc9fLqaPWnYzscr5O9JKxS371j3IPAAEBK4gTAAAAAAAAIlEglDQtzOhDbJ7VOzv4Y4k9mxMnbtpTWTc4JflKEIatknohFrKktYEOznb4eBjUiZ0VT+4OTQuXE+WwX2RquXfXp+4jGQBzxdoKVgAAgB+fDIAAAACAAAAAAA4AAAABFyCypLWBDs52+HgY1ImdFU/uDk0LlxPlsF9karl316fuIwAm/ANNUEMA9p3aZVvSe886rs07XWD2vquh0GutQeK6o4xdX29gYGog1ms2Ftr8A/m78jaypYLnSFT/6M22JR8KStpu8sz5wxgG/ANNUEMBCH+0ZmLIWLl1BvwDTVBDECBY4w/YJWMcQuck0OIZ0SVXzRVsnrQVY1avji8OYZI9Mgb8A01QQxH9PwEDAAAIAAAAAAMr9jmqMScSweRgGnsjWoFUYMzsN0L+WL10RERdxSOiRAAD+Mz1T25F1gS5F9fOr7XIOEAOutZS4b6QqLPtEJ4OfbUAA0ozIuAdV13T0fH7Hqme4N8ThhajjeZW/Shzb6Z42U5JAAMjQdRTXA8HvKpgDpI6LyclyvTXWWaN1aj/vqG3KMu1BgADzljv6tTAD5bf4jgNPa5jr2YKmKDP8rQGd+APUUSVcikAA4OSQCPUFV+tC9THiaEi6IJnvCgJawo2neupANs0sXR5Afad2mVb0nvPOq7NO11g9r6rodBrrUHiuqOMXV9vYGBq1ms2Ftr8A/m78jaypYLnSFT/6M22JR8KStpu8sz5wxgAA/X+L1oUktp/Lx/F6/euyFAO4zqlS9J+0KOPliGHqRPdAX+0ZmLIWLl1CPwFT1BSRVQBIFjjD9glYxxC5yTQ4hnRJVfNFWyetBVjVq+OLw5hkj0yAAEFIEL9SeQDwrrpFk1sQ/15mHbwQ8BK0AhQqrT2i9zH5Xr4IQdC/UnkA8K66RZNbEP9eZh28EPAStAIUKq09ovcx+V6+BkAc8XaClYAAIAfnwyAAAAAgAAAAAAPAAAAAA=="
    static let rgbInvoice =
        "rgb:9p3aZVvS-e886rs0-7XWD2vq-uh0GutQ-eK6o4xd-X29gYGo/~/~/bcrt:utxob:rrenuOZq-sm2KkQo-w_ksB_K-ESeK4vF-N79kMAi-suQX4q2-J1tYQ?endpoints=rpc://proxy:3000/json-rpc"

}

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
            case "/v1/wallet/unspents": return .json(#"{"unspents":[]}"#)
            case "/v1/wallet/transfers": return .json(#"{"transfers":[]}"#)
            case "/v1/onchain/fee-estimate?blocks=6":
                return .json(#"{"blocks":6,"sourceBlocks":3,"feeRateSatPerVb":2}"#)
            case "/v1/wallet/sync": return .json(#"{"status":"ok"}"#)
            case "/v1/wallet/receive":
                let expiry = UInt64(Date().timeIntervalSince1970) + 86_400
                let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
                let witness = body?["mode"] as? String == "witness"
                let recipient = witness
                    ? "bcrt:wvout:A8cJ7Ww3-NIzADo3-Tzp_5aD-7CTBWmA-AAAAAAA-AAAAAAA-ALSQkcw"
                    : "bcrt:utxob:rrenuOZq-sm2KkQo-w_ksB_K-ESeK4vF-N79kMAi-suQX4q2-J1tYQ"
                let invoice = "rgb:~/~/~/\(recipient)?expiry=\(expiry)&endpoints=rpc://proxy.example"
                return .json(String(decoding: try JSONSerialization.data(withJSONObject: [
                    "invoice": invoice, "recipientId": recipient, "expirationTimestamp": expiry,
                    "mode": witness ? "witness" : "blind", "batchTransferIdx": 42,
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
            let unspents = try await wallet.listUnspents()
            XCTAssertTrue(unspents.isEmpty)
            let assets = try await wallet.listAssets()
            XCTAssertTrue(assets.nia.isEmpty && assets.cfa.isEmpty && assets.ifa.isEmpty && assets.uda.isEmpty && assets.bfa.isEmpty)
            let transfers = try await wallet.listTransfers()
            let filtered = try await wallet.listTransfersByTxid(TransactionID(String(repeating: "a", count: 64)))
            let onchainTransfers = try await wallet.listOnchainTransfers()
            XCTAssertTrue(transfers.isEmpty && filtered.isEmpty && onchainTransfers.isEmpty)
            let fee = try await wallet.estimateFeeRate(blocks: .init(rawValue: 6))
            XCTAssertEqual(fee.feeRate.milliSatsPerVByte, 2_000)
            let sync = try await wallet.syncWallet()
            let refresh = try await wallet.refreshWallet()
            XCTAssertNil(sync.tipHeight)
            XCTAssertNil(refresh.tipHeight)
            let received = try await wallet.onchainReceive(OnchainReceiveRequest())
            XCTAssertEqual(received.batchTransferIndex, 42)
            let blind = try await wallet.blindReceive(InvoiceRequest())
            let witness = try await wallet.witnessReceive(InvoiceRequest())
            XCTAssertEqual(blind.batchTransferIndex, 42)
            XCTAssertEqual(witness.batchTransferIndex, 42)
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

            // Read-only integration omits independent chain context; signing
            // must fail before any preparation or journal mutation.
            let beforeSend = server.snapshot().count
            do {
                _ = try await wallet.sendBtc(
                    address: BitcoinAddress("bcrt1pbounded-payment-fixture"), amount: Satoshis(10_000),
                    feeRate: FeeRate(satsPerVByte: 2), idempotencyKey: IdempotencyKey("public-gated-payment")
                )
                XCTFail("signing without chain context must fail")
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

    func testOrdinaryFactoryLocallySignsAllThreeSpendingOperations() async throws {
        let namespace = "org.utexo.public-spending.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(namespace, isDirectory: true)
        let walletID = try WalletID("public-spending")
        let seedStore = try KeychainSeedStore(service: namespace, walletID: walletID)
        let credentials = try KeychainAPIKeyStore(service: namespace, account: "gateway")
        let mnemonic = try SecretMnemonic(copyingUTF8: Array(
            "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about".utf8))
        defer { mnemonic.close() }
        let seed = try deriveSeedFromMnemonic(mnemonic: mnemonic)
        defer { seed.close() }
        let keys = try deriveKeysFromSeed(network: .regtest, seed: seed)
        defer { keys.close() }
        let peer = PublicSpendingPeer(fingerprint: keys.masterFingerprint)
        let server = try LoopbackHTTPServer { try await peer.reply($0) }
        defer {
            server.stop()
            for service in [namespace, namespace + ".utexo-seed-marker", namespace + ".utexo-api-key", namespace + ".utexo-journal"] {
                SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                    kSecAttrSynchronizable: false, kSecUseDataProtectionKeychain: true] as CFDictionary)
            }
            try? FileManager.default.removeItem(at: directory)
        }
        try await seedStore.storeNew(seed: seed)
        try await storeCredential("public-spending-key", in: credentials, replacing: false)
        let url = try await server.start()
        let service = try WalletServiceConfiguration(baseURL: url, apiKeyProvider: credentials,
            allowInsecureLocalDevelopment: true, chainContextProvider: PublicSpendingChainContext())
        let configuration = try WalletConfiguration(walletID: walletID, network: .regtest)
        let storage = try WalletStorageConfiguration(directory: directory, keychainService: namespace)
        let wallet = try await UTEXOWallet.create(configuration: configuration, service: service, storage: storage)
        let btc = try SendBtcRequest(address: BitcoinAddress("bcrt1pjyd6wjs2nlefjehddqsvxe8r0ng5r70urvlx72u5fvpsnhs35feqsu7305"),
            amount: Satoshis(40_000), idempotencyKey: IdempotencyKey("public-btc"))
        let create = try CreateUtxosRequest(size: Satoshis(5_000), idempotencyKey: IdempotencyKey("public-create"))
        let rgb = try OnchainSendRequest(invoice: RGBInvoice(PublicSpendingFixtures.rgbInvoice),
            amount: AssetAmount(40), idempotencyKey: IdempotencyKey("public-rgb"))
        do {
            try await wallet.initialize(); try await wallet.unlock()
            let capabilities = await wallet.capabilities
            XCTAssertEqual(capabilities.localSigningOperations, [.sendBtc, .createUtxos, .onchainSend])
            XCTAssertFalse(capabilities.localRGBValidation)
            let btcResult = try await wallet.sendBtc(btc)
            XCTAssertEqual(btcResult.hex, PublicSpendingPeer.btcTxid)
            let created = try await wallet.createUtxos(create)
            XCTAssertEqual(created.createdUtxoCount, 5)
            XCTAssertEqual(created.txid.hex, PublicSpendingPeer.createTxid)
            let sent = try await wallet.onchainSend(rgb)
            XCTAssertEqual(sent.txid.hex, PublicSpendingPeer.rgbTxid)
            XCTAssertNil(sent.batchTransferIndex)
            try await wallet.destroy()
        } catch { try? await wallet.destroy(); throw error }
        // Terminal replay on an ordinary-factory reopen needs neither provider
        // nor HTTP status and never creates replacement transactions.
        let recoveryService = try WalletServiceConfiguration(baseURL: url, apiKeyProvider: credentials,
            allowInsecureLocalDevelopment: true)
        let reopened = try await UTEXOWallet.create(configuration: configuration, service: recoveryService, storage: storage)
        do {
            try await reopened.initialize(); try await reopened.unlock()
            let capabilities = await reopened.capabilities
            XCTAssertFalse(capabilities.localTransactionSigning)
            XCTAssertTrue(capabilities.localSigningOperations.isEmpty)
            let before = server.snapshot().count
            let restoredBtc = try await reopened.sendBtc(btc)
            let restoredCreate = try await reopened.createUtxos(create)
            let restoredRgb = try await reopened.onchainSend(rgb)
            XCTAssertEqual(restoredBtc.hex, PublicSpendingPeer.btcTxid)
            XCTAssertEqual(restoredCreate.createdUtxoCount, 5)
            XCTAssertNil(restoredRgb.batchTransferIndex)
            XCTAssertEqual(server.snapshot().count, before)
            try await reopened.destroy()
        } catch { try? await reopened.destroy(); throw error }
        XCTAssertEqual(server.snapshot().filter { $0.path.hasSuffix("/complete") }.count, 3)
        XCTAssertEqual(server.snapshot().filter { $0.path.hasSuffix("/prepare") }.count, 3)
        let signedBodies = await peer.validatedSignedBodies
        XCTAssertEqual(signedBodies, 3)
    }
}

private struct PublicSpendingChainContext: WalletChainContextProvider {
    func loadChainContext(network: Network) async throws -> WalletChainContext {
        try .init(network: network, tipHeight: 110, observedAt: .init(rawValue: UInt64(Date().timeIntervalSince1970)))
    }
}

private actor PublicSpendingPeer {
    static let btcTxid = "c85326c4ef41a07740b0024b9ffd405ec0b114684b63833dd01653ad4df579fb"
    static let createTxid = "9f4b8d594d577e5b73cd941db229870965f099bf0092df8cf9444cc309986967"
    static let rgbTxid = "e41e4ebdc769b0575126a5d728394d4c01206110e7eaebf6446029d5acd0d814"
    let fingerprint: String
    private(set) var validatedSignedBodies = 0
    init(fingerprint: String) { self.fingerprint = fingerprint }
    func reply(_ request: LoopbackHTTPServer.Request) throws -> LoopbackHTTPServer.Response {
        func json(_ value: [String: Any], status: Int = 200) throws -> LoopbackHTTPServer.Response {
            .json(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self), status: status)
        }
        if request.path == "/v1/me" { return try json(["userId": "spending-user", "createdAt": 1]) }
        if request.path == "/v1/wallet/xpubs" {
            return try json(["fingerprint": fingerprint, "address": "bcrt1ppublic-fixture"], status: 201)
        }
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let create = request.path.contains("create-utxos")
        let rgb = request.path.contains("send-asset")
        let unsigned = create ? PublicSpendingFixtures.create : rgb ? PublicSpendingFixtures.rgb : PublicSpendingFixtures.btc
        let txid = create ? Self.createTxid : rgb ? Self.rgbTxid : Self.btcTxid
        let opId = create ? "b1111111-1111-4111-8111-111111111111"
            : rgb ? "c1111111-1111-4111-8111-111111111111" : "a1111111-1111-4111-8111-111111111111"
        if request.path.hasSuffix("/complete") {
            let signed = try XCTUnwrap(body["signedPsbt"] as? String)
            guard signed != unsigned, Data(base64Encoded: signed)?.prefix(5) == Data([0x70, 0x73, 0x62, 0x74, 0xff]),
                  body["opId"] as? String == opId else {
                return try json([:], status: 400)
            }
            validatedSignedBodies += 1
            return try json(create ? ["txid": txid, "utxosCreated": 5] : ["txid": txid])
        }
        guard request.path.hasSuffix("/prepare") else { return try json([:], status: 404) }
        var intent: [String: Any] = ["kind": create ? "create_utxos" : rgb ? "send_asset" : "send_btc",
            "feeRateSatPerVb": body["feeRateSatPerVb"]!, "recipients": [], "asset": NSNull(), "utxos": NSNull()]
        if create { intent["utxos"] = ["num": body["num"]!, "size": body["size"]!, "upTo": body["upTo"]!] }
        else if rgb { intent["asset"] = ["assetId": body["assetId"]!, "amount": body["amount"]!,
            "recipientId": body["recipientId"]!, "witnessAmountSat": body["witnessAmountSat"] ?? NSNull(),
            "transportEndpoints": body["transportEndpoints"]!] }
        else { intent["recipients"] = [["address": body["address"]!, "amountSat": body["amountSat"]!,
            "scriptHex": "5120911ba74a0a9ff29966ed6820c364e37cd141f9fc1b3e6f2b944b0309de11a272"]] }
        return try json(["opId": opId, "psbt": unsigned,
            "intent": intent, "expiresAt": UInt64(Date().timeIntervalSince1970 * 1_000) + 600_000], status: 201)
    }
}
