# Security model

## Status

This code is pre-release. It has not completed an independent security audit,
backend interoperability testing, or Bitcoin Core regtest validation. Reported
capabilities describe implemented local checks; they are not a claim that the
future end-to-end service is production-ready.

## Assets and trust boundaries

Private seed/mnemonic/xpriv material is trusted and must remain local. The
backend, transport, prepared PSBT, network data, persisted operation records,
and all caller strings are treated as untrusted inputs.

For the enabled `sendBtc` profile, the local core verifies before signing:

- canonical bounded PSBTv0 and unsigned transaction version 2;
- unique, wallet-owned BIP86 P2TR inputs with exact fingerprints and paths;
- matching witness/non-witness UTXO data when both are present;
- no finalized inputs, script-path data, merkle roots, or unknown fields;
- the caller's exact recipient `(scriptPubKey, satoshis)` multiset;
- only locally derived vanilla change outputs;
- app and SDK fee/size/count/child-index ceilings;
- fee rate no higher than the caller's requested rate;
- locktime `0`, sequence `0xfffffffd`, and required RBF;
- no OP_RETURN outputs or colored-account inputs;
- only permitted Taproot sighashes;
- immediate verification of every generated BIP340 signature; and
- structural equality before/after signing except newly added key signatures.

The backend result txid must match the locally validated unsigned txid before a
terminal result is persisted or returned.

For `sendBtc`, “vanilla-only inputs” has an exact local meaning: every input
must carry one BIP86 origin in the vanilla external/change account, and its
Taproot internal key and script must match a fresh derivation from the local
seed. The shared core enforces this as a mandatory floor even if a higher layer
tries to widen the allowed scopes.

## What is not proved

`rust-bitcoin` is not a chain validator or complete script interpreter. Local
policy does not prove that an input exists, is unspent, is confirmed, or will
be accepted by a node/mempool.

A Bitcoin PSBT also cannot prove an RGB transition. Without the complete
transition/consignment, contracts, schemas, consumed assignments, change
assignments, commitment proof, and witness/history evidence, a malicious
backend could commit a different RGB state transition while presenting an
otherwise acceptable Bitcoin transaction. Consequently:

- A vanilla derivation path does not itself prove that an outpoint carries no
  RGB assignment. If “vanilla-only” means allocation-free rather than the
  segregated vanilla account, that guarantee requires authoritative RGB state
  evidence and is not available in this lightweight profile.

- `localTransactionValidation` never means chain-state validation.
- `localRGBValidation` remains `false`.
- RGB money-moving operations remain disabled until their trust contract is
  explicit and versioned (or a full local RGB validation engine is added).

## Key custody

On Apple platforms, use `KeychainSeedStore` or an equivalently reviewed
`WalletKeyProvider`. The store is device-bound, non-synchronizing, and
create-only. Loss/invalidation produces an explicit error; the SDK never
creates a replacement wallet automatically. `.biometryCurrentSet` deliberately
invalidates access after biometric enrollment changes.

Do not log, serialize, compare, hash, copy to clipboard, or include secret
wrappers in analytics/crash reports. Close them promptly. Zeroization across
Swift, Foundation, UniFFI, and Rust is best effort, not an absolute guarantee.
Keychain/Secure Enclave access controls protect seed retrieval but do not make
secp256k1/BIP32 operations execute inside Secure Enclave.

Root extended-private-key import/export exists only for RN compatibility, is
deprecated, and should not be used in new integrations.

## Backend and retry requirements

The future backend must negotiate an exact supported profile and echo the
locally computed request hash, idempotency key, network, operation ID, and
expiry. Unknown versions/fields fail closed.

Production journals must atomically encrypt and authenticate the opaque bytes
from `OperationCheckpointCodec`; its trailing SHA-256 detects accidental
corruption but is not authentication. The exact prepared transaction is saved
before signing, and the exact signed PSBT plus validation report is saved before
submission. PREPARED revalidates and signs that same preparation, SIGNED submits
the identical signed bytes, and SUBMITTING reconciles without preparing or
signing again. Definitive success, rejection, and expiry outcomes are terminal
and replay locally on subsequent same-key calls.

## Production release gates

- Freeze versioned backend profiles and test backend-produced golden PSBTs for
  every operation/network.
- Add one-mutation rejection tests for all paths, scripts, outputs, fees,
  sighashes, fields, locktime/sequence, ownership, and replay properties.
- Run BIP39/BIP32/BIP340/BIP174/BIP371 official vectors and fuzz the parser and
  policy boundary.
- Differential-test final transactions with Bitcoin Core `decodepsbt`,
  `finalizepsbt`, and `testmempoolaccept` on regtest.
- Black-box test the shipped XCFramework on devices/simulators, including
  device lock, biometric invalidation, cancellation, process death, and retry.
- Run dependency/license/SBOM/audit checks, reproducible builds, artifact
  checksums, ABI checks, and an independent cryptographic/policy review.

Security reports should include the affected version/profile and a minimal
reproduction with secrets and real wallet data removed.
