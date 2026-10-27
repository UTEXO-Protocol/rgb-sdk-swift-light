# Getting started with the UTEXO Swift SDK

This guide takes an iOS or macOS app from an empty project to its first BTC
payment and its first RGB asset transfer. It covers installing the SDK, setting
up a wallet, and both payment flows end to end, including what the receiving
wallet has to do. The [README](../README.md) is the reference for every limit,
error code and lifecycle method; this guide links to it where you need more
detail.

The [example app](../example-app) exercises every step below on an iOS
Simulator. Its [`ExampleWallet.swift`](../example-app/UTEXOExample/ExampleWallet.swift)
is a compact version of the code in this guide.

## How a payment works

Your app holds the keys. The UTEXO wallet gateway does everything else: it syncs
the chain, tracks RGB state, builds transactions and broadcasts them. Every
spend takes the same path:

1. The gateway prepares an unsigned transaction for your request.
2. The SDK checks it on the device against your request and against a chain
   tip that your app reads from its own trusted source.
3. The SDK signs it locally.
4. The gateway submits it.

The gateway never sees the seed. For BTC, the device checks the recipient,
amount, change and fee before signing, so the gateway can't redirect a payment.
For RGB, the device checks the Bitcoin side of the transaction and the invoice,
but trusts the gateway for RGB state, allocations and consignments.

The cost of that check is the chain tip. Without one, balances and invoices
still work, but every new spend fails.

## What you need from UTEXO

- **An API key.**
- **The wallet gateway URL** for your account. It's an origin only: scheme, host
  and optional port, with no path. A plain RLN, Cloud API or Swap API URL won't
  work in its place.
- **The network** your gateway runs. The SDK accepts `.mainnet`, `.testnet`,
  `.signet` and `.regtest`. UTEXO's signet test environment uses `.signet`.
- **For RGB, an asset contract ID** your gateway supports. The send path handles
  fungible assets (NIA, CFA and IFA). It can't send UDA assets, and it doesn't
  support BFA, which current Mint-issued USDT uses.

Your app needs iOS 15 or macOS 13 and Swift 6 language mode. The package ships
a prebuilt binary, built with Xcode 27.0 (Swift 6.4); older compilers aren't
qualified yet.

## 1. Add the SDK

In Xcode, choose **File → Add Package Dependencies**, enter the repository URL,
select the revision agreed for your integration, and add the **RGBSDK** product
to your app target:

```text
https://github.com/UTEXO-Protocol/rgb-sdk-swift-light
```

In a `Package.swift`, pin the same revision:

```swift
dependencies: [
    .package(url: "https://github.com/UTEXO-Protocol/rgb-sdk-swift-light", revision: "<reviewed commit>"),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [.product(name: "RGBSDK", package: "rgb-sdk-swift-light")]
    ),
]
```

The package links `Artifacts/RGBSDK.xcframework`, which contains the Swift
facade and the native signer. You don't need a Rust toolchain or any generated
bindings.

## 2. Set up the wallet

The snippets `import RGBSDK`. `UTEXOWallet` is an actor and its methods are
`async throws`, so call them from a task.

### Choose a wallet ID

```swift
let walletID = try WalletID("customer-wallet-42")
let network = Network.signet
let keychainService = "com.example.wallet"
```

Create the wallet ID once and persist it, and keep the Keychain service and
storage directory stable too. The SDK keys its Keychain items and operation
journal by these values, so the same ones reopen the same wallet. The journal is
also bound to the gateway URL, to the gateway account the wallet first registers
with, and to the wallet's seed. With another gateway URL, `UTEXOWallet.create`
fails with `storage.operation_journal_unavailable`. With another account's API
key, `initialize()` fails with `wallet.invalid_state`, and with another seed,
`unlock()` fails with the same code. Retrying doesn't clear any of these.

### Store the API key

`apiKeyBytes` is a `[UInt8]` holding the key's UTF-8 bytes, from your app's
provisioning flow:

