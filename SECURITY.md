# Security model

## Status

This code is pre-release. It has not completed an independent security audit,
end-to-end backend interoperability, or comprehensive Bitcoin Core differential
validation. A shipped-XCFramework regtest diagnostic passed Core mempool
acceptance and signature-tamper rejection for a policy-compliant BTC send;
this does not validate the unchanged gateway profile or every signing case. Reported
capabilities describe implemented local checks; they are not a claim that the
future end-to-end service is production-ready.

## Assets and trust boundaries

Private seed/mnemonic/xpriv material is trusted and must remain local. The
backend, transport, prepared PSBT, network data, persisted operation records,
and all caller strings are treated as untrusted inputs.

For the legacy local `sendBtc` profile, the local core verifies before signing
(the ordinary gateway factory selects the separate profile described below):

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
- BIP174/BIP371 final key-path witnesses with consumed input signing metadata
  cleared; transaction inputs/outputs and fees remain unchanged.

The backend result txid must match the locally validated unsigned txid before a
terminal result is persisted or returned.

The ordinary gateway factory's `utexo.psbt.rgb-lib.v1` profile does not
reinterpret this legacy policy or its persisted intent digests. It fixes input
and owned output derivation to the native builder's branch 0, retains version 2
and required RBF, and bounds height-based locktime by an independently trusted
caller context. A PSBT cannot supply its own trusted height. It separately
enforces the requested fee target against conservative signed transaction weight
(65-byte Taproot signatures, integer fee rounding), and the app's hard absolute
and rate caps. No arbitrary dust or percentage overpayment is authorized.

New spending requires an app-owned `WalletChainContextProvider`. Its observation
must match the selected network, be at most 300 seconds old, and be no more than
30 seconds in the future. `observedAt` is the tip-observation time, not the block
timestamp. Fresh context is fetched before signing and revalidation immediately
before first submission. Missing, stale or invalid context cannot authorize a
signature or submission; terminal replay and submitted-operation status recovery
do not require it.

Create-UTXO authorization binds the caller's defaults/count/size and every exact
colored output path in the retained plan; vanilla change is independently
re-derived. Fungible RGB authorization checks the invoice's literal encoded
state, effective asset, witness BTC recipient/amount, expiry, and caller options;
it limits Bitcoin spending/change/commitment shape but **does not validate the
RGB transition or prove allocations**. Server RGB state remains trusted.

The SDK persists create/RGB operations through the same conservative state
machine as BTC. It never terminalizes a different txid, result kind, operation
ID or create-output count. An expired invoice or newly disabled signing
capability is checked only before new risky transitions, never used as a reason
to discard SUBMITTING evidence or prevent completed-result replay. BTC, create
and fungible RGB transport are enabled. A matching completed create transaction
supplies its count through the retained locally validated output plan; absent
RGB batch identity remains nullable, never invented.

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
- Enabled RGB money movement relies on server-side RGB validation and state.
  Bitcoin-level validation does not make these operations trustless.

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

The seed access policy is installed only at item creation. Reopening with a
different policy does not migrate its Keychain ACL. After unlock, native signing
material remains in memory for the session; subsequent signatures do not
automatically request biometrics. The app must enforce its background/idle/device
lock policy and await shutdown/disposal. Shutdown serializes behind in-flight
wallet work and is not transaction rollback. Physical-device qualification of
that app-owned lifecycle is required.

Root extended-private-key import/export exists only for RN compatibility, is
deprecated, and should not be used in new integrations.

## Backend and retry requirements

The SDK binds each preparation to the original local request hash, logical
idempotency key, network, operation kind/ID and expiry. The gateway's intent
summary is checked against that request; it is not a substitute for local PSBT
validation. Unsupported versions and semantically invalid fields fail closed.
The current private JSON adapter ignores additive object keys for compatibility;
required recovery fields, enums, types, explicit nulls, and intent allowances are
validated. Additive keys never authorize signing or extra transaction outputs.

`syncWallet`/`refreshWallet` call the gateway's combined BTC synchronization and
RGB refresh route; success is returned only after a 200 JSON `status: "ok"`
acknowledgment. Their timestamp records the client's observation, not a claim
about server time, tip height, independent chain validation, or absolute data
freshness. Both methods may perform the combined operation in this adapter.

Production journals must atomically encrypt and authenticate the opaque bytes
from `OperationCheckpointCodec`; its trailing SHA-256 detects accidental
corruption but is not authentication. The exact prepared transaction is saved
before signing, and the exact signed PSBT plus validation report is saved before
submission. PREPARED revalidates and signs that same preparation, SIGNED runs
full validation under the current policy before submitting the identical signed
bytes, and SUBMITTING reconciles without preparing or
signing again. Definitive success, rejection, and expiry outcomes are terminal
and replay locally on subsequent same-key calls.

