#!/usr/bin/env bash
set -euo pipefail

# Build the complete public Swift facade, not a redistributable raw C module.
# Staging is retained for diagnosis; the old artifact is replaced only after
# every platform/architecture and textual interface has compiled successfully.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SDK_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
if [[ "$(xcodebuild -version)" != $'Xcode 27.0\nBuild version 27A266a' ]]; then
    echo "error: facade builds require the reviewed Xcode 27.0 (27A266a) toolchain" >&2
    exit 1
fi
mkdir -p "${SDK_DIR}/.build"
STAGE="$(mktemp -d "${SDK_DIR}/.build/facade-stage.XXXXXX")"
node "${SCRIPT_DIR}/facade-provenance.mjs" --snapshot "${STAGE}/inputs.json"
NATIVE="${SDK_DIR}/Artifacts/UtexoLocalSigner.xcframework"
OUTPUT="${SDK_DIR}/Artifacts/RGBSDK.xcframework"
export SWIFT_MODULECACHE_PATH="${STAGE}/module-cache"
export CLANG_MODULE_CACHE_PATH="${STAGE}/clang-cache"
# Keep archive member timestamps out of libtool output. This supports repeatable
# builds; it is not a substitute for an independent reproduction/attestation.
export ZERO_AR_DATE=1

build_arch() {
    local sdk="$1" triple="$2" slice="$3" arch="$4" platform="$5" minimum="$6"
    local work="${STAGE}/${triple}" sdk_path framework native_library
    sdk_path="$(xcrun --sdk "${sdk}" --show-sdk-path)"
    framework="${STAGE}/${slice}/RGBSDK.framework"
    mkdir -p "${work}" "${framework}/Modules/RGBSDK.swiftmodule"
    native_library="${work}/native.a"
    if [[ "$(lipo -archs "${NATIVE}/${slice}/libutexo_local_signer.a")" == "${arch}" ]]; then
        cp "${NATIVE}/${slice}/libutexo_local_signer.a" "${native_library}"
    else
        lipo "${NATIVE}/${slice}/libutexo_local_signer.a" -thin "${arch}" -output "${native_library}"
    fi
    local common=(-target "${triple}" -sdk "${sdk_path}" -swift-version 6 -O
        -parse-as-library -whole-module-optimization -enable-library-evolution
        -package-name UtexoSDKBuild -module-cache-path "${SWIFT_MODULECACHE_PATH}"
        -debug-prefix-map "${SDK_DIR}=/utexo/rgb-sdk-swift-light")
    xcrun swiftc "${common[@]}" -module-name UtexoLocalSignerBindings \
        -I "${NATIVE}/${slice}/Headers" \
        -emit-module -emit-module-path "${work}/UtexoLocalSignerBindings.swiftmodule" \
        -emit-object -o "${work}/Bindings.o" "${SDK_DIR}/Generated/UtexoLocalSignerBindings.swift"
    xcrun swiftc "${common[@]}" -module-name RGBSDK -I "${work}" \
        -I "${NATIVE}/${slice}/Headers" \
        -emit-module -emit-module-path "${work}/RGBSDK.swiftmodule" \
        -emit-module-interface-path "${work}/RGBSDK.swiftinterface" \
        -emit-object -o "${work}/RGBSDK.o" "${SDK_DIR}"/Sources/RGBSDK/*.swift
    # Ship only self-contained public textual interfaces, never serialized
    # compiler modules/private interfaces that refer to internal build modules.
    if rg -q 'UtexoLocalSigner|@testable|@_spi' "${work}/RGBSDK.swiftinterface"; then
        echo "error: implementation API leaked into public Swift interface" >&2
        exit 1
    fi
    local module_triple
    module_triple="${arch}-apple-${platform}"
    cp "${work}/RGBSDK.swiftinterface" "${framework}/Modules/RGBSDK.swiftmodule/${module_triple}.swiftinterface"
    xcrun libtool -static -o "${work}/RGBSDK.a" \
        "${work}/RGBSDK.o" "${work}/Bindings.o" "${native_library}"
    cp "${SDK_DIR}/Sources/RGBSDK/PrivacyInfo.xcprivacy" "${framework}/PrivacyInfo.xcprivacy"
    /usr/libexec/PlistBuddy -c 'Clear dict' -c 'Add :CFBundleIdentifier string org.utexo.RGBSDK' \
        -c 'Add :CFBundleName string RGBSDK' -c 'Add :CFBundleExecutable string RGBSDK' \
        -c 'Add :CFBundlePackageType string FMWK' -c 'Add :CFBundleVersion string 1' \
        -c 'Add :CFBundleShortVersionString string 0.1.0' \
        -c "Add :MinimumOSVersion string ${minimum}" "${framework}/Info.plist"
}

build_arch macosx arm64-apple-macosx13.0 macos-arm64_x86_64 arm64 macos 13.0
build_arch macosx x86_64-apple-macosx13.0 macos-arm64_x86_64 x86_64 macos 13.0
build_arch iphoneos arm64-apple-ios15.0 ios-arm64 arm64 ios 15.0
build_arch iphonesimulator arm64-apple-ios15.0-simulator ios-arm64_x86_64-simulator arm64 ios-simulator 15.0
build_arch iphonesimulator x86_64-apple-ios15.0-simulator ios-arm64_x86_64-simulator x86_64 ios-simulator 15.0

lipo -create "${STAGE}/arm64-apple-macosx13.0/RGBSDK.a" "${STAGE}/x86_64-apple-macosx13.0/RGBSDK.a" \
    -output "${STAGE}/macos-arm64_x86_64/RGBSDK.framework/RGBSDK"
cp "${STAGE}/arm64-apple-ios15.0/RGBSDK.a" "${STAGE}/ios-arm64/RGBSDK.framework/RGBSDK"
lipo -create "${STAGE}/arm64-apple-ios15.0-simulator/RGBSDK.a" "${STAGE}/x86_64-apple-ios15.0-simulator/RGBSDK.a" \
    -output "${STAGE}/ios-arm64_x86_64-simulator/RGBSDK.framework/RGBSDK"
xcodebuild -create-xcframework \
    -framework "${STAGE}/macos-arm64_x86_64/RGBSDK.framework" \
    -framework "${STAGE}/ios-arm64/RGBSDK.framework" \
    -framework "${STAGE}/ios-arm64_x86_64-simulator/RGBSDK.framework" \
    -output "${STAGE}/RGBSDK.xcframework"
plutil -lint "${STAGE}/RGBSDK.xcframework/Info.plist"
if [[ -e "${OUTPUT}" ]]; then mv "${OUTPUT}" "${STAGE}/previous-RGBSDK.xcframework"; fi
mv "${STAGE}/RGBSDK.xcframework" "${OUTPUT}"
node "${SCRIPT_DIR}/facade-provenance.mjs" --record "${STAGE}/inputs.json"
echo "Facade built from the current source into ${OUTPUT}; build evidence retained in ${STAGE}."
