//
//  SceneStoreActivationConfirmer.swift
//  NaviMapKit
//
//  The generation manager's render confirmation, realized on the scene
//  store: activation binds the content to its generation directory as an
//  ordinary scene update, and "an acknowledgement covering that
//  generation" is the reconciler's acknowledgement of the revision that
//  carried the binding, checked against the epoch bound at the time. The
//  bounded wait belongs to the manager; this type only translates.
//

import Foundation
import NaviMapCore
import NaviMapOffline

package struct SceneStoreActivationConfirmer: ActivationConfirming {
    private let store: NaviMapSceneStore

    package init(store: NaviMapSceneStore) {
        self.store = store
    }

    package func confirmActivation(of generation: ActivatedGeneration) async throws -> ActivationConfirmation {
        let revision = await store.bindContentSource(generation.contentID, .prepared(generation.mount))
        guard let revision else {
            throw GenerationFailure.confirmationFailed(generation.generationID, .surfaceNotAttached)
        }
        do {
            try await store.acknowledgement(covering: revision)
        } catch let failure as AcknowledgementFailure {
            throw GenerationFailure.confirmationFailed(generation.generationID, Self.reason(for: failure))
        }
        // Regional confirmation arrives with a region-aware content family;
        // a plain acknowledgement is a full render confirmation.
        return .rendered
    }

    private static func reason(for failure: AcknowledgementFailure) -> ActivationConfirmationFailure {
        switch failure {
        case .notAttached: .surfaceNotAttached
        case .epochChanged: .epochChanged
        case .applyFailed: .applyRejected
        }
    }

    /// Rebinds to the previous generation (or unbinds). Not awaited: the
    /// rollback plan is submitted; the manager does not wait on it.
    package func submitRollback(for contentID: ContentID, to previous: ActivatedGeneration?) async {
        await store.bindContentSource(contentID, previous.map { .prepared($0.mount) } ?? .none)
    }
}
