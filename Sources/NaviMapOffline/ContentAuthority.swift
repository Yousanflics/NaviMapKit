//
//  ContentAuthority.swift
//  NaviMapOffline
//
//  Content authority is a property of content, never a global mode. These
//  types are public because the first content family consumes them end to
//  end.
//

import Foundation
import NaviMapCore

/// How long an installed generation stays trustworthy.
public struct RefreshPolicy: Sendable, Equatable {
    /// Age after which the content is reported `stale` (still rendered).
    public var staleAfter: Duration
    /// Age after which the content is reported `expired` (rendered only as
    /// a conservative fallback; the report is the safety signal).
    public var expiredAfter: Duration

    public init(staleAfter: Duration, expiredAfter: Duration) {
        precondition(expiredAfter >= staleAfter, "expiry cannot precede staleness")
        self.staleAfter = staleAfter
        self.expiredAfter = expiredAfter
    }
}

public struct HybridPolicy: Sendable, Equatable {
    /// The local generation's refresh policy; remote content may be used
    /// once the local generation is expired.
    public var local: RefreshPolicy

    public init(local: RefreshPolicy) {
        self.local = local
    }
}

public enum ContentAuthority: Sendable, Equatable {
    case localAuthoritative(RefreshPolicy)
    case remoteAllowed
    case hybrid(HybridPolicy)

    /// The refresh policy that governs freshness reporting, if any.
    public var refreshPolicy: RefreshPolicy? {
        switch self {
        case .localAuthoritative(let policy): policy
        case .hybrid(let policy): policy.local
        case .remoteAllowed: nil
        }
    }
}

/// Freshness derived from the registry's installation time and the
/// content's authority policy. Without a policy the answer is the
/// explicit `.unknown` state, never a guess.
package enum ContentFreshness {
    package static func health(
        installedAt: InstalledAt,
        authority: ContentAuthority,
        now: Date
    ) -> ContentHealth {
        guard let policy = authority.refreshPolicy else { return .unknown }
        let age = now.timeIntervalSince(installedAt.instant)
        if age >= Self.seconds(policy.expiredAfter) { return .expired }
        if age >= Self.seconds(policy.staleAfter) { return .stale }
        return .fresh
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
