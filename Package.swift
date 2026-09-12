// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UsageNow",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "UsageNow", targets: ["UsageNow"]),
    ],
    targets: [
        .executableTarget(
            name: "UsageNow",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "UsageNowTests",
            dependencies: ["UsageNow"]
        ),
    ]
)
