// swift-tools-version:5.9
import PackageDescription

// OrbitCore (the physics), OrbitInstruments (keys and instrument pages) and
// OrbitScene (what only the renderer reads: scene extraction, the camera,
// photometry and the look maths, snapshot specs) are plain Swift + Foundation
// so they build and test on Linux as well as macOS. OrbitRender (the Metal
// renderer), the OrbitSim app, the orbitsnap snapshot tool and the
// PlanetTiles data tool are only added on macOS hosts.
//
// Files dropped into Sources/OrbitScene/Resources are bundled as they are
// (`OrbitSceneResources`), and Tests/OrbitRenderTests/Goldens is read from
// the source tree, so neither needs a change here.

var products: [Product] = [
    .library(name: "OrbitCore", targets: ["OrbitCore"]),
    .library(name: "OrbitInstruments", targets: ["OrbitInstruments"]),
    .library(name: "OrbitScene", targets: ["OrbitScene"]),
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
    .target(
        name: "OrbitScene",
        dependencies: ["OrbitCore"],
        resources: [.copy("Resources")]
    ),
    .testTarget(
        name: "OrbitSceneTests",
        dependencies: ["OrbitScene"]
    ),
]

#if os(macOS)
products += [
    .library(name: "OrbitRender", targets: ["OrbitRender"]),
    .executable(name: "OrbitSim", targets: ["OrbitSim"]),
    .executable(name: "orbitsnap", targets: ["orbitsnap"]),
    .executable(name: "PlanetTiles", targets: ["PlanetTiles"]),
]
targets += [
    .target(
        name: "OrbitRender",
        dependencies: ["OrbitCore", "OrbitScene"]
    ),
    .testTarget(
        name: "OrbitRenderTests",
        dependencies: ["OrbitRender"],
        exclude: ["Goldens"]
    ),
    .executableTarget(
        name: "OrbitSim",
        dependencies: ["OrbitCore", "OrbitInstruments", "OrbitScene", "OrbitRender"],
        resources: [.copy("MFD/Resources/coastlines.bin")]
    ),
    .executableTarget(
        name: "orbitsnap",
        dependencies: ["OrbitCore", "OrbitScene", "OrbitRender"]
    ),
    .executableTarget(
        name: "PlanetTiles",
        dependencies: ["OrbitCore", "OrbitScene"],
        path: "tools/PlanetTiles"
    ),
]
#endif

let package = Package(
    name: "OrbitSim",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
