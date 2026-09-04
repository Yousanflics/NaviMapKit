//
//  SceneStore.swift
//  NaviMapKit
//
//  The scene engine: owns the desired scene, the reconciler, the executor,
//  and the driver binding. Two invariants live HERE and only here:
//
//  Revision monotonicity ownership. This store is the ONLY minter of
//  SceneRevision values: every published snapshot takes the next value of a
//  store-lifetime counter. Revisions never reset — not on surface rebuild,
//  not on re-attach (epochs change instead) — so "newer revision" is a total
//  order per store and the reconciler's stale-rejection guards are sound.
//  No other code constructs a SceneRevision on the live path.
//
//  SceneEpoch ↔ driver surfaceGeneration binding. The binding is
//  explicit and single-sited in `attach(driver:host:)`:
//    1. `reconciler.attachSurface` mints the attachGeneration;
//    2. the store builds the SceneEpoch from it (+ its scopeGeneration) and
//       hands that exact epoch to `driver.attach`;
//    3. the driver's event stream is consumed by a task that captured that
//       same attachGeneration — every surfaceGeneration the driver reports
//       is forwarded to the reconciler ONLY paired with the generation it
//       was bound to at attach. The task dies with the binding (detach /
//       re-attach cancels it), so a stale driver can never feed the
//       reconciler under a newer attach.
//

import Foundation
import NaviMapCore
import NaviMapRuntime
import NaviMapScene

