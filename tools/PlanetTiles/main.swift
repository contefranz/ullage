import Foundation

// PlanetTiles converts fetched planet data into the cube-sphere tile store in
// ~/Library/Application Support/OrbitSim:
//   swift run -c release PlanetTiles earth ...   (M1.6, track E1)
//   swift run -c release PlanetTiles moon ...    (M2, track MR1)
// No subcommand is built yet.
FileHandle.standardError.write(Data("usage: PlanetTiles earth|moon ... (no subcommand built yet)\n".utf8))
exit(2)
