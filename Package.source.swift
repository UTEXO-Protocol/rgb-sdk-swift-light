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
        .target(
            name: "RGBSDK", dependencies: ["UtexoLocalSignerBindings"], path: "Sources/RGBSDK",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(name: "RGBSDKTests", dependencies: ["RGBSDK"], path: "Tests/RGBSDKTests"),
    ],
    swiftLanguageModes: [.v6]
)
