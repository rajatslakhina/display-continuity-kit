// swift-tools-version: 6.0
import PackageDescription

// Platforms declared here are exactly the ones CI builds:
//   - `.iOS(.v17)`  is built by the macos-15 job via
//     `xcodebuild -destination 'generic/platform=iOS Simulator'`.
//   - `.macOS(.v14)` is what `swift build` / `swift test` resolve to when the
//     package is built natively on the macOS runner and on Linux CI.
// No watchOS / tvOS / visionOS declaration: CI does not build them, and a
// platform nobody compiles is a claim nobody has checked.
let package = Package(
    name: "DisplayContinuityKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        // Pure-Swift core. No SwiftUI, no UIKit, no platform conditionals:
        // this is the half that is fully testable headlessly, including on Linux.
        .library(name: "DisplayContinuity", targets: ["DisplayContinuity"]),
        // The SwiftUI projection layer. Deliberately thin — every decision it
        // renders was already made (and tested) in the core.
        .library(name: "DisplayContinuityUI", targets: ["DisplayContinuityUI"])
    ],
    targets: [
        .target(name: "DisplayContinuity"),
        .target(name: "DisplayContinuityUI", dependencies: ["DisplayContinuity"]),
        .testTarget(
            name: "DisplayContinuityTests",
            dependencies: ["DisplayContinuity"]
        )
    ],
    swiftLanguageModes: [.v6]
)
