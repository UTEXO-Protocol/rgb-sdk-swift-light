#!/usr/bin/env bash
set -euo pipefail

# There is no development bypass: applications must only see the facade.
if [[ "$#" -ne 0 ]]; then
    echo "usage: $0" >&2
    exit 2
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SDK_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
FIXTURE_DIR="${SDK_DIR}/Tests/ExternalConsumerFixture"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-${FIXTURE_DIR}/.build/swift-module-cache}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${FIXTURE_DIR}/.build/clang-module-cache}"

PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/utexo-boundary.XXXXXX")"
swift run --disable-sandbox --package-path "${FIXTURE_DIR}" \
    --scratch-path "${PROBE_DIR}/build" FacadeConsumer

if swift build --disable-sandbox --package-path "${FIXTURE_DIR}" --target ForbiddenBindingsConsumer \
    --scratch-path "${PROBE_DIR}/build" > "${PROBE_DIR}/bindings.log" 2>&1; then
    echo "error: generated UniFFI Swift API is externally callable" >&2
    exit 1
fi
if ! rg -q "no such module 'UtexoLocalSignerBindings'|unable to resolve module dependency: 'UtexoLocalSignerBindings'" "${PROBE_DIR}/bindings.log"; then
    echo "error: wrapper negative consumer failed for an unexpected reason" >&2
    cat "${PROBE_DIR}/bindings.log" >&2
    exit 1
fi

if swift build --disable-sandbox --package-path "${FIXTURE_DIR}" --target ForbiddenFFIConsumer \
    --scratch-path "${PROBE_DIR}/build" > "${PROBE_DIR}/ffi.log" 2>&1; then
    echo "error: raw C FFI module remains transitively importable" >&2
    exit 1
fi
if ! rg -q "no such module 'UtexoLocalSignerFFI'|unable to resolve module dependency: 'UtexoLocalSignerFFI'" "${PROBE_DIR}/ffi.log"; then
    echo "error: raw C negative consumer failed for an unexpected reason" >&2
    cat "${PROBE_DIR}/ffi.log" >&2
    exit 1
fi

echo "Facade consumer runs; private Swift and raw C modules are unavailable. Logs: ${PROBE_DIR}"
