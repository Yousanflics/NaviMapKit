// Known-good input for the default-argument gate: defaults are a constant
// marker, nil, a literal, and an enum case; nothing is evaluated.
// expect: none
import Foundation

struct Marker: Sendable {
    private enum Location: Sendable { case applicationDefault, path(String) }
    private let location: Location
    static var `default`: Marker { Marker(location: .applicationDefault) }
}

enum Mode: Sendable { case standard }

@MainActor
final class MustPassCoordinator {
    init(marker: Marker = .default, root: String? = nil, retries: Int = 3, mode: Mode = .standard) {}
}
