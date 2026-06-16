// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DigiaEngage",
    platforms: [
        .iOS(.v17),
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
    ],
    targets: [
        .target(
            name: "DigiaEngage",
            dependencies: [
                .product(name: "Lottie", package: "lottie-spm"),
                .product(name: "SDWebImageSwiftUI", package: "SDWebImageSwiftUI"),
                .product(name: "SDWebImageSVGCoder", package: "SDWebImageSVGCoder"),
            ],
            path: "Sources/DigiaEngage"
        ),
        .testTarget(
            name: "DigiaEngageTests",
            dependencies: [
                "DigiaEngage",
            ],
            path: "Tests/DigiaEngageTests"
        ),
    ]
)
