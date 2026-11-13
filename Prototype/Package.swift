// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClashPrototype",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "ClashPrototype",
            path: "Sources/ClashPrototype"
        )
    ]
)
