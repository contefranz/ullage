import Foundation
import OrbitCore

/// Where each point of a layer finds its finest resident tile (M1.6 design
/// §3, track E1): the CPU mirror of the GPU's indirection, which the tile
/// cache uploads where it changed and the planet shader reads
/// (PlanetTileCommon's `planet_tile_find` does what `lookup` does).
///
/// Two parts:
/// - **The indirection texture**, levels 0 to `textureLevels - 1`: per face
///   a pyramid, level ℓ a 2^ℓ × 2^ℓ grid (mip `textureLevels - 1 - ℓ` of
///   the face's slice), each entry the finest resident tile at level ℓ or
///   coarser that contains that level-ℓ tile.
/// - **The deep table**, for tiles deeper than that (the Cape inset's): an
///   open-addressed hash of tile id to entry, probed from the wanted level
///   up to the texture's deepest.
///
/// An entry packs the tile's atlas slot in bits 0-15 and its level in bits
/// 16-20, with bit 31 set; 0 means no resident tile.
public struct PlanetTileIndirection {
    /// Levels the texture holds, 0 ..< textureLevels.
    public let textureLevels: Int
    /// The layer's deepest level.
    public let maxLevel: Int
    /// [face][level] row-major 2^ℓ × 2^ℓ entries.
    public private(set) var table: [[[UInt32]]]
    public private(set) var hash: TileHashTable
    /// Changed since `takeDirty`: per face and level the rectangle of
    /// entries (x0, y0, x1, y1), exclusive upper bounds.
    public private(set) var dirty: [Region] = []
    public private(set) var hashDirty = false

    public struct Region: Equatable {
        public var face: Int, level: Int, x0: Int, y0: Int, x1: Int, y1: Int
    }

    public static let validBit: UInt32 = 1 << 31

    @inlinable public static func pack(slot: Int, level: Int) -> UInt32 {
        validBit | UInt32(level) << 16 | UInt32(slot)
    }

    @inlinable public static func unpack(_ e: UInt32) -> (slot: Int, level: Int)? {
        e & validBit == 0 ? nil : (Int(e & 0xFFFF), Int(e >> 16 & 31))
    }

    /// For a layer `maxLevel` deep with atlas `slots`; the texture holds at
    /// most `maxTextureLevel` + 1 levels (9: 512² entries per face).
    public init(maxLevel: Int, slots: Int, maxTextureLevel: Int = 9) {
        precondition(slots <= 1 << 16, "at most 65,536 atlas slots")
        self.maxLevel = maxLevel
        textureLevels = min(maxLevel, maxTextureLevel) + 1
        table = (0 ..< 6).map { _ in (0 ..< min(maxLevel, maxTextureLevel) + 1).map { [UInt32](repeating: 0, count: 1 << (2 * $0)) } }
        hash = TileHashTable(capacity: maxLevel >= textureLevels ? max(16, slots * 2) : 16)
    }

    /// The deepest level the texture holds.
    public var textureMaxLevel: Int { textureLevels - 1 }

    /// Records `key` resident in `slot`. Its parent must be resident (or it
    /// a root) and none of its children: the tile cache's invariant.
    public mutating func insert(_ key: TileKey, slot: Int) {
        let e = Self.pack(slot: slot, level: key.level)
        if key.level > textureMaxLevel {
            hash.insert(key.id, e)
            hashDirty = true
            return
        }
        fill(key) { old in
            // Coarser (or nothing) gives way; a finer entry cannot be there.
            (Self.unpack(old)?.level ?? -1) < key.level ? e : old
        }
    }

    /// Records `key` gone. It must have no resident children; its entries
    /// fall back to its parent's.
    public mutating func remove(_ key: TileKey) {
        if key.level > textureMaxLevel {
            hash.remove(key.id)
            hashDirty = true
            return
        }
        let parentEntry: UInt32
        if let p = key.parent {
            parentEntry = table[p.face.rawValue][p.level][p.y << p.level + p.x]
        } else {
            parentEntry = 0
        }
        let mine = Self.pack(slot: 0, level: key.level) & ~UInt32(0xFFFF)
        fill(key) { old in old & ~UInt32(0xFFFF) == mine ? parentEntry : old }
    }