```swift
let apiKeyStore = try KeychainAPIKeyStore(service: keychainService, account: walletID.value)
let apiKey = try WalletAPIKey(copyingUTF8: apiKeyBytes)
defer { apiKey.close() }
try await apiKeyStore.storeNew(apiKey: apiKey)
```

Store the key once during onboarding. `storeNew` refuses to overwrite a stored
key; to rotate it, call `replace(apiKey:)`. Pass the key itself, without a
`Bearer ` prefix. The SDK reads it for each request, so a rotation takes effect
without reopening the wallet. Never put the key in source code, logs or URLs,
and wipe `apiKeyBytes` once it's stored.

### Create or restore the seed

Do this once, before the wallet is first opened, and use the same
`keychainService` you will pass to `WalletStorageConfiguration`: the wallet
loads its seed from there. For a new wallet, `generateKeys` returns a 12-word
recovery phrase:

```swift
let seedStore = try KeychainSeedStore(service: keychainService, walletID: walletID)

let keys = try generateKeys(network: network)
defer { keys.close() }
guard let mnemonic = keys.mnemonic else {
    throw SDKError(code: .internalInvariantViolation, message: "Missing recovery phrase")
}
let seed = try deriveSeedFromMnemonic(mnemonic: mnemonic)
defer { seed.close() }
try mnemonic.consume { words in
    // `words` is the phrase as UTF-8. Show it to the user and confirm they
    // wrote it down. Don't log, keep or upload it.
}
try await seedStore.storeNew(seed: seed)
```

`consume` exposes the phrase once and wipes its buffer afterwards. To restore an
existing wallet, provision from the user's phrase instead. `phraseBytes` is the
phrase as UTF-8:

```swift
let mnemonic = try SecretMnemonic(copyingUTF8: phraseBytes)
defer { mnemonic.close() }
try await seedStore.provisionNew(mnemonic: mnemonic)
```

Provisioning never replaces a seed. If one is already stored, it throws an
`SDKError` with code `.invalidState` and `details["operation"] == "store seed"`,
and leaves the stored seed alone. Track onboarding in your own app state rather
than provisioning on every launch.

The recovery phrase is the only backup of the keys. The seed store is
device-bound: it doesn't sync through iCloud Keychain or move to a new device. A
restored phrase brings back the keys, not your pending-payment records or the
SDK's operation journal.

