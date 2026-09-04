//
//  ActivationConfirming.swift
//  NaviMapOffline
//
//  The manager's view of render confirmation: after
//  activation, the content change is submitted to the reconciler and an
//  acknowledgement covering the generation is awaited. This target depends
//  only on Core, so the scene/runtime side is
//  abstracted behind this protocol; the map layer provides the real
//  implementation and tests script it. The bounded wait is the manager's,
//  not the confirmer's.
//

import Foundation
import NaviMapCore

package enum ActivationConfirmation: Sendable, Equatable {
    /// An acknowledgement covering the generation was received.
    case rendered
    /// Regional activation (rule 6): the generation is in effect for its
    /// own scope; the predecessor stays leased until an in-region render
    /// confirms it.
    case deferredUntilRegionalRender
}

package protocol ActivationConfirming: Sendable {
    /// Submit the activated generation for rendering and return once an
    /// acknowledgement covering it arrives. Must honour task cancellation:
    /// the manager cancels this on timeout.
    func confirmActivation(of generation: ActivatedGeneration) async throws -> ActivationConfirmation

    /// A rollback render plan: point rendering back at `previous`, or at
    /// nothing when there was no previous generation.
    func submitRollback(for contentID: ContentID, to previous: ActivatedGeneration?) async
}

/// Content-family-specific validation: checksum, schema, and coverage must
/// all pass before activation. A failure names which check rejected.
package protocol GenerationValidating: Sendable {
    func validate(directory: URL, fileSystem: any ContentFileSystem) throws(RejectionReason)
}

/// Derives the render mount for an activated generation's directory. Runs
/// on the preparation actor; a derivation failure is a file-system fault.
package protocol ContentMounting: Sendable {
    func mount(for directory: URL, fileSystem: any ContentFileSystem) throws -> ContentMount
}
