import Foundation
import OrbitCore

/// Which tiles of a layer are in its GPU atlas, and in which slot (M1.6
/// track E1): the tile cache's bookkeeping, pure Swift so that it is tested
/// on Linux against a simulated GPU timeline.
///
/// Rules:
/// - **Parents first.** A tile is admitted only when its parent is resident
///   (or it is a root), and only leaves (tiles with no resident child) are
///   evicted. So every resident tile's ancestors are resident: the
///   indirection always finds a tile, and the Moon's mesh (MR2) finds the
///   parent level's heights it morphs to.
/// - **Pinned levels.** Tiles at `pinnedLevel` and coarser are never
///   evicted: with the roots loaded first, every point of the body has a
///   tile from the first frame on.
/// - **Use stamps.** Each frame the cache touches the tiles it wants: the
///   current selection's (and their ancestors) as current, prefetched ones
///   as prefetch. A stamp is 2·frame + 1 for current, 2·frame for prefetch;
///   eviction takes the least recently stamped leaf, so prefetch gives way
///   to current within a frame.
/// - **In-flight frames.** An evicted tile's slot is quarantined, tagged
///   with the frame that dropped it, and reused only once the GPU has
///   finished that frame (`beginFrame(_:completedThrough:)`): frames still
///   in flight may sample the slot through their own indirection.
public struct PlanetTileResidency {
    public let slotCount: Int
    /// Levels up to this one are never evicted (-1: none).
    public let pinnedLevel: Int
    public private(set) var indirection: PlanetTileIndirection
    public private(set) var frame: UInt64 = 0

    var slotKey: [TileKey?]
    var slotStamp: [UInt64]
    var residentSlot: [TileKey: Int] = [:]
    var residentChildren: [TileKey: Int] = [:]
    var free: [Int]
    var quarantine: [(slot: Int, frame: UInt64)] = []

    /// Counts since the cache's last look (`takeCounters`).
    public struct Counters: Equatable {
        public var admitted = 0
        public var evicted = 0
        public var refused = 0
        public init() {}
    }
    public private(set) var counters = Counters()

    public init(slots: Int, maxLevel: Int, pinnedLevel: Int = 1, maxTextureLevel: Int = 9) {
        precondition(slots >= CubeSphere.tileCount(level: 0), "fewer slots than the six roots")
        slotCount = slots
        self.pinnedLevel = pinnedLevel
        indirection = PlanetTileIndirection(maxLevel: maxLevel, slots: slots, maxTextureLevel: maxTextureLevel)
        slotKey = [TileKey?](repeating: nil, count: slots)
        slotStamp = [UInt64](repeating: 0, count: slots)
        // Popped from the end: slot 0 first.
        free = Array((0 ..< slots).reversed())
    }

    public var residentCount: Int { residentSlot.count }
    public var freeCount: Int { free.count }
    public var quarantinedCount: Int { quarantine.count }
    public var residentKeys: Dictionary<TileKey, Int>.Keys { residentSlot.keys }

    public func slot(of key: TileKey) -> Int? { residentSlot[key] }
    public func isResident(_ key: TileKey) -> Bool { residentSlot[key] != nil }
    public func key(inSlot slot: Int) -> TileKey? { slotKey[slot] }

    /// Starts frame `frame`: slots quarantined by frames up to
    /// `completedThrough` (all finished on the GPU) become free.
    public mutating func beginFrame(_ frame: UInt64, completedThrough: UInt64?) {
        precondition(frame >= self.frame, "frames go forward")
        self.frame = frame
        guard let done = completedThrough else { return }
        var kept: [(slot: Int, frame: UInt64)] = []
        for q in quarantine {
            if q.frame <= done { free.append(q.slot) } else { kept.append(q) }
        }
        quarantine = kept
    }

    /// Marks a resident tile wanted this frame.
    public mutating func touch(_ key: TileKey, current: Bool) {
        guard let s = residentSlot[key] else { return }
        slotStamp[s] = max(slotStamp[s], 2 * frame + (current ? 1 : 0))
    }

    /// Whether `key` may be admitted now: not resident, and its parent is.
    public func canAdmit(_ key: TileKey) -> Bool {
        guard residentSlot[key] == nil else { return false }
        guard let p = key.parent else { return true }
        return residentSlot[p] != nil
    }

    /// Puts `key` in a free slot and returns it; nil if none is free (then,
    /// for a `current` tile, the least recent evictable leaf not wanted as
    /// current this frame is evicted, so a slot frees once the GPU is past
    /// this frame). The tile is stamped as wanted now.
    public mutating func admit(_ key: TileKey, current: Bool) -> Int? {
        precondition(canAdmit(key), "admit \(key): resident, or its parent is not")
        guard let s = free.popLast() else {
            counters.refused += 1
            if current { _ = evictLeastRecent(below: 2 * frame + 1) }
            return nil
        }
        slotKey[s] = key
        slotStamp[s] = 2 * frame + (current ? 1 : 0)
        residentSlot[key] = s
        if let p = key.parent { residentChildren[p, default: 0] += 1 }
        indirection.insert(key, slot: s)
        counters.admitted += 1
        return s
    }

