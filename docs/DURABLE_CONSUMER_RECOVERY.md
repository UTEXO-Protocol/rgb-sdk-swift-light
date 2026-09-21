# Durable consumer payment recovery

Fresh BTC submission is still disabled in the ordinary factory. This integration contract describes existing same-request recovery and the app responsibilities required before payments are enabled. It does not enable the provisional PSBT profile or certify backend durability.

The SDK's encrypted journal retains signing/submission evidence. It does not expose PSBTs, enumerate application payment intents, or retain enough public request fields to reconstruct a request automatically. Persist the application's exact payment intent separately, before calling `sendBtc`.

## Application record and ordering

Commit the following in one protected app-database transaction:

| Field | Required representation |
| --- | --- |
| Record schema and application payment ID | Versioned record; stable unique ID chosen once for this user-approved payment |
| Wallet, logical network, service and app-owned account reference | The original wallet/configuration and the application's own account identity; verify bindings on reopen rather than silently selecting a different account |
| Recipient | Exact `request.address.value` |
| Amount | Exact unsigned `request.amount.value` in satoshis |
| Fee rate | Exact unsigned `request.feeRate.milliSatsPerVByte`, without floating-point or display-text conversion |
| Sync behavior | Original `request.skipSync`, including an explicitly stored default |
| Idempotency key | Exact `request.idempotencyKey.value`; generate once when creating a new logical payment |
| Application result | Pending until the returned result is committed; retain the original payment ID/key with successful history |

Use a unique constraint and transactional insert-or-load for the application payment ID. Concurrent UI jobs must load the same original record, not independently generate different keys for the same action. If persistence fails, do not dispatch. After dispatch may have occurred, changing the key, amount, recipient, fee, wallet or network is not a retry.

The ordinary factory does not expose its private gateway user ID. Keep the app's existing account reference in this record; do not add raw gateway requests or depend on infrastructure SPI to discover an internal ID. The SDK separately enforces its authenticated gateway-user binding.

Payment metadata is private. Apply the app's encryption, access control, backup, migration and retention policy. This record must not contain seed/mnemonic/API-key material or raw prepared/signed PSBTs. Losing the record is a recovery problem, not permission to generate a replacement payment.

Restore the exact typed request, supplying every field explicitly:

```swift
let request = try SendBtcRequest(
    address: BitcoinAddress(record.address),
    amount: Satoshis(record.amountSatoshis),
    feeRate: FeeRate(milliSatsPerVByte: record.feeMilliSatsPerVByte),
    skipSync: record.skipSync,
    idempotencyKey: IdempotencyKey(record.idempotencyKey)
)
let txid = try await wallet.sendBtc(request)
// Commit this txid to the SAME application payment record before reporting success.
```

`record` represents the app's committed database row, not an SDK-provided type. Omitting `idempotencyKey` creates a new logical payment; equal recipients and amounts do not make two independently created requests equivalent.

## Reopen and uncertainty

Reopen the same protected wallet storage and service/account, initialize and unlock, then restore the pending app record. A retained SUBMITTING operation uses read-only status recovery. It never prepares, signs or completes again. Pending/unavailable/unbound status remains `operation.ambiguous` with the retained operation ID. Use bounded backoff or display the pending state; do not replace the intent.

Once the SDK has committed a matching terminal receipt, another exact retry returns that result without a second status call or completion. This also handles an app crash between the SDK's result commit and the app's own result commit. Preserve these semantics in the future full SDK. A seed backup alone does not replace the app intent, SDK journal, or server-held RGB state.

## Executable evidence and limits

`Tests/RGBSDKTests/DurableHTTPRecoveryConsumerTests.swift` persists an AES-GCM app record containing exact request fields and explicit wallet/network/service/account/schema bindings. Its negative test rejects ciphertext tampering and validly encrypted records with wrong bindings, and preserves a fractional milli-unit fee and `skipSync=true` exactly without making a request.

The recovery test constructs genuine local native signing evidence from a public synthetic PSBT, stages a SUBMITTING journal checkpoint, and closes all original wallet/backend/journal objects. It reconstructs the app request from disk for two independently reopened wallets. Real URLSession requests first return pending and then a matching completed transaction. The test checks bound ambiguity, preserved signed evidence, status-only recovery, compact terminal replay, and rejection of changed same-key intent. The ordinary fresh-send profile remains disabled throughout recovery.

This is controlled source-level evidence: the journal uses real encrypted files but a file-persisted **test** anchor instead of OS Keychain; the app encryption key and synthetic seed are test fixtures. Checkpoint preparation is infrastructure-only, because the current ordinary factory cannot create a new payment. No funded gateway, actual broadcast, process kill, power loss, production app database, or cross-device restoration is exercised. Separate ordinary-factory consumer tests execute OS Keychain and HTTP lifecycle/read/receive paths on iOS Simulator; they do not exercise payment dispatch. Those distinctions are release gates, not interchangeable test claims.