PR #174 at `bf50f88b7259653a18d845e0eaee8dd01ad4f799` provides a read-only
operation-status endpoint. Its completed result is accepted only against
the original caller request and authenticated SUBMITTING checkpoint: canonical
operation ID, kind, recipient/amount/fee, millisecond timestamp range/order/TTL,
stored expiry floor, retained PSBT SHA-256, and locally signed txid. Recipient
`scriptHex` must be bounded canonical hex but is non-authoritative: the native
signer already validated the actual PSBT outputs against the local address and
amount before storing its report. No fresh signing occurs during recovery.

The gateway's unqueued read is not a no-broadcast proof. Both pending and expired
states, including null txid/false `mayHaveBroadcast`, preserve SUBMITTING and
return `operation.ambiguous`. A complete 410 `OP_EXPIRED` is treated the same way,
not as a definitive terminal rejection. Matching completed BTC/create/RGB may become
terminal success. The SDK performs at most one recovery GET per call and never
automatically retries complete or prepares a replacement. A missing operation,
invalid payload, mismatching intent/txid, or failed GET cannot release the signed
evidence. Cancellation remains cancellation and preserves that evidence. Backend
crash/TTL recovery remains a known risk, not an SDK activation gate: a broadcast
whose identity/outcome was not recorded may remain unresolved. Enabling spending
does not repair that server-side durability gap. RGB batch identity is nullable;
create counts come from the exact signed plan, not the requested count.

`UTEXOWallet.create` supplies this persistence automatically. CryptoKit
AES-256-GCM authenticates the versioned snapshot against wallet/network, service,
and Keychain namespace. The encrypted snapshot binds both the local account
xpub identity and the gateway user. A device-bound, non-synchronizing Keychain
record contains the AES key and committed/pending ciphertext hashes. The
two-phase anchor makes an interrupted disk/Keychain write recoverable without
accepting an older signed checkpoint after a completed commit. A lost key,
deleted snapshot, changed identity, or failed authentication never starts an
empty journal. Interrupted initial empty provisioning can resume with the
original key and ciphertext only. Root/Keychain compromise is outside this
guarantee; no software journal can recover if every copy and identity marker
has been deliberately removed.

Snapshot replacement synchronizes the temporary file and containing directory,
including `F_FULLFSYNC` for the file. A process-wide wallet lease and a kernel
file lock prevent cooperating instances/processes from owning the same store.
The lock survives `shutdown` and is released on `destroy` or deallocation.
Symlink/hard-linked snapshot files are rejected. Logical app-container-relative
binding preserves normal iOS app upgrades; changing a dedicated external
directory is an explicit migration and currently fails closed. Data is excluded
from backups because its encryption key is device-bound. Keep a separate seed
recovery backup; it cannot replace pending-operation/RGB-state recovery data.

The 64 MiB snapshot ceiling bounds disk reads; the history also has a 100,000
operation limit. Reaching either is a storage error, not permission to discard
recovery identity. V2 terminal receipts remove only prepared/signed PSBT payloads
after a definitive outcome, preserving every key, request hash, outcome and local
validation report indefinitely within the wallet. Nonterminal records are never
pruned or compacted. V1 histories migrate on the next successful atomic write;
interrupted upgrades use the existing committed/pending recovery protocol.
Older SDKs fail closed on v2 snapshots; downgrades are unsupported. Storage-budget
qualification and cross-device wallet migration remain release work. Device lock, actual Keychain
authentication/invalidation, and power-loss tests still require Apple-device
validation; host tests use fault-injected Keychain persistence with real files.

The app-facing API loads API credentials per request through a provider.
`KeychainAPIKeyStore` uses `WhenUnlockedThisDeviceOnly`; credential rotation is
explicit and checked against the same gateway user before wallet operations.
Secrets are redacted in descriptions/reflection, but URLSession necessarily
copies an Authorization header into process memory for the request.

## Production release gates

- Keep the facade-only binary distribution and its strict external-consumer
  gates passing. Private C/Swift modules are no longer dependencies of the root
  product. Rebuild after source/native changes and verify the recorded complete
  input/output inventories. This API boundary is not a same-process sandbox.
- Inspect the signed app's aggregated privacy report and operator disclosures;
  the SDK's own manifest and independent unsigned archive resource check are
  necessary but are not App Store approval. See `PRIVACY.md`.
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
