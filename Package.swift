// swift-tools-version:5.9
import PackageDescription

// OrbitCore (the physics) and OrbitInstruments (keys and instrument pages)
// are plain Swift + Foundation so they build and test on Linux as well as
// macOS. The OrbitSim app (Metal + SwiftUI) is only added on macOS hosts.

var products: [Product] = [
    .library(name: "OrbitCore", targets: ["OrbitCore"]),
    .library(name: "OrbitInstruments", targets: ["OrbitInstruments"]),
]

var targets: [Target] = [
    .target(
        name: "OrbitCore",
        resources: [
            .copy("Resources/ephem.bin"),
            .copy("Resources/landmask.bin"),
            .copy("Resources/stars.bin"),
            .copy("Resources/ut1.txt"),
        ]
    ),
    .testTarget(
        name: "OrbitCoreTests",
        dependencies: ["OrbitCore"]
    ),
    .target(
        name: "OrbitInstruments",
        dependencies: ["OrbitCore"]
    ),
    .testTarget(
        name: "OrbitInstrumentsTests",
        dependencies: ["OrbitInstruments"]
    ),
]

#if os(macOS)
products.append(.executable(name: "OrbitSim", targets: ["OrbitSim"]))
targets.append(
    .executableTarget(
        name: "OrbitSim",
        dependencies: ["OrbitCore", "OrbitInstruments"],
        resources: [.copy("MFD/Resources/coastlines.bin")]
    )
)
#endif

let package = Package(
    name: "OrbitSim",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
