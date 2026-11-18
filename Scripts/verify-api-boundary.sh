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

# require_unavailable <negative-consumer-target> <private-module> <what-leaked>
require_unavailable() {
    local target="$1" module="$2" leak="$3" log="${PROBE_DIR}/$1.log"
    if swift build --disable-sandbox --package-path "${FIXTURE_DIR}" --target "${target}" \
        --scratch-path "${PROBE_DIR}/build" > "${log}" 2>&1; then
        echo "error: ${leak}" >&2
        exit 1
    fi
    if ! rg -q "no such module '${module}'|unable to resolve module dependency: '${module}'" "${log}"; then
        echo "error: ${target} failed for an unexpected reason" >&2
        cat "${log}" >&2
        exit 1
    fi
}

require_unavailable ForbiddenBindingsConsumer UtexoLocalSignerBindings \
    "generated UniFFI Swift API is externally callable"
require_unavailable ForbiddenFFIConsumer UtexoLocalSignerFFI \
    "raw C FFI module remains transitively importable"
require_unavailable ForbiddenVerifierBindingsConsumer UtexoRgbVerifierBindings \
    "generated RGB verifier Swift API is externally callable"
require_unavailable ForbiddenVerifierFFIConsumer UtexoRgbVerifierFFI \
    "raw RGB verifier C FFI module remains transitively importable"

echo "Facade consumer runs; private Swift and raw C modules are unavailable. Logs: ${PROBE_DIR}"
