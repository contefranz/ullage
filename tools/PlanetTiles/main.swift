import Foundation

// PlanetTiles converts fetched planet data into the cube-sphere tile store
// (OSTILES1, docs/m16/planet-tiles.md) in ~/Library/Application Support/OrbitSim/Tiles:
//   swift run -c release PlanetTiles earth all    (M1.6, track E1; `earth` alone for the steps)
//   swift run -c release PlanetTiles info FILE... (any tile file)
//   swift run -c release PlanetTiles moon ...     (M2, track MR1: not built yet)
// The sources come from tools/fetch_planet_data.sh.
let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "earth": try Earth.run(Array(arguments.dropFirst()))
    case "info": try Earth.info(Array(arguments.dropFirst()))
    case "tiff": try checkTIFF(Array(arguments.dropFirst()))
    case "tile": try Earth.extract(Array(arguments.dropFirst()))
    case "moon": throw ToolError("the moon subcommand is M2's (track MR1), not built yet")
    default: throw ToolError(Earth.usage)
    }
} catch {
    log("\(error)")
    exit(1)
}
