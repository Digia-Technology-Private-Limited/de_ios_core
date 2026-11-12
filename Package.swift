// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DigiaEngage",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(
            name: "DigiaEngage",
            targets: ["DigiaEngage"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/airbnb/lottie-spm.git", from: "4.5.0"),
        .package(url: "https://github.com/SDWebImage/SDWebImageSwiftUI.git", from: "3.1.4"),
        .package(url: "https://github.com/SDWebImage/SDWebImageSVGCoder.git", from: "1.8.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", from: "1.18.0"),
        // TODO(split-pin): the local cache checkout until DigiaMediaCache is tagged with the Xcode 26.6 fix.
        .package(name: "DigiaMediaCache", path: "../media-cache"),
    ],
    targets: [
        .target(
            name: "DigiaEngage",
            dependencies: [
                .product(name: "Lottie", package: "lottie-spm"),
                .product(name: "SDWebImageSwiftUI", package: "SDWebImageSwiftUI"),
                .product(name: "SDWebImageSVGCoder", package: "SDWebImageSVGCoder"),
                .product(name: "DigiaMediaCache", package: "DigiaMediaCache"),
                .product(name: "DigiaVideoEngine", package: "DigiaMediaCache"),
            ],
            path: "Sources/DigiaEngage",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "DigiaEngageTests",
            dependencies: [
                "DigiaEngage",
                .product(name: "DigiaVideoEngine", package: "DigiaMediaCache"),
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            path: "Tests/DigiaEngageTests"
        ),
    ]
)
