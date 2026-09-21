#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SDK_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
mkdir -p "${SDK_DIR}/.build"
STAGE="$(mktemp -d "${SDK_DIR}/.build/source-stage.XXXXXX")"
cp "${SDK_DIR}/Package.source.swift" "${STAGE}/Package.swift"
cp -R "${SDK_DIR}/Sources" "${SDK_DIR}/Generated" "${STAGE}/"
mkdir -p "${STAGE}/Artifacts" "${STAGE}/Tests"
cp -R "${SDK_DIR}/Artifacts/UtexoLocalSigner.xcframework" "${STAGE}/Artifacts/"
cp -R "${SDK_DIR}/Tests/RGBSDKTests" "${STAGE}/Tests/"
echo "Verifying exact shipping sources using development manifest at ${STAGE}"
swift test --disable-sandbox --package-path "${STAGE}" "$@"
