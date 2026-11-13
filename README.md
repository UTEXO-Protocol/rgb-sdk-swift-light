# UTEXO Lightweight Swift SDK

Integrate Bitcoin and RGB on-chain wallet workflows into an iOS or macOS app with `import RGBSDK`. `UTEXOWallet` provides an asynchronous, actor-isolated API for wallet setup, balances, receiving, locally signed payments, and transfer history.

**You need a UTEXO API key and an SDK-compatible wallet gateway to use the wallet service. Contact [UTEXO](https://utexo.com/contact-sales) or [sales@utexo.com](mailto:sales@utexo.com) to obtain the API key, gateway URL, and supported network/asset configuration.** The key goes into `WalletServiceConfiguration` through its `apiKeyProvider`; it is separate from your wallet seed and recovery phrase.

## How the lightweight SDK fits together

[UTEXO](https://docs.utexo.com/overview) provides Bitcoin-native payment infrastructure. [RGB](https://docs.utexo.com/getting-started/rgb-concepts) represents asset ownership and transfers using off-chain state anchored to Bitcoin transactions. On the server side, [rgb-node-api](https://github.com/UTEXO-Protocol/rgb-node-api) keeps one watch-only wallet per user behind the wallet gateway.

This package connects your app to the compatible wallet gateway in that stack:

```text
Your iOS/macOS app
  └─ RGBSDK / UTEXOWallet
       ├─ Local: seed storage, key derivation, invoice parsing, Bitcoin checks/signing
       └─ HTTPS + UTEXO API key → compatible wallet gateway → rgb-node-api → Bitcoin indexer, RGB proxy
```

The gateway prepares transactions and manages state, synchronization, and submission. The SDK validates the authorized Bitcoin transaction and signs on the device. Registration sends the two account xpubs and master fingerprint; the seed, mnemonic, and private keys remain local. Xpubs still reveal wallet information and should be treated as private metadata.

**Lightweight means server-assisted RGB state.** The SDK's local invoice checks and Bitcoin signing do not validate a full RGB transition or prove asset allocations. Balances and RGB state are gateway assertions; `localRGBValidation` is `false`.

The gateway handles on-chain Bitcoin and RGB only, so this Swift facade has **no Lightning channel, Lightning invoice, or Lightning payment API**. Its asset listing recognizes NIA, CFA, UDA, IFA, and BFA. [Current Mint-issued USDT](https://docs.utexo.com/getting-started/rgb-concepts) uses BFA. If your gateway's wallet service has BFA enabled, a wallet can request it with or without its asset ID, and `listAssets()` returns it in `bfa`. The local signer recognizes the BFA schema ID that `rgb-lib-bfa` `bfa.5` emits and rejects an invoice naming any other. Sending BFA hasn't been tested. Obtain a compatible asset ID and schema from UTEXO before integrating a particular token.

## 1. Install the package

Requirements:

- iOS 15+ or macOS 13+.
- Swift 6 language mode. The committed binary facade was built with Xcode 27.0 / Swift 6.4; older compilers and runtime behavior on the oldest supported OS versions are not yet qualified.
- Access to this repository and the compatible UTEXO wallet service.

In Xcode, choose **File → Add Package Dependencies**, enter this repository's URL, select the revision agreed for your integration, and add the **RGBSDK** product to your app target:

```text
https://github.com/UTEXO-Protocol/rgb-sdk-swift-light
```

For a checked-out sibling repository, a consumer `Package.swift` can use:

```swift
dependencies: [
    .package(path: "../rgb-sdk-swift-light")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [.product(name: "RGBSDK", package: "rgb-sdk-swift-light")]
    )
]
```

Then import:

```swift
import Foundation
import RGBSDK
```

The package links the bundled `Artifacts/RGBSDK.xcframework`, including the Swift facade and private Rust signer. You do not need Rust, generated bindings, backend SPI imports, or PSBT handling in application code. Pin a reviewed commit for reproducible builds.

## 2. Provision the UTEXO API key

Receive the real API key through your app's trusted provisioning flow. Supply its UTF-8 bytes to `WalletAPIKey`, store it with `KeychainAPIKeyStore`, and pass that store to the service configuration. Supply the **key itself**, without the `Bearer ` prefix; the transport adds the authorization header.

This credential authenticates a wallet gateway user. Cloud management tokens and Swap affiliate keys belong to different APIs and cannot be substituted here; rgb-node-api has no credentials of its own and is never called by the app.

```swift
func provisionAPIKey(
    utexoAPIKeyUTF8: [UInt8], // The API key obtained by contacting UTEXO.
    walletID: WalletID,
    keychainService: String
) async throws {
    let credentials = try KeychainAPIKeyStore(
        service: keychainService,
        account: walletID.value
    )
    let apiKey = try WalletAPIKey(copyingUTF8: utexoAPIKeyUTF8)
    defer { apiKey.close() }
    try await credentials.storeNew(apiKey: apiKey)
}
```

Call this once for a new credential. `storeNew` refuses to overwrite an existing item; use `credentials.replace(apiKey:)` for explicit rotation. Each request loads a fresh key, and a rotated credential must resolve to the same gateway user. A custom `WalletAPIKeyProvider` must return a new wrapper on every call because the SDK closes it after use.

Keep the API key out of source control, app logs, URLs, and analytics. Close the wrapper and wipe the caller-owned byte buffer when it is no longer needed. Keychain storage protects it at rest; an API key distributed to a client app remains accessible to that app's process.

## 3. Create and securely back up a wallet

`generateKeys(network:)` generates a 12-word English BIP39 recovery phrase locally. The wallet factory does not generate or provision a seed. Complete the app's authenticated recovery-phrase backup flow, then store the derived seed before opening the wallet.

```swift
func provisionNewSeed(
    walletID: WalletID,
    network: Network,
    keychainService: String,
    saveRecoveryPhrase: ([UInt8]) throws -> Void
) async throws {
    let keys = try generateKeys(network: network)
    defer { keys.close() }
    guard let mnemonic = keys.mnemonic else {
        throw SDKError(code: .internalInvariantViolation, message: "Missing recovery phrase")
    }
    let seed = try deriveSeedFromMnemonic(mnemonic: mnemonic)
    defer { seed.close() }
    let seedStore = try KeychainSeedStore(
        service: keychainService,
        walletID: walletID,
        accessPolicy: .whenUnlocked
    )
    try mnemonic.consume { bytes in
        try saveRecoveryPhrase(bytes) // Return only after secure backup/confirmation succeeds.
    }
    try await seedStore.storeNew(seed: seed)
}
```

`consume` exposes the phrase once and wipes its temporary buffer when the closure returns. This example confirms the backup before storing the seed. If seed storage then fails, resume with the confirmed recovery phrase; do not silently generate a replacement wallet. These helper functions are app integration examples, not SDK methods. SDK secret cleanup is best effort because Swift/Foundation may make copies.

For an existing recovery phrase, create `SecretMnemonic(copyingUTF8:)` and pass it to `seedStore.provisionNew(mnemonic:passphraseUTF8:)` in an explicit restore flow. Use the original BIP39 passphrase; a different passphrase creates a different wallet. Close the mnemonic afterward. Provisioning refuses existing or invalidated seed records, so do not use it as an automatic fallback when `unlock()` fails.

The built-in seed store is device-bound and does not synchronize to iCloud Keychain. `.userPresence` and `.biometryCurrentSet` are optional provisioning policies; use the same policy in `WalletStorageConfiguration`. These policies protect seed retrieval, not every signature during an unlocked session. The seed is not a Secure Enclave secp256k1 key. A custom custody implementation can supply a `WalletKeyProvider` to `UTEXOWallet.create`.

## 4. Configure, initialize, and unlock

Use a stable wallet ID, Keychain service, and dedicated storage directory. The example uses `.signet`; choose the network UTEXO provisioned for your gateway. Gateway configuration accepts `.mainnet`, `.testnet`, `.signet`, and `.regtest`, subject to the service's deployment. `.testnet4` and logical `.utexo` are rejected by the current gateway adapter even though they exist in the public `Network` enum.

**Fresh spending also requires an app-owned `WalletChainContextProvider`.** Implement `loadChainContext(network:)` using an independently trusted source for that Bitcoin network, returning `WalletChainContext(network:tipHeight:observedAt:)`. Use the time the source observed its tip, not the block timestamp. The SDK requires a height below 500,000,000, an observation at most 300 seconds old, and future clock skew at most 30 seconds. Do not copy the height from the prepared transaction; this gateway has no chain-tip route. The tip must come from the chain your gateway actually runs on. UTEXO's stage gateway runs on Bitcoin's public signet; read its tip from a public-signet indexer such as `https://mempool.space/signet/api/blocks/tip/height`. A tip from another chain is far off the gateway's height, and the signer then rejects every new spend.

```swift
func openWallet(
    gatewayURL: URL, // The SDK-compatible origin supplied by UTEXO.
    chainContextProvider: (any WalletChainContextProvider)?
) async throws -> UTEXOWallet {
    let walletID = try WalletID("primary-wallet")
    let keychainService = "com.example.my-wallet"
    let credentials = try KeychainAPIKeyStore(
        service: keychainService,
        account: walletID.value
    )
    let service = try WalletServiceConfiguration(
        baseURL: gatewayURL,
        apiKeyProvider: credentials, // The stored UTEXO API key enters the SDK here.
        chainContextProvider: chainContextProvider
    )
    let applicationSupport = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    )
    let storage = try WalletStorageConfiguration(
        directory: applicationSupport.appendingPathComponent("UTEXOWallet", isDirectory: true),
        keychainService: keychainService,
        seedAccessPolicy: .whenUnlocked
    )
    let wallet = try await UTEXOWallet.create(
        configuration: WalletConfiguration(walletID: walletID, network: .signet),
        service: service,
        storage: storage
    )
    do {
        try await wallet.initialize()
        try await wallet.unlock()
        return wallet
    } catch {
        try? await wallet.destroy()
        throw error
    }
}
```

Run the provisioning functions once using these same wallet/service values. On later launches, load the existing stores and call `openWallet`; do not provision again. Passing `nil` for the chain provider permits reads, receiving, and submitted-operation recovery, but new local signing is unavailable. Inspect `await wallet.capabilities` after unlocking; `localSigningOperations` identifies locally enabled operations and does not certify backend readiness.

`baseURL` is an HTTPS **origin**, such as the host UTEXO supplies, with no path, query, fragment, or embedded credentials. It must serve this SDK's wallet gateway contract; an rgb-node-api endpoint, Cloud API URL, or Swap API URL is not interchangeable. Local HTTP is allowed only for an exact loopback host with `allowInsecureLocalDevelopment: true`.

## 5. Receive Bitcoin and fund RGB operations

```swift
func fundingAddress(wallet: UTEXOWallet) async throws -> String {
    let address = try await wallet.getAddress()
    return address.value // Display/QR in the app's receive screen.
}

func spendableBitcoin(wallet: UTEXOWallet) async throws -> UInt64 {
    _ = try await wallet.syncWallet()
    let balance = try await wallet.getBtcBalance()
    return balance.vanilla.spendable.value // Satoshis, not BTC.
}
```

Fund the address on the selected Bitcoin network and wait for the necessary confirmations. `getAddress()` and `rotateVanillaAddress()` both allocate a fresh vanilla address and verify its ownership locally; this profile has no address reuse/pinning setting. BTC balances separate `vanilla` and `colored` accounts, each with `settled`, `future`, and `spendable` satoshi amounts. Ordinary BTC sends spend from the vanilla account.

RGB transfers require Bitcoin for fees and appropriate colored UTXOs. Create allocation outputs after funding when needed:

```swift
func createAllocationOutputs(
    wallet: UTEXOWallet,
    persistedRequest: CreateUtxosRequest
) async throws -> CreateUtxosResult {
    return try await wallet.createUtxos(persistedRequest)
}

let allocationRequest = try CreateUtxosRequest(
    upTo: true,
    num: 5,
    size: Satoshis(1_000),
    feeRate: FeeRate(satsPerVByte: 2),
    skipSync: false,
    idempotencyKey: IdempotencyKey.random()
)
// Persist this request and key before calling createAllocationOutputs.
```

Defaults are up to five outputs of 1,000 sats each. The gateway accepts 1–50 outputs, with a minimum size of 330 sats. Use `result.createdUtxoCount` for the accepted count; funding may produce fewer outputs than requested, including when `upTo` is `false`. This creates Bitcoin outputs for RGB use; it does not issue an asset or mint tokens.

## 6. Send Bitcoin

```swift
func sendBitcoin(
    wallet: UTEXOWallet,
    persistedRequest: SendBtcRequest
) async throws -> String {
    let txid = try await wallet.sendBtc(persistedRequest)
    return txid.hex
}

func newBitcoinRequest(recipient: String, paymentKey: IdempotencyKey) throws -> SendBtcRequest {
    try SendBtcRequest(
        address: BitcoinAddress(recipient),
        amount: Satoshis(10_000),
        feeRate: FeeRate(satsPerVByte: 2),
        skipSync: false,
        idempotencyKey: paymentKey
    )
}
```

Create `paymentKey` once for a user-approved payment, persist the exact request, then pass it to `sendBitcoin`. See the recovery rules below before adding retries. `estimateFeeRate(blocks: BlockCount(rawValue: 6))` requests a six-block estimate; confirmation targets must be 1–1008 and unavailable/capped estimates fail explicitly.

The gateway accepts only whole sat/vB fees and `skipSync: false`. Fractional rates remain exact in `FeeRate` but are rejected for these gateway operations. The default target is 2 sat/vB. Configure `LocalSigningPolicy` in `WalletConfiguration` to lower app spending ceilings if needed; default hard ceilings include a 1,000,000-sat absolute fee and 100 sat/vB maximum rate. A fee target is separate from those ceilings.

## 7. Receive and send RGB assets on-chain

Use a network-compatible asset ID from UTEXO or the wallet's asset list. Asset amounts are integer **base units**. For an asset with precision 6, `AssetAmount(1_000_000)` represents one displayed token; never pass a floating-point token balance. Although `AssetAmount` supports an unsigned 64-bit integer, gateway receive/send amounts must not exceed 9,007,199,254,740,991 to preserve exact JSON integers.

For an asset already known to the receiving wallet, create a witness invoice and share its explicit value:

```swift
func receiveAsset(wallet: UTEXOWallet, assetID: AssetID) async throws -> String {
    let response = try await wallet.onchainReceive(OnchainReceiveRequest(
        amount: AssetAmount(1_000_000),
        assetID: assetID,
        minConfirmations: BlockCount(rawValue: 1),
        duration: DurationSeconds(3_600),
        witness: true
    ))
    return response.invoice.value // Display/share privately; descriptions are redacted.
}
```

Use `witness: false` for a blinded recipient backed by an existing suitable allocation UTXO. Receive duration defaults to 86,400 seconds; the gateway accepts 60–2,592,000 seconds and 0–100 minimum confirmations. `onchainReceive` tolerates unavailable batch metadata. The compatibility methods `blindReceive` and `witnessReceive` require a native batch ID and fail if it is missing; do not automatically repeat invoice creation after an uncertain response. The gateway sets the invoice expiry from its own clock, so it must match the requested duration within 300 seconds of device/gateway clock difference; an invoice already expired by the device clock is still rejected.

For a first receipt of an asset not yet known to the wallet, omit both `assetID` and `amount` to create an asset-agnostic invoice. After creating suitable allocation UTXOs, a blinded receive can use:

```swift
func firstAssetInvoice(wallet: UTEXOWallet) async throws -> String {
    let response = try await wallet.onchainReceive(OnchainReceiveRequest(witness: false))
    return response.invoice.value
}
```

The sender supplies the intended contract's `AssetID` and `amount` in `OnchainSendRequest`, without `witnessData` for this blinded invoice. Confirm the contract and amount with the counterparty and use a supported schema; later receipts can use asset-specific invoices.

For a witness invoice, explicitly authorize the Bitcoin amount paid to its recipient:

```swift
func newWitnessAssetRequest(
    wallet: UTEXOWallet,
    invoiceText: String,
    assetID: AssetID,
    paymentKey: IdempotencyKey
) async throws -> OnchainSendRequest {
    let invoice = try RGBInvoice(invoiceText)
    _ = try await wallet.decodeRGBInvoice(invoice) // Local syntax/checksum/schema parsing.
    return try OnchainSendRequest(
        invoice: invoice,
        amount: AssetAmount(1_000_000),
        assetID: assetID,
        witnessData: WitnessData(amountSat: Satoshis(1_000)),
        donation: false,
        feeRate: FeeRate(satsPerVByte: 2),
        minConfirmations: BlockCount(rawValue: 1),
        skipSync: false,
        idempotencyKey: paymentKey
    )
}

func sendAsset(
    wallet: UTEXOWallet,
    persistedRequest: OnchainSendRequest
) async throws -> OnchainSendResponse {
    return try await wallet.onchainSend(persistedRequest)
}
```

For a blinded invoice, omit `witnessData`. For a witness invoice, its satoshi amount is separate from the RGB asset amount; the gateway requires at least 294 sats and does not support explicit blinding. Before first submission the SDK binds the invoice's network, asset, encoded amount, beneficiary type, expiry, and endpoints to the request and Bitcoin transaction. This profile sends fungible owner assignments; UDA/NFT sends are outside its supported send domain. A returned `txid` identifies the accepted Bitcoin transaction; optional `batchTransferIndex` may be `nil`.

Keep invoice transport endpoints intact. The send route requires 1–4 unique endpoints accepted by the gateway; invoices using out-of-band consignment exchange without endpoints are unsupported.

Refresh and inspect the resulting state with `refreshWallet()`, `listAssets()`, `getAssetBalance(assetID:)`, `listUnspents()`, `listTransfers(assetID:)`, `listTransfersByTxid(_:)`, or `listOnchainTransfers(assetID:)`. `listTransfersByTxid(_:)` and `listTransfers()` without an asset ID search every asset, which costs one gateway request per asset. A transaction ID is not a settled RGB transfer; track statuses such as `.waitingCounterparty`, `.waitingConfirmations`, `.settled`, and `.failed`. Optional fields mean unknown, not zero. Both sync and refresh await the gateway's combined Bitcoin sync/RGB refresh; `completedAt` is a client-observed completion time and `tipHeight` is `nil`.

## 8. Persist payment intents and recover safely

The SDK encrypts a durable operation journal automatically. Your app must separately persist the user's exact payment intent **before** the first `sendBtc`, `createUtxos`, or `onchainSend` call. Store the wallet/network/service/account binding, every request field, and its explicit idempotency key in protected app storage. For RGB include the exact invoice and all witness/options fields. Commit a returned result to that same app payment record before presenting success.

- Generate one key per logical payment. Default request keys and convenience overloads generate a new key on each invocation; repeating them is a new payment.
- After timeout, cancellation, or restart, reopen the same wallet/storage/service and retry the exact stored request with the original key. Changed intent with the same key raises `operation.conflict`.
- Submitted operations recover through status reconciliation, preserving the original signed bytes. Definitive terminal results replay from the journal without a second payment.
- `operation.ambiguous` means the outcome is unknown. Keep it pending and use bounded backoff or manual reconciliation; creating a new key or payment can double-pay.

Keep wallet IDs, storage directories, Keychain services, gateway identity, and account identity stable. The journal is bound to them, encrypted with a device-bound key, and protected against tampering and rollback. It retains unresolved evidence and compact terminal receipts, with limits of 64 MiB and 100,000 logical operations per wallet. Do not delete/copy journal files or Keychain items to clear uncertainty or reclaim capacity; downgraded SDK versions cannot read upgraded snapshots.

## Lifecycle and errors

Call `initialize()` before `unlock()`; wallet operations require unlock. Use `shutdown()` for background/idle locking: it drops the local signer and preserves storage for `reinit()` followed by `unlock()`, or `reinitialize(parameters:)`. The app controls this policy; the SDK has no automatic app lifecycle observer. Shutdown waits for in-flight work and cannot cancel or roll back a submitted payment.

Call `destroy()` or its alias `dispose()` when permanently releasing an instance. This closes its resources and storage lock without deleting wallet/backend data. Only one instance may own the same storage; `shutdown()` retains ownership, so destroy the old instance before constructing a replacement.

Catch `SDKError` and branch on `code`, not text. Its `retryable`, `operationID`, and `correlationID` fields support app decisions and support diagnostics. Retryable does not authorize a replacement payment. Treat `wallet.key_access_failed` as a key access/restore issue, `configuration.unsupported` as a capability/configuration issue, and `backend.protocol_mismatch` as an incompatible service response. Never log credentials, recovery material, invoices, or backend bodies.

## Available surface

| Workflow | Current lightweight gateway behavior |
| --- | --- |
| Key generation/restoration | Local BIP39/BIP32 derivation; device Keychain or custom key provider |
| BTC balances, addresses, unspents, fee estimate | Supported after unlock; address ownership checked locally |
| BTC send, create UTXOs, fungible RGB on-chain send | Supported with trusted chain context and durable requests |
| RGB receive/decode, asset balances/listing, transfer history | Supported within the compatible schema/invoice profile |
| Asset issuance (`issueAssetNia` / `issueAssetIfa`), `inflate`, `failTransfers` | Public compatibility methods; unsupported by this gateway |
| `listTransactions` / `listTransactionsByTxid` | Unsupported by this gateway; RGB transfer history is available |
| Lightning, swaps, minting/redemption | No public APIs in this package |

The [Kotlin lightweight SDK](https://github.com/UTEXO-Protocol/rgb-sdk-kotlin-light)
is the companion integration for Android.
