// swift-tools-version:5.9
//
// THE GRAINE IN-APP AGENT, FOR NATIVE iOS.
//
// No dependencies, on purpose: this drops into a bank's app next to whatever
// that app already ships, and every dependency is a version conflict waiting
// for the release that matters.
//
// The pure logic (Sources/GraineInApp/Core) imports only Foundation, so
// `swift test` runs the contract, parity and core tests on a Mac with no
// simulator. Everything that touches UIKit, WebKit or SwiftUI is compiled for
// iOS (and Mac Catalyst) only. Tests use swift-testing; see README.md for the
// command that runs them with only the Command Line Tools installed.
import PackageDescription

let package = Package(
    name: "GraineInApp",
    platforms: [
        .iOS(.v15),
        .macCatalyst(.v15),
        // The Mac only runs the tests (the pure logic); swift-testing needs macOS 14.
        .macOS(.v14),
    ],
    products: [
        .library(name: "GraineInApp", targets: ["GraineInApp"]),
    ],
    targets: [
        .target(
            name: "GraineInApp",
            path: "Sources/GraineInApp",
            // The privacy manifest: the required-reason APIs the SDK calls
            // (systemUptime for timing, UserDefaults for the calls' settings).
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "GraineInAppTests",
            dependencies: ["GraineInApp"],
            path: "Tests/GraineInAppTests"
        ),
    ]
)
