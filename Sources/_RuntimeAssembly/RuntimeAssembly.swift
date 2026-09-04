//
//  RuntimeAssembly.swift
//  _RuntimeAssembly
//
//  Internal assembly point: profiles depend on this target to transitively
//  carry the default runtime. Profiles ask for a
//  driver here; no Provider name crosses this boundary.
//

import _PrimaryVectorRuntime
import _TileRuntimeBridge
import NaviMapRuntime

@MainActor
package enum RuntimeAssembly {
    /// The default runtime's surface driver and its host view type.
    package static func makeDefaultDriver() -> any MapSurfaceDriving {
        PrimaryVectorSurfaceDriver()
    }

    package static func makeDefaultHost() -> any SurfaceHosting {
        PrimaryVectorSurfaceHost()
    }
}
