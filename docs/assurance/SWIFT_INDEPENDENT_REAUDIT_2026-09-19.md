# Swift independent release-readiness audit — 2026-09-19

The Swift SDK is **not a release candidate for the intended RN-like wallet feature set**. The current tree has a substantial local cryptographic/persistence foundation, but most business operations remain unavailable, fresh public-facade BTC sends are disabled, and independent inspection reproduced a remaining SDK-owned completion-error defect. Backend changes alone do not close all remaining work.

This is a source and evidence audit, not a claim that software can be certified “100% correct.” No shipping implementation was changed. An audit-only test was added to an isolated `.build` source stage to reproduce the finding below.

## Scope and evidence

- Repository HEAD: `78b983b3d9d68a965e239dd964e46530f993e7c3`, including the current dirty/untracked source and artifact tree.
- Read all 20 handwritten shipping files under `Sources/RGBSDK`: 7,338 physical lines, including comments and blank lines. Reviewed both package manifests, all files in `Scripts`, the Swift CI workflow, public API baseline mechanism, source tests relevant to recovery/custody/validation, and independent consumer fixtures.
- Inspected generated binding initialization/error boundaries and the packaging records; did not treat generated code, every native archive instruction, or every transitive Rust dependency line as manually audited Swift implementation. The shared Rust policy/core has a separate review owner.
- No `AGENTS.md` was found beneath the workspace in the read-only inventory.
- Fresh `node Scripts/facade-provenance.mjs --check`: **pass, 37 inputs / 15 outputs**. The distributed facade inventory matches the recorded current source/native inputs.
- Fresh `shasum -a 256 -c NativeSource/SHA256SUMS`: **all entries pass**. This establishes local consistency, not independent reproduction or release authenticity.
- Fresh isolated source build and existing `gatewayOperationKindMismatchIsAProtocolViolation` test: **pass**, confirming the current test expects the problematic error classification.
- Fresh audit-only `independentAuditKnown409BypassesImmediateReadOnlyRecovery` test: **pass**, reproducing both known-409 paths, retained SUBMITTING state, and successful recovery on a subsequent call.
- The ordinary source test script initially encountered sandbox-denied default compiler caches. Redirecting `CLANG_MODULE_CACHE_PATH` and `SWIFT_MODULECACHE_PATH` into the isolated stage completed the same source build without an escalation. That first cache failure is environmental, not a product defect.

Audit reproduction stage: `.build/source-stage.CIMIRj`. Its production Swift files are unchanged copies of the current shipping sources. Its `Tests/RGBSDKTests/GatewayWalletBackendTests.swift` contains one additional audit-only test; this stage is therefore not the pristine 131-test release evidence snapshot.

## Confirmed remaining SDK defect

### SW-S1: Known completion 409 responses bypass ambiguity recovery

Owner: Swift SDK. Severity: **S1 before enabling payments**; dormant for fresh sends constructed through today's ordinary public factory.

`GatewayWalletBackend.swift:869` maps HTTP 409 `IDEMPOTENCY_KEY_REUSED` to `operation.conflict`, without an operation ID. `GatewayWalletBackend.swift:886` maps HTTP 409 `OP_KIND_MISMATCH` to `backend.protocol_mismatch`. Both branches run before the generic submitted-operation ambiguity handling at line 903. Those error codes default to `retryable=false` (`Errors.swift:24`).

The coordinator performs an immediate status reconciliation only for `backend.unavailable` or a matching `operation.ambiguous` (`OperationCoordinator.swift:330`). The two known-409 responses consequently escape as nonretryable errors after SUBMITTING has already been saved and complete has been dispatched. A complete response can come from a gateway/intermediary without proving a durable no-broadcast outcome, so the API should not present these cases as a resolved failure while other malformed/unknown completion errors remain ambiguous.

The reproduction starts from a retained SIGNED checkpoint with the development profile enabled. For each code it observes:

1. GET `/v1/me`, then POST complete.
2. A nonretryable conflict/protocol error and **no immediate status GET**, although a matching completed status is available.
3. The exact signed checkpoint remains SUBMITTING.
4. Calling again with the same key performs a status GET and returns the locally bound successful txid.

