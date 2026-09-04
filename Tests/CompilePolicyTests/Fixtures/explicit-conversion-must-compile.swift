// EXPECT-PASS: the named degradation init is the sanctioned, auditable path —
// it MUST compile (audit, not prohibition; review B1). Positive control that
// keeps the harness honest: a broken include path would fail this too.
import Foundation
import NaviMapCore

func consume(_ observed: ObservedAt) {}

func explicitConversion(installed: InstalledAt) {
    consume(ObservedAt(assumingObservation: installed))
    _ = ObservedAt(instant: installed.instant) // documented escape hatch
}
