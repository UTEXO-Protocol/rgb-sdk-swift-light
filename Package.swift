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
    // Only this facade is placed on application import/link paths. The private
    // native artifacts/source remain in the repository for reproducible audits;
    // Package.source.swift is staged by Scripts/verify-source.sh for development.
    targets: [.binaryTarget(name: "RGBSDK", path: "Artifacts/RGBSDK.xcframework")],
    swiftLanguageModes: [.v6]
)
