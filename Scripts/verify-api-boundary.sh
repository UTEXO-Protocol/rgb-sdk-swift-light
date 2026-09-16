#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SDK_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
FIXTURE_DIR="${SDK_DIR}/Tests/ExternalConsumerFixture"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-${FIXTURE_DIR}/.build/swift-module-cache}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${FIXTURE_DIR}/.build/clang-module-cache}"

swift build --disable-sandbox --package-path "${FIXTURE_DIR}" --target FacadeConsumer

if swift build --disable-sandbox --package-path "${FIXTURE_DIR}" --target ForbiddenBindingsConsumer \
    > /dev/null 2>&1; then
    echo "error: generated UniFFI Swift API is externally callable" >&2
    exit 1
fi

if swift build --disable-sandbox --package-path "${FIXTURE_DIR}" --target ForbiddenFFIConsumer \
    > /dev/null 2>&1; then
    echo "warning: raw C FFI module remains transitively importable; packaging release blocker" >&2
else
    echo "Raw C FFI module is not externally callable."
fi

echo "External consumer cannot call the generated Swift bindings."
