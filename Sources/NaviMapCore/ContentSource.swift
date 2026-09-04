//
//  ContentSource.swift
//  NaviMapCore
//
//  What the render pipeline is handed for a content identity: nothing, or
//  a mount prepared off the main thread from an activated generation. The
//  mount names the files a runtime loads; it is derived from the generation
//  directory every time it is needed and is never persisted.
//

import Foundation

/// A prepared, provider-neutral description of activated content. Closed
/// set: one case per content family, added by explicit decision.
package enum ContentMount: Sendable, Equatable {
    /// A GeoJSON overlay: `entry` is the feature collection inside `directory`.
    case geoJSON(directory: URL, entry: URL)

    /// The file a runtime loads for this mount.
    package var entry: URL {
        switch self {
        case .geoJSON(_, let entry): entry
        }
    }
}

package enum ContentSourceLocation: Sendable, Equatable {
    /// No activated generation: the content renders nothing locally.
    case none
    /// An activated generation, prepared for loading.
    case prepared(ContentMount)
}
