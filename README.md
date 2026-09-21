# rgb-sdk-swift-light

Lightweight Swift facade for UTEXO RGB wallets. Its public API is intentionally
high-level and tracks the operation names and defaults in `rgb-sdk-rn`; raw
PSBTs never enter the application-facing wallet API.

This repository is an implementation foundation, not a production release.
It contains an experimental adapter for the minimal gateway in
`rgb-lightning-node` PR #174. That PR is not yet a frozen production contract.
Do not ship money-moving builds until backend compatibility, packaged artifact
tests, the regtest suite, and an independent security review are complete.

## What works now

- BIP39 English mnemonic generation/restoration with NFKD passphrases.
- BIP32 root/account derivation and RN-compatible public identity fields.
- BIP86-style P2TR derivation for vanilla and UTEXO RGB account paths.
- Strict PSBTv0 parsing, local caller-intent validation, BIP341 key-path signing,
  and immediate BIP340 signature verification in the shared Rust core.
- An actor-isolated `UTEXOWallet` lifecycle and backend SPI.
- A fail-closed PR #174 HTTP adapter for watch-only registration, exact BTC/RGB
  balance projections, completed wallet sync/refresh, and the `sendBtc` prepare/complete transport hidden
  behind the wallet facade.
- Crash-safe operation coordination: exact prepared and signed payloads are
  journaled, retries never prepare a different transaction, and definitive
  success/rejection/expiry outcomes replay without another backend mutation.
- Device-bound Apple Keychain seed storage with optional user-presence or
  current-biometry access control.
- Ordinary app construction, encrypted durable operation storage, exclusive
  wallet ownership, and per-request Keychain API-key loading/rotation.
- Local RGB invoice syntax/checksum/schema decoding, plus `onchainReceive`
  transport and independent checks of the returned network, beneficiary mode,
  encoded amount, asset, expiry and public response consistency.

The ordinary wallet factory still gates new gateway money movement. Its legacy
local signer profile supports BTC only. A separate internal, explicitly selected
`utexo.psbt.rgb-lib.v1` profile now validates/signs BTC, exact create-UTXO plans
and fungible RGB **Bitcoin** intent using the real branch-0 builder shape. It
requires an independently trusted maximum block height and is not selected by
an application API or an untrusted PSBT. `inflate` still has no reviewed flow.
Local RGB state validation is not implemented and cannot be inferred from a
Bitcoin PSBT.

The shared coordinator handles BTC/create/RGB preparation, signing, retained
policy revalidation, exact-byte submission, ambiguity and terminal replay. The
gateway create/RGB routes remain gated because their durable results/recovery
and complete adapter contracts are not available. Complete/status create results
must match the exact locally authorized output count, not the requested count.
Expired RGB invoices and disabled new-operation capabilities cannot block an
already-submitting status lookup or replay of an authenticated terminal result.

The new internal profile keeps the requested fee **target** separate from the
app's absolute and rate ceilings. It permits only the native conservative
65-byte Taproot-signature weight budget and integer fee rounding, not an
arbitrary percentage/dust allowance. The legacy profile and journal digest
semantics remain unchanged. Untouched gateway fixtures are exercised locally;
this does not establish completion/broadcast/restart interoperability.

The signer does guarantee that every `sendBtc` input belongs to the locally
re-derived vanilla BIP86 account (external or change), never the colored
account. That account-path guarantee is not proof that an outpoint has no RGB
assignment: proving allocation-free UTXOs would require the RGB state evidence
that this lightweight profile deliberately does not validate locally.

## Package integration

The package targets iOS 15+ and macOS 13+ using Swift 6 strict concurrency.
The committed facade is built and checked with Xcode 27.0 (27A266a), Swift 6.4;
older Swift 6 compilers and minimum-OS runtime execution are not yet qualified.
Add this directory as a Swift Package dependency and link the `RGBSDK` product.
The checked-in `RGBSDK.xcframework` contains the Swift facade, private generated
bindings and shared `utexo-local-signer` core. Only the `RGBSDK` module is exposed;
see [NATIVE_ARTIFACTS.md](NATIVE_ARTIFACTS.md) for build provenance and
checksums. Application code should import only:

```swift
import RGBSDK
```

Key creation returns redacting, closeable secret wrappers:

