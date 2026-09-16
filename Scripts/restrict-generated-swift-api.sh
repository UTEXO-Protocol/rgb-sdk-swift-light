#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <generated-swift-bindings>" >&2
    exit 64
fi

BINDINGS_FILE="$1"
if [[ ! -f "${BINDINGS_FILE}" ]]; then
    echo "error: generated Swift bindings not found: ${BINDINGS_FILE}" >&2
    exit 66
fi

# UniFFI intentionally emits a public standalone SDK. In this package the
# generated module is an implementation detail behind RGBSDK, so Swift's
# package access level is the enforceable boundary shared by its targets.
perl -pi -e 's/^(\s*)public\b/${1}package/; s/^(\s*)open\b/${1}package/; s/^(\s*required\s+)public\b/${1}package/' \
    "${BINDINGS_FILE}"

if grep -Eq '^[[:space:]]*(public|open)[[:space:]]|^[[:space:]]*required[[:space:]]+public[[:space:]]' \
    "${BINDINGS_FILE}"; then
    echo "error: generated Swift bindings still contain exported declarations" >&2
    exit 1
fi
