import Foundation
import Metal

/// A shared piece of MSL that modules include after ShaderCommon: the
/// lighting and shadow functions, the vessel's paint and materials.
public struct ShaderHeader {
    public let name: String
    public let source: String

    public init(name: String, source: String) {
        self.name = name
        self.source = source
    }
}

/// One MSL source compiled into its own MTLLibrary: ShaderCommon, then its
/// headers, then its own source. A module that fails to compile disables
/// the passes that use it, not the renderer.
public struct ShaderModule {
    public let name: String
    public let headers: [ShaderHeader]
    public let source: String

    public init(name: String, headers: [ShaderHeader] = [], source: String) {
        self.name = name
        self.headers = headers
        self.source = source
    }

    /// What is compiled: ShaderCommon, the headers, the module's own source.
    public var fullSource: String {
        ([shaderCommonSource] + headers.map(\.source) + [source]).joined(separator: "\n")
    }

    /// Every module, for the compile tests and `scripts/check-shaders.sh`.
    /// A track adding a module adds it here.
    public static let all: [ShaderModule] = [.planet, .vessel, .star, .overlay, .plume, .atmosphere, .cloud,
                                             .particle, .entry, .post, .shadow, .probe]
}

/// Compiles shader modules on first use and keeps the libraries, and the
/// errors of those that failed.
@MainActor
public final class ShaderLibrary {
    public enum Failure: Error, CustomStringConvertible {
        case compile(module: String, message: String)
        case missingFunction(String)

        public var description: String {
            switch self {
            case let .compile(module, message): "shader module \(module) failed to compile: \(message)"
            case let .missingFunction(name): "shader function \(name) not found"
            }
        }
    }

    public let device: MTLDevice
    private var libraries: [String: MTLLibrary] = [:]
    /// The modules that failed, by name, with the compiler's message.
    public private(set) var errors: [String: String] = [:]

    public init(device: MTLDevice) {
        self.device = device
    }

    /// The module's library, compiled now if it was not yet.
    public func library(_ module: ShaderModule) throws -> MTLLibrary {
        if let l = libraries[module.name] { return l }
        if let e = errors[module.name] { throw Failure.compile(module: module.name, message: e) }
        do {
            // Default options (fast math, the newest language version), as
            // the single library before the split had.
            let l = try device.makeLibrary(source: module.fullSource, options: nil)
            libraries[module.name] = l
            return l
        } catch {
            errors[module.name] = "\(error)"
            NSLog("OrbitSim: shader module \(module.name) failed to compile: \(error)")
            throw Failure.compile(module: module.name, message: "\(error)")
        }
    }
}
