# Swift S1/S3/S7 remediation — 2026-09-20

The confirmed completion-409 SDK defect is fixed, and the previously missing real-HTTP, ordinary-factory consumer, and persisted-intent recovery regressions now execute. **The intended full wallet SDK is not release-ready:** fresh ordinary-factory BTC sends remain disabled and the unsupported function inventory is unchanged. This report supersedes the S1/S3/S7 findings of the September 19 audit only to the extent of the evidence below.

## Scope

This remediation reviewed and changed the completion-error mapping, relevant coordinator contract comments, corresponding source tests, new loopback/consumer fixtures and integration documentation. It also rechecked unsupported public methods against current gateway wallet schemas/routes and independently cross-reviewed Kotlin's corresponding completion mapping/recovery tests. The current Swift shipping inventory is 20 handwritten files / 7,380 physical lines; that is an inventory, **not a claim that all 7,380 lines and every dependency were re-audited anew during this focused remediation**. The earlier [independent source audit](SWIFT_INDEPENDENT_REAUDIT_2026-09-19.md) records the broader review scope and full parameter/output table.

No backend changes, new public declarations, provisional-payment enablement, or replacement cryptographic library were introduced here. Existing dirty/untracked work was preserved. The parent release task owns artifact rebuild/provenance, while the Apple/storage owner records S4/S5 in [its separate evidence note](SWIFT_S4_S5_REMEDIATION_EVIDENCE_2026-09-20.md).

## S1: submitted completion conflicts remain ambiguous

`Sources/RGBSDK/GatewayWalletBackend.swift:869` and `:892` now check for a submitted operation identity before mapping `IDEMPOTENCY_KEY_REUSED` or `OP_KIND_MISMATCH` as a prepare-style failure. Once complete may have been dispatched, both return retryable `operation.ambiguous` with the original operation ID. `OperationCoordinator.swift:330` consequently performs one read-only reconciliation; it never interprets these envelopes as proof of no broadcast or authority for another completion.

Prepare-phase idempotency conflicts remain distinct and nonretryable before signing/submission. Recovery retains exact signed evidence if the status response is pending, unavailable, malformed or not bound to the local transaction. Matching completed status commits a terminal receipt before success returns.

Evidence in `Tests/RGBSDKTests/GatewayWalletBackendTests.swift`:

| Regression | Evidence |
| --- | --- |
| Direct operation-kind completion response | `gatewayCompletionOperationKindMismatchPreservesAmbiguity`, line 1341 |
| Both known 409s participate in the completed-status response matrix | `gatewayAmbiguousCompletionImmediatelyPerformsOneReadOnlyReconciliation`, line 1485 |
| Both known 409s preserve evidence and next-call status-only recovery | `unknownCompletionRejectionRetainsSignedEvidenceAndNextCallOnlyPolls`, line 1527 |
| Each known code followed by GET 401/404/500 | `knownCompletionConflictsRetainIdentityThroughFailedReconciliation`, line 1554; exact SUBMITTING retained, operation identity preserved, subsequent matching GET succeeds |
| Prepare conflict never signs or polls status | `prepareIdempotencyConflictRemainsAConflictBeforeSigning`, line 1581 |
| Prepare operation-kind mismatch remains a protocol failure | `prepareOperationKindMismatchRemainsProtocolFailureBeforeSigning`; no operation ID, signing or status lookup |
| Immediate status reconciliation preserves cancellation | `completionConflictReconciliationCancellationPreservesEvidenceAndResumesReadOnly`; for both known complete-409 codes the transport raises cancellation on the immediate GET, exact signed evidence remains SUBMITTING, and a subsequent GET-only retry succeeds |

The original defect was an error-contract/reconciliation problem, not demonstrated duplicate spending or evidence deletion. It was reachable through retained SIGNED/development-profile execution; fresh payments from the ordinary factory were and remain gated. Closing it does not make the backend's broadcast/idempotency contract durable.

## S3: actual HTTP and ordinary consumer execution

Eight tests in `Tests/RGBSDKTests/GatewayHTTPTransportTests.swift` use actual URLSession connections to a test-only `Network` loopback server, not an injected response transport. They cover:

- exact configured response-byte limit and one byte over, with fixed-length and chunked bodies;
- malformed/deeply nested JSON, unexpected success status and wrong MIME type;
- redirects with zero requests/credentials delivered to the target server;
- timeout and task cancellation both before headers and during body delivery, without retry;
- a truncated Content-Length response;
- fresh credentials, same-user rotation, foreign-user rejection, and absence of cookie/cache reuse;
- exact balance/sync/refresh/receive behavior and request defaults.

`Tests/AppleConsumerFixture/PublicGatewayConsumerTests.swift:10` imports only the ordinary `RGBSDK` product and executes `UTEXOWallet.create`, real OS Keychain seed/API-key/journal storage, actual HTTP, initialize/unlock, balance/sync/refresh/receive/local decode, credential rotation, foreign-user rejection, destroy/reopen and the unchanged fresh-send gate. It never requests prepare/complete. Cleanup targets only UUID-namespaced test records/directories.

The Apple/runtime owner wired this fixture into the distributed-package test target and recorded two independent **3/3** simulator suite passes, including `PublicGatewayConsumerTests/testOrdinaryFactoryHTTPWorkflowRotationAndReopen()`. Its script evidence is `.build/apple-consumer.DQHz79/simulator-tests.xcresult`, on iOS Simulator 26.5. Those results are owner-executed evidence inspected here; this subtask did not independently launch the simulator. See the S4/S5 note for commands, exact bundle/build hashes and runtime limitations.

This closes the specific unexecuted URLSession/ordinary-factory gap. It does not prove real gateway transaction acceptance, TLS/production infrastructure configuration, minimum-iOS runtime, physical-device custody or funded payments.

## S7: exact app intent survives reconstruction

`Tests/RGBSDKTests/DurableHTTPRecoveryConsumerTests.swift:12` stores a separate AES-GCM application intent before the first wallet call. It retains schema, wallet/network/service/account bindings plus every exact `SendBtcRequest` field. The test seeds genuine locally signed synthetic SUBMITTING evidence, closes its original journal, and reconstructs request/backend/wallet/journal objects from storage for two recovery attempts. Actual HTTP first returns pending, then a matching completed transaction. Assertions require original operation identity, unchanged signed evidence on ambiguity, exactly one status lookup per recovery, no prepare/complete, compact terminal replay without network and local rejection of changed same-key intent.

The negative test at line 131 rejects ciphertext tampering and individually rejects validly encrypted wrong schema/wallet/network/service/account bindings. An exact 5.001 sat/vB fee and `skipSync=true` round-trip demonstrates that persistence does not silently coerce public parameters; that negative/codec test makes no payment request.

The [durable consumer recovery guide](../DURABLE_CONSUMER_RECOVERY.md) documents app-record uniqueness, commit-before-dispatch, explicit same-key reconstruction, account binding, protected metadata and replay behavior. Apps use their own account reference; they do not need the SDK-private gateway user ID or backend SPI.

Limits are intentional and explicit: this is same-process object reconstruction using actual encrypted journal files and a file-persisted **test** anchor, not OS Keychain or a process-kill/power-loss campaign. The signed checkpoint is infrastructure-seeded because ordinary-factory fresh payment remains disabled. A public synthetic mnemonic/PSBT and local HTTP responses are used, with no funded gateway/broadcast. Public-factory Keychain/runtime tests are separate evidence. Real app database/crash/device and gateway broadcast recovery qualification remain necessary before payments.

## Final verification

After the final binding-negative test, the independent review's two additional prepare/cancellation regressions, and all concurrent S4/S5 source/test edits were present:

| Command | Stage | Result |
| --- | --- | --- |
| `bash Scripts/verify-source.sh` | `.build/source-stage.7rGUrw` | **148/148 passed**; debug build 10.71 s; tests 2.881 s |
| `bash Scripts/verify-source.sh --configuration release -Xswiftc -warnings-as-errors` | `.build/source-stage.1nTrAl` | **148/148 passed**; release build 28.50 s; tests 2.494 s |
| `git diff --check` | Current Swift repository | Passed |

Both source suites used repository-local `CLANG_MODULE_CACHE_PATH` and `SWIFT_MODULECACHE_PATH`. Localhost listening requires execution outside the filesystem sandbox; the initial EPERM listen failures were environmental and the approved executable runs above passed. The suites include the new HTTP/recovery tests, all prior native/API/coordinator tests and the other owner's exact 100,000-record/64-MiB journal boundary tests. Test counts are executed regressions, not a line-coverage or correctness percentage. No shipping code changed after these final runs; subsequent changes here are documentation only.