The default seed store needs no user authentication. To require Face ID, Touch
ID or the passcode, pass `.userPresence` or `.biometryCurrentSet` as the
`accessPolicy` before provisioning, and the same policy as
`WalletStorageConfiguration`'s `seedAccessPolicy`; see
[Create and securely back up a wallet](../README.md#3-create-and-securely-back-up-a-wallet).

### Supply a trusted chain tip

The SDK asks your app for the current block height before it signs anything.
Read it from a node or indexer you trust, not from the gateway:

```swift
struct EsploraChainTip: WalletChainContextProvider {
    let url: URL

    func loadChainContext(network: Network) async throws -> WalletChainContext {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let (data, response) = try await URLSession.shared.data(for: request)
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let height = UInt32(text) else {
            throw URLError(.badServerResponse)
        }
        let observedAt = UnixSeconds(rawValue: UInt64(Date().timeIntervalSince1970))
        return try WalletChainContext(network: network, tipHeight: height, observedAt: observedAt)
    }
}
```

The tip has to be from the chain your gateway runs on, and no more than 300
seconds old. Stamp it with the time you actually read it.

For UTEXO's signet, use `https://esplora-api.utexo.com/blocks/tip/height`.
UTEXO's signet is its own chain, not Bitcoin's public signet, even though its
invoices carry the `sb` signet tag. A public-signet tip is far behind it, and
the signer rejects every spend with `policy.rejected`.

### Open and unlock the wallet

```swift
let service = try WalletServiceConfiguration(
    baseURL: gatewayURL,
    apiKeyProvider: apiKeyStore,
    chainContextProvider: EsploraChainTip(url: tipURL)
)
let storage = try WalletStorageConfiguration(
    directory: FileManager.default
        .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        .appendingPathComponent("UTEXOWallet", isDirectory: true),
    keychainService: keychainService
)
let wallet = try await UTEXOWallet.create(
    configuration: WalletConfiguration(walletID: walletID, network: network),
    service: service,
    storage: storage
)
try await wallet.initialize() // starts the gateway session; safe to call again
try await wallet.unlock()     // loads the seed and registers watch-only public keys
```

Keep this instance for the user's session and call `destroy()` when the session
ends, or when `initialize()` or `unlock()` throws. Only one instance can own a
wallet's storage at a time, so destroy the old instance before creating another
for the same wallet. To pause on backgrounding or device lock, use `shutdown()`
and later `reinit()` with `unlock()`; see
[Lifecycle and errors](../README.md#lifecycle-and-errors).

The first call for a newly registered wallet can fail with
`backend.unavailable` while the gateway creates the wallet on its side. That
error is retryable, so try the call again. The request timeout defaults to 30
seconds; `requestTimeout` accepts up to 120.

## Send BTC

| Step | Wallet | Calls |
| --- | --- | --- |
| 1. Share an address | Receiver | `getAddress()` |
| 2. Check the balance | Sender | `syncWallet()`, `getBtcBalance()` |
| 3. Choose a fee rate | Sender | `estimateFeeRate(blocks:)` |
| 4. Save the payment, then send | Sender | `sendBtc(_:)` |
| 5. See the payment arrive | Receiver | `syncWallet()`, `getBtcBalance()` |

### 1. The receiver shares an address

```swift
let address = try await wallet.getAddress()
// Show address.value as text or a QR code.
```

Each call allocates a new address, which the SDK re-derives from the local seed
before returning it. Keep the address you showed the user; calling
`getAddress()` again returns a different one.

### 2. The sender checks its balance

```swift
_ = try await wallet.syncWallet()
let btc = try await wallet.getBtcBalance()
let spendableSats = btc.vanilla.spendable.value
```

The balance comes in two parts. `vanilla` is plain BTC, and it's what `sendBtc`
spends. `colored` is BTC on outputs set aside for RGB assets (see
[Send an RGB asset](#send-an-rgb-asset)). Within each part, `settled` counts
confirmed funds, `future` also counts pending ones, and `spendable` is what a
new payment can use now.

### 3. The sender chooses a fee rate

```swift
let feeRate = try await wallet.estimateFeeRate(blocks: BlockCount(rawValue: 6)).feeRate
```

The target is a number of blocks, from 1 to 1,008. If the gateway can't
estimate for that target, the call throws `configuration.unsupported`; fall back
to a fixed rate such as `FeeRate(satsPerVByte: 2)`, which is also the request
default. The gateway accepts whole sat/vB only. By default the device refuses
to sign above 100 sat/vB or above 1,000,000 sats of total fee; you can lower
those limits with `LocalSigningPolicy` in `WalletConfiguration`.

### 4. The sender saves the payment, then sends it

```swift
let request = try SendBtcRequest(
    address: BitcoinAddress(recipientText),
    amount: Satoshis(50_000),
    feeRate: feeRate,
    idempotencyKey: IdempotencyKey.random()
)
// Commit every request field, including the key, to your database first.
try payments.insertPending(request)
let txid = try await wallet.sendBtc(request)
try payments.markSubmitted(request.idempotencyKey, txid: txid.hex)
```

`payments` stands for your app's own database. Saving the request before the
call is what makes a retry safe after a crash or timeout; see
[Retry safely](#retry-safely-after-a-crash-or-timeout).

The amount must be at least 294 sats, and the device may refuse an output below
the dust limit for the recipient's address type. A returned txid means the
gateway accepted the signed transaction. It doesn't mean the transaction is
confirmed.

### 5. The receiver sees the payment

```swift
_ = try await wallet.syncWallet()
let received = try await wallet.getBtcBalance().vanilla
```

The payment shows in `received.future` once the receiver syncs, and in
`received.settled` after it confirms. To look up a transaction on UTEXO's
signet, use `https://esplora-api.utexo.com/tx/<txid>`. Public explorers such as
mempool.space don't index that chain.

## Send an RGB asset

### Colored UTXOs and invoices

RGB assets live on Bitcoin outputs. The wallet's `colored` balance is BTC on
outputs that can hold assets. An RGB send pays everything from colored outputs:
the Bitcoin fee, the change, and any new output it creates for the receiver. It
never touches `vanilla`. So a wallet needs colored UTXOs before it can send,
even if it already holds the asset.

The receiver starts every transfer by creating an invoice. There are two kinds:

| | Witness invoice | Blind invoice |
| --- | --- | --- |
| Created with | `onchainReceive(OnchainReceiveRequest(witness: true))`, the default | `witness: false` |
| Where the asset lands | A new output the sender creates and funds | One of the receiver's existing colored UTXOs |
| Receiver needs colored UTXOs | No | Yes |
| Sender pays extra BTC | Yes, for the new output (`witnessData`) | No |
| Recipient ID contains | `wvout:` | `utxob:` |

Use a witness invoice when the receiver has no colored UTXOs, such as a new
wallet. Use a blind invoice when the receiver already has a free colored UTXO
and you don't want the sender to fund a new output.

Asset amounts are integers in the asset's base units. Apply the asset's
`precision` only for display: `1000000` at precision 6 is 1 token.

### 1. The receiver creates an invoice

```swift
let receive = try await wallet.onchainReceive(OnchainReceiveRequest(
    amount: AssetAmount(1_000_000),
    assetID: AssetID(assetContractID),
    duration: DurationSeconds(3_600)
))
let invoiceText = receive.invoice.value // Send this to the payer as text or a QR code.
```

The gateway can only put an asset in an invoice if the receiving wallet already
knows that asset. For a wallet's first receipt of an asset, leave `assetID` and
`amount` out; the sender then names the asset in its send request.

The SDK decodes the invoice the gateway returns and checks its network, asset,
amount, type and expiry against your request. The gateway sets the expiry from
its own clock, so the device clock must be within 300 seconds of the gateway's.
The duration can be from 60 seconds to 30 days, and defaults to 24 hours.

### 2. The sender creates colored UTXOs

```swift
let created = try await wallet.createUtxos(CreateUtxosRequest(
    num: 5,
    size: Satoshis(1_000),
    feeRate: FeeRate(satsPerVByte: 2),
    idempotencyKey: IdempotencyKey.random()
))
let count = created.createdUtxoCount
```

This spends vanilla BTC to create colored outputs; the defaults are 5 outputs of
1,000 sats each. Use `createdUtxoCount` as the number actually created, not
`num`. Wait for the transaction to confirm before sending RGB from these
outputs. `createUtxos` signs and submits a transaction, so save the request
before calling it, as you would a payment.

A wallet that received an asset on a single 1,000-sat witness output still
needs this step: that output alone can't pay for the send.

### 3. The sender decodes the invoice

```swift
let invoice = try RGBInvoice(invoiceText)
let decoded = try await wallet.decodeRGBInvoice(invoice)
let isWitnessInvoice = decoded.recipientID.contains("wvout:")
```

Show the user what the invoice asks for before they confirm: `decoded.assetID`,
`decoded.assignment.amount`, and `decoded.expirationTimestamp`. Decoding fails
with `validation.wrong_network` for an invoice from another network. It checks
the invoice's syntax and contents, not the asset's RGB history.

### 4. The sender sends

```swift
let request = try OnchainSendRequest(
    invoice: invoice,
    amount: AssetAmount(1_000_000),
    assetID: AssetID(assetContractID),
    witnessData: isWitnessInvoice ? WitnessData(amountSat: Satoshis(1_000)) : nil,
    feeRate: FeeRate(satsPerVByte: 2),
    idempotencyKey: IdempotencyKey.random()
)
// Commit every request field, including the key, to your database first.
let sent = try await wallet.onchainSend(request)
let txid = sent.txid
```

- `amount` is required. If the invoice names an amount, they must match.
- `assetID` is required when the invoice doesn't name an asset. If both name
  one, they must match.
- `witnessData` is required for a witness invoice and must be left out for a
  blind one. Its `amountSat` is the BTC that goes to the receiver's new output,
  at least 294 sats.
- The invoice must carry between one and four transport endpoints, such as
  `rpcs://rgb-proxy.utexo.com/json-rpc` on UTEXO's signet. Invoices without
  endpoints aren't supported.

`sent.batchTransferIndex` may be `nil`; use the txid to find the transfer.

### 5. Both wallets sync until the transfer settles

The txid that `onchainSend` returns is not on chain yet. An RGB transfer needs
both wallets to take part, and the sender broadcasts only after the receiver
acknowledges the transfer:

1. **The receiver syncs.** It fetches the transfer data (the consignment) from
   the RGB proxy, validates it and acknowledges it.
2. **The sender syncs.** It sees the acknowledgement and broadcasts the
   transaction. Only now is the txid on chain.
3. **After the transaction confirms, both sync again.** The receiver's sync
   settles the incoming transfer, and the sender's settles its side.

Each step is a `syncWallet()` call, which syncs Bitcoin and refreshes RGB state
in one gateway request. UTEXO's RGB proxy acknowledges a transfer as soon as the
sender uploads it, so the sender can broadcast on its next sync without waiting
for the receiver. The receiver still has to sync to accept the asset.

In practice, have each app call `syncWallet()` while it has a transfer pending,
for example when the user opens the wallet or the transfers screen.

### 6. Track the transfer

```swift
_ = try await wallet.syncWallet()
let transfers = try await wallet.listTransfersByTxid(sent.txid)
let settled = !transfers.isEmpty && transfers.allSatisfy { $0.status == .settled }
let balance = try await wallet.getAssetBalance(assetID: AssetID(assetContractID))
```

`listTransfers(assetID:)` lists every transfer for an asset, and each transfer's
`kind` says whether it's `.send`, `.receiveWitness` or `.receiveBlind`.
`listTransfersByTxid(_:)` and `listTransfers()` without an asset ID search every
asset, so they make one gateway request per asset. The statuses you'll see
most are:

| Status | Meaning |
| --- | --- |
| `.waitingCounterparty` | The other wallet hasn't taken its step yet. For an incoming transfer, the receiver hasn't accepted a consignment. |
| `.waitingConfirmations` | The transfer is accepted, and its transaction is waiting for confirmations. |
| `.settled` | The transfer is complete. |
| `.failed` | The transfer failed or expired. |

The gateway can return other statuses, including ones added later. Treat any
status you don't recognize as pending, and keep its `rawValue`.

Asset balance fields are optional, and `nil` means unavailable, not zero. While
an incoming transfer waits for confirmations, the amount shows in the
receiver's `future` balance; it moves to `settled` and `spendable` once the
transfer settles.

## Retry safely after a crash or timeout

This applies to `sendBtc`, `createUtxos` and `onchainSend`, the calls that sign
and submit a transaction.

A timeout, app termination or task cancellation can happen after a transaction
was already submitted. Retrying is safe if you retry with the **same request
and idempotency key**. If the operation was already submitted, the SDK checks
its status instead of signing and submitting again. If it already succeeded,
the SDK returns the saved result. A new key means a new payment, even for the
same amount and recipient.

So before each call, commit a record of the request to your database in one
transaction. For `sendBtc`, store:

| Field | Store |
| --- | --- |
| Your payment ID | A unique ID created once for the user's approved payment |
| Wallet | Wallet ID, network, gateway URL and your own account ID |
| Address | `request.address.value` |
| Amount | `request.amount.value`, in sats |
| Fee | `request.feeRate.milliSatsPerVByte`, as an integer |
| `skipSync` | The value you sent, even if it's the default |
| Idempotency key | `request.idempotencyKey.value` |
| Outcome | Pending until you've saved the txid |

For `onchainSend`, also store `invoice.value`, `amount.decimal`,
`assetID?.value`, `witnessData?.amountSat.value`, `donation` and
`minConfirmations.rawValue`. Never store the recovery phrase, seed or API key
in this record. If saving the record fails, don't call the SDK.

To retry, rebuild the request from the record, setting every field explicitly:

```swift
let request = try SendBtcRequest(
    address: BitcoinAddress(record.address),
    amount: Satoshis(record.amountSats),
    feeRate: FeeRate(milliSatsPerVByte: record.feeMilliSatsPerVByte),
    skipSync: record.skipSync,
    idempotencyKey: IdempotencyKey(record.idempotencyKey)
)
let txid = try await wallet.sendBtc(request)
```

Don't rely on initializer defaults here: an omitted `idempotencyKey` generates a
new random key, which starts a new payment. After a restart, reopen and unlock
the same wallet before retrying. Recovering an already submitted operation
doesn't need the chain tip provider or an unexpired invoice.

Catch `SDKError` and handle failures by `code`, never by `message`:

| Code | What to do |
| --- | --- |
| `operation.ambiguous` | The outcome is unknown. Keep the payment pending and retry the same request with backoff. |
| `backend.unavailable` | Retry with backoff. For a payment, retry with the same request and key. |
| `policy.rejected` | The device refused to sign. Check the fee, the invoice and the chain tip. |
| `operation.conflict` | This key was already used for a different request. Load the original record and investigate. |
| `validation.invalid_argument`, `validation.wrong_network`, `configuration.unsupported` | Fix the request or configuration before sending again. |

These are the codes' `rawValue`s; in Swift they're `SDKErrorCode` cases such as
`.operationAmbiguous`. `retryable` on an error means the same request may
succeed later. It is not permission to create a second payment. Let
`CancellationError` propagate; cancelling a task doesn't undo a broadcast. The
README's
[recovery section](../README.md#8-persist-payment-intents-and-recover-safely)
covers the rest.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Every spend fails with `policy.rejected` | The chain tip is from the wrong chain or older than 300 seconds. On UTEXO's signet, read it from `esplora-api.utexo.com`, not a public-signet source. |
| Creating an invoice fails with `backend.protocol_mismatch` about expiry | The device and gateway clocks differ by more than 300 seconds. Fix the device clock. |
| The first call fails with `backend.unavailable` | The gateway is still creating a newly registered wallet. Retry the call. |
| `unlock()` fails with `wallet.key_access_failed` | No seed is stored for this wallet ID under the storage's `keychainService`. Provision it with the same service, or check the user's authentication for a protected seed. |
| An RGB send, or a blind invoice, fails with `backend.rejected` (`INSUFFICIENT_FUNDS`) while the wallet has BTC | Both need colored UTXOs. Call `createUtxos`, wait for a confirmation, and retry. |
| An incoming transfer stays `.waitingCounterparty` | The receiver hasn't accepted a consignment. Sync the receiver, then the sender. |
| `UTEXOWallet.create` fails with `storage.operation_journal_unavailable` | The wallet's storage is bound to another gateway URL. Use the original gateway, or a new wallet ID. |
| `initialize()` or `unlock()` fails with `wallet.invalid_state` for a wallet that worked before | The wallet's storage is bound to another gateway account (`initialize()`) or seed (`unlock()`). Use the original API key and seed, or a new wallet ID. |
