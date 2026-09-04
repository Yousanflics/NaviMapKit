//
//  NaviMapHandle.swift
//  NaviMapKit
//
//  Public v0 opaque handle: the app's stable reference to
//  a live map — delegate registration, point query, explicit viewport
//  flush. Deliberately NOT the view and deliberately not a global
//  singleton: everything internal stays behind package closures the
//  coordinator installs while the map is live.
//

import Foundation
import NaviMapCore
import NaviMapOffline

@MainActor
public final class NaviMapHandle {
    /// Staging and activation of the map's offline content.
    public let content = NaviMapContentAccess()

    /// Typed event sink. Weak: the handle never owns app
    /// objects.
    public weak var delegate: (any NaviMapDelegate)?

    /// Set by the map's coordinator while the map is live.
    package var onFlushViewport: (() -> Void)?
    package var onFeatureQuery: ((ScreenPoint) async -> [NavigationFeature])?

    public init() {}

    /// Persist the current viewport session (atomic write). The write is
    /// scheduled on the SDK's serial I/O queue and never runs on the main
    /// thread; this call returns immediately. No-op when no map is attached
    /// to this handle, or before the session restore has resolved.
    public func flushViewport() {
        onFlushViewport?()
    }

    /// Rendered features at a view-space point (point query
    /// only in v0). Empty when no map is attached.
    public func features(at point: ScreenPoint) async -> [NavigationFeature] {
        await onFeatureQuery?(point) ?? []
    }
}

/// The application's entry points for offline content. A downloader hands
/// over an unpacked generation directory; the map stages it, and activation
/// validates it, switches the registry, and waits for the render
/// confirmation. Failures are thrown to the caller and reported once to
/// the delegate.
@MainActor
public final class NaviMapContentAccess {
    package var onStage: ((ContentID, GenerationID, URL) async throws -> StagedDownload)?
    package var onActivate: ((StagedDownload) async throws -> Void)?

    package init() {}

    /// Moves `directory` into the map's staging area for `contentID` and
    /// registers it as generation `generation`. The directory must already
    /// hold the content family's files; the application must not touch it
    /// afterwards.
    public func stage(_ contentID: ContentID, generation: GenerationID, directory: URL) async throws -> StagedDownload {
        guard let onStage else { throw NaviMapContentError.mapNotAttached }
        return try await onStage(contentID, generation, directory)
    }

    /// Validates and activates a staged generation. Returns once the new
    /// generation is confirmed rendered; on failure the previous generation
    /// stays in effect and the failure is thrown as an operational issue.
    public func activate(_ staged: StagedDownload) async throws {
        guard let onActivate else { throw NaviMapContentError.mapNotAttached }
        try await onActivate(staged)
    }
}

public enum NaviMapContentError: Error, Sendable, Equatable {
    /// No live map is attached to the handle.
    case mapNotAttached
    /// The content identity is not declared in the map's scene.
    case contentNotDeclared(ContentID)
    /// The map's content pipeline or its storage is not available (the
    /// registry could not be opened, or a file-system or registry fault
    /// interrupted the operation); declared content reports unknown freshness.
    case contentUnavailable
    /// An internal fault prevented staging or activation (an unknown
    /// generation or a refused state transition); the previous generation
    /// stays in effect.
    case activationFailed
    /// The generation is already installed for this content. Benign: the
    /// application can discard its unpacked copy; nothing is reported to
    /// the delegate.
    case generationAlreadyExists(GenerationID)
    /// The generation was rejected earlier and its identity is spent;
    /// corrected content must be staged as a new generation. Raised before
    /// any copy or digest, and not reported to the delegate again. The
    /// reason is nil only when the rejection was recorded by an earlier
    /// version that did not keep it.
    case generationPreviouslyRejected(GenerationID, RejectionReason?)
}