@MainActor
package final class NaviMapSceneStore {
    package let reconciler = ReconcilerCore()
    private let executor = RenderPlanExecutor()

    private var driver: (any MapSurfaceDriving)?
    private var eventTask: Task<Void, Never>?

    /// The epoch every published snapshot and driver attach share.
    package private(set) var boundEpoch: SceneEpoch?
    private var scopeGeneration: UInt64 = 0

    /// The single revision mint (see header).
    private var revisionCounter: UInt64 = 0
    package private(set) var lastPublishedRevision: SceneRevision?

    private var components: [AnySceneComponent] = []
    private var timeline: SceneTimeline = .realtime
    /// The clock behind realtime evaluation. Injected so tests control it;
    /// components never read a clock themselves.
    package var now: @Sendable () -> Date = { Date() }
    /// The represented time every component was evaluated at for the last
    /// published revision: the timeline cursor, or the clock sampled once
    /// at publish when the scene is realtime.
    package private(set) var publishedReference: RepresentedTime?
    /// How the store waits for a transition boundary. Injected so tests
    /// can make the wait immediate.
    package var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// The boundary the store will re-evaluate at, when the scene is
    /// realtime and some component's depiction changes on its own; nil
    /// otherwise. Exactly one wait is pending at a time.
    package private(set) var scheduledTransition: Date?
    private var transitionTask: Task<Void, Never>?
    /// Content bindings (offline pipeline): merged into every published
    /// snapshot as binding components, so an activation is an ordinary
    /// scene update and its confirmation is the reconciler's own
    /// acknowledgement — never a second write path.
    private var contentSources: [ContentID: ContentSourceLocation] = [:]
    private var acknowledgementWaiters: [AcknowledgementWaiter] = []
    /// The revision whose apply last failed, cleared by the next successful
    /// apply, so an acknowledgement requested after the failure still sees it.
    private var lastFailedRevision: SceneRevision?

    private var pumping = false
    package private(set) var lastFailure: SurfaceDriverFailure?

    /// Camera/interaction facts forwarded to the view layer (the store is
    /// the surface-event stream's single consumer).
    package var onSurfaceSignal: ((SurfaceSignal) -> Void)?
    /// Fired once per newly-refused component (fail-fast).
    package var onCapabilityRefusal: ((ComponentID, CapabilitySet) -> Void)?
    /// Fired whenever the degraded set of the report changes, so health can
    /// be re-emitted with the new projection.
    package var onDegradationChanged: (() -> Void)?
    /// Fired when a component draws a fallback although every optional
    /// capability it declared is offered: a component defect, reported
    /// once per component while it keeps doing so.
    package var onUnexpectedFallback: ((ComponentID, DegradationFallback) -> Void)?
    private var announcedUnexpectedFallbacks: Set<ComponentID> = []
    /// Fired once per newly rejected declared element (component, address,
    /// defect) while the declaration stands; a re-declaration of the same
    /// malformed element is not announced again.
    package var onDeclarationRejected: ((ComponentID, String, DeclarationDefect) -> Void)?
    /// Rejected elements already announced, keyed by component.
    private var announcedRejections: [ComponentID: Set<RejectedDeclaration>] = [:]
    /// Fired once per newly duplicated component identity while the
    /// duplicate persists: a scene-level conflict, not a declaration defect.
    package var onDuplicateComponent: ((ComponentID) -> Void)?
    private var announcedDuplicates: Set<ComponentID> = []
    /// Negotiation outcome for the current attach (nil before attach).
    package private(set) var capabilityReport: CapabilityReport?

    /// External (DataSource) revision chain — continuity only. Authority
    /// stays with the store's own mint: app revisions never become
    /// published SceneRevisions.
    private var externalRevision: SceneRevision?
    private var pendingExternalChanges: [ComponentID: SceneChange] = [:]
    private var pendingExternalTimeline: SceneTimeline?
    private var externalFlushScheduled = false

    package init() {}

    // MARK: Attach / detach (the epoch binding site)

    package func attach(driver: any MapSurfaceDriving, host: any SurfaceHosting) async throws {
        await detach()

        scopeGeneration &+= 1
        let attachGeneration = reconciler.attachSurface(initialSurfaceGeneration: 0)
        let epoch = SceneEpoch(
            attachGeneration: attachGeneration,
            scopeGeneration: scopeGeneration
        )
        boundEpoch = epoch
        self.driver = driver
        lastFailure = nil
        capabilityReport = CapabilityReport(supported: driver.manifest.supported)
        externalRevision = nil
        pendingExternalChanges = [:]
        pendingExternalTimeline = nil

        do {
            try await driver.attach(to: host, epoch: epoch)
        } catch {
            self.driver = nil
            boundEpoch = nil
            throw error
        }

        // Subscribe after attach: drivers mint one stream per attach, and
        // events emitted during attach buffer in it until consumed.
        let events = driver.surfaceEvents
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.handle(event, boundTo: attachGeneration)
            }
        }

        publishSnapshot()
    }

    package func detach() async {
        transitionTask?.cancel()
        transitionTask = nil
        scheduledTransition = nil
        eventTask?.cancel()
        eventTask = nil
        failAcknowledgementWaiters(with: .epochChanged)
        if let driver {
            self.driver = nil
            await driver.detach()
        }
        boundEpoch = nil
    }

    private func handle(_ event: SurfaceEvent, boundTo attachGeneration: UInt64) {
        // Events pair the driver's surfaceGeneration with the
        // attachGeneration captured when THIS driver was bound.
        guard attachGeneration == boundEpoch?.attachGeneration else { return }
        switch event {
        case .loadStarted(let surfaceGeneration):
            reconciler.surfaceLoadStarted(
                attachGeneration: attachGeneration,
                surfaceGeneration: surfaceGeneration
            )
            executor.surfaceDidReset()
        case .becameReady(let surfaceGeneration):
            let accepted = reconciler.surfaceBecameReady(
                attachGeneration: attachGeneration,
                surfaceGeneration: surfaceGeneration
            )
            if accepted {
                executor.surfaceDidReset()
                pump()
                onSurfaceSignal?(.becameReady)
            }
        case .userInteractionBegan:
            onSurfaceSignal?(.userInteractionBegan)
        case .cameraIdle(let pose):
            onSurfaceSignal?(.cameraIdle(pose))
        }
    }

    // MARK: Desired scene (the revision mint site)

    /// External entry for a producer's declaration: identities are
    /// de-duplicated and new duplicates announced here and nowhere else.
    package func setComponents(_ next: [AnySceneComponent]) {
        declare(deduplicated(next))
    }

    /// Publishes an already de-duplicated declaration. Internal re-entries
    /// (boundary re-evaluation, external delta flushes) come through here so
    /// they neither re-judge duplicates nor disturb what has been announced.
    private func declare(_ next: [AnySceneComponent]) {
        let reference = sampleReference()
        components = accept(next, at: reference)
        publishSnapshot(at: reference)
        pump()
    }

    /// Re-evaluates the standing declaration at a fresh reference. Used at
    /// a transition boundary: the declaration is unchanged, but the drawn
    /// set of a temporal component may not be, and that reconciles as an
    /// ordinary signature-triggered update.
    package func reevaluate() {
        declare(components)
    }

    // MARK: Transition scheduling (realtime only)

    /// After each publish in realtime, waits until the earliest boundary
    /// any component reports after the published reference, then
    /// re-evaluates once and schedules the next. Nothing is scheduled while
    /// a cursor is set, or when no component reports a boundary; there is
    /// no periodic tick.
    private func scheduleTransition(after reference: RepresentedTime) {
        transitionTask?.cancel()
        transitionTask = nil
        scheduledTransition = nil
        guard timeline.cursor == nil else { return }
        let boundary = components.compactMap { $0.makeNextTransition(reference) }.min()
        guard let boundary else { return }
        scheduledTransition = boundary
        let wait = Duration.seconds(max(0, boundary.timeIntervalSince(reference.instant)))
        transitionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await sleep(wait)
            } catch {
                return // cancelled: a newer publish owns the schedule
            }
            guard !Task.isCancelled, scheduledTransition == boundary else { return }
            reevaluate()
        }
    }

    /// The evaluation reference for one publish: the cursor when the scene
    /// replays a represented time, otherwise the clock, sampled once so
    /// every component of the revision sees the same instant. `cursor == nil`
    /// keeps meaning realtime; realtime is defined as this instant.
    private func sampleReference() -> RepresentedTime {
        timeline.cursor ?? RepresentedTime(instant: now())
    }

    /// Fail-fast capability gate: components whose requirements
    /// exceed the runtime's manifest are refused at construction — reported,
    /// recorded, and excluded from the desired scene. Never a silent drop of
    /// safety content: the refusal IS the report.
    private func accept(_ incoming: [AnySceneComponent], at reference: RepresentedTime) -> [AnySceneComponent] {
        guard var report = capabilityReport else { return incoming }
        var accepted: [AnySceneComponent] = []
        // The degraded set is rebuilt from the incoming declaration: a
        // component that is no longer declared is no longer degraded.
        let degradedBefore = report.degraded
        report.degraded = [:]
        for component in incoming {
            let missingRequired = report.supported.missing(from: component.requiredCapabilities)
            let missingOptional = report.supported.missing(from: component.optionalCapabilities)
            // A required gap, or an optional gap the component forbids
            // degrading over, refuses the component. The refusal is the
            // report; the component is never drawn.
            let refusal: CapabilitySet? = if !missingRequired.isEmpty {
                missingRequired
            } else if !missingOptional.isEmpty, component.degradation == .forbid {
                missingOptional
            } else {
                nil
            }
            if let refusal {
                if report.incompatible[component.componentID] == nil {
                    report.incompatible[component.componentID] = refusal
                    onCapabilityRefusal?(component.componentID, refusal)
                }
                continue
            }
            // Degradation is read off the depiction itself: the same
            // presentation the executor will draw, evaluated with the same
            // offering. The report can neither claim a fallback that was not
            // drawn nor miss one that was.
            let fragment = component.makePresentation(reference, report.supported)
            if let fallback = fragment.appliedFallback {
                if missingOptional.isEmpty {
                    // A fallback drawn while nothing is missing is a component
                    // defect, not a degradation: an entry with an empty set
                    // would assert a degradation that has no cause. It is
                    // reported through the issue channel, in every build.
                    if announcedUnexpectedFallbacks.insert(component.componentID).inserted {
                        onUnexpectedFallback?(component.componentID, fallback)
                    }
                } else {
                    report.degraded[component.componentID] = missingOptional
                }
            }
            announceRejections(of: component.componentID, in: fragment)
            accepted.append(component)
        }
        // Components no longer declared drop their announced rejections, so
        // a malformed element declared again later is announced again.
        let incomingIDs = Set(incoming.map(\.componentID))
        announcedRejections = announcedRejections.filter { incomingIDs.contains($0.key) }
        announcedUnexpectedFallbacks = announcedUnexpectedFallbacks.intersection(incomingIDs)
        capabilityReport = report
        if report.degraded != degradedBefore {
            onDegradationChanged?()
        }
        return accepted
    }

    /// Two components with one identity would trap the keyed tables
    /// downstream (the reconciler, the executor ledger, and the flush
    /// index all key by identity and are reached only through here). The
    /// first declared is kept; each newly duplicated identity is announced
    /// once, and announced again only after the duplicate has gone away
    /// and returned.
    private func deduplicated(_ incoming: [AnySceneComponent]) -> [AnySceneComponent] {
        var seen: Set<ComponentID> = []
        var kept: [AnySceneComponent] = []
        var duplicates: Set<ComponentID> = []
        for component in incoming {
            if seen.insert(component.componentID).inserted {
                kept.append(component)
            } else {
                duplicates.insert(component.componentID)
            }
        }
        for componentID in duplicates.subtracting(announcedDuplicates).sorted(by: { $0.rawValue < $1.rawValue }) {
            onDuplicateComponent?(componentID)
        }
        announcedDuplicates = duplicates
        return kept
    }

    /// Rejections are read off the same presentation the executor draws:
    /// an element is announced exactly when it is left out, once per
    /// (address, defect) while the declaration keeps it malformed.
    private func announceRejections(of componentID: ComponentID, in fragment: PresentationFragment) {
        let current = Set(fragment.rejectedDeclarations)
        let previous = announcedRejections[componentID] ?? []
        for rejection in fragment.rejectedDeclarations where !previous.contains(rejection) {
            onDeclarationRejected?(componentID, rejection.address, rejection.defect)
        }
        announcedRejections[componentID] = current.isEmpty ? nil : current
    }

    // MARK: External scene feed (DataSource road)

    /// Full snapshot from the app. App epoch/revision are not authority —
    /// the store keeps its single mint and tracks the app revision only as
    /// the delta-chain anchor.
    package func applyExternalSnapshot(_ snapshot: NavigationSceneSnapshot) {
        externalRevision = snapshot.revision
        pendingExternalChanges = [:]
        pendingExternalTimeline = nil
        timeline = snapshot.timeline
        setComponents(snapshot.components)
    }

    /// Incremental change. Returns false on a revision-chain gap — the
    /// caller must self-heal by re-requesting the full snapshot. Accepted
    /// changes coalesce per component (newest wins) and flush once per
    /// main-actor turn, so 60 fps bursts cost one publish per drain.
    package func applyExternalDelta(_ delta: NavigationSceneDelta) -> Bool {
        guard delta.baseRevision == externalRevision else { return false }
        externalRevision = delta.revision
        for change in delta.changes {
            switch change {
            case .upsert(let component):
                pendingExternalChanges[component.componentID] = change
            case .remove(let componentID):
                pendingExternalChanges[componentID] = change
            case .timeline(let next):
                pendingExternalTimeline = next
            }
        }
        scheduleExternalFlush()
        return true
    }

    private func scheduleExternalFlush() {
        guard !externalFlushScheduled else { return }
        externalFlushScheduled = true
        Task { @MainActor [weak self] in
            self?.flushExternalChanges()
        }
    }

    private func flushExternalChanges() {
        externalFlushScheduled = false
        guard !pendingExternalChanges.isEmpty || pendingExternalTimeline != nil else { return }
        // Identities are unique: `accept()` de-duplicated the declaration.
        var byID = Dictionary(uniqueKeysWithValues: components.map { ($0.componentID, $0) })
        var order = components.map(\.componentID)
        for (componentID, change) in pendingExternalChanges {
            switch change {
            case .upsert(let component):
                if byID[componentID] == nil { order.append(componentID) }
                byID[componentID] = component
            case .remove:
                byID[componentID] = nil
            case .timeline:
                break
            }
        }
        pendingExternalChanges = [:]
        if let pendingExternalTimeline {
            timeline = pendingExternalTimeline
        }
        pendingExternalTimeline = nil
        // Keyed by identity above, so the result is unique without another
        // de-duplication pass; announced duplicates stay as they are.
        declare(order.compactMap { byID[$0] })
    }

    // MARK: Query passthrough

    package func entityHits(at point: ScreenPoint) async -> [EntityID] {
        await driver?.entityHits(at: point) ?? []
    }

    package func setTimeline(_ next: SceneTimeline) {
        timeline = next
        publishSnapshot()
        pump()
    }

    // MARK: Content bindings and acknowledgement (offline pipeline)

    /// Binds a content identity to its activated generation (`.none`
    /// unbinds) and returns the revision that carries the change, or nil
    /// before attach (the binding is kept and published at attach).
    @discardableResult
    package func bindContentSource(_ contentID: ContentID, _ location: ContentSourceLocation) -> SceneRevision? {
        contentSources[contentID] = location == .none ? nil : location
        guard boundEpoch != nil else { return nil }
        publishSnapshot()
        pump()
        return lastPublishedRevision
    }

    package func contentSource(for contentID: ContentID) -> ContentSourceLocation {
        contentSources[contentID] ?? .none
    }

    /// Resolves once a plan whose revision covers `revision` has been
    /// acknowledged **under the epoch bound at the call**
    /// a stale epoch never confirms anything). Fails on apply failure,
    /// epoch change, or detach; honours cancellation (the caller owns the
    /// bounded wait).
    package func acknowledgement(covering revision: SceneRevision) async throws {
        guard let boundEpoch else { throw AcknowledgementFailure.notAttached }
        if let applied = reconciler.actual.appliedRevision,
           applied >= revision, reconciler.desired?.epoch == boundEpoch {
            return
        }
        if let failedRevision = lastFailedRevision, failedRevision >= revision, let lastFailure {
            throw AcknowledgementFailure.applyFailed(lastFailure)
        }
        let waiterID = UUID()
        // Cancellation ordering relies on this store being main-actor
        // isolated: the handler's hop runs after the append below even when
        // the task is already cancelled on entry, so the waiter is always
        // found and resumed with CancellationError — never leaked.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                acknowledgementWaiters.append(AcknowledgementWaiter(
                    id: waiterID, epoch: boundEpoch, revision: revision, continuation: continuation
                ))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelAcknowledgementWaiter(waiterID) }
        }
    }

    private func settleAcknowledgementWaiters(applied revision: SceneRevision, epoch: SceneEpoch) {
        let (done, pending) = acknowledgementWaiters.partitioned {
            $0.epoch == epoch && $0.revision <= revision
        }
        acknowledgementWaiters = pending
        done.forEach { $0.continuation.resume() }
    }

    private func failAcknowledgementWaiters(with failure: AcknowledgementFailure) {
        let waiters = acknowledgementWaiters
        acknowledgementWaiters = []
        waiters.forEach { $0.continuation.resume(throwing: failure) }
    }

    private func cancelAcknowledgementWaiter(_ id: UUID) {
        guard let index = acknowledgementWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = acknowledgementWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private var contentComponents: [AnySceneComponent] {
        contentSources
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { AnySceneComponent(ContentSourceComponent(contentID: $0.key, location: $0.value)) }
    }

    private func publishSnapshot(at reference: RepresentedTime? = nil) {
        guard let boundEpoch else { return } // pre-attach edits publish at attach
        let reference = reference ?? sampleReference()
        publishedReference = reference
        revisionCounter &+= 1
        let revision = SceneRevision(revisionCounter)
        lastPublishedRevision = revision
        // Temporal evaluation: signatures derive at the reference, so a
        // cursor move or a later clock sample reconciles as ordinary
        // signature-triggered updates — never a bypass.
        reconciler.updateDesired(NavigationSceneSnapshot(
            epoch: boundEpoch,
            revision: revision,
            components: components.map { $0.evaluated(at: reference) } + contentComponents,
            timeline: timeline
        ))
        scheduleTransition(after: reference)
    }

    // MARK: Camera passthrough (driver-owned camera)

    package func updateCamera(_ pose: CameraPose, animated: Bool) {
        driver?.updateCamera(pose, animated: animated)
    }

    package func currentCamera() -> CameraPose? {
        driver?.currentCamera()
    }

    // MARK: Reconcile pump

    /// Single-flight drain: plans apply strictly one at a time; whatever
    /// changes mid-apply is picked up by the next loop iteration.
    private func pump() {
        guard !pumping, driver != nil else { return }
        pumping = true
        Task { [weak self] in
            await self?.drainPlans()
        }
    }

    private func drainPlans() async {
        defer { pumping = false }
        while let driver, let plan = reconciler.reconcilePlan() {
            // The executor ledger advances at plan-build time; that is safe
            // to replay because every base primitive is idempotent — a
            // rejected/stale apply just re-emits upserts on the next plan.
            // Plans draw at the reference the desired snapshot was evaluated
            // at, so replay after a surface rebuild reproduces that revision.
            let renderPlan = executor.makeRenderPlan(
                from: plan,
                components: components + contentComponents,
                cursor: publishedReference,
                offering: driver.manifest.supported
            )
            do {
                let acknowledgement = try await driver.apply(renderPlan)
                // Epoch-mismatched acks are dropped — and the
                // pump bails rather than looping: a driver that repeatedly
                // acks the wrong epoch is broken, and `continue` would spin
                // hot on the same plan.
                guard acknowledgement.epoch == plan.epoch else {
                    lastFailure = .applyRejected(plan.revision)
                    lastFailedRevision = plan.revision
                    failAcknowledgementWaiters(with: .applyFailed(.applyRejected(plan.revision)))
                    return
                }
                if reconciler.markApplied(plan) { // internally revision-guarded
                    lastFailedRevision = nil
                    settleAcknowledgementWaiters(applied: plan.revision, epoch: plan.epoch)
                }
            } catch {
                let failure = error as? SurfaceDriverFailure ?? .applyRejected(plan.revision)
                lastFailure = failure
                lastFailedRevision = plan.revision
                failAcknowledgementWaiters(with: .applyFailed(failure))
                return // stop; the next event or desired-update re-pumps
            }
        }
    }
}

package enum AcknowledgementFailure: Error, Sendable, Equatable {
    case notAttached
    case epochChanged
    case applyFailed(SurfaceDriverFailure)
}

private struct AcknowledgementWaiter {
    let id: UUID
    let epoch: SceneEpoch
    let revision: SceneRevision
    let continuation: CheckedContinuation<Void, any Error>
}

private extension Array {
    func partitioned(by belongsToFirst: (Element) -> Bool) -> ([Element], [Element]) {
        var first: [Element] = []
        var second: [Element] = []
        for element in self {
            if belongsToFirst(element) { first.append(element) } else { second.append(element) }
        }
        return (first, second)
    }
}

/// Facts the store forwards out of the (single-consumer) surface event
/// stream for the view/viewport layer.
package enum SurfaceSignal: Sendable, Equatable {
    case becameReady
    case userInteractionBegan
    case cameraIdle(CameraPose)
}