```swift
let keys = try generateKeys(network: .signet)
defer { keys.close() }

try keys.mnemonic?.consume { mnemonicUTF8 in
    // Persist once using an authenticated, encrypted application flow.
    // The temporary byte array is wiped when this closure returns.
}

let accountKeys = keys.accountXpubs
```

Construct the wallet using ordinary `import RGBSDK`; no backend types, PSBTs,
or journal implementation are needed:

```swift
let walletID = try WalletID("primary-wallet")
let credentials = try KeychainAPIKeyStore(
    service: "com.example.my-wallet", account: walletID.value
)
let service = try WalletServiceConfiguration(
    baseURL: URL(string: "https://your-gateway.example")!,
    apiKeyProvider: credentials
)
let applicationSupport = try FileManager.default.url(
    for: .applicationSupportDirectory, in: .userDomainMask,
    appropriateFor: nil, create: true
)
let storage = try WalletStorageConfiguration(
    directory: applicationSupport.appendingPathComponent("UTEXOWallet", isDirectory: true),
    keychainService: "com.example.my-wallet",
    seedAccessPolicy: .whenUnlocked
)
let wallet = try await UTEXOWallet.create(
    configuration: WalletConfiguration(walletID: walletID, network: .signet),
    service: service, storage: storage
)
try await wallet.initialize()
try await wallet.unlock()
let balance = try await wallet.getBtcBalance()
```

Provision the seed once through `KeychainSeedStore(service:walletID:accessPolicy:)`
using the same service, wallet ID, and policy as `storage`, followed by
`provisionNew(mnemonic:passphraseUTF8:)`. Provision the API credential once using
`WalletAPIKey(copyingUTF8:)` and `credentials.storeNew(apiKey:)`; close the wrapper
after the awaited call. Neither factory nor unlock generates or replaces keys.
An existing app custody implementation may be passed as the optional
`keyProvider` factory argument. A future local SDK must preserve these ordinary
factory signatures, configuration/model names, and the `RGBSDK` module.

Use `credentials.replace(apiKey:)` to rotate an existing credential. Each
request loads a fresh value, and a changed credential must resolve to the same
gateway user before a wallet request is sent. Custom `WalletAPIKeyProvider`
implementations must return a fresh wrapper on each call; the SDK closes it.
`RGBInvoice.value` explicitly exposes an invoice for display/QR sharing while
its description remains redacted. Swift bounded text constructors normalize
surrounding whitespace; applications should supply canonical text when sharing
fixtures with Kotlin, whose stored-string data classes reject that whitespace.

The backend transport and operation journal remain Swift SPI in the development
sources, but are not exported by the facade-only binary distribution. Source
tests and infrastructure development use `Package.source.swift` through the
staging script; ordinary applications use the factory above.
Every `WalletBackend` implementation or decorator must explicitly implement
the required, side-effect-free `preflightOperation` SPI check; there is no
default that can silently bypass a wrapped backend's money-movement policy.
`OperationCheckpointCodec` provides shared Swift/Kotlin `UTXOPCHK` v1 full
checkpoints and v2 compact terminal receipts. The factory encrypts/authenticates
those opaque bytes automatically. V1 decoding remains supported.
`InMemoryOperationJournal` is for tests and prototypes only.

The factory journal uses CryptoKit AES-256-GCM, a device-bound Keychain key,
atomic replacement with file/directory synchronization, and a Keychain commit
anchor that rejects stale ciphertext rollback. It authenticates wallet/network,
service URL, account xpub identity, and gateway user. Missing/corrupt records or
keys fail closed; only an interrupted *empty* journal bootstrap can finish with
its exact existing key/ciphertext. Files are excluded from backup and receive
complete iOS file protection. Keep the directory and Keychain service stable;
normal iOS container UUID changes are handled through container-relative binding.

One wallet instance owns its storage at a time, including across `shutdown()` /
`reinit()`. Call `destroy()`/`dispose()` to release it; dropping the last instance
also releases the lock. The journal is bounded to 64 MiB and 100,000 logical
operations per wallet. Definitive terminal checkpoints are atomically compacted
to small encrypted receipts retaining every idempotency key, request hash,
operation identity, result/error and local validation report. Only their prepared
and signed PSBT payloads are removed. CREATED/PREPARED/SIGNED/SUBMITTING records
retain all recovery evidence, with no age-based eviction. Existing v1 snapshot
histories migrate to v2 through the same crash-safe atomic commit on the next
write; earlier SDK versions cannot open upgraded snapshots, so downgrades are
not supported. A same-key retry still returns the original result, or conflicts
if the caller's intent differs. Receipts are never evicted to free capacity.

