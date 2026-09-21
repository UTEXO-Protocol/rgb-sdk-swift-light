# Swift SDK findings closure — 2026-09-21

This follow-up supersedes the earlier report's statement that create-UTXO wire
mapping had to wait for new response fields. It does not supersede the backend
crash-recovery gate or claim a production release candidate.

## SDK-owned changes

- `FeeRate.default` is exactly 2 sat/vB. Explicit 1.5 remains a valid exact
  value type, but the integer-only gateway rejects it rather than rounding.
  Current gateway fee/option domains are checked before a new coordinator
  checkpoint or wallet-effect request is created.
- The private gateway adapter implements create prepare, complete and
  checkpoint-aware status recovery using existing PR174 fields. No server
  output-plan/count endpoint or fabricated batch identifier is introduced.
- Create sends explicit `upTo`, count and size; omitted values mean true, 5 and
  1,000 respectively. Gateway count is 1–50; Taproot size is 330–UInt32.max.
  The public request retains native u8/u32-compatible carriers for the future
  binary-backed SDK. Unsupported `skipSync: true` is rejected.
- A bounded Rust parser extracts an **untrusted** colored-output plan from the
  exact PSBT. The independent local signer still verifies derivation, ownership,
  scripts, request count/size, Bitcoin inputs, transaction policy and fees.
  Extraction is not ownership verification or RGB validation.
- Complete must return the locally signed txid and exact validated output
  count. A malformed/null/mismatched result stays ambiguous. A matching
  `completed` status permits count derivation from the authenticated retained
  plan; `pending`/`expired`, even without a txid, never authorize retry or a new
  transaction. After a restart/TTL, recovery remains read-only with spending
  disabled and preserves the exact signed bytes.
- BTC completion requires canonical lowercase txids, consistent with create
  and status responses; whitespace/uppercase is not silently normalized.
- Read/prepare/registration results cannot escape into a shut-down session
  after an asynchronous request. Malformed registration addresses are backend
  protocol failures, not caller-argument failures.
- Cancellation after an awaited rotated-credential identity check is honored
  before the requested wallet effect can be dispatched.

Fresh spending remains disabled in the ordinary application factory. The
private create path requires the pre-existing explicit development opt-in and
a separately qualified local gateway signer. An internal adapter is not a
newly enabled public feature; no package/import/API signature baseline changed.

## Regression and review evidence

| Check | Result |
| --- | --- |
| Complete debug source suite | 180 tests pass, `.build/source-stage.tjv0XQ` |
| Complete optimized release suite | Same 180 tests pass, `.build/source-stage.fO4zz5` |
| Public source API baseline | Pass, including deliberate API-removal negative control |
| External package boundary | Ordinary consumer executes; private Swift and raw C imports are rejected |
| macOS consumers | arm64 and x86_64 link; host arm64 native derivation executes, `.build/macos-consumer.ENROM1` |
| Five-architecture facade | Rebuilt successfully, `.build/facade-stage.TXB4J6` |
| Native/facade input-output receipts | Pass; current Swift artifact manifest regenerated |
| Packaged privacy manifests | Three platform slices verified |
| Whitespace/error check | `git diff --check` passes |

New create tests use the untouched historical gateway PSBT and actual local
native signer with stubbed HTTP responses. They cover exact parameters,
5-of-7 partial creation, result-count tampering, null/missing/wrong txids,
ambiguous completion, immutable terminal replay, restart after expiry with
the profile disabled, changed intents, malformed/RGB PSBT rejection, invalid
request rejection before journal/HTTP, and the ordinary spending gate.

Additional regression coverage proves no preparation dispatch after cancelled
credential validation, no stale-session balance result, and rejection of
noncanonical BTC completion identifiers. Parent review rechecked the retained
plan/count trust boundary and found the canonical-BTC-result inconsistency,
which was fixed and included in the final reruns.
The rebuilt binary's external consumers also assert the shipped 2 sat/vB
default and exact preservation of an explicitly constructed 1.5 sat/vB value.

The first sandboxed full run could not bind nine existing loopback tests; its
release build also lacked Xcode symbol-generation permissions. Both entire
suites were rerun with permission and passed without exclusions. A nested
test macro compile error was fixed before the successful final runs.

## Remaining boundaries

The SDK still cannot independently reconstruct data the gateway omits:
unspent existence/pending/type state, asset-wide metadata/supplies, actual
transfer assignment arrays, and required receive/send batch IDs. Complete
Bitcoin history and target-based fee estimation still need a data source.
RGB send's durable batch result and witness-blinding option remain contract
gaps. Address ownership discovery and persistent reuse require a qualified
recovery contract, not an arbitrary scan limit.

All spending still depends on authoritative backend submission/reconciliation
across crashes and expiry. BTC additionally needs qualification of RGB-bearing,
pending and reserved input selection in the intended native/gateway setup.
Full RGB state validation remains server-side by the agreed phase scope.
Issuance is explicitly excluded. Inflation has no selected gateway flow and is
not claimed implemented. Safe abandoned-transfer cleanup can be backend-owned
without a public SDK API.

No backend source was changed, no live gateway payment was completed, no funds
were broadcast, and no commit, push or deployment was performed in this pass.
Staging end-to-end qualification, physical/minimum-OS coverage, release/legal
and independent security approvals remain separate work. Passing these tests
does not establish an unconditional package-swap or “100% production” guarantee.
