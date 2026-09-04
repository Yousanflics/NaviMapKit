//
//  ContentSourceComponent.swift
//  NaviMapKit
//
//  The scene component that carries a content binding. Its definition
//  signature is the binding itself, so activating a new generation is an
//  ordinary signature-triggered update through the reconciler's decision
//  table, and unbinding is a removal — no separate content write path.
//

import Foundation
import NaviMapCore
import NaviMapScene

package struct ContentSourceComponent: SceneComponent {
    package let contentID: ContentID
    package let location: ContentSourceLocation

    package init(contentID: ContentID, location: ContentSourceLocation) {
        self.contentID = contentID
        self.location = location
    }

    package var componentID: ComponentID {
        ComponentID("navimap.content.\(contentID.rawValue)")
    }

    package var definitionSignature: DefinitionSignature {
        switch location {
        case .none:
            DefinitionSignature("content/\(contentID.rawValue)/none")
        case .prepared(let mount):
            DefinitionSignature("content/\(contentID.rawValue)/mount/\(mount.entry.standardizedFileURL.path)")
        }
    }

    package var presentation: PresentationFragment {
        PresentationFragment(operations: [.setContentSource(contentID, location)])
    }
}