The count/byte limits remain finite and fail closed, while updates to existing
operations remain allowed at the count limit. This is not an unlimited-history
promise or a cross-device migration API. High-throughput products must qualify
their lifetime storage budget before release. Do not delete/copy journal files
or Keychain items to reset an ambiguous payment or reclaim capacity.

Before a payment's first call, persist its `SendBtcRequest` fields and explicit
`idempotencyKey` in your app's protected intent storage. Retry the exact request
with the same key after timeout, cancellation, or restart. The convenience
overload's default key creates a **new logical payment on every invocation**;
calling it again without the original key is not a retry. There is currently no
public pending-operation enumeration API. A future full SDK must retain these
idempotency semantics; the durable journal cannot infer that two different keys
represent the same user action.

See [the durable consumer recovery contract](docs/DURABLE_CONSUMER_RECOVERY.md)
for exact persisted fields, ordering, executable evidence, and its limitations.

Current signing policy is enforced again immediately before a first submission,
including a retained SIGNED checkpoint after a restart. Validation re-derives
ownership and checks the exact original preparation without re-signing or
replacing the retained signed bytes. A tightened fee/size/count/derivation limit
can reject that submission and leaves its checkpoint SIGNED. Once SUBMITTING
was committed, only status reconciliation is allowed; tightened policy or a
disabled gateway profile cannot block that read-only recovery or terminal replay.

## Experimental PR #174 gateway adapter

`GatewayWalletBackend` is an SPI implementation of the reviewed gateway routes;
application feature code must continue to call only `UTEXOWallet`. The adapter:

- requires HTTPS by default; exact loopback HTTP for a local container requires
  the explicit `allowInsecureLocalDevelopment: true` configuration flag;
- keeps fresh spending disabled by default. Development against the provisional
  profile requires the explicit `allowUnverifiedPsbtProfile: true` SPI flag;
  reads and watch-only registration remain available without that flag.
  Disabling it later still permits durable terminal replay and status-only
  reconciliation of an already-SUBMITTING operation;
- refuses redirects, bounds request/response bodies, disables URLSession caches,
  cookies, and stored credentials, and never copies raw backend messages into
  log-safe SDK errors;
- sends only the two account xpubs and master fingerprint during registration;
- binds the stable gateway user identity internally but creates a fresh opaque
  local session nonce after every shutdown/reinitialize, so retained contexts
  from an earlier session remain invalid;
- binds the prepare response back to the original BTC recipient, amount, exact
  whole-sat fee rate, operation kind, null RGB/UTXO allowances, UUID, canonical
  Base64 PSBT, and a bounded future expiry before local signing;
- provisionally derives separate `prepare` and `complete` HTTP idempotency keys
  from the one public logical key using a shared Swift/Kotlin SHA-256 domain;
  this adapter-local mapping is not part of the frozen public SDK contract; and
- never retries completion blindly. A malformed/non-JSON 2xx completion or a
  result that cannot be bound to the locally validated transaction is reported
  as `operation.ambiguous`, because broadcast may already have happened.

Preparation expiry can prevent a first submission. After completion dispatch,
the current gateway's error envelope does not prove a durable pre-broadcast
outcome, so even `PSBT_MISMATCH`, unknown/malformed 4xx and `OP_EXPIRED` preserve
the signed checkpoint and trigger read-only reconciliation. They never become
invented terminal rejections. Definitive SPI backend outcomes and bound successful
results are journaled before return. Known idempotency and operation-kind conflicts
from complete also retain bound ambiguity and trigger one read-only status lookup;
they never authorize another completion request. A prepare-phase idempotency
conflict remains a distinct conflict before signing or submission.

PR #174 currently accepts only whole sat/vB fee rates. This SDK's convenience
default is 2 sat/vB (RN requires an explicit rate for `sendBtc`). Explicit
fractional values remain exact in `FeeRate` but fail before HTTP or creation of
a new operation checkpoint; they are never silently rounded.
`sendBtc(skipSync: true)` also fails before HTTP because PR #174 hardcodes
`skipSync` to false and cannot preserve the caller's requested semantics.
The adapter rejects logical `utexo` and `testnet4` networks because the gateway
cannot negotiate or preserve those identities.

