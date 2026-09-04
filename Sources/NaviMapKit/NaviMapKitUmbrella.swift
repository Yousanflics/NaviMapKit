//
//  NaviMapKitUmbrella.swift
//  NaviMapKit
//
//  Umbrella target: re-exports the public v0 faces, which are derived from
//  the frozen acceptance example (example-first API discipline).
//

@_exported import NaviMapCore
@_exported import NaviMapOffline
import NaviMapRuntime
import NaviMapScene

package enum NaviMapKitPhase {
    package static let populatedIn = "public v0 faces frozen from the acceptance example"
}
