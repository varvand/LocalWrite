// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LocalWrite",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "LocalWrite", targets: ["LocalWrite"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(name: "LocalWriteCore"),
        .executableTarget(
            name: "LocalWrite",
            dependencies: ["LocalWriteCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "LocalWriteCoreTests", dependencies: ["LocalWriteCore"])
    ]
)
