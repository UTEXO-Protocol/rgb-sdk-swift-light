#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SDK_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
BASELINE="${SDK_DIR}/API/RGBSDK.macos.json"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-${SDK_DIR}/.build/swift-module-cache}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${SDK_DIR}/.build/clang-module-cache}"

if [[ $# -gt 1 || ($# -eq 1 && "$1" != "--update-baseline") ]]; then
    echo "usage: $0 [--update-baseline]" >&2
    exit 2
fi

# Read the actual distributed binary facade, not an assumed SwiftPM build layout.
# Textual module interfaces also prove the consumer needs no private C module.
FRAMEWORK_DIR="${SDK_DIR}/Artifacts/RGBSDK.xcframework/macos-arm64_x86_64"
test -d "${FRAMEWORK_DIR}/RGBSDK.framework/Modules/RGBSDK.swiftmodule"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
TARGET_ARCH="$(uname -m)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/utexo-api-check.XXXXXX")"
trap 'rm -f -- "${TEMP_DIR}/RGBSDK.json" "${TEMP_DIR}/negative.json"; rmdir "${TEMP_DIR}" 2>/dev/null || true' EXIT
CURRENT="${TEMP_DIR}/RGBSDK.json"

xcrun swift-api-digester -dump-sdk -module RGBSDK -swift-only \
    -avoid-location -avoid-tool-args -abort-on-module-fail \
    -target "${TARGET_ARCH}-apple-macosx13.0" -sdk "${SDK_PATH}" \
    -module-cache-path "${SWIFT_MODULECACHE_PATH}" \
    -F "${FRAMEWORK_DIR}" \
    -o "${CURRENT}"

if [[ "${1:-}" == "--update-baseline" ]]; then
    mkdir -p "${SDK_DIR}/API"
    cp "${CURRENT}" "${BASELINE}"
    echo "Updated source API baseline. Review and commit the diff with the API change."
else
    # Without -error-on-abi-breakage, some Swift versions report a source removal
    # but still exit zero. This flag was verified against a removed UTEXOWallet.
    xcrun swift-api-digester -diagnose-sdk -error-on-abi-breakage -compiler-style-diags \
        -swift-only -disable-os-checks \
        -ignore-spi-group Backend -input-paths "${BASELINE}" -input-paths "${CURRENT}"
    echo "Ordinary Swift public source API is compatible with the checked-in baseline."
    node "${SCRIPT_DIR}/verify-api-negative.mjs" "${BASELINE}" "${CURRENT}" "${TEMP_DIR}/negative.json"
fi
rm "${CURRENT}"
