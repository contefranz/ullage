// swift-tools-version:5.9
import PackageDescription

// OrbitCore is plain Swift + Foundation so it builds and tests on Linux as well
// as macOS. The OrbitSim app (Metal + SwiftUI) is only added on macOS hosts.

var products: [Product] = [
    .library(name: "OrbitCore", targets: ["OrbitCore"]),
]

var targets: [Target] = [
    .target(
        name: "OrbitCore",
        resources: [
            .copy("Resources/ephem.bin"),
            .copy("Resources/stars.bin"),
        ]
    ),
    .testTarget(
        name: "OrbitCoreTests",
        dependencies: ["OrbitCore"]
    ),
]

#if os(macOS)
products.append(.executable(name: "OrbitSim", targets: ["OrbitSim"]))
targets.append(
    .executableTarget(
        name: "OrbitSim",
        dependencies: ["OrbitCore"]
    )
)
#endif

let package = Package(
    name: "OrbitSim",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