This is a demonstrated error-semantics/recovery defect. It does **not** demonstrate duplicate spending, loss of signed evidence, or an automatic repeat of complete. The durable state remains conservative; the public error and missing first-call reconciliation are the problem. Fix by making post-dispatch completion ambiguity take precedence for these codes, retain the operation identity, and extend the coordinator-level response matrix. Keep prepare-phase idempotency conflicts distinct. `Tests/RGBSDKTests/GatewayWalletBackendTests.swift:1341` currently enshrines the operation-kind error; the broader ambiguity matrix at line 1484 omits these two codes.

Fresh sends through `UTEXOWallet.create` cannot currently reach this path because the public factory does not enable the provisional profile. It is reachable through the source-development SPI and retained SIGNED recovery with that profile enabled, so it must be closed before that path is released.

## Actual public wallet implementation inventory

The inventory counts 31 business-method declarations / 28 distinct spellings. Seven declarations implement six underlying behaviors, two `sendBtc` overloads are gated, and 22 declarations are unsupported with the default gateway. Aliases and overloads are counted explicitly rather than presented as independent product features. These counts describe functionality; **7/31 is not a production-readiness percentage**.

All business methods are `async throws`, run through the unlocked wallet gate, and therefore require a successful initialize/unlock first. Local invoice decoding makes no request once unlocked, but the current public lifecycle itself contacts the server during initialize and unlock.

| Public method(s), parameters | Output | Current default-gateway behavior | Source entry |
| --- | --- | --- | --- |
| `getBtcBalance()` | `BTCBalance` | Implemented GET balances projection; values are gateway assertions, not independent chain proofs | `UTEXOWallet.swift:187`, `GatewayWalletBackend.swift:320` |
| `getAddress()` | `BitcoinAddress` | Unsupported: reservation account/keychain/index evidence missing | `UTEXOWallet.swift:193`, `Backend.swift:60` |
| `rotateVanillaAddress()` | `BitcoinAddress` | Unsupported: same address reservation contract | `UTEXOWallet.swift:197` |
| `listUnspents()` | `[Unspent]` | Unsupported: exact UTXO/allocation DTO contract not mapped | `UTEXOWallet.swift:201`, `Backend.swift:61` |
| `estimateFeeRate(blocks: BlockCount)` | `FeeEstimate` | Unsupported | `UTEXOWallet.swift:207`, `Backend.swift:62` |
| `sendBtc(_ request: SendBtcRequest)` | `TransactionID` | Local BTC signing/coordinator implemented, fresh gateway payment gated | `UTEXOWallet.swift:215` |
| `sendBtc(address: BitcoinAddress, amount: Satoshis, feeRate: FeeRate = .default, skipSync: Bool = false, idempotencyKey: IdempotencyKey = .random())` | `TransactionID` | Same gated path; omitted key creates a new logical payment on each call | `UTEXOWallet.swift:229` |
| `createUtxos()`; `createUtxos(_ request: CreateUtxosRequest)` | `CreateUtxosResult` | Unsupported; both local operation-specific authorization and backend result/profile work remain | `UTEXOWallet.swift:249` |
| `listAssets()` | `ListAssets` | Unsupported: complete asset shapes not mapped | `UTEXOWallet.swift:260`, `Backend.swift:65` |
| `getAssetBalance(assetID: AssetID)` | `AssetBalance` | Implemented exact on-chain balance projection; gateway amount ceiling applies; off-chain fields absent | `UTEXOWallet.swift:266`, `GatewayWalletBackend.swift:328` |
| `issueAssetNia(_ request: IssueAssetNiaRequest)`; `issueAssetNIA(_ request: IssueAssetNiaRequest)` | `AssetNIA` | Unsupported, second spelling is an alias | `UTEXOWallet.swift:272` |
| `issueAssetIfa(_ request: IssueAssetIfaRequest)`; `issueAssetIFA(_ request: IssueAssetIfaRequest)` | `AssetIFA` | Unsupported, second spelling is an alias | `UTEXOWallet.swift:283` |
| `blindReceive(_ request: InvoiceRequest)` | `InvoiceReceiveData` | Unsupported: required batch-transfer index absent in gateway response | `UTEXOWallet.swift:294`, `Backend.swift:74` |
| `witnessReceive(_ request: InvoiceRequest)` | `InvoiceReceiveData` | Unsupported: same required field; local returned-invoice checks exist | `UTEXOWallet.swift:298`, `Backend.swift:77` |
| `decodeRGBInvoice(_ invoice: RGBInvoice)`; `decodeRgbInvoice(_ invoice: RGBInvoice)` | `InvoiceData` | Implemented local syntax/checksum/schema projection; not RGB state/consignment validation | `UTEXOWallet.swift:302` |
| `onchainReceive(_ request: OnchainReceiveRequest)` | `OnchainReceiveResponse` | Implemented gateway receive and local returned-intent validation; receiver ownership/server-held seals remain trusted | `UTEXOWallet.swift:313` |
| `onchainSend(_ request: OnchainSendRequest)` | `OnchainSendResponse` | Unsupported: local operation-specific RGB authorization/signing and backend contract pending | `UTEXOWallet.swift:366` |
| `inflate(_ request: InflateRequest)` | `TransactionID` | Unsupported: local inflation authorization and backend transition contract pending | `UTEXOWallet.swift:375` |
| `listTransactions()` | `[Transaction]` | Unsupported | `UTEXOWallet.swift:384`, `Backend.swift:84` |
| `listTransactionsByTxid(_ txid: TransactionID, skipSync: Bool = false)`; `listTransactions(txid: TransactionID, skipSync: Bool = false)` | `[Transaction]` | Unsupported; second spelling delegates to first | `UTEXOWallet.swift:390` |
| `listTransfers(assetID: AssetID? = nil)`; `listOnchainTransfers(assetID: AssetID? = nil)` | `[Transfer]` | Unsupported; second spelling is an alias | `UTEXOWallet.swift:409` |
| `listTransfersByTxid(_ txid: TransactionID)` | `[Transfer]` | Unsupported | `UTEXOWallet.swift:415` |
| `failTransfers(_ request: FailTransfersRequest)` | `FailTransfersResult` | Unsupported | `UTEXOWallet.swift:425`, `Backend.swift:96` |
| `refreshWallet()` | `SyncResult` | Implemented combined BTC sync + RGB refresh acknowledgment; local observation timestamp, no chain-tip proof | `UTEXOWallet.swift:431` |
| `syncWallet()` | `SyncResult` | Same combined gateway operation | `UTEXOWallet.swift:437` |

