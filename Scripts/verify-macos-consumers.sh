#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SDK_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
mkdir -p "${SDK_DIR}/.build"
STAGE="$(mktemp -d "${SDK_DIR}/.build/macos-consumer.XXXXXX")"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
for architecture in arm64 x86_64; do
    xcrun swiftc -swift-version 6 -O -target "${architecture}-apple-macosx13.0" \
        -sdk "${SDK_PATH}" -module-cache-path "${STAGE}/module-cache" \
        -F "${SDK_DIR}/Artifacts/RGBSDK.xcframework/macos-arm64_x86_64" \
        -framework RGBSDK "${SDK_DIR}/Tests/ExternalConsumerFixture/Sources/FacadeConsumer/main.swift" \
        -o "${STAGE}/consumer-${architecture}"
done
"${STAGE}/consumer-$(uname -m)"
echo "Both macOS architectures link; the host architecture executes native derivation. Evidence: ${STAGE}"
