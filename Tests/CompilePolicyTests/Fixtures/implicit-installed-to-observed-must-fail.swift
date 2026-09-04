// EXPECT-FAIL: implicit InstalledAt → ObservedAt flow must not compile
import Foundation
import NaviMapCore

func consume(_ observed: ObservedAt) {}

func implicitFlows(installed: InstalledAt) {
    let assigned: ObservedAt = installed // direct assignment
    consume(installed) // direct argument passing
    _ = assigned
}
