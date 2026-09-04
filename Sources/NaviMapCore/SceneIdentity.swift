//
//  SceneIdentity.swift
//  NaviMapCore
//
//  Public v0 identity/epoch types (promoted from package forms in
//  an explicit, reviewed promotion). Semantics frozen (identity vs
//  definition signature) and epoch rejection; the public marker
//  follows because the component protocol and snapshot are
//  public v0, since the DataSource path exposes them).
//

/// Mount/unmount lifecycle identity of a scene component.
public struct ComponentID: Hashable, Sendable {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Full-definition signature; a change means the component needs an update.
/// Interim: an opaque comparable value built by conformances; the
/// macro/codegen derivation plus the exhaustiveness test land
/// with the first public domain components.
public struct DefinitionSignature: Hashable, Sendable {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Surface-attach generation + scope generation: everything
/// crossing the scene boundary carries one; mismatches are rejected.
public struct SceneEpoch: Hashable, Sendable {
    public var attachGeneration: UInt64
    public var scopeGeneration: UInt64

    public init(attachGeneration: UInt64, scopeGeneration: UInt64) {
        self.attachGeneration = attachGeneration
        self.scopeGeneration = scopeGeneration
    }
}

/// Monotonic revision of the desired scene state.
public struct SceneRevision: Hashable, Sendable, Comparable {
    public var rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: SceneRevision, rhs: SceneRevision) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