    /// Applies `update` to every entry under `key`, at its level and deeper.
    mutating func fill(_ key: TileKey, _ update: (UInt32) -> UInt32) {
        let f = key.face.rawValue
        for level in key.level ... textureMaxLevel {
            let shift = level - key.level, side = 1 << level
            let x0 = key.x << shift, y0 = key.y << shift, span = 1 << shift
            table[f][level].withUnsafeMutableBufferPointer { t in
                for y in y0 ..< y0 + span {
                    for x in x0 ..< x0 + span { t[y * side + x] = update(t[y * side + x]) }
                }
            }
            mark(Region(face: f, level: level, x0: x0, y0: y0, x1: x0 + span, y1: y0 + span))
        }
    }

    /// Adds a changed rectangle: merged with one of its face and level that
    /// it touches; past 8 rectangles for a face and level, they become their
    /// bounding box. Scattered tiles so upload little.
    mutating func mark(_ r: Region) {
        var r = r
        // Absorb every touching rectangle of the same face and level.
        var k = 0
        while k < dirty.count {
            let d = dirty[k]
            if d.face == r.face && d.level == r.level && d.x0 <= r.x1 && r.x0 <= d.x1 && d.y0 <= r.y1 && r.y0 <= d.y1 {
                r = Region(face: r.face, level: r.level, x0: min(d.x0, r.x0), y0: min(d.y0, r.y0),
                           x1: max(d.x1, r.x1), y1: max(d.y1, r.y1))
                dirty.remove(at: k)
                k = 0
            } else {
                k += 1
            }
        }
        let same = dirty.indices.filter { dirty[$0].face == r.face && dirty[$0].level == r.level }
        if same.count >= 8 {
            for i in same {
                let d = dirty[i]
                r = Region(face: r.face, level: r.level, x0: min(d.x0, r.x0), y0: min(d.y0, r.y0),
                           x1: max(d.x1, r.x1), y1: max(d.y1, r.y1))
            }
            dirty = dirty.enumerated().filter { !same.contains($0.offset) }.map(\.element)
        }
        dirty.append(r)
    }

    /// The changed regions since the last call, and whether the deep table
    /// changed; clears both.
    public mutating func takeDirty() -> (regions: [Region], hash: Bool) {
        defer { dirty = []; hashDirty = false }
        return (dirty, hashDirty)
    }

    /// Marks everything changed (a fresh GPU texture).
    public mutating func markAllDirty() {
        dirty = []
        for f in 0 ..< 6 {
            for l in 0 ..< textureLevels { dirty.append(Region(face: f, level: l, x0: 0, y0: 0, x1: 1 << l, y1: 1 << l)) }
        }
        hashDirty = true
    }

    /// The finest resident tile containing `direction` (figure coordinates)
    /// at `level` or coarser, and its slot: what the shader finds.
    public func lookup(_ direction: Vec3, level: Int) -> (key: TileKey, slot: Int)? {
        let p = CubeSphere.faceCoordinates(direction)
        return lookup(face: p.face, u: p.u, v: p.v, level: level)
    }

    public func lookup(face: CubeSphere.Face, u: Double, v: Double, level: Int) -> (key: TileKey, slot: Int)? {
        var l = min(max(level, 0), maxLevel)
        while l > textureMaxLevel {
            let k = TileKey.containing(face: face, u: u, v: v, level: l)
            if let e = hash.find(k.id), let r = Self.unpack(e) { return (k, r.slot) }
            l -= 1
        }
        let k = TileKey.containing(face: face, u: u, v: v, level: l)
        guard let r = Self.unpack(table[face.rawValue][l][k.y << l + k.x]) else { return nil }
        return (k.ancestor(atLevel: r.level), r.slot)
    }

