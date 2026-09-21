#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SDK_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
mkdir -p "${SDK_DIR}/.build"
STAGE="${UTEXO_APPLE_EVIDENCE_DIR:-$(mktemp -d "${SDK_DIR}/.build/apple-consumer.XXXXXX")}"
mkdir -p "${STAGE}"
PROJECT="${SDK_DIR}/Tests/AppleConsumerFixture/SDKConsumer.xcodeproj"
COMMON=(-quiet -project "${PROJECT}" -scheme SDKConsumer)
xcodebuild "${COMMON[@]}" CODE_SIGNING_ALLOWED=NO -destination 'generic/platform=iOS' \
    -derivedDataPath "${STAGE}/device" -archivePath "${STAGE}/SDKConsumer.xcarchive" archive
xcodebuild "${COMMON[@]}" CODE_SIGNING_ALLOWED=NO -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "${STAGE}/simulator" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build-for-testing

SIMULATOR_ID="${UTEXO_SIMULATOR_UDID:-}"
AVAILABLE_DEVICES="$(xcrun simctl list devices available)"
if [[ -z "${SIMULATOR_ID}" ]]; then
    SIMULATOR_ID="$(sed -nE '/iPhone.*\(Booted\)[[:space:]]*$/s/.*\(([0-9A-Fa-f-]{36})\) \(Booted\)[[:space:]]*$/\1/p' <<<"${AVAILABLE_DEVICES}" | head -n 1)"
fi
if [[ -z "${SIMULATOR_ID}" ]]; then
    SIMULATOR_ID="$(sed -nE '/iPhone.*\((Shutdown|Booted)\)[[:space:]]*$/s/.*\(([0-9A-Fa-f-]{36})\) \((Shutdown|Booted)\)[[:space:]]*$/\1/p' <<<"${AVAILABLE_DEVICES}" | head -n 1)"
fi
if [[ -z "${SIMULATOR_ID}" ]]; then
    SIMULATOR_ID="$(sed -nE '/.*\((Shutdown|Booted)\)[[:space:]]*$/s/.*\(([0-9A-Fa-f-]{36})\) \((Shutdown|Booted)\)[[:space:]]*$/\1/p' <<<"${AVAILABLE_DEVICES}" | head -n 1)"
fi
if [[ -z "${SIMULATOR_ID}" ]] || ! grep -Fq "${SIMULATOR_ID}" <<<"${AVAILABLE_DEVICES}"; then
    echo "No available iOS Simulator matches UTEXO_SIMULATOR_UDID='${SIMULATOR_ID}'." >&2
    exit 1
fi

STARTED_SIMULATOR=0
if ! grep -E "${SIMULATOR_ID}.*\(Booted\)[[:space:]]*$" <<<"${AVAILABLE_DEVICES}" >/dev/null; then
    xcrun simctl boot "${SIMULATOR_ID}"
    STARTED_SIMULATOR=1
fi
cleanup() {
    if [[ "${STARTED_SIMULATOR}" == 1 && "${UTEXO_KEEP_SIMULATOR_BOOTED:-0}" != 1 ]]; then
        xcrun simctl shutdown "${SIMULATOR_ID}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT
xcrun simctl bootstatus "${SIMULATOR_ID}" -b

RESULT_BUNDLE="${STAGE}/simulator-tests.xcresult"
xcodebuild "${COMMON[@]}" -destination "platform=iOS Simulator,id=${SIMULATOR_ID}" \
    -derivedDataPath "${STAGE}/simulator-runtime" -resultBundlePath "${RESULT_BUNDLE}" test
xcrun xcresulttool get test-results summary --path "${RESULT_BUNDLE}" --format json \
    > "${STAGE}/simulator-test-summary.json"
xcrun xcresulttool get test-results tests --path "${RESULT_BUNDLE}" --format json \
    > "${STAGE}/simulator-test-tree.json"
node - "${STAGE}/simulator-test-summary.json" "${STAGE}/simulator-test-tree.json" <<'NODE'
const fs = require('fs');
const summary = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const tree = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const passed = Number(summary.passedTests ?? summary.testsPassed ?? 0);
const failed = Number(summary.failedTests ?? summary.testsFailed ?? 0);
const skipped = Number(summary.skippedTests ?? summary.testsSkipped ?? 0);
const expectedFailures = Number(summary.expectedFailures ?? 0);
const total = Number(summary.totalTestCount ?? passed + failed + skipped + expectedFailures);
if (
  ![passed, failed, skipped, expectedFailures, total].every(Number.isFinite)
  || passed < 3
  || failed !== 0
  || skipped !== 0
  || expectedFailures !== 0
  || total !== passed
  || summary.result !== 'Passed'
) {
  throw new Error(
    `Apple consumer suite was not completely green: result=${summary.result}, total=${total}, `
      + `passed=${passed}, failed=${failed}, skipped=${skipped}, expectedFailures=${expectedFailures}`
  );
}

const cases = new Map();
function collect(node) {
  if (node?.nodeType === 'Test Case' && typeof node.nodeIdentifier === 'string') {
    cases.set(node.nodeIdentifier, node.result);
  }
  for (const child of node?.children ?? []) collect(child);
}
for (const node of tree.testNodes ?? []) collect(node);
const required = [
  'SDKConsumerTests/testPublicNativeDerivationAndLiteralCompatibility()',
  'SDKConsumerTests/testRealKeychainRoundTripDuplicateAndExplicitDeletion()',
  'PublicGatewayConsumerTests/testOrdinaryFactoryHTTPWorkflowRotationAndReopen()',
];
const missingOrUnpassed = required.filter((identifier) => cases.get(identifier) !== 'Passed');
if (missingOrUnpassed.length !== 0) {
  throw new Error(
    `Required Apple consumer tests were absent or not passed: ${missingOrUnpassed.join(', ')}; `
      + `observed=${JSON.stringify(Object.fromEntries(cases))}`
  );
}
const nonPassingCases = [...cases].filter(([, result]) => result !== 'Passed');
if (nonPassingCases.length !== 0) {
  throw new Error(`Apple consumer test tree contains non-passing cases: ${JSON.stringify(nonPassingCases)}`);
}
console.log(
  `Executed required Apple consumer tests on Simulator: total=${total}, passed=${passed}, `
    + `failed=${failed}, skipped=${skipped}, expectedFailures=${expectedFailures}`
);
NODE
node "${SCRIPT_DIR}/verify-privacy.mjs" "${STAGE}/SDKConsumer.xcarchive/Products/Applications/SDKConsumer.app"
SIMULATOR_DESCRIPTION="$(xcrun simctl list devices available | grep -F "${SIMULATOR_ID}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
echo "Unsigned iOS device archive and arm64/x86_64 Simulator builds link the public package."
echo "Executed packaged native, real Keychain, and loopback public-factory tests on ${SIMULATOR_DESCRIPTION}."
echo "This is Simulator evidence only; it does not claim physical-device or minimum-iOS runtime qualification."
echo "Evidence: ${STAGE}"
