// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Revive",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Revive",
            path: "Sources/Revive"
        ),
        .testTarget(
            name: "ReviveTests",
            dependencies: ["Revive"],
            path: "Tests/ReviveTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