The unsupported backend functions use throwing protocol defaults in `Backend.swift:57`. They are not implemented merely because public methods and result models exist.

### Request objects and exact defaults

| Request | Fields / defaults | Current implementation limit |
| --- | --- | --- |
| `SendBtcRequest` | `address`, positive `amount`, `feeRate=.default` (1.5 sat/vB), `skipSync=false`, `idempotencyKey=.random()` | Provisional gateway permits only whole 1–1000 sat/vB and `skipSync=false`; app signing ceiling is 100 sat/vB by default; public factory gate remains off |
| `CreateUtxosRequest` | `upTo=true`, `num: UInt16?=nil` (1–256 when present), `size: Satoshis?=nil` (positive), `feeRate=.default`, `skipSync=false`, `idempotencyKey=.random()` | Entire operation unsupported |
| `InvoiceRequest` | `amount: AssetAmount?=nil` (positive), `assetID: AssetID?=nil`, `minConfirmations=0`, `duration: DurationSeconds?=nil` | Blind/witness receive result contract unsupported |
| `OnchainReceiveRequest` | Same fields plus `witness=true` | Gateway defaults duration to 86400 and permits 60–2592000 seconds, confirmations 0–100, amount at most 2^53−1; local amount type can represent full UInt64 |
| `OnchainSendRequest` | `invoice`, positive `amount`, `assetID=nil`, `witnessData=nil`, `donation=false`, `feeRate=.default`, `minConfirmations=1`, `skipSync=false`, `idempotencyKey=.random()` | Entire operation unsupported |
| `WitnessData` | positive `amountSat`, `blinding: UInt64?=nil` | Relevant to future RGB send profile |
| `IssueAssetNiaRequest` | `ticker`, `name`, nonempty positive `amounts`, `precision` 0–18 | Entire operation unsupported |
| `IssueAssetIfaRequest` | `ticker`, `name`, `precision` 0–18, nonempty positive `amounts`, positive `inflationAmounts`, `rejectListURL=nil` | Entire operation unsupported |
| `InflateRequest` | `assetID`, nonempty positive `inflationAmounts`, `feeRate=.default`, `minConfirmations=1`, `idempotencyKey=.random()` | Entire operation unsupported |
| `FailTransfersRequest` | `batchTransferIndex: UInt64?=nil`, `noAssetOnly=false`, `skipSync=false` | Entire operation unsupported |

