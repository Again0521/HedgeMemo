// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HedgeMemo",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HedgeMemoCore", targets: ["HedgeMemoCore"]),
        .executable(name: "HedgeMemo", targets: ["HedgeMemo"]),
        .executable(name: "HedgeMemoWhitebox", targets: ["HedgeMemoWhitebox"]),
    ],
    targets: [
        .target(name: "HedgeMemoCore"),
        .executableTarget(
            name: "HedgeMemo",
            dependencies: ["HedgeMemoCore"],
            exclude: ["Resources"]
        ),
        .executableTarget(name: "HedgeMemoWhitebox", dependencies: ["HedgeMemoCore"]),
    ]
)
