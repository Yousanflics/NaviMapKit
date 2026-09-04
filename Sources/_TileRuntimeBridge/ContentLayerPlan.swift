//
//  ContentLayerPlan.swift
//  _TileRuntimeBridge
//
//  Turns a prepared content mount into a provider-neutral layer plan: the
//  source to load, the layers to build on it, and the family's default
//  styling. The runtime that imports the renderer turns this plan into
//  provider sources and layers; this target never reads the mount's files
//  and never imports a renderer.
//

import Foundation
import NaviMapCore
import NaviMapRuntime

package struct ContentLayerPlan: Sendable, Equatable {
    package enum Geometry: Sendable, Equatable {
        case fill
        case line
        case circle
    }

    package struct Layer: Sendable, Equatable {
        package var id: String
        package var geometry: Geometry
        /// RGBA in 0...1.
        package var color: (Double, Double, Double, Double) { style.color }
        package var style: ContentLayerStyle
    }

    package var sourceID: String
    package var sourceURL: URL
    package var layers: [Layer]

    /// The plan for a content identity's mount. Layer and source ids are
    /// derived from the content identity so unbinding removes exactly what
    /// binding created.
    package static func plan(for contentID: ContentID, mount: ContentMount) -> ContentLayerPlan {
        let base = "navimap.content.\(contentID.rawValue)"
        switch mount {
        case .geoJSON(_, let entry):
            return ContentLayerPlan(
                sourceID: base,
                sourceURL: entry,
                layers: [
                    Layer(id: "\(base).fill", geometry: .fill, style: .overlayFill),
                    Layer(id: "\(base).line", geometry: .line, style: .overlayLine),
                    Layer(id: "\(base).circle", geometry: .circle, style: .overlayPoint),
                ]
            )
        }
    }
}

/// Family-owned default styling for overlay content. Fixed in this version;
/// applications do not configure it.
package struct ContentLayerStyle: Sendable, Equatable {
    package var color: (Double, Double, Double, Double)
    package var width: Double

    package static let overlayFill = ContentLayerStyle(color: (0.85, 0.35, 0.10, 0.25), width: 0)
    package static let overlayLine = ContentLayerStyle(color: (0.85, 0.35, 0.10, 0.9), width: 2)
    package static let overlayPoint = ContentLayerStyle(color: (0.85, 0.35, 0.10, 0.9), width: 5)

    package static func == (lhs: ContentLayerStyle, rhs: ContentLayerStyle) -> Bool {
        lhs.color == rhs.color && lhs.width == rhs.width
    }
}
