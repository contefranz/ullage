import Foundation

// orbitsnap renders snapshot specs offscreen, with no window:
//   swift run -c release orbitsnap spec.json --out DIR [--shot N]
// The tool arrives with the render foundation's F0b; this is its target.
FileHandle.standardError.write(Data("orbitsnap: not built yet\n".utf8))
exit(2)
