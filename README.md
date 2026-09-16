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
  balance projections, and the `sendBtc` prepare/complete transport hidden
  behind the wallet facade.
- Crash-safe operation coordination: exact prepared and signed payloads are
  journaled, retries never prepare a different transaction, and definitive
  success/rejection/expiry outcomes replay without another backend mutation.
- Device-bound Apple Keychain seed storage with optional user-presence or
  current-biometry access control.

`sendBtc` is the only operation whose current local signer profile is enabled.
`createUtxos`, `onchainSend`, and `inflate` are present to freeze the public
surface but reject before contacting the backend. They require exact
operation-specific owned-output/RGB contracts. Local RGB state validation is
not implemented and cannot be inferred from a Bitcoin PSBT.

The signer does guarantee that every `sendBtc` input belongs to the locally
re-derived vanilla BIP86 account (external or change), never the colored
account. That account-path guarantee is not proof that an outpoint has no RGB
assignment: proving allocation-free UTXOs would require the RGB state evidence
that this lightweight profile deliberately does not validate locally.

## Package integration

The package supports iOS 15+ and macOS 13+ using Swift 6 strict concurrency.
Add this directory as a Swift Package dependency and link the `RGBSDK` product.
The checked-in XCFramework is built from the shared `utexo-local-signer` core;
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

The backend transport and operation journal use Swift SPI so infrastructure
composition does not make prepared/signed PSBTs a normal app API.
Every `WalletBackend` implementation or decorator must explicitly implement
the required, side-effect-free `preflightOperation` SPI check; there is no
default that can silently bypass a wrapped backend's money-movement policy.
`OperationCheckpointCodec` provides the shared Swift/Kotlin `UTXOPCHK` v1
encoding. A production journal must atomically encrypt and authenticate those
opaque bytes. `InMemoryOperationJournal` is for tests and prototypes only.

## Experimental PR #174 gateway adapter

`GatewayWalletBackend` is an SPI implementation of the reviewed gateway routes;
application feature code must continue to call only `UTEXOWallet`. The adapter:

- requires HTTPS by default; exact loopback HTTP for a local container requires
  the explicit `allowInsecureLocalDevelopment: true` configuration flag;
- keeps `sendBtc` disabled by default. Development against the provisional
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

Direct non-retryable gateway rejections and expiry responses are durably saved
as terminal outcomes before they are returned, so a restart replays the same
definitive result without resubmission. Completion idempotency conflicts and
operation-kind mismatches remain explicit contract blockers: the current journal
has no truthful terminal variant for them, and they never authorize an automatic
completion retry.

PR #174 currently accepts only whole sat/vB fee rates. The RN-compatible SDK
default is 1.5 sat/vB, so callers using this experimental adapter must explicitly
choose an integral rate such as 2 sat/vB; fractional values fail before HTTP.
`sendBtc(skipSync: true)` also fails before HTTP because PR #174 hardcodes
`skipSync` to false and cannot preserve the caller's requested semantics.
The adapter rejects logical `utexo` and `testnet4` networks because the gateway
cannot negotiate or preserve those identities.

Only exact DTO projections are enabled. `getAddress` remains unavailable because
the route omits account/keychain/index data needed for local re-derivation.
`syncWallet`/`refreshWallet` remain unavailable because `{status:"ok"}` cannot
produce the facade's authoritative completion fields. UTXO/transfer/asset-list
shapes with missing fields and all RGB signing paths also remain fail-closed.

Durable `GET operation` status has been promised by the backend team but is not
present in the reviewed gateway contract. If completion becomes ambiguous, the
durable coordinator reports `operation.ambiguous` and will not broadcast or
complete again without authoritative status. The endpoint and its exact schema
remain a backend release gate. The PR's current PSBT transaction/derivation
profile must also be aligned with `utexo.psbt.bip86.v1` and proven with real
gateway fixtures; until then money movement is default-off and the local signer
will also reject any PSBT that violates its narrow policy.

For this experimental pass the bearer token is private, redacted, and retained
for the adapter lifetime. Loading and rotating it through an OS-backed credential
provider is a production release gate.

## Native implementation boundary

The generated UniFFI Swift declarations are mechanically rewritten to Swift
`package` access after every regeneration. This lets the `RGBSDK` target use the
native signer while preventing an external package from calling raw
derive/sign/validate wrappers. Run `Scripts/verify-api-boundary.sh` to compile a
real external facade consumer and a negative raw-wrapper consumer.

SwiftPM still places the transitive `UtexoLocalSignerFFI` Clang module on an
external consumer's import path. C declarations have no Swift `package` access
equivalent, so callers can currently reach exported C symbols directly. The
boundary audit reports this explicitly; producing a single precompiled facade
artifact (or an equivalent private linker shim with no public C header) is a
production packaging release gate.

## Apple key custody

`KeychainSeedStore` stores one exact 64-byte BIP39 seed as a generic-password
item with:

- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- `kSecAttrSynchronizable = false`
- optional `.userPresence` or `.biometryCurrentSet`
- create-only semantics; an existing wallet is never silently replaced

Secure Enclave does not expose BIP32/secp256k1 signing. The Keychain protects
seed retrieval; Bitcoin signing still happens briefly in process memory.
Zeroization is best effort because Swift/Foundation/FFI runtimes may copy data.

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
swift test
```

The suite covers cross-platform request-hash and checkpoint-codec goldens, the
RN key compatibility vector, Unicode passphrase normalization, hard policy
ceilings, redaction/use-after-close, Keychain query policy, cancellation, and
PREPARED/SIGNED/SUBMITTING/terminal crash-recovery behavior.

See [SECURITY.md](SECURITY.md) for guarantees, trust boundaries, and release gates.
