# Native and facade artifact provenance

Applications link the `RGBSDK` product from `Artifacts/RGBSDK.xcframework`.
It contains the Swift facade, private UniFFI bindings and the Rust signer.
The root package does not expose the private `UtexoLocalSignerFFI` or
`UtexoLocalSignerBindings` modules. The separate raw native archive and generated
sources remain in this repository for rebuilding and independent inspection.

## Three distinct records

1. **Native binary build inputs.** `NativeSource/native-build.json` records exact
   toolchain, Cargo lock/source inputs and produced native archives. The relevant
   files are included in `NativeSource/SHA256SUMS`; do not infer a binary rebuild
   from a later source archive or a passing source-only test run.
2. **Source/assurance snapshot.** `NativeSource/utexo-local-signer-source.tar.gz`
   packages the current Rust source, locked dependencies, tests and build scripts.
   Its canonical checksum is in `NativeSource/SHA256SUMS`, not duplicated here.
   Adding tests or tooling can change this snapshot without changing production
   native code; such a change must not be relabeled as new binary provenance.
3. **Complete Swift facade build.** `NativeSource/facade-build.json` records all
   facade source files, generated bindings, complete raw native input tree,
   build scripts, exact Xcode/Swift versions, and complete resulting framework
   tree hashes. `Scripts/build-facade.sh` rejects input changes during a build.
   `node Scripts/facade-provenance.mjs --check` rejects source/output drift and
   never overwrites the evidence to make a check pass.

This separation supersedes older prose that named a 2026-09-18 source archive
and Cargo lock hash as if they described every later assurance snapshot.
Canonical generated records, not hand-copied hashes in Markdown, identify the
artifacts checked out by the consumer.

## Rebuild and verify

The shared core is `utexo-local-signer` 0.1.0. Its source archive includes the
locked Rust graph and the platform packaging scripts. Extract it into a fresh
temporary directory and run `cargo test --locked` to audit the core independently.
The platform packaging scripts use the documented three-directory workspace:
`shared/utexo-local-signer`, `rgb-sdk-swift-light`, `rgb-sdk-kotlin-light`.

After rebuilding/regenerating the shared native core, from this repository run:

```sh
bash Scripts/verify-source.sh
bash Scripts/verify-source.sh --configuration release -Xswiftc -warnings-as-errors
bash Scripts/build-facade.sh
node Scripts/facade-provenance.mjs --check
bash Scripts/verify-api-boundary.sh
bash Scripts/verify-public-api.sh
bash Scripts/verify-macos-consumers.sh
bash Scripts/verify-apple-consumer.sh
shasum -a 256 -c NativeSource/SHA256SUMS
```

The facade is compiled with Swift 6 strict concurrency, library evolution,
optimization and whole-module optimization. It preserves iOS 15 and macOS 13
deployment targets, and includes iOS arm64, simulator arm64/x86_64 and macOS
arm64/x86_64. Only self-contained public textual interfaces are shipped; private
compiler modules and C headers are not part of the facade distribution.

## RGB send verifier

The facade also calls `utexo-rgb-verifier`, a second Rust library, before it
signs an RGB send. Its generated Swift binding, C header and module map are in
`GeneratedRgbVerifier/`, kept apart from `Generated/` because the signer's
build receipt hashes that whole directory as its own input. The binding is
restricted to `package` access like the signer's. The crate's source is bundled
as [NativeSource/utexo-rgb-verifier-source.tar.gz](NativeSource/utexo-rgb-verifier-source.tar.gz),
and `SHA256SUMS` lists these four files.

`Artifacts/UtexoRgbVerifier.xcframework` is not checked in yet. Apple libraries
can only be built on macOS, and this integration was written on Linux. Until it
is built, `Scripts/verify-source.sh`, `Scripts/build-facade.sh` and
`node Scripts/facade-provenance.mjs --check` fail on the missing input, and the
checked-in `RGBSDK.xcframework` contains neither the verifier nor the RGB send
evidence checks. To build it, extract the source archive and run, from the crate:

```sh
scripts/build-apple.sh /path/to/rgb-sdk-swift-light/Artifacts
```

Then run the rebuild steps above. `LocalSigningPolicy` gains
`allowUnverifiedRGBSends`, so `Scripts/verify-public-api.sh` needs
`--update-baseline` after the facade is rebuilt. `scripts/build-apple.sh` has not been run
yet, so treat its first run as its test. It prelinks each slice into one object
that exports only the verifier's UniFFI symbols, and fails if any other symbol
is still global. Both Rust libraries embed libsecp256k1, so without that step
the facade's static archive defines those symbols twice.

The verifier has less evidence than the signer. `artifact-manifest.json`,
`native-build.json`, the SBOM, the notices and the license review describe the
signer only. None of them covers the verifier's RGB dependencies
(`rgb-consensus`, `rgb-ops` and `rgb-invoicing` 0.11.2-rc.1,
`rgb-strict-encoding`, `amplify`).

`NativeSource/dependencies.json` is the Cargo source/build/test dependency
inventory and license metadata, not proof of completed vulnerability or legal
review. Local checksums and locally recorded build metadata are not signed
release attestations or independently reproduced artifact evidence. Read the
remaining deployment/security gates in `README.md`, `SECURITY.md` and `PRIVACY.md`.