## Unsupported operation recheck: counts unchanged

There are **31 wallet business-method declarations / 28 distinct spellings**: **7 implemented declarations, 2 gated `sendBtc` overloads, 22 unsupported declarations**. Aliases and overloads are counted explicitly. Eleven public key-management helpers and lifecycle/construction are outside this business-method count and are implemented. The seven implemented declarations are `getBtcBalance`, `getAssetBalance`, `decodeRGBInvoice`, `decodeRgbInvoice`, `onchainReceive`, `refreshWallet`, `syncWallet` (six canonical API operations after collapsing the decoder alias; sync and refresh share the combined gateway implementation).

The complete unsupported inventory is below; grouped counts sum to 22:

| Public declarations | Count | Why no safe contract-preserving implementation was added |
| --- | ---: | --- |
| `getAddress`, `rotateVanillaAddress` | 2 | Address response lacks account/keychain/index reservation identity for local re-derivation |
| `listUnspents` | 1 | Gateway projection lacks required exists/pending-blinded/typed-assignment semantics |
| `estimateFeeRate` | 1 | No corresponding gateway fee-estimation contract |
| `createUtxos()` and `createUtxos(request)` | 2 | Operation-specific output authorization, PSBT profile and complete result contract unresolved |
| `listAssets` | 1 | Balance projection is not complete NIA/IFA metadata, supply, timestamps/media schema |
| `issueAssetNia`, `issueAssetNIA`, `issueAssetIfa`, `issueAssetIFA` | 4 | No issuance endpoint/result authorization contract; uppercase spellings are aliases |
| `blindReceive`, `witnessReceive` | 2 | Required batch-transfer index absent; unified `onchainReceive` already supports its optional result contract |
| `onchainSend`, `inflate` | 2 | RGB/inflation operation-specific local authorization and exact backend contracts unresolved |
| `listTransactions()`, `listTransactions(txid:skipSync:)`, `listTransactionsByTxid` | 3 | No complete transaction-history route/shape; last two share one implementation path |
| `listTransfers`, `listTransfersByTxid`, `listOnchainTransfers` | 3 | Flat gateway transfer projection lacks required batch index/typed assignments; optional UTXO/endpoint metadata is also lost |
| `failTransfers` | 1 | No route/acknowledgment semantics preserving the public request/result |

Evidence: throwing defaults at `Sources/RGBSDK/Backend.swift:57`; public routing at `UTEXOWallet.swift:187–437`; current gateway `minimal-sdk/packages/gateway/src/routes/wallet.ts` and `schemas/wallet.ts`. Missing required fields cannot be fabricated as zeros/empty arrays without breaking RN-like semantics. Backend contracts are prerequisites; SDK mappings and operation-specific policy tests still require implementation once those contracts exist. Full RGB transition/consignment validation remains a separately deferred scope, not a feature claimed by local invoice parsing.

## Independent Kotlin cross-check and remaining gates

Read-only cross-review of `RgbLightningNodeGatewayBackend.kt:934`, its `OperationCoordinator`, the new completion regression matrix and `EncryptedOperationJournalTest` found no additional shipping defect in the reviewed paths. Kotlin maps all submitted-operation 3xx/4xx to bound ambiguity before prepare-specific codes; its coordinator matrix covers matching completed, pending, unavailable and mismatching status while retaining exact evidence. Prepare conflict behavior remains distinct. Kotlin's durable-intent test uses host test cipher/fake backend/fake signer, and its new recovery guide accurately disclaims real Android process-kill, real gateway and production database qualification. This was a bounded independent review, not a full Kotlin re-audit or a new Kotlin test execution.

Remaining release gates include frozen PSBT/fee/network/vanilla-input and durable broadcast contracts, implementation of blocked business operations, unchanged real-gateway funded/restart fixtures, physical-device/minimum-OS custody and restore qualification, release publication/provenance/license/security decisions, and full-engine migration. Passing a public API baseline alone cannot prove package-only migration: a future full SDK must accept the same initializer/configuration, preserve names/types/defaults/errors and protected storage, and atomically import server-held RGB state, address progress and unresolved operations. No such future-engine importer exists in this remediation.
