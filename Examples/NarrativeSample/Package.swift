// swift-tools-version:5.9
import PackageDescription

// A small narrative game skeleton that shows how to instrument runs,
// encounters, rerolls and progression with Ravensight. NarrativeKit is pure
// logic with no SDK dependency (so its rules are unit tested); the
// NarrativeSample executable is a SwiftUI front end that sends the events
// through the Ravensight package two directories up.
let package = Package(
    name: "NarrativeSample",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    dependencies: [
        .package(name: "Ravensight", path: "../.."),
    ],
    targets: [
        .target(name: "NarrativeKit"),
        .executableTarget(
            name: "NarrativeSample",
            dependencies: [
                "NarrativeKit",
                .product(name: "Ravensight", package: "Ravensight"),
            ]
        ),
        .testTarget(name: "NarrativeKitTests", dependencies: ["NarrativeKit"]),
    ]
)
