// swift-tools-version: 6.0
//
// SHARED-DEPS distribution note for Swift Package Manager.
//
// The slim DigiaEngage.xcframework (built by Scripts/build-shared-xcframework.sh)
// records its dependencies as DYNAMIC @rpath references:
//     @rpath/Lottie.framework/Lottie
//     @rpath/SDWebImage.framework/SDWebImage
//     @rpath/SDWebImageSVGCoder.framework/SDWebImageSVGCoder
//     @rpath/SDWebImageSwiftUI.framework/SDWebImageSwiftUI
//
// SPM links its package products STATICALLY by default, so those .framework
// dylibs do not exist at runtime -> a .binaryTarget here would crash with
// "Library not loaded: @rpath/Lottie.framework/Lottie".
//
// Therefore, for SPM, KEEP THE SOURCE-BASED Package.swift (it already shares the
// deps correctly via SPM resolution and has no co-linking crash to fix on the
// SPM side). The slim binary distribution is for CocoaPods (see
// DigiaEngage-binary.podspec), where use_frameworks! :linkage => :dynamic makes
// the deps real dynamic frameworks that satisfy the @rpath references.
//
// (If a binary SPM distribution is ever required, the deps must also be shipped
//  as dynamic xcframeworks and wired as a companion target — at which point the
//  CocoaPods + source-SPM split below is simpler to maintain.)
import PackageDescription

let package = Package(
    name: "DigiaEngage",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "DigiaEngage", targets: ["DigiaEngage"]),
    ],
    dependencies: [
        .package(url: "https://github.com/airbnb/lottie-ios.git", from: "4.5.0"),
        .package(url: "https://github.com/SDWebImage/SDWebImageSwiftUI.git", from: "3.1.4"),
        .package(url: "https://github.com/SDWebImage/SDWebImageSVGCoder.git", from: "1.8.0"),
    ],
    targets: [
        .target(
            name: "DigiaEngage",
            dependencies: [
                .product(name: "Lottie", package: "lottie-ios"),
                .product(name: "SDWebImageSwiftUI", package: "SDWebImageSwiftUI"),
                .product(name: "SDWebImageSVGCoder", package: "SDWebImageSVGCoder"),
            ],
            path: "Sources/DigiaEngage"
        ),
    ]
)
