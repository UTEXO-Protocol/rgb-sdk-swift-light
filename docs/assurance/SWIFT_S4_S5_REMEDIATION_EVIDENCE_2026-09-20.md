# Swift S4/S5 remediation evidence — 2026-09-20

This note records the backend-independent remediation and executable evidence for
the Apple runtime-consumer gap (S4) and encrypted-journal validation/capacity gap
(S5) identified in `INDEPENDENT_RELEASE_AUDIT_2026-09-19.md`. It is scoped to the
current dirty working tree based on repository HEAD
`78b983b3d9d68a965e239dd964e46530f993e7c3`; it is not a release attestation.

## S4: executable packaged Apple consumer

`Tests/AppleConsumerFixture` is an ordinary application consumer of the shipping
`RGBSDK` package product. Its XCTest target now includes:

- packaged native mnemonic/key derivation and public numeric-literal behavior;
- real OS Keychain create-only storage, duplicate rejection, reload, and explicit
  deletion under a UUID-scoped service;
- ordinary `UTEXOWallet.create` construction against an actual `URLSession` TCP
  loopback server, including initialize/unlock, balance, sync/refresh, receive,
  local invoice decode, same-user API-key rotation, foreign-user rejection,
  payment-profile gating, destroy/reopen, and cookie/prepare/complete absence.

The exact required XCTest identities are:

```text
SDKConsumerTests/testPublicNativeDerivationAndLiteralCompatibility()
SDKConsumerTests/testRealKeychainRoundTripDuplicateAndExplicitDeletion()
PublicGatewayConsumerTests/testOrdinaryFactoryHTTPWorkflowRotationAndReopen()
```

`Scripts/verify-apple-consumer.sh` now performs all of the following:

1. creates an unsigned generic iOS archive of the consumer application;
2. builds the Simulator consumer for both arm64 and x86_64;
3. selects an available Simulator without creating or deleting devices, boots it
   only when needed, and restores a simulator it booted to Shutdown on exit;
4. executes XCTest and saves an `.xcresult` bundle;
5. rejects failed, skipped, or expected-failure results and verifies the exact
   three required test identifiers in the result tree;
6. checks the packaged privacy manifest in the archived application.

Before this remediation, the script created an unsigned archive and used
`build-for-testing`; those actions proved compilation/linking but never launched
the test bundle. The current script retains that archive/build evidence and adds
the executable runtime and fail-closed result-tree checks above.

Two independent executions against the rebuilt binary facade passed:

- XcodeBuildMCP `test_sim`: **3 passed, 0 failed, 0 skipped** on iPhone 17 Pro,
  iOS Simulator 26.5 (build 23F77). Result bundle:
  `~/Library/Developer/XcodeBuildMCP/workspaces/utexo-lightweight-6ce632ae8337/result-bundles/test_sim_2026-09-20T14-11-41-267Z_pid59566_719e99e1.xcresult`.
- `bash Scripts/verify-apple-consumer.sh`: **3 passed, 0 failed, 0 skipped,
  0 expected failures** on the same target. Evidence directory:
  `.build/apple-consumer.DQHz79`; result bundle:
  `.build/apple-consumer.DQHz79/simulator-tests.xcresult`.

The second run confirmed that the selected simulator returned to its pre-run
Shutdown state. The application target retains the package's iOS 15 deployment
target; the available host supplied only iOS 26.5, so this is compile/archive
evidence for iOS 15 and runtime evidence for iOS 26.5, not minimum-OS execution.

Both runtime passes linked the rebuilt `Artifacts/RGBSDK.xcframework`. Its facade
input/output receipt is `NativeSource/facade-build.json`, the encompassing file
manifest is `NativeSource/artifact-manifest.json`, and the corresponding build
snapshot is `.build/facade-stage.5ZSipX/inputs.json`. The receipt records source
hash `220215e9c2b035f05fdf56065a5a8d542895d488f34296d9978b2d08b86e98b3`
for `EncryptedOperationJournal.swift` and these executable hashes:

```text
iOS arm64:                  c7da520536c9cd44e8ca1ba2e1d7a31ddb43568af8c25a4e67251180a2f5304f
iOS Simulator arm64+x86_64: 8550cfd11582291f23ddaa42f2e6642a502e5d651f928a1a40c4b5f0f2e41efc
macOS arm64+x86_64:          ea533f4f99693ffa0bc6d7f1a57f7006c31f987aa17929d42d2a64c382d25560
```

## S5: encrypted journal failure and boundary coverage

The journal has an internal, default-disabled file-operation fault seam. Tests can
fail immediately before temporary-file creation, write, file `fsync`, Apple
`F_FULLFSYNC`, atomic rename, and directory `fsync`. No public declaration or
ordinary construction path exposes the seam.

The new deterministic matrix injects ENOSPC or EIO at every point and verifies:

- the previously committed checkpoint remains readable;
- the write-ahead Keychain anchor remains pending after the interrupted save;
- restart accepts the old file before rename or the new file after rename;
- recovery clears the pending anchor only after directory synchronization; and
- no `.pending-*` file remains.

Boundary tests prove both configured limits rather than using reduced fixtures:

- exactly **100,000** authenticated checkpoints open and the last record loads;
  adding checkpoint 100,001 is rejected;
- a separately authenticated 100,001-record snapshot remains below 64 MiB and is
  rejected at open by the count boundary;
- exactly **67,108,864 bytes (64 MiB)** of authenticated ciphertext opens;
  67,108,865 bytes is rejected before allocation/decryption.

Fresh full-source verification, including real loopback transport tests, passed
**145/145** tests. The command used repository-local compiler/module caches and ran
outside the filesystem sandbox solely so the tests could bind localhost sockets:

```text
bash Scripts/verify-source.sh
```

One macOS host sample from the exact 100,000-record test reported:

```text
ciphertextBytes=25254191
totalSeconds=1.5486390590667725
openSeconds=0.12397408485412598
residentBefore=179011584
residentAfter=321323008
```

These numbers are diagnostic observations, not a latency or memory SLA. They are
macOS measurements from one run and include allocator/process effects.

## Claims deliberately not made

- No physical-device, minimum-iOS-runtime, Secure Enclave, distribution-signing,
  restore, or App Store qualification was performed.
- The fault seam deterministically exercises the journal's error branches; it is
  not a real full-disk, filesystem corruption, process-kill, power-loss, or flash
  durability campaign.
- The maximum-history performance sample is not constrained-device evidence.
- These results close executable backend-independent S4/S5 gaps only. They do not
  close missing backend contracts, disabled/unsupported wallet operations,
  gateway-to-local migration, release signing/provenance, or independent security
  review requirements.
