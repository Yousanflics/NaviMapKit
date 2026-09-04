// Known-bad input for the default-argument gate: a main-actor type whose
// initializer evaluates calls in default arguments, and a static member
// used as a default whose definition body performs work. The violating
// defaults sit after a parenthesized parameter type on purpose: a scanner
// that stops at the first closing parenthesis would never see them.
// The gate's self-test requires exactly these parameters to be reported.
// expect: locator, fallback, timeout
import Foundation

protocol Storage: Sendable {}
struct DiskStorage: Storage {}

struct Locator: Sendable {
    let path: String
    static var `default`: Locator { Locator(path: NSHomeDirectory() + "/x") }
}

@MainActor
final class MustFailCoordinator {
    init(
        storage: (any Storage)? = nil,
        locator: Locator = .default,
        fallback: (any Storage)? = DiskStorage(),
        timeout: Duration = .seconds(8)
    ) {}
}
