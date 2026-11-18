// swift-tools-version: 6.0
// Development-only manifest. Scripts/verify-source.sh stages it as Package.swift
// alongside an exact source snapshot. Applications use the root binary manifest.
import PackageDescription

let package = Package(
    name: "rgb-sdk-swift-light",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [.library(name: "RGBSDK", targets: ["RGBSDK"])],
    targets: [
        .binaryTarget(name: "UtexoLocalSignerFFI", path: "Artifacts/UtexoLocalSigner.xcframework"),
        .target(
            name: "UtexoLocalSignerBindings", dependencies: ["UtexoLocalSignerFFI"],
            path: "Generated", exclude: ["UtexoLocalSignerFFI.h", "UtexoLocalSignerFFI.modulemap"],
            sources: ["UtexoLocalSignerBindings.swift"]
        ),
        // The pre-sign RGB verifier is a separate Rust library with its own bindings.
        .binaryTarget(name: "UtexoRgbVerifierFFI", path: "Artifacts/UtexoRgbVerifier.xcframework"),
        .target(
            name: "UtexoRgbVerifierBindings", dependencies: ["UtexoRgbVerifierFFI"],
            path: "GeneratedRgbVerifier", exclude: ["UtexoRgbVerifierFFI.h", "UtexoRgbVerifierFFI.modulemap"],
            sources: ["UtexoRgbVerifierBindings.swift"]
        ),
        .target(
            name: "RGBSDK", dependencies: ["UtexoLocalSignerBindings", "UtexoRgbVerifierBindings"],
            path: "Sources/RGBSDK", resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(name: "RGBSDKTests", dependencies: ["RGBSDK"], path: "Tests/RGBSDKTests"),
    ],
    swiftLanguageModes: [.v6]
)
