import RGBSDK
import Foundation

let network: Network = .regtest
precondition(network == .regtest)
let integerRate = try FeeRate(satsPerVByte: 3)
let fractionalRate = try FeeRate(satsPerVByte: 1.5)
precondition(integerRate.milliSatsPerVByte == 3_000)
precondition(fractionalRate.milliSatsPerVByte == 1_500)
precondition(FeeRate.default.milliSatsPerVByte == 2_000)
let publicProbeSeed = try SecretSeed(copying: Array(repeating: UInt8(7), count: 64))
let publicProbeKeys = try deriveKeysFromSeed(network: .regtest, seed: publicProbeSeed)
precondition(!publicProbeKeys.accountXpubVanilla.isEmpty)
publicProbeKeys.close()
publicProbeSeed.close()

// Compiled as an independent package with ordinary import RGBSDK. This verifies
// app construction never requires backend/journal/PSBT or generated FFI symbols.
func makeWallet(directory: URL) async throws -> UTEXOWallet {
    let walletID = try WalletID("external-consumer")
    let credentials = try KeychainAPIKeyStore(service: "com.example.wallet", account: "gateway")
    let service = try WalletServiceConfiguration(
        baseURL: URL(string: "https://gateway.example")!, apiKeyProvider: credentials
    )
    let storage = try WalletStorageConfiguration(directory: directory, keychainService: "com.example.wallet")
    let wallet = try await UTEXOWallet.create(
        configuration: WalletConfiguration(walletID: walletID, network: .regtest),
        service: service, storage: storage
    )
    try await wallet.initialize()
    try await wallet.unlock()
    let invoice = try RGBInvoice("rgb:external-consumer")
    precondition(invoice.value == "rgb:external-consumer")
    return wallet
}

// Keep the current lightweight unknown-metadata contract visible through only
// the shipping facade; no generated/private module is imported by consumers.
func readWallet(_ wallet: UTEXOWallet) async throws {
    _ = try await wallet.getAddress()
    _ = try await wallet.rotateVanillaAddress()
    for unspent in try await wallet.listUnspents() {
        let exists: Bool? = unspent.utxo.exists
        _ = exists
    }
    for asset in try await wallet.listAssets().ifa {
        let supplies: [AssetAmount?] = [asset.initialSupply, asset.maximumSupply, asset.knownCirculatingSupply]
        _ = supplies
    }
    for transfer in try await wallet.listTransfers() {
        let batch: UInt64? = transfer.batchTransferIndex
        let transports: [TransferTransportEndpoint]? = transfer.transportEndpoints
        _ = (batch, transports, transfer.assetID)
    }
    _ = try await wallet.estimateFeeRate(blocks: .init(rawValue: 6))
    _ = try await wallet.blindReceive(InvoiceRequest())
    _ = try await wallet.witnessReceive(InvoiceRequest())
}
