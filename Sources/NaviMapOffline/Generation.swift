//
//  Generation.swift
//  NaviMapOffline
//
//  Generation identity, the activation state machine's vocabulary,
//  the registry record, and the two types that make the
//  type-level authority guarantee real: a downloader can
//  only produce `StagedDownload`, and the render pipeline only accepts
//  `ActivatedGeneration` — there is no conversion outside the manager.
//

import Foundation
import NaviMapCore

/// Identity of one generation of a content item, chosen by the application
/// (a cycle name, a build number, a date).
public struct GenerationID: Hashable, Sendable, Comparable {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: GenerationID, rhs: GenerationID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Every state has a defined failure transition.
package enum GenerationState: String, Sendable, Equatable {
    case downloading
    case staged
    case validating
    case validated
    case activating
    case active
    case retiring
    case deleted
    case rejected
    case activationFailed
}

/// Where a generation's files currently live: the staging tree until
/// validation passes, the generations tree afterwards.
package enum GenerationLocation: Sendable, Equatable {
    case staging(UUID)
    case generations
}

package struct GenerationRecord: Sendable, Equatable {
    package var contentID: ContentID
    package var generationID: GenerationID
    package var state: GenerationState
    package var location: GenerationLocation
    /// Set on the predecessor while a successor is active but unconfirmed;
    /// a leased generation is never deleted.
    package var isLeased: Bool
    /// Regional lease (rule 6): the region whose render must confirm the
    /// successor before this generation may retire. Survives restart.
    package var leaseScope: String?
    /// A render acknowledgement covering this generation has been received.
    package var isConfirmed: Bool
    /// Registration order within the registry (monotonic).
    package var sequence: Int64
    package var installedAt: InstalledAt
    /// Why validation rejected this generation; a persistent fact once set.
    package var rejectionReason: RejectionReason?

    package init(
        contentID: ContentID,
        generationID: GenerationID,
        state: GenerationState,
        location: GenerationLocation,
        isLeased: Bool = false,
        leaseScope: String? = nil,
        isConfirmed: Bool = false,
        sequence: Int64 = 0,
        installedAt: InstalledAt,
        rejectionReason: RejectionReason? = nil
    ) {
        self.contentID = contentID
        self.generationID = generationID
        self.state = state
        self.location = location
        self.isLeased = isLeased
        self.leaseScope = leaseScope
        self.isConfirmed = isConfirmed
        self.sequence = sequence
        self.installedAt = installedAt
        self.rejectionReason = rejectionReason
    }
}

/// What staging produces: files in the staging tree, registered as
/// `staged`. Never a render source; activation is the only way forward.
public struct StagedDownload: Sendable, Equatable {
    public var contentID: ContentID
    public var generationID: GenerationID
    /// Nil once the files have moved into the generations tree (validated).
    package var stagingID: UUID?

    package init(contentID: ContentID, generationID: GenerationID, stagingID: UUID?) {
        self.contentID = contentID
        self.generationID = generationID
        self.stagingID = stagingID
    }
}

/// The only render source type for locally authoritative content. Minted
/// exclusively by the generation manager after activation: the memberwise
/// initializer stays module-internal on purpose so nothing outside the
/// manager can mint one. The mount is derived from the directory on the
/// preparation actor whenever the generation is handed out; it is never
/// stored.
package struct ActivatedGeneration: Sendable, Equatable {
    package let contentID: ContentID
    package let generationID: GenerationID
    package let directory: URL
    package let mount: ContentMount
}

package enum GenerationFailure: Error, Sendable, Equatable {
    case unknownGeneration(GenerationID)
    /// The generation is already registered for this content; a benign
    /// outcome for an application that installs the same generation again.
    case duplicateGeneration(GenerationID)
    /// The generation was rejected earlier and its identity is spent;
    /// corrected content must arrive as a new generation. The reason is
    /// nil only for rejections recorded by a version that did not keep it.
    case previouslyRejected(GenerationID, RejectionReason?)
    case invalidTransition(GenerationID, from: GenerationState, to: GenerationState)
    case validationFailed(GenerationID, RejectionReason)
    case acknowledgementTimedOut(GenerationID)
    case confirmationFailed(GenerationID, ActivationConfirmationFailure)
    case registry(String)
    case fileSystem(String)
}

/// What happens to a generation whose activation could not be confirmed:
/// back to `staged` (retryable) or `rejected`.
package enum RollbackPolicy: Sendable, Equatable {
    case retry
    case reject
}
