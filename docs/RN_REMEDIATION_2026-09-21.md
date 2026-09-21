# Swift RN-reference remediation and verification — 2026-09-21

## Result

The ordinary public gateway factory still does **not** enable new spending.
No public function signature, package import, generated public SDK interface,
checkpoint encoding or existing legacy BTC intent digest was intentionally changed.

Backend-independent work completed:

- Native create count is 1...255 and size is 1...UInt32.max satoshis, without
  narrowing the existing public value carriers or permitting FFI truncation.
- Fee estimation validates targets 1...1008 before backend work and binds the
  returned target to the requested target.
- Complete-snapshot transaction/transfer txid filters reuse the base read
  primitive. `skipSync: true` still requires an actual unsynchronized operation.
  Records/order are preserved; missing history is not replaced with empty data.
- Impossible BTC balances are classified as backend protocol failures rather
  than caller argument errors. Existing exact-JSON asset limits remain intact.
- A separately selected internal `utexo.psbt.rgb-lib.v1` signer profile supports
  the branch-0 builder, independently trusted height limits, independent fee
  targets/hard ceilings, exact create plans and fungible RGB Bitcoin intent.
  The ordinary factory and legacy profile remain unchanged and gated.
- Swift create/RGB unconditional orchestration stubs were replaced with the same
  typed durable operation workflow as BTC: request binding, preflight, exact
  prepared/signed checkpoints, revalidation before first submission, ambiguity,
  status-only recovery and terminal replay.
- Create and RGB request hashes include every existing request option and match
  the Kotlin canonical field ordering. Additional common-domain golden vectors
  were independently calculated using length-prefixed SHA-256.
- Create plans bind owned colored paths, requested/default size and maximum
  count. Native partial creation is accepted in either `upTo` mode, but the
  authoritative result count must equal the exact locally authorized plan.
- Outgoing RGB checks read the literal encoded assignment, not the lossy RN
  projection. They check caller amount/asset conflicts, network, owner assignment,
  expiry, transport endpoints and explicit witness instructions. Witness Bitcoin
  script/address derivation uses the native invoice helper, not a server string.
- Both private signer entry points and the coordinator bind operation, network,
  request hash and idempotency key. Retained validation checks current policy
  without generating or replacing a signature.
- RGB expiry and new-operation capability checks occur only at risky transitions,
  including after a suspending preflight. They cannot prevent already-submitting
  reconciliation or authenticated terminal replay after expiry/profile changes.

## Verification

Final source snapshots, including the newly rebuilt native XCFramework:

| Configuration | Result | Exact staged source snapshot |
| --- | --- | --- |
| Debug | 171 tests passed | `.build/source-stage.BpFfue` |
| Release | Same 171 tests passed | `.build/source-stage.4Iv4xq` |

Both complete runs included the nine real loopback-HTTP tests with socket access
authorized. Earlier sandbox socket denials were infrastructure failures, not
silently skipped tests. Initial audit cycles also corrected test actor-isolation
and canonical invoice-query ordering before these final runs.

The added evidence includes:

- Untouched real gateway BTC/create/RGB PSBTs captured 2026-09-18 at PR174 commit
  `8eebc40a44ff519bd21c818a7fbe7c11d3275e8c`, native npm `0.3.0-beta.18`.
- Correct local signature/final-witness results, original txids, fee/size facts,
  original legacy-profile rejection, too-low trusted height and independent hard
  fee rejection, wrong exact output plan and request identity rejection.
- Typed create/RGB fresh success, byte-identical retained signed submission,
  preflight denial before mutation, request conflict, pending recovery after
  preparation expiry and disabled signing, actual-count tampering, compact
  terminal replay, partial-count success and actual invoice-expiry recovery.
- Existing BTC recovery, encrypted journal, malformed transport, cancellation,
  key derivation and API value tests continue passing.

These are local packaged-native policy and source orchestration tests with mocked
backend effects. They perform no live gateway complete/broadcast/payment. They
are not evidence of full RGB state validation, a physical-device lifecycle run,
an independent security audit or completed production release qualification.
Final facade distribution rebuild, provenance and external-consumer checks are
owned by the parent verification workflow after this source freeze.

## Remaining unsupported public gateway surface

Conservatively unchanged for the **ordinary current gateway factory**: seven
implemented declarations, two gated BTC overloads, 22 unsupported declarations
(18 logical functions). Internal authorizers/workflows do not count as publicly
enabled endpoints. Source aliases are not independent backend requirements.

| Function family | What actually remains |
| --- | --- |
| Address | Existing route lacks an index/recovery contract for bounded local ownership verification. A finite scan-from-zero would introduce a wallet lifetime/reinstall/multidevice failure boundary. Persistent reuse/rotation is a separate missing native gateway behavior. |
| Estimation/history | Server estimator and complete BTC history exposure are absent. Txid filters need no separate endpoint once complete data and requested sync semantics exist. |
| Unspents/assets/transfers | Existing serializers omit required real metadata/assignment/state fields. SDK models must not fabricate these. Scope the chosen schemas and fields. |
| Blind/witness receive | Existing common receive route lacks the required real batch index. Unified receive remains usable; no extra receive business algorithm is needed. |
| BTC/create/RGB spending | Backend write-ahead submission/reconciliation/replay and complete durable results remain unresolved. Create requires authoritative actual counts; RGB requires real batch results, witness blinding/selected options and consistent ownership bookkeeping. The exact gateway native build/profile and trusted chain context must be pinned before internal profile activation. |
| Issuance/inflation/failure/reuse | Missing gateway primitives for whichever families are selected. Inflation still needs its operation-specific authorization once its actual flow is defined; it is not implemented by copying RGB send or requiring full local RGB validation. |

Actual create count can be derived from the locally validated transaction once
completion is authoritative; a missing count in GET alone is not an independent
backend blocker. The exact output plan can also be constructed by a reviewed
SDK-owned PSBT extractor, rather than requiring a new server field. RGB batch
identity is not derivable from Bitcoin outputs.

The current gateway adapter deliberately has no enabled create/RGB preparation
or recovery mapping against incomplete wire schemas. Implementing those mappings
and qualifying end-to-end success/crash/restart behavior remain follow-on SDK
work once the selected backend contract is supplied; they are not proof that no
SDK work will remain after backend changes.

Other release decisions remain with SDK/product/release owners: selected feature
subset, supported numeric/fee domains, credential/deployment provisioning,
physical/minimum-OS behavior, immutable release artifacts/CI, licensing and an
independent security review. They must not all be labelled backend bugs or
converted into an unsupported-API percentage.
