// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KillTheBill",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "KillTheBill",
            path: "Sources/KillTheBill"
        ),
        .testTarget(
            name: "KillTheBillTests",
            dependencies: ["KillTheBill"],
            path: "Tests/KillTheBillTests"
        ),
    ]
)
