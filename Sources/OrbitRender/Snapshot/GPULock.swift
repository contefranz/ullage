import Foundation

/// The machine's GPU lock, `~/Library/Application Support/OrbitSim/gpu.lock`:
/// performance runs and harness flights hold it so that sessions running
/// at once do not disturb each other's timings. Image runs need not.
public final class GPULock {
    private let fd: Int32

    public static var url: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("OrbitSim/gpu.lock")
    }

    /// Takes the lock, waiting for whoever holds it; `waiting` is called once
    /// if it has to wait.
    public init?(waiting: () -> Void = {}) {
        let url = Self.url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            waiting()
            guard flock(fd, LOCK_EX) == 0 else {
                close(fd)
                return nil
            }
        }
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
