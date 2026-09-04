//
//  PrimaryVectorRuntime.swift
//  _PrimaryVectorRuntime
//
//  The ONLY target in the repository allowed to import MapboxMaps
//  The access-level import keeps Mapbox types out of any public surface at
//  compile time.
//

internal import MapboxMaps
import NaviMapRuntime

package enum PrimaryVectorRuntimePhase {
    package static let populatedIn = "MapSurfaceDriving implementation"
}
