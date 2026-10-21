import Metal
import XCTest
@testable import OrbitRender

@MainActor
final class ShaderCompileTests: XCTestCase {
    func device() throws -> MTLDevice { try XCTUnwrap(RenderDevice.shared, "no Metal device") }

    /// Every module compiles on its own, ShaderCommon and its headers in front.
    func testEveryModuleCompiles() throws {
        let shaders = ShaderLibrary(device: try device())
        for module in ShaderModule.all {
            XCTAssertNoThrow(try shaders.library(module), module.name)
        }
        XCTAssertEqual(shaders.errors, [:])
        XCTAssertEqual(Set(ShaderModule.all.map(\.name)).count, ShaderModule.all.count, "module names are unique")
    }

    /// A module that does not compile fails alone, and says why.
    func testBrokenModuleFailsAlone() throws {
        let shaders = ShaderLibrary(device: try device())
        let broken = ShaderModule(name: "Broken", source: "fragment float4 f() { return undeclared; }")
        XCTAssertThrowsError(try shaders.library(broken))
        XCTAssertNotNil(shaders.errors["Broken"])
        XCTAssertTrue(shaders.errors["Broken"]!.contains("undeclared"))
        XCTAssertNoThrow(try shaders.library(.planet))
    }

    /// The Swift mirrors of ShaderCommon's structs have MSL's sizes.
    func testSharedStructLayoutsMatchMSL() throws {
        let device = try device()
        let module = ShaderModule(name: "Sizes", source: """
            kernel void sizes(device uint *out [[buffer(0)]]) {
                out[0] = sizeof(FrameUniforms);
                out[1] = sizeof(LightingUniforms);
                out[2] = sizeof(AtmosphereUniforms);
                out[3] = sizeof(VertexV2);
                out[4] = sizeof(LocalLight);
                out[5] = sizeof(PointUniforms);
                out[6] = orbit_surfaceIDs(float(7 + 256 * 9 + 65536 * 200)).x;
                out[7] = orbit_surfaceIDs(float(7 + 256 * 9 + 65536 * 200)).y;
                out[8] = orbit_surfaceIDs(float(7 + 256 * 9 + 65536 * 200)).z;
            }
            """)
        let library = try ShaderLibrary(device: device).library(module)
        let pipeline = try device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: "sizes")))
        let out = try XCTUnwrap(device.makeBuffer(length: 9 * 4, options: .storageModeShared))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer()), enc = try XCTUnwrap(cb.makeComputeCommandEncoder())
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(out, offset: 0, index: 0)
        enc.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let v = out.contents().bindMemory(to: UInt32.self, capacity: 9)
        XCTAssertEqual(Int(v[0]), MemoryLayout<FrameUniforms>.stride, "FrameUniforms")
        XCTAssertEqual(Int(v[1]), MemoryLayout<LightingUniforms>.stride, "LightingUniforms")
        XCTAssertEqual(Int(v[2]), MemoryLayout<AtmosphereUniforms>.stride, "AtmosphereUniforms")
        XCTAssertEqual(Int(v[3]), MemoryLayout<VertexV2>.stride, "VertexV2")
        XCTAssertEqual(Int(v[3]), 64, "vertex v2 is 64 bytes")
        XCTAssertEqual(Int(v[4]), MemoryLayout<LocalLight>.stride, "LocalLight")
        XCTAssertEqual(Int(v[5]), MemoryLayout<PointUniforms>.stride, "PointUniforms")
        XCTAssertEqual([v[6], v[7], v[8]], [7, 9, 200], "the packed surface ids decode as OrbitScene packs them")
    }
}
