//
//  MapProfile.swift
//  NaviMapKit
//
//  Public v0 profile handle. A profile is the only way an
//  app selects a runtime: domain targets (NaviAviationMapKit, …) construct
//  profiles from the internal assembly; no driver or Provider type ever
//  crosses this boundary. The factories are package — apps can hold and pass
//  a MapProfile but cannot build one from arbitrary runtimes in v0.
//

import NaviMapRuntime

public struct MapProfile: Sendable {
    /// Stable identity for logs/diagnostics (e.g. "navimap.profile.aviation.ifr").
    public var identifier: String

    package var makeDriver: @MainActor @Sendable () -> any MapSurfaceDriving
    package var makeHost: @MainActor @Sendable () -> any SurfaceHosting

    package init(
        identifier: String,
        makeDriver: @escaping @MainActor @Sendable () -> any MapSurfaceDriving,
        makeHost: @escaping @MainActor @Sendable () -> any SurfaceHosting
    ) {
        self.identifier = identifier
        self.makeDriver = makeDriver
        self.makeHost = makeHost
    }
}