Definitions are in `Requests.swift`; numeric wrappers are in `Amounts.swift`. The full SDK must preserve the effective defaults, labels, optionality and error behavior of the lightweight contract rather than copy incompatible low-level FFI declarations.

### Lifecycle, construction and key helpers

Ordinary construction is implemented as `UTEXOWallet.create(configuration:service:storage:keyProvider: = nil)` at `UTEXOWallet.swift:38`. `configuration`, `capabilities`, `getNetwork()`, `isDisposed()`, `initialize()`, all three `unlock` spellings, `reinit(_:)`, `reinitialize(parameters:)`, `shutdown()`, `destroy()`, and `dispose()` have implemented lifecycle behavior. Destroy/dispose release ownership but do not delete wallet data. The actor's FIFO operation gate retains serialization across awaits; shutdown is not cancellation or rollback of an in-flight payment.

Eleven public top-level key helpers are implemented locally: `generateKeys`, `createWallet`, `deriveKeysFromMnemonic`, `deriveKeysFromSeed`, `deriveSeedFromMnemonic`, `deriveKeysFromMnemonicOrSeed`, `restoreKeys`, `accountXpubsFromMnemonic`, `getXprivFromMnemonic`, `getXpubFromXpriv`, and `deriveKeysFromXpriv` (`KeyManagement.swift:63`). Mnemonic derivation accepts `passphraseUTF8=[]`; source-selecting helpers require exactly one mnemonic or seed. Root private-key import/export is deprecated. Keychain stores and redacting/closeable secret wrappers are concrete implementations; seed retrieval policy applies at unlock, not to every signature.

`WalletCapabilities.localSigningOperations=[.sendBtc]` describes the local native core (`LocalSigningEngine.swift:49`). It is **not** an end-to-end backend capability promise. The actual public factory constructs `GatewayBackendConfiguration` without `allowUnverifiedPsbtProfile` (`UTEXOWallet.swift:45`); its default is false. The distributed `Package.swift:17` exports only the binary facade and no ordinary backend SPI opt-in. Therefore every fresh send through the ordinary public factory is currently unavailable.

## Remaining blockers and gates by owner