    /// Keeps at least `count` slots free or quarantined, evicting leaves
    /// not wanted this frame, least recent first. Returns the tiles evicted.
    @discardableResult
    public mutating func reserve(_ count: Int) -> [TileKey] {
        var out: [TileKey] = []
        while free.count + quarantine.count < count, let k = evictLeastRecent(below: 2 * frame) { out.append(k) }
        return out
    }

    /// Evicts the least recently stamped evictable leaf whose stamp is
    /// below `stamp` (deeper first among equals); nil if there is none.
    @discardableResult
    mutating func evictLeastRecent(below stamp: UInt64) -> TileKey? {
        var best = -1
        for s in 0 ..< slotCount {
            guard let k = slotKey[s], k.level > pinnedLevel, slotStamp[s] < stamp,
                  residentChildren[k, default: 0] == 0 else { continue }
            if best < 0 || slotStamp[s] < slotStamp[best]
                || (slotStamp[s] == slotStamp[best] && k.level > slotKey[best]!.level) { best = s }
        }
        guard best >= 0, let k = slotKey[best] else { return nil }
        evict(k)
        return k
    }

    /// Drops `key`, a resident leaf, now: its slot is quarantined until the
    /// GPU finishes this frame.
    public mutating func evict(_ key: TileKey) {
        guard let s = residentSlot[key] else { return }
        precondition(residentChildren[key, default: 0] == 0, "evict \(key): it has resident children")
        indirection.remove(key)
        residentSlot[key] = nil
        residentChildren[key] = nil
        if let p = key.parent {
            let n = residentChildren[p, default: 0] - 1
            residentChildren[p] = n > 0 ? n : nil
        }
        slotKey[s] = nil
        slotStamp[s] = 0
        quarantine.append((s, frame))
        counters.evicted += 1
    }

    /// The counters, reset.
    public mutating func takeCounters() -> Counters {
        defer { counters = Counters() }
        return counters
    }

    /// The indirection's changes since the last call.
    public mutating func takeIndirectionChanges() -> (regions: [PlanetTileIndirection.Region], hash: Bool) {
        indirection.takeDirty()
    }

    /// Marks the whole indirection changed (its GPU copy is new).
    public mutating func markIndirectionDirty() { indirection.markAllDirty() }

    /// Checks the invariants (tests): ancestors resident, child counts,
    /// slots consistent.
    public func validate() -> String? {
        for (k, s) in residentSlot {
            if slotKey[s] != k { return "slot \(s) holds \(String(describing: slotKey[s])), not \(k)" }
            if let p = k.parent, residentSlot[p] == nil { return "\(k) resident without its parent" }
            let n = k.children.filter { residentSlot[$0] != nil }.count
            if n != residentChildren[k, default: 0] { return "\(k): \(n) resident children, counted \(residentChildren[k, default: 0])" }
        }
        let used = Set(residentSlot.values), freeSet = Set(free), quarantined = Set(quarantine.map(\.slot))
        if used.count + freeSet.count + quarantined.count != slotCount
            || !used.isDisjoint(with: freeSet) || !used.isDisjoint(with: quarantined) || !freeSet.isDisjoint(with: quarantined) {
            return "slots: \(used.count) used, \(freeSet.count) free, \(quarantined.count) quarantined of \(slotCount)"
        }
        return nil
    }
}

/// The tiles a layer wants this frame, in the order to load them: from the
/// quadtree's selection and the prefetch views, each tile's finest stored
/// ancestor and that one's ancestors, coarse to fine.
public enum PlanetTileWants {
    /// `selection`'s tiles mapped to what `finestAvailable` finds (nil:
    /// nothing stored there), with their ancestors, deduplicated, by level
    /// then distance (nearest first).
    public static func ordered(_ selection: [PlanetQuadtree.Tile],
                               finestAvailable: (TileKey) -> TileKey?) -> [TileKey] {
        var best: [TileKey: Double] = [:]
        best.reserveCapacity(selection.count * 2)
        for t in selection {
            guard var k = finestAvailable(t.key) else { continue }
            while true {
                // Once a tile holds a distance this near, so do its ancestors.
                if let d = best[k], d <= t.distance { break }
                best[k] = t.distance
                guard let p = k.parent else { break }
                k = p
            }
        }
        return best.sorted { a, b in
            a.key.level != b.key.level ? a.key.level < b.key.level
                : a.value != b.value ? a.value < b.value : a.key < b.key
        }.map(\.key)
    }
}