The private gateway adapter now maps the existing create-UTXO prepare/complete
and operation-status routes. It sends explicit defaults (`upTo: true`, 5 outputs,
1,000 sats each); the gateway-specific supported count is 1–50 and the local
Taproot output minimum is 330 sats. The public request type retains the broader
native count/size domain for future full-SDK compatibility. `skipSync: true` is
rejected instead of ignored. A bounded native parser projects an **untrusted**
output plan from the PSBT; the local signer independently verifies its keys,
scripts, count, amounts, transaction policy and fees. Only a matching successful
completion or completed-status result can establish the actual created count.
Pending/expired status never authorizes retry or a replacement transaction. This
plumbing does not enable the ordinary factory or resolve backend crash recovery.

Only exact DTO projections are enabled. `getAddress` remains unavailable because
the route omits index data needed for bounded local re-derivation. The fixed
vanilla branch-0 account is known from the RN profile; searching a small window
from zero on every unlock is not a replacement for an index/recovery contract:
remote calls, lost responses, other devices, and restored wallets may advance
the server beyond that window. No address is returned without local ownership
verification. `rotateVanillaAddress` additionally requires persistent native
reuse-mode semantics and is not an alias for another `getAddress` call.
`syncWallet` and `refreshWallet` both use the gateway's combined BTC sync + RGB
refresh operation. The gateway awaits both native operations before returning
`{status:"ok"}`. Their `SyncResult.completedAt` is explicitly the **client-observed
successful completion time** from the local clock, not a server/block timestamp
or independent evidence of freshness; `tipHeight` is `nil` because the gateway
does not provide it. Invalid acknowledgments, unexpected HTTP status, cancellation,
and errors never fabricate success or cause automatic retries. This supersedes
the earlier planning assumption that sync needed a backend timestamp field.
UTXO/transfer/asset-list shapes with missing fields and public gateway RGB
money-movement paths remain fail-closed.

The public create-UTXO count accepts 1...255, matching the native RN `u8`
domain without wrapping; size accepts 1...UInt32.max satoshis. The gateway's
smaller service limits are separate. The native builder may create fewer than
requested when funds are insufficient even with `upTo: false`; authorization
allows 1...requested-count, but the exact prepared plan and returned **actual**
count must agree. No-op preparation with no transaction is not fabricated as
a successful transaction result.
Fee estimation accepts native confirmation targets 1...1008 and rejects a
response for a different target. Internal transaction/transfer txid filters
reuse complete authoritative snapshots and preserve their records and order;
they do not synthesize history from the operation journal. A backend must
provide a genuine unsynchronized transaction-history operation to honor
`skipSync: true`.

`decodeRGBInvoice`/`decodeRgbInvoice` parse locally and make no HTTP request once
the wallet is unlocked. They validate a bounded, canonical supported invoice
profile; they do not verify RGB state, prove an asset exists, authenticate the
invoice, or prove that its beneficiary is controlled by the wallet.
Decoded networks preserve their on-wire identity: a Signet invoice reports
`signet`, including when checked against the logical `utexo` Signet configuration.

`onchainReceive` maps the existing receive route. It explicitly sends the
gateway's 86,400-second default when duration is omitted, preserves the caller's
0-confirmation default, rejects durations outside 60–2,592,000 seconds,
confirmations above 100 and amounts beyond the gateway's exact JSON integer
range before HTTP. It verifies the actual encoded assignment state, not only
the RN-compatible public projection (which can hide an unnamed encoded amount).
The returned expiry must be consistent with the invoice and the request's
duration within the client's start/end time window. Client and server clocks
must agree; the SDK does not invent an undocumented clock-skew allowance.
The invoice must encode that expiry; the gateway's separately nullable envelope
timestamp is preserved as `nil` when null, and must match the invoice when present.
No transport retry is automatic, and no missing batch-transfer index is invented.

The gateway is still trusted for receive allocation/blinded-seal state and
recipient ownership. Internal invoice consistency is not a proof that a
malicious server returned a recipient owned by the local seed. Lower-level
`blindReceive`/`witnessReceive` still need the backend's required batch-transfer
index and remain unavailable. Full RGB transition validation remains a later
phase; it is not implied by local invoice parsing.

