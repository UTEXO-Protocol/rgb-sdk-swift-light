// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RGBSDKExternalConsumerFixture",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "FacadeConsumer",
            dependencies: [
                .product(name: "RGBSDK", package: "rgb-sdk-swift-light"),
            ]
        ),
        .executableTarget(
            name: "ForbiddenBindingsConsumer",
            dependencies: [
                .product(name: "RGBSDK", package: "rgb-sdk-swift-light"),
            ]
        ),
        .executableTarget(
            name: "ForbiddenFFIConsumer",
            dependencies: [
                .product(name: "RGBSDK", package: "rgb-sdk-swift-light"),
            ]
        ),
    ]
)
