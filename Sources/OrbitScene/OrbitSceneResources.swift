import Foundation

// OrbitScene holds what only the renderer reads, in plain Swift + Foundation
// (no simd, no Apple-only frameworks) so that it builds and is tested on
// Linux: scene extraction, the camera, photometry, exposure and tone curves,
// the BRDF and its LUT bakes, shadow fitting, AO, paint and decals, the cloud
// field, LOD selection, snapshot specs. OrbitCore keeps what the simulation
// reads; Metal code goes in OrbitRender.

/// The files of Sources/OrbitScene/Resources, bundled as they are: a file
/// added there is found here with no change to Package.swift.
public enum OrbitSceneResources {
    /// The bundled file `name` (with its extension), nil if there is none.
    public static func url(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources")
    }
}
