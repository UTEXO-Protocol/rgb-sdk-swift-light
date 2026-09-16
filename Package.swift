// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "rgb-sdk-swift-light",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
    ],
    products: [
        .library(name: "RGBSDK", targets: ["RGBSDK"]),
    ],
    targets: [
        .binaryTarget(
            name: "UtexoLocalSignerFFI",
            path: "Artifacts/UtexoLocalSigner.xcframework"
        ),
        .target(
            name: "UtexoLocalSignerBindings",
            dependencies: ["UtexoLocalSignerFFI"],
            path: "Generated",
            exclude: [
                "UtexoLocalSignerFFI.h",
                "UtexoLocalSignerFFI.modulemap",
            ],
            sources: ["UtexoLocalSignerBindings.swift"]
        ),
        .target(
            name: "RGBSDK",
            dependencies: ["UtexoLocalSignerBindings"],
            path: "Sources/RGBSDK"
        ),
        .testTarget(
            name: "RGBSDKTests",
            dependencies: ["RGBSDK"],
            path: "Tests/RGBSDKTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
