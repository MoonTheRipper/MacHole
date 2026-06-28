// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacHole",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MacHole",
            path: "Sources/MacHole",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
