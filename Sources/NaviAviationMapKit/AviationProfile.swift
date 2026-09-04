//
//  AviationProfile.swift
//  NaviAviationMapKit
//
//  Aviation profile. One import gives an aviation app the
//  whole v0 surface, so the base modules are re-exported here.
//  The profile is the only place aviation selects a runtime — via the
//  internal assembly, never a Provider name.
//

import _RuntimeAssembly
@_exported import NaviMapCore
@_exported import NaviMapKit
import NaviMapOffline

/// Flight-rules flavor of the aviation profile. v0: profile identity only —
/// content/capability differences between VFR and IFR arrive with the chart
/// components.
public enum AviationFlightRules: String, Sendable {
    case vfr
    case ifr
}

extension MapProfile {
    /// The aviation profile on the default runtime.
    public static func aviation(_ rules: AviationFlightRules) -> MapProfile {
        MapProfile(
            identifier: "navimap.profile.aviation.\(rules.rawValue)",
            makeDriver: { RuntimeAssembly.makeDefaultDriver() },
            makeHost: { RuntimeAssembly.makeDefaultHost() }
        )
    }
}
