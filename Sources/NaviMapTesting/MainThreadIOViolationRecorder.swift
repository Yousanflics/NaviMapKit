//
//  MainThreadIOViolationRecorder.swift
//  NaviMapTesting
//
//  Turns the main-thread I/O contract's DEBUG hook into an assertable
//  fact: once installed, violations are recorded instead of aborting the
//  test process. Process-wide by nature (the hook is global), so tests
//  assert on deltas filtered by operation name rather than on totals, and
//  a test that provokes a violation on purpose runs inside a task-local
//  `scope` so its reports never pollute a concurrent test's zero-delta
//  assertion (the hook calls the handler inline, in the caller's task).
//

import NaviMapCore
import os

package final class MainThreadIOViolationRecorder: Sendable {
    package static let shared = MainThreadIOViolationRecorder()

    private struct Entry: Sendable {
        let scope: String?
        let violation: MainThreadIOContract.Violation
    }

    /// Set by tests that provoke violations deliberately.
    @TaskLocal package static var scope: String?

    private let entries = OSAllocatedUnfairLock<[Entry]>(initialState: [])
    private static let installed = OSAllocatedUnfairLock(initialState: false)

    private init() {}

    /// Idempotent: the first call routes the contract hook to the shared
    /// recorder; later calls are no-ops.
    package static func install() {
        let first = installed.withLock { was -> Bool in
            if was { return false }
            was = true
            return true
        }
        if first {
            MainThreadIOContract.setViolationHandler { shared.record($0) }
        }
    }

    package func record(_ violation: MainThreadIOContract.Violation) {
        let entry = Entry(scope: Self.scope, violation: violation)
        entries.withLock { $0.append(entry) }
    }

    /// Violations whose operation starts with `prefix`, reported under
    /// `scope` (nil = unscoped reports only), in report order.
    package func violations(
        operationPrefix prefix: String,
        scope: String? = nil
    ) -> [MainThreadIOContract.Violation] {
        entries.withLock { entries in
            entries
                .filter { $0.scope == scope && $0.violation.operation.hasPrefix(prefix) }
                .map(\.violation)
        }
    }
}
