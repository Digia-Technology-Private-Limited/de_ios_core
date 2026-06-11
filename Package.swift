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
        .package(url: "https://github.com/Digia-Technology-Private-Limited/digia_expr_swift.git", from: "0.1.0"),
        .package(url: "https://github.com/airbnb/lottie-spm.git", from: "4.5.0"),
        .package(url: "https://github.com/SDWebImage/SDWebImageSwiftUI.git", from: "3.1.4"),
        .package(url: "https://github.com/SDWebImage/SDWebImageSVGCoder.git", from: "1.8.0"),
        .package(url: "https://github.com/elai950/AlertToast.git", from: "1.3.9"),
    ],
    targets: [
        .target(
            name: "DigiaEngage",
            dependencies: [
                .product(name: "DigiaExpr", package: "digia_expr_swift"),
                .product(name: "Lottie", package: "lottie-spm"),
                .product(name: "SDWebImageSwiftUI", package: "SDWebImageSwiftUI"),
                .product(name: "SDWebImageSVGCoder", package: "SDWebImageSVGCoder"),
                .product(name: "AlertToast", package: "AlertToast"),
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