The backend update `7f318a80372ae3bdc7e2f54cd6cd4b7b5d734d9d` adds durable
`GET /v1/onchain/operations/:opId` status. Recovery now reads that route for an
already-SUBMITTING BTC operation, including after restart or after the provisional
profile is disabled. Success requires a completed status whose operation ID,
kind, original recipient/amount/fee, preparation expiry, and canonical txid match
the locally authenticated checkpoint and signing report. The retained prepared
PSBT must match the report's SHA-256. No public API or journal-format change is
required. One read-only reconciliation also follows an ambiguous complete
response (including `OP_ALREADY_COMPLETED`, `OP_EXPIRED`, and malformed success).

All pending and expired statuses remain `operation.ambiguous`, even when
`mayHaveBroadcast` is false and `txid` is null: the unqueued GET can race an
in-flight complete or observe a crash before the broadcast txid is persisted.
404, malformed responses, and cancelled reads never erase the signed checkpoint
or trigger a replacement prepare, re-signing, or automatic complete retry.
Cancellation propagates; the next same-key call can repeat the read. The raw
backend SPI without a retained local checkpoint remains unsupported. The route
also omits `utxosCreated` and RGB `batchTransferIdx`. Actual create count can be
derived from locally validated outputs once completion of that exact operation
is authoritative; its missing field alone is not an independent backend blocker.
RGB batch identity cannot be inferred from Bitcoin outputs. These operation paths
remain unqualified and disabled; local counting is not proof of completion.

Distinct stable prepare/complete idempotency keys are now confirmed by the
backend documentation, matching this adapter's phase-separated wire keys and
single public logical key. Atomic prepare persistence and crash-safe broadcast
reconciliation still need backend changes. The PSBT transaction/derivation
profile must also be aligned with `utexo.psbt.bip86.v1` and proven with real
gateway fixtures; money movement remains default-off and local policy is unchanged.

The ordinary factory uses the credential-provider flow above. The legacy SPI
`bearerToken` initializer is retained for compatibility and keeps that token in
memory for the adapter lifetime; new integrations should use the factory.

## Native implementation boundary

The root Swift package exposes only the precompiled `RGBSDK` facade. Its static
framework contains the private bindings and native signer but ships no raw C
headers/module map and no private Swift modules. Library-evolution textual Swift
interfaces contain only the ordinary public facade. No application-level unsafe
compiler flags, import changes, or manually linked native targets are required.

`Scripts/build-facade.sh` builds device arm64, simulator arm64/x86_64 and macOS
arm64/x86_64 from the source tree and records source/native-input and complete
facade-output hashes in `NativeSource/facade-build.json`. Input drift during the
build is rejected; `--check` never rewrites evidence. The separately shipped raw
native archive and source snapshot remain available for auditing, but are not
dependencies in the application's SwiftPM graph.

`Package.source.swift` is a development-only manifest. `Scripts/verify-source.sh`
stages an exact source copy with this manifest and runs the real unit tests;
it does not edit the public manifest or make private implementation modules
accessible to integrators. After any implementation/native change, rebuild the
facade before running the separate external-consumer/API gates. The strict gate
executes public key derivation and proves imports of both private modules fail
for the expected reason. There is no development bypass.

This is API encapsulation, not an isolation boundary against malicious code
already executing inside the same application. Applications must not depend on
private symbol names or manually link the separately published audit artifacts.

## Privacy manifest

The SDK declares its own file-metadata uses and wallet-linked data sent to the
configured gateway. [PRIVACY.md](PRIVACY.md) records the reasons and data-flow
scope. An external iOS archive test verifies that the manifest reaches the
application's framework resource bundle. A signed shipping app still needs its
own accurate disclosures and final Xcode/App Store privacy validation.

## Apple key custody

`KeychainSeedStore` stores one exact 64-byte BIP39 seed as a generic-password
item with:

- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- `kSecAttrSynchronizable = false`
- optional `.userPresence` or `.biometryCurrentSet`
- create-only semantics; an existing wallet is never silently replaced

`accessPolicy` / `seedAccessPolicy` is **creation-only**. Reopening an existing
`.whenUnlocked` item with `.biometryCurrentSet` configuration does not strengthen
its installed access control. Use the original provisioning policy consistently;
this SDK does not provide automatic ACL migration. Never delete a working seed
as an ad-hoc upgrade path. An explicit authenticated custody migration requires
independent recovery and device testing.

