//
//  ContentPreparationActor.swift
//  NaviMapOffline
//
//  The isolation domain where the "no main-thread disk or network"
//  contract is realized: content preparation, the
//  generation registry, and startup reconciliation all execute here, on
//  one dedicated serial executor backed by a utility-QoS queue. Nothing in
//  this domain ever runs on the main thread, so every disk access inside
//  it is off-main by construction — and still passes the contract hook,
//  which is the runtime proof rather than the argument.
//

import Foundation
import NaviMapCore

@globalActor
package actor ContentPreparationActor: GlobalActor {
    package static let shared = ContentPreparationActor()

    private static let executor = ContentPreparationExecutor()

    package nonisolated var unownedExecutor: UnownedSerialExecutor {
        Self.executor.asUnownedSerialExecutor()
    }

    package static var sharedUnownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    /// DEBUG guard for code that must only run inside this domain: the
    /// registry and the staging tree.
    package static func assertPreparationContext(_ operation: StaticString) {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(executor.queue))
        #endif
        MainThreadIOContract.assertOffMainThread(operation)
    }
}

/// Serial executor over a dedicated dispatch queue
/// "dedicated actor and executor").
final class ContentPreparationExecutor: SerialExecutor {
    let queue = DispatchQueue(label: "navimapkit.content-preparation", qos: .utility)

    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.async { unownedJob.runSynchronously(on: executor) }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}
