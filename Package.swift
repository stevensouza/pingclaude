// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "PingClaude",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "PingClaude",
            path: "Sources/PingClaude",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)