    /// The entry rows of a face's level, for upload.
    public func entries(face: Int, level: Int) -> [UInt32] { table[face][level] }
}

/// An open-addressed hash of tile ids to indirection entries, laid out as
/// the GPU reads it: four UInt32 per bucket (id low, id high, entry, 0), an
/// empty bucket's id all ones (no tile id has bit 63 set). Linear probing
/// from `TileHashTable.home`, deletion by backward shift, so a lookup stops
/// at the first empty bucket or after `maxProbe` buckets.
public struct TileHashTable {
    public private(set) var buckets: [UInt32]
    public let capacity: Int
    /// The longest probe any key present needed (an upper bound after removals).
    public private(set) var maxProbe = 0
    public private(set) var count = 0

    static let empty: UInt32 = 0xFFFF_FFFF

    public init(capacity: Int) {
        var c = 16
        while c < capacity { c <<= 1 }
        self.capacity = c
        buckets = [UInt32](repeating: Self.empty, count: 4 * c)
        for i in 0 ..< c { buckets[4 * i + 2] = 0; buckets[4 * i + 3] = 0 }
    }

    /// The bucket a key starts its probe at: a 32-bit mix of its id
    /// (MurmurHash3's finaliser), the same in MSL.
    @inlinable public static func home(_ id: UInt64, capacity: Int) -> Int {
        var h = UInt32(truncatingIfNeeded: id) ^ (UInt32(truncatingIfNeeded: id >> 32) &* 0x9E37_79B1)
        h ^= h >> 16; h = h &* 0x85EB_CA6B
        h ^= h >> 13; h = h &* 0xC2B2_AE35
        h ^= h >> 16
        return Int(h) & (capacity - 1)
    }

    func id(at i: Int) -> UInt64? {
        let lo = buckets[4 * i], hi = buckets[4 * i + 1]
        return lo == Self.empty && hi == Self.empty ? nil : UInt64(hi) << 32 | UInt64(lo)
    }

    public func find(_ id: UInt64) -> UInt32? {
        var i = Self.home(id, capacity: capacity)
        for _ in 0 ... maxProbe {
            guard let k = self.id(at: i) else { return nil }
            if k == id { return buckets[4 * i + 2] }
            i = (i + 1) & (capacity - 1)
        }
        return nil
    }

    public mutating func insert(_ id: UInt64, _ entry: UInt32) {
        precondition(count < capacity / 2 || find(id) != nil, "tile hash table over half full")
        var i = Self.home(id, capacity: capacity), probe = 0
        while let k = self.id(at: i), k != id {
            i = (i + 1) & (capacity - 1)
            probe += 1
        }
        if self.id(at: i) == nil { count += 1 }
        buckets[4 * i] = UInt32(truncatingIfNeeded: id)
        buckets[4 * i + 1] = UInt32(truncatingIfNeeded: id >> 32)
        buckets[4 * i + 2] = entry
        maxProbe = max(maxProbe, probe)
    }

    public mutating func remove(_ id: UInt64) {
        var i = Self.home(id, capacity: capacity)
        var found = false
        for _ in 0 ... maxProbe {
            guard let k = self.id(at: i) else { return }
            if k == id { found = true; break }
            i = (i + 1) & (capacity - 1)
        }
        guard found else { return }
        count -= 1
        // Backward shift: pull later members of the cluster into the hole
        // when their home does not lie cyclically in (hole, j].
        var hole = i, j = i
        while true {
            j = (j + 1) & (capacity - 1)
            guard let k = self.id(at: j) else { break }
            let h = Self.home(k, capacity: capacity)
            let between = hole <= j ? (h > hole && h <= j) : (h > hole || h <= j)
            if !between {
                for w in 0 ..< 4 { buckets[4 * hole + w] = buckets[4 * j + w] }
                hole = j
            }
        }
        buckets[4 * hole] = Self.empty; buckets[4 * hole + 1] = Self.empty
        buckets[4 * hole + 2] = 0; buckets[4 * hole + 3] = 0
    }
}
