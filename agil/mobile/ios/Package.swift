// swift-tools-version:5.7
//
// AgilFrame iOS SDK (tier-1 native UI module).
//
// The package is a thin, dependency-free WKWebView host for the hosted
// `/embed.html` widget. It requires iOS 14.3 because that is the first iOS
// release with `getUserMedia` support in WKWebView.
import PackageDescription

let package = Package(
    name: "AgilCallsSDK",
    platforms: [
        .iOS("14.3")
    ],
    products: [
        .library(
            name: "AgilCallsSDK",
            targets: ["AgilCallsSDK"]
        )
    ],
    targets: [
        .target(
            name: "AgilCallsSDK",
            path: "Sources/AgilCallsSDK",
            resources: [
                // App Store privacy manifest (no data collection, no tracking).
                .copy("PrivacyInfo.xcprivacy")
            ]
        ),
        .testTarget(
            name: "AgilCallsSDKTests",
            dependencies: ["AgilCallsSDK"],
            path: "Tests/AgilCallsSDKTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
