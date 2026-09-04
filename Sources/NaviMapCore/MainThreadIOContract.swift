//
//  MainThreadIOContract.swift
//  NaviMapCore
//
//  The main-thread I/O contract: SDK disk access never runs on the main
//  thread. Every SDK file-system or database access passes through
//  `assertOffMainThread` — the single choke point that makes the contract
//  observable. In DEBUG builds a violation is reported to the installed
//  handler (default: assertion failure); release builds compile the check
//  away. This hook is the standing defence for the contract whenever direct
//  tracing evidence is unavailable; it complements tracing-based
//  verification and never substitutes for it.
//

import Foundation
import os

package enum MainThreadIOContract {
    /// One reported main-thread disk access: what ran and where it was
    /// called from.
    package struct Violation: Sendable, Equatable {
        package let operation: String
        package let file: String
        package let line: UInt

        package init(operation: String, file: String, line: UInt) {
            self.operation = operation
            self.file = file
            self.line = line
        }
    }

    package typealias Handler = @Sendable (Violation) -> Void

    private static let handlerLock = OSAllocatedUnfairLock<Handler?>(initialState: nil)

    /// Replaces the DEBUG violation handler. Tests install a recorder so a
    /// violation becomes an assertable fact instead of a process abort;
    /// `nil` restores the default assertion behaviour.
    package static func setViolationHandler(_ handler: Handler?) {
        handlerLock.withLock { $0 = handler }
    }

    /// Call at the entry of every SDK disk access. No-op off the main
    /// thread and in release builds.
    package static func assertOffMainThread(
        _ operation: StaticString,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        #if DEBUG
        guard Thread.isMainThread else { return }
        let violation = Violation(operation: "\(operation)", file: "\(file)", line: line)
        if let handler = handlerLock.withLock({ $0 }) {
            handler(violation)
        } else {
            assertionFailure(
                "Main-thread disk I/O: \(violation.operation) at \(violation.file):\(violation.line)"
            )
        }
        #endif
    }
}
