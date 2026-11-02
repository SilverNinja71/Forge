// swift-tools-version: 6.0
import PackageDescription
import Foundation

// One package, several products:
//   CommonKit   – this repo's own copy of the Universal Cloud Sync Engine.
//   ForgeCore   – everything in the Forge parametric CAD app; the Mac app is a thin shell over it.
//
// CommonKit is written in the strict Swift 6 language mode. The Metal/SwiftUI app code uses Swift 5
// mode (still compiled by the Swift 6 compiler) because Metal objects are not Sendable.
//
// Set COMMON_ONLY=1 to build and test just CommonKit (handy while the app targets are mid-edit).
let commonOnly = ProcessInfo.processInfo.environment["COMMON_ONLY"] != nil

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

var products: [Product] = [.library(name: "CommonKit", targets: ["CommonKit"])]
var targets: [Target] = [
    .target(name: "CommonKit", path: "Sources/Common"),
    .testTarget(name: "CommonKitTests", dependencies: ["CommonKit"], path: "Tests/CommonKitTests"),
]

if !commonOnly {
    products += [
        .library(name: "ForgeCore", targets: ["ForgeCore"]),
        .executable(name: "Forge", targets: ["ForgeMac"]),
        .executable(name: "ForgeSnapshots", targets: ["ForgeSnapshots"]),
    ]
    targets += [
        .target(name: "ForgeCore", dependencies: ["CommonKit"], path: "Sources/Forge", swiftSettings: swift5),
        .executableTarget(name: "ForgeMac", dependencies: ["ForgeCore"], path: "Sources/ForgeMac",
                          swiftSettings: swift5 + [.unsafeFlags(["-parse-as-library"])]),
        .executableTarget(name: "ForgeSnapshots", dependencies: ["ForgeCore"], path: "Sources/ForgeSnapshots",
                          swiftSettings: swift5),
        .testTarget(name: "ForgeCoreTests", dependencies: ["ForgeCore"], path: "Tests/ForgeCoreTests",
                    swiftSettings: swift5),
    ]
}

let package = Package(
    name: "Forge",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: products,
    targets: targets
)
