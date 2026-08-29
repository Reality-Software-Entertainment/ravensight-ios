// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ravensight",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "Ravensight", targets: ["Ravensight"]),
    ],
    targets: [
        .target(
            name: "Ravensight",
            path: "Sources/Ravensight"
        ),
        .testTarget(
            name: "RavensightTests",
            dependencies: ["Ravensight"],
            path: "Tests/RavensightTests"
        ),
    ]
)
