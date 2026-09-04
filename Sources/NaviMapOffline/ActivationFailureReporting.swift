//
//  ActivationFailureReporting.swift
//  NaviMapOffline
//
//  The bridge from the manager's failure vocabulary to the public issue
//  the delegate receives (: safety-relevant failures are
//  reported explicitly). Only activation outcomes map; programming and
//  infrastructure errors are not activation outcomes and stay internal.
//

import NaviMapCore

package extension GenerationFailure {
    /// The public issue for this failure, or nil when the failure is not an
    /// activation outcome (unknown generation, refused transition,
    /// registry or file-system fault).
    func operationalIssue(for contentID: ContentID) -> MapOperationalIssue? {
        switch self {
        case .acknowledgementTimedOut:
            .contentActivationFailed(contentID, .acknowledgementTimedOut)
        case .confirmationFailed(_, let failure):
            .contentActivationFailed(contentID, .confirmationFailed(failure))
        case .validationFailed(_, let reason):
            .contentActivationFailed(contentID, .rejected(reason))
        case .unknownGeneration, .duplicateGeneration, .previouslyRejected, .invalidTransition, .registry, .fileSystem:
            nil
        }
    }
}
