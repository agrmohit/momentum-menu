// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MomentumMenu",
    platforms: [.macOS(.v14)],
    targets: [
        // Protocol, transport and device state. No UI, so it can be unit tested.
        .target(name: "M4Core", path: "Sources/M4Core"),

        // The menu bar app itself.
        .executableTarget(
            name: "MomentumMenu",
            dependencies: ["M4Core"],
            path: "Sources/MomentumMenu"
        ),

        .testTarget(
            name: "MomentumMenuTests",
            dependencies: ["M4Core"],
            path: "Tests/MomentumMenuTests"
        ),
    ]
)
