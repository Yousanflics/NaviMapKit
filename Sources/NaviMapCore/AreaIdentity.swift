//
//  AreaIdentity.swift
//  NaviMapCore
//
//  Render identity of one filled area. Areas are keyed per volume, not per
//  component, so a component declaring many volumes can add or drop one
//  without re-sending the rest. The address is the component's own stable
//  name for the volume within its declaration.
//

/// Identity of one rendered area: the owning component plus the
/// component's address for that area.
package struct AreaID: Hashable, Sendable {
    package var componentID: ComponentID
    package var address: String

    package init(componentID: ComponentID, address: String) {
        self.componentID = componentID
        self.address = address
    }

    /// Stable string form used for provider-side identifiers and ordering.
    package var rawValue: String {
        "\(componentID.rawValue)/\(address.utf8.count):\(address)"
    }
}
