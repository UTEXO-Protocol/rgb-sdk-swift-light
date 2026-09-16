# Native signer artifact provenance

The checked-in `UtexoLocalSigner.xcframework` was built from
`utexo-local-signer` 0.1.0 with its locked dependency graph. The native source
is maintained as the shared signer core alongside the Swift and Kotlin SDK
repositories; it is not duplicated in this repository.

Build inputs for this snapshot:

- Rust 1.88.0 (`6b00bc3880198600130e1cf62b8f8a93494488cc`)
- Cargo lockfile SHA-256:
  `0a23166791ea9724859b48d72c97be16ea8699c3ef74c48004cde44a8be8fc3d`
- Xcode 26.6 (`17F113`)
- macOS deployment target 13.0
- iOS deployment target 15.0
- Cargo release profile with locked dependencies, thin LTO, one codegen unit,
  and stripped symbols
- Rust and C source paths remapped so build-machine paths are not embedded in
  the distributed archives

SHA-256 checksums:

```text
96109cfd1b81e0db81334d5644a118cce9e5a80f76bf4d6f1a08670c611f66ca  Artifacts/UtexoLocalSigner.xcframework/ios-arm64/libutexo_local_signer.a
1236c9bbe763a42299bfda4065fc325a3a5bf05eddce5878aeeaf5ba6b243e2d  Artifacts/UtexoLocalSigner.xcframework/ios-arm64_x86_64-simulator/libutexo_local_signer.a
3b7d759b73ae07c07cbd0edbd87528e8d0a8d0d95236427c10bcb40748432829  Artifacts/UtexoLocalSigner.xcframework/macos-arm64_x86_64/libutexo_local_signer.a
```

These checksums identify this source snapshot; they are not a signed release
attestation. Do not publish a production release until the packaging and
security gates in `README.md` and `SECURITY.md` are closed.
