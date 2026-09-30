// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LocalWrite",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "LocalWrite", targets: ["LocalWrite"])],
    targets: [
        .target(name: "LocalWriteCore"),
        .executableTarget(name: "LocalWrite", dependencies: ["LocalWriteCore"]),
        .testTarget(name: "LocalWriteCoreTests", dependencies: ["LocalWriteCore"])
    ]
)