| ID | Owner/category | Required closure | Evidence / consequence |
| --- | --- | --- | --- |
| SW-S1 | SDK implementation | Correct the two known completion-409 cases, retaining ambiguity/operation identity and running one read-only reconciliation | Confirmed above; does not require backend changes |
| SW-F1 | SDK + backend integration | Implement the currently unsupported business methods once exact contracts exist, with local operation-specific authorization and result mappings | `Backend.swift:57`; `UTEXOWallet.swift:253`, `366`, `375`; backend contract arrival is a prerequisite, not the implementation itself |
| SW-F2 | Shared transaction contract | Align actual backend PSBT version, derivation/change branch, locktime, sequence, sighash/finalization, fee rounding/defaults, request limits and network identity; test unchanged real preparations | Swift intent hardcodes locktime 0, sequence `0xfffffffd`, vanilla change branch, no OP_RETURN (`LocalSigningEngine.swift:152`); adapter rejects fractions/skipSync and logical UTEXO/Testnet4 |
| SW-F3 | Backend recovery | Durable logical operation identity and write-ahead broadcast evidence, correct expiry semantics, authoritative terminal results | Gateway status can establish only matching completed BTC; pending/expired null-txid remains ambiguous (`GatewayWalletBackend.swift:549`) |
| SW-V1 | SDK automated verification | Exercise the actual URLSession transport and ordinary public factory against a controlled loopback server in an executable consumer; cover streaming/body caps, redirects, timeouts, cancellation, key rotation and read/sync/receive lifecycle | Gateway unit tests inject `GatewayHTTPTransport`; transport's streaming implementation at `GatewayWalletBackend.swift:1260` is not exercised by those stubs; external `makeWallet` is only compiled |
| SW-V2 | Apple runtime verification | Execute simulator tests, then real supported-device/minimum-OS custody and lifecycle qualification | `Scripts/verify-apple-consumer.sh:9` archives and line 12 only `build-for-testing`; no simulator/device test action in CI; `SDKConsumerTests` includes real Keychain work but building does not execute it |
| SW-V3 | Storage validation/capacity | Swift-specific count/byte-limit, interrupted write/rename/sync, memory/latency and long-history qualification, including real Keychain anchors | Swift sustained test is 250 records under 512 KiB (`EncryptedOperationJournalTests.swift:66`), not the 100000-record/64-MiB ceiling; every load/save decodes the entire snapshot (`EncryptedOperationJournal.swift:121`) |
| SW-M1 | Full SDK migration / shared protocol | Build and test an atomic importer with the future native engine, including outstanding gateway operations and RGB receive state | Current authenticated journal context includes service URL, gateway user and signer identity; device-bound journal and seed alone do not contain all server-held RGB state |
| SW-R1 | Release engineering | Produce clean immutable revisions, qualify the declared CI runner and toolchain, validate a remote dependency consumer/release artifact, sign/attest the intended release | Current tree remains dirty/untracked; local facade hashes pass but there is no release attestation in this audit; CI names `xcode-27` and pinned Xcode 27.0 without a proven CI run here |
| SW-R2 | Owner/legal | Select SDK distribution license and close dependency notice review | `NativeSource/license-review.json` explicitly says `requires-owner-review`, SDK license not selected, `hex_lit@0.1.1` notice absent |
| SW-R3 | Independent review / product deployment | Independent security review, signed shipping-app aggregate privacy/disclosures, and actual custody/recovery operations qualification | Existing privacy-resource checks are useful; unsigned archived manifests do not qualify signed App Store distribution or operator policies |

SW-V1 is a test gap with concrete uncovered boundaries, not a proven URLSession vulnerability. SW-V2/SW-V3 are missing qualification evidence, not a claim that a device failure has been observed. They remain non-backend work. `Scripts/verify-public-api.sh` checks the macOS public facade baseline and a real API-removal negative control; it does not exercise all public behavior or prove interoperability with the future full SDK.

## Can consumers later change only the dependency?

The API design supports preserving source compatibility, but **a package-only full-SDK migration is not yet demonstrated**. The future implementation must retain module `RGBSDK`, the same names/types/labels/defaults, async and lifecycle behavior, error codes, numeric semantics, credentials/service configuration as compatibility inputs, and protected storage identities. The API-key exception is acceptable only if the future initializer continues accepting the old configuration (even if unused); removing its parameter would still force application edits.

The migration must preserve local idempotency receipts and pending signed operations, address derivation high-water marks, RGB assignments/consignments and concealed-seal state held by the server. `EncryptedOperationJournal.swift:42` authenticates the service URL and `bindGatewayUserID` binds the gateway identity. Changing to a new local journal context without an importer will fail authentication. Keeping the old context is possible, but must be deliberately supported. Only the local v1→v2 journal compaction migration exists today; it is not a gateway-to-full-RGB-engine state migration.

There is no public pending-operation enumeration API. Apps are currently instructed to persist the exact request and explicit idempotency key before submitting (`README.md`). The full SDK must continue recovering those requests unchanged. A seed backup alone does not restore server-held RGB state or resolve ambiguous operations.

The required proof is an unchanged real consumer app, backed by a populated wallet with completed and pending operations and RGB receive state, upgraded by changing only its dependency, followed by successful lifecycle/read/send/recovery checks. No current signature baseline or local key vector substitutes for that test.

## Readiness decision

The local core/wrapper and packaging work have meaningful passing evidence. A narrow developer preview for key derivation and selected read/receive functions can be described accurately. The intended wallet SDK release cannot be called near-final on test counts alone: fresh payment flow is gated, the majority of public business functions are placeholders, SW-S1 remains, Apple runtime/public-factory coverage is incomplete, and migration/release ownership is unresolved.

Do not reuse the earlier closure report's statement that all safely completable SDK implementation work is closed. This audit identifies an SDK-owned defect and further executable SDK/platform qualification work. Backend changes are necessary for product completion, but they are not the only remaining blockers.
