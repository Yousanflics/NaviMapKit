// Input with no main-actor type at all. The gate must fail on it rather
// than report an empty green: a scan that checks nothing proves nothing.
import Foundation

struct PlainValue: Sendable {
    let name: String
}
