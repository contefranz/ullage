import Foundation
import XCTest
@testable import OrbitCore

/// `ObjectSerial`: an identity no later object takes, where an
/// `ObjectIdentifier` (an address) is taken over as soon as its object is
/// freed. The renderer keys its part meshes and nozzle poses by it.
final class ObjectSerialTests: XCTestCase {
    func testSerialsAreNeverReusedWhenAddressesAre() {
        var addresses: [ObjectIdentifier: Int] = [:]
        var serials = Set<ObjectSerial>()
        var last: ObjectSerial?
        for i in 0..<2_000 {
            // Each part is freed before the next is made, so the allocator
            // hands its memory out again.
            let part = VesselPart(name: "part \(i)", dryMass: 1, length: 1, radius: 1,
                                  thrusters: [Thruster(name: "jet", position: .zero, direction: .unitX,
                                                       rating: EngineRating(thrustVacuum: 1, ispVacuum: 300),
                                                       feed: nil, groups: [])])
            addresses[ObjectIdentifier(part), default: 0] += 1
            XCTAssertTrue(serials.insert(part.serial).inserted, "serial \(part.serial) given twice")
            XCTAssertTrue(serials.insert(part.thrusters[0].serial).inserted, "a thruster shares a serial")
            if let last { XCTAssertGreaterThan(part.serial, last) }
            last = part.thrusters[0].serial
        }
        // The hazard the serials remove: freed parts' addresses come back
        // (reported, not required: it is the allocator's business).
        print("ObjectSerialTests: 2,000 parts took \(addresses.count) addresses")
    }

    func testSerialsAreUniqueAcrossThreads() {
        let lock = NSLock()
        var all: [ObjectSerial] = []
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let mine = (0..<1_000).map { _ in ObjectSerial.next() }
            lock.withLock { all += mine }
        }
        XCTAssertEqual(Set(all).count, 8_000)
    }
}