Secure Enclave does not expose BIP32/secp256k1 signing. Keychain protection is
applied when the seed is retrieved. The native signer retains signing material
for the unlocked wallet session; each later signature does not prompt again.
Device lock/backgrounding does not automatically revoke that in-memory session.
The app must stop accepting signing actions at its chosen lock/background/idle
boundary and await `shutdown()` (or `destroy()` for permanent disposal), then
explicitly reinitialize/unlock before subsequent use. These operations serialize
with in-flight wallet work; they do not cancel or roll back a submitted payment.
The SDK drops its signer before awaiting backend shutdown, even if that remote
shutdown fails. Zeroization is best effort because Swift/Foundation/FFI runtimes
may copy data. Hardware-backed at-rest protection is not hardware-isolated
secp256k1 execution, per-signature biometric consent, or an immediate device-lock
revocation guarantee. Validate the selected lifecycle on physical devices.

## Cryptography and standards

The XCFramework uses the narrow shared Rust implementation and these pinned
runtime dependencies:

| Dependency | Version | Purpose |
|---|---:|---|
| `bitcoin` (`rust-bitcoin`, bundled `rust-secp256k1`/libsecp256k1) | 0.32.102 | BIP32, transactions, PSBT, Taproot, signatures |
| `bip39` | 2.2.2 | English mnemonic parsing/generation and seed derivation |
| `getrandom` | 0.4.3 | operating-system entropy |
| `sha2` | 0.10.9 | intent/message hashing |
| `base64` | 0.22.1 | canonical PSBT/signature transport encoding |
| `zeroize` | 1.9.0 | best-effort Rust secret cleanup |
| `uniffi` | 0.32.1 | generated Swift/Rust boundary |

The `utexo.bip86.v1` derivation profile supports BIP39, BIP32, BIP43-style
paths, BIP86 single-key P2TR, BIP340 Schnorr, BIP341 key-path spending,
BIP174 PSBTv0, BIP371 Taproot PSBT fields, BIP350 Bech32m, supported BIP173
v0 recipient addresses, and an explicit BIP125 RBF policy.

Vanilla paths are `m/86'/0'/0'` on mainnet and `m/86'/1'/0'` elsewhere.
Colored paths use UTEXO compatibility coin types `827166` (mainnet) and
`827167` (non-mainnet). Those colored coin types are not standard BIP44
assignments, which is why the profile is named for UTEXO rather than simply
“BIP86”. The logical `utexo` network uses Signet Bitcoin parameters.

Not supported: PSBTv2/BIP370, Taproot script paths/BIP342, multisig, annexes,
ANYONECANPAY/SINGLE/NONE, arbitrary scripts, or generic transaction signing.
The compatibility account-message scheme is SHA256(UTF-8) followed by BIP340
at vanilla account child `/0/0`; it is not BIP322 and is not exposed as the
wallet-instance/node-identity `signMessage` API.

## Verification

```sh
bash Scripts/verify-source.sh
bash Scripts/verify-source.sh --configuration release -Xswiftc -warnings-as-errors
bash Scripts/build-facade.sh
node Scripts/facade-provenance.mjs --check
bash Scripts/verify-api-boundary.sh
bash Scripts/verify-public-api.sh
bash Scripts/verify-macos-consumers.sh
bash Scripts/verify-apple-consumer.sh
```

The suite covers cross-platform request-hash and checkpoint-codec goldens, the
RN key compatibility vector, Unicode passphrase normalization, hard policy
ceilings, redaction/use-after-close, Keychain query policy, cancellation, and
PREPARED/SIGNED/SUBMITTING/terminal crash-recovery behavior.
It also tests encrypted-journal tamper/rollback/loss, interrupted commits,
exclusive ownership, credential rotation/user binding, and packaged-native
signing. `API/RGBSDK.macos.json` records the public source API; intentional
updates require `bash Scripts/verify-public-api.sh --update-baseline` and review.
The same checks run on pull requests. An API baseline proves source shape,
not backend behavior or automatic migration of server-held RGB state.

`Tests/AppleConsumerFixture` is an independent iOS application/test host using
only the public package. The archive validates iOS 15 linking and privacy-resource
packaging; both simulator architectures build the native-derivation and real
Keychain round-trip tests. The test bundle uses iOS 17+ because the selected
Xcode's XCTest runtime requires it; that does not raise the SDK's iOS 15 minimum.
Runtime execution needs an available simulator/device and is separate evidence
from `build-for-testing`. Physical biometric/lock/invalidation and oldest-OS
qualification still require that platform matrix.

See [SECURITY.md](SECURITY.md) for guarantees, trust boundaries, and release gates.
