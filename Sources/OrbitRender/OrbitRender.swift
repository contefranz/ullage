import Metal

// OrbitRender: the Metal renderer (macOS only). It draws a RenderScene that
// OrbitScene extracts from the simulation, through a frame graph of passes,
// each a Swift file with its own shader source compiled into its own
// MTLLibrary behind the shared ShaderCommon header. The app's MTKView and
// the orbitsnap tool both drive it.

/// The GPU this process renders with: the system default device.
public enum RenderDevice {
    public static let shared: MTLDevice? = MTLCreateSystemDefaultDevice()
}
