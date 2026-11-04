// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "urlqueue",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "urlqueue",
            path: "Sources/urlqueue"
        )
    ]
)
