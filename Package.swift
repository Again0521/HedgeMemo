// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemeMemo",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MemeMemoCore", targets: ["MemeMemoCore"]),
        .executable(name: "MemeMemo", targets: ["MemeMemo"]),
        .executable(name: "MemeMemoWhitebox", targets: ["MemeMemoWhitebox"]),
    ],
    targets: [
        .target(name: "MemeMemoCore"),
        .executableTarget(
            name: "MemeMemo",
            dependencies: ["MemeMemoCore"],
            exclude: ["Resources"]
        ),
        .executableTarget(name: "MemeMemoWhitebox", dependencies: ["MemeMemoCore"]),
    ]
)
