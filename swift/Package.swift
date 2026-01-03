// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "fm-proxy",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        .executableTarget(
            name: "fm-proxy",
            path: "Sources/fm-proxy"
        )
    ]
)
