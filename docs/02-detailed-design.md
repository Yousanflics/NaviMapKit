# NaviMapKit — Detailed Design

- Document: 02 of 03 (analysis and plan → **detailed design** → implementation details)
- Status: Living document
- Prerequisite: docs/01-analysis-and-plan.md (decision numbers D1–D8 are referenced directly below)

Contents: **architecture** (§1–§2), **API design** (§3), **data design** (§4), **interface and compliance design** (§5–§6), and **detailed subsystem design** (§7).

Annotation convention:

- `public v0` — part of the v0 public API, governed by SemVer.
- `internal draft` — present in the source at `package`/`internal` access level, not governed by SemVer (D5: example-first minimal surface).

---

## 1. Architecture overview

### 1.1 Layers and dependency direction

```
┌─────────────────────────────────────────────────────┐
│ Application            import NaviAviationMapKit    │
├─────────────────────────────────────────────────────┤
│ Domain profile   NaviAviationMapKit / Maritime / UAS│
│   domain components (ownship, airspace, flight plan)│
│   units, domain validation                          │
├─────────────────────────────────────────────────────┤
│ Scene            NaviMapScene                       │
│   snapshot/delta, SceneComponent, reconciler,       │
│   render-plan generation                            │
├─────────────────────────────────────────────────────┤
│ Runtime          NaviMapRuntime                     │
│   surface-driver contract, capability negotiation,  │
│   render-plan execution                             │
├──────────────┬──────────────┬───────────────────────┤
│ Offline      │ Query /      │ Core                  │
│ NaviMap-     │ snapshot /   │ NaviMapCore           │
│ Offline      │ telemetry    │ 4D model, time, id    │
├──────────────┴──────────────┴───────────────────────┤
│ Internal/_PrimaryVectorRuntime (only renderer import)│
│ Internal/_TileRuntimeBridge, _RuntimeAssembly        │
└─────────────────────────────────────────────────────┘
```

Dependency rules (enforced by SwiftPM target dependencies plus CI):

1. `NaviMapCore` has no dependencies beyond Foundation. No UI, no provider.
2. `NaviMapScene` and `NaviMapOffline` depend only on Core.
3. `NaviMapRuntime` depends on Core and Scene.
4. Profiles depend on Core/Scene/Runtime/Offline and **transitively carry the default runtime** (`_PrimaryVectorRuntime`), so one `import NaviAviationMapKit` yields a renderable map (the SwiftPM reality behind D3).
5. `Internal/*` is never `@_exported` by a public module; `_PrimaryVectorRuntime` is the only target in the repository permitted to import a renderer SDK.

### 1.2 Surface ownership (D2)

Each `NaviMap` scene binds exactly one `SurfaceDriver` instance, which exclusively owns:

- camera and projection state;
- the render loop and frame scheduling;
- the GPU surface.

Other capabilities join **only** through three channels: the render plan (declarative), a custom render pass (`CustomRenderPassDriving` capability), or resource provision (tile/asset providers). The SDK exposes no API for obtaining the underlying view or graphics context.

### 1.3 Data flow (one-way)

```
App DataSource ──(snapshot / AsyncStream<delta>)──▶ scene store
scene store ──(desired revision)──▶ reconciler ──(render-plan diff)──▶ surface driver
surface driver ──(ack / typed events)──▶ reconciler / delegate ──▶ app
```

- The data source supplies immutable snapshots and deltas one way.
- The delegate emits user actions and operational state the other way.
- The SDK never mutates application stores; the application never touches the renderer.
- **The reconciler is the only component that can mutate runtime layer state** (01 §2.2 acceptance criterion; no "refresh this layer" seam exists, public or internal).

---

## 2. Modules and products

| Product | Targets | v0 status |
|---|---|---|
| `NaviMapKit` | Umbrella, `@_exported import` of the Core/Scene/Runtime public surface | public v0 |
| `NaviMapCore` | 4D model, time, identity, capability types | public v0 (minimal) |
| `NaviMapScene` | snapshot/delta/component/reconciler | public v0 (component protocols) + internal (reconciler implementation) |
| `NaviMapRuntime` | Surface-driver contract, manifest, assembly entry points | public v0 (assembly entry); driver protocols at `package` level |
| `NaviMapOffline` | Content authority, generation manager | public v0 (policy types and state queries); pipeline internal |
| `NaviMapNavigation` | Route plan, corridor, constraint | internal draft |
| `NaviAviationMapKit` | Aviation profile | public v0: basemap, ownship, viewport, route path; everything else internal draft |
| `NaviMaritimeMapKit` / `NaviUASMapKit` | Domain packs | P8 skeletons, internal draft |
| `NaviMapTesting` | Fake surface driver, test matrix, replay harness | public (test-only dependency) |

---

## 3. API design

**What `import NaviMapKit` publishes.** The umbrella re-exports `NaviMapCore` with `@_exported`, so every `public` declaration in Core is part of this SDK's public API by that act alone — a consumer writing `import NaviMapKit` sees all of them without naming Core. Two consequences are binding: making a type `public` in Core is a public-surface decision, not an internal one, and withdrawing the re-export later is a breaking change even if no Core type changes. The `public v0` / `internal draft` labels in this section therefore apply to Core declarations exactly as they do to declarations in the umbrella itself, and the API digester's module set must include every re-exported module (§2 module table).

### 3.1 Entry view (public v0)

The minimal surface derived from the "few lines for a working operational map" example (D5). SwiftUI first; UIKit wraps the same implementation.

```swift
// public v0 — non-generic; the builder produces [NavigationSceneElement]
public struct NaviMap: View {
    public init(
        viewport: Binding<NavigationViewport>,
        profile: MapProfile,
        handle: NaviMapHandle? = nil,            // explicit handle injection (flushViewport etc.)
        @NavigationSceneBuilder content: () -> [NavigationSceneElement]
    )
    // modifier-style optional configuration (data-source / delegate path)
    public func mapDelegate(_ delegate: any NaviMapDelegate) -> Self
    public func mapDataSource(_ dataSource: any NaviMapDataSource) -> Self
}
```

`NavigationSceneBuilder` borrows declarative composition and the mount/update/unmount content-tree idea, but its elements are navigation objects (D1), not layers. **v0 implements it with concrete `buildExpression` overloads and exposes no extension protocol** — third-party component extensibility is an explicit later decision, not an implicit v0 promise.

**Single-import guarantee:** `NaviAviationMapKit` re-exports the `NaviMapCore`/`NaviMapKit` public surface with `@_exported import`, so the frozen example compiles from one import line.

**Imperative (data-source) overload:**

```swift
public init(
    viewport: Binding<NavigationViewport>,
    profile: MapProfile,
    handle: NaviMapHandle,            // required — without a handle the data-source path
    dataSource: any NaviMapDataSource //   cannot deliver events or flush; the contract is
)                                     //   expressed in the type, not a runtime assertion
```

The declarative overload keeps `handle` optional. The differing handle requirement between the two overloads is itself the documentation: for the declarative path a handle is an enhancement, for the imperative path it is a precondition.

### 3.2 Viewport and camera (public v0)

```swift
// public v0 — intent, not provider state
public enum NavigationViewport: Sendable, Equatable {
    case free(CameraPose)
    case follow(EntityID, FollowConfiguration)
    // internal draft (not public in v0): frame(NavigationGeometry),
    //   routeOverview / missionOverview (frozen with RoutePlan / Mission)

    /// A binding intent: recomputed on **every** arrival at `.fit`; waiting for a valid
    /// surface size only delays the intent, it never consumes it. Restore applies first
    /// without animation and `.fit` then recomputes and takes over (net effect: fit wins,
    /// §7.5). What is persisted is the resulting free pose, not the intent (§7.5).
    case fit(ViewportFit)

    // `restored(fallback:)` was **removed** (recorded 2026-09-01). It resolved the
    // persisted session synchronously inside a SwiftUI `@State` initializer, which
    // cannot await, so honouring the main-thread I/O contract forced the main thread
    // to block on the IO queue instead. Restore is now wholly the coordinator's job —
    // which §7.5 already required of it — so the view-level factory was a second
    // implementation of one responsibility, and the one that produced the conflict.
    //
    // Consequence for callers: the `@State` initial value is the **fallback intent**,
    // not a startup guarantee. A persisted session overrides a `free`/`follow` initial
    // value. For a deterministic opening view use `.fit` (a single position degenerates
    // to a centred `fallbackScale`); there is no API for disabling session persistence.
    // If the persisted intent is unrepresentable or its schema is unrecognized, nothing
    // is written back and the caller's initial value stands.
}

public struct ViewportFit: Sendable, Equatable {
    public var positions: [NavigationPosition]
    public var padding: ViewportPadding      // .symmetric(horizontal:vertical:) — labels required
    public var closestScale: MapScale        // lower bound in metres per point: the camera
                                             // never comes closer than this. (The name
                                             // "maxScale" was rejected: in the scale domain
                                             // it reads exactly backwards.)
    public var fallbackScale: MapScale       // fixed centred scale for single-point or
                                             // degenerate input — an explicit field with a
                                             // documented default, never a buried constant
}

public struct FollowConfiguration: Sendable, Equatable {
    public static let courseUp: FollowConfiguration   // v0 derives course from successive
    public static let northUp: FollowConfiguration    // positions (NavigationPosition carries
    // default scale 30 m/pt                          // no course field yet)
}

public struct CameraPose: Sendable, Equatable {
    public var center: NavigationPosition
    public var scale: MapScale            // ground resolution (metres per point)
    public var bearing: Bearing           // true north; magnetic conversion lives in profiles
    public var pitchDegrees: Double
    public var padding: ViewportPadding
    // Value-range semantics:
    //   Bearing.degreesTrue accepts any Double and is interpreted modulo 360 at use
    //   (720° ≡ 0°, -90° ≡ 270°); equality compares the stored value.
    //   pitchDegrees accepts any non-negative intent; the runtime clamps to the capability
    //   range at apply time — no crash, no silent jump beyond the clamp.
    // Provider zoom never appears in the public surface; it is converted only inside the
    // internal runtime.
    // Explicitly deferred in v0 (internal draft): camera altitude and projection.
}

public extension EntityID {
    /// The scene's ownship id. Following ownship requires no internal types:
    /// `.follow(.ownship, .courseUp)`.
    static let ownship: EntityID
}

// Component landed alongside fit: RoutePath(_ positions:startLabel:endLabel:) — a pure value
// component whose definitionSignature encodes a canonical digest of the positions and, via a
// length-prefixed encoding with an explicit nil marker, the labels as well (so nil ≠ "" and a
// separator inside a label cannot shift fields). A single-point route never emits an end
// marker, and endpoint markers use a reserved id namespace so they cannot collide with
// business entities.
// Known v0 asymmetry (documented, resolved later): statically declared components update live
// on re-declaration, whereas entity streams bind at creation time.
```

- The business layer uses scale and framing intent; provider compatibility zoom exists only in the adapter (01 §2.8).
- Viewport change events distinguish their origin: `.user(gesture)` / `.program(animated:)` / `.restore`.
- **Binding and follow:** the binding expresses **intent**, not per-frame camera state. During `.follow`, 60fps camera updates are **not** written back to the binding (which would invalidate SwiftUI every frame); the actual camera is reported through the delegate's `NavigationViewportState`. When a user gesture breaks follow, the SDK writes the binding once to `.free(current pose)` with origin `.user`.
- **Restore semantics:** `.restore` is animation-free and applies strictly before the default camera or the first GPS follow (ordering guaranteed by the scene lifecycle, §7.5).

### 3.3 DataSource / Delegate (public v0)

```swift
@MainActor // public v0
public protocol NaviMapDataSource: AnyObject {
    func initialScene(for map: NaviMapHandle) async throws -> NavigationSceneSnapshot
    func updates(for map: NaviMapHandle) -> AsyncStream<NavigationSceneDelta>
}

@MainActor // public v0
public protocol NaviMapDelegate: AnyObject {
    func map(_ map: NaviMapHandle, didChange viewport: NavigationViewportState)
    func map(_ map: NaviMapHandle, didSelect feature: NavigationFeature)
    func map(_ map: NaviMapHandle, didChange health: OperationalMapHealth)
    func map(_ map: NaviMapHandle, didFail issue: MapOperationalIssue)
}
```

- `NaviMapHandle` is an opaque handle (not the view), so a delegate cannot reach internals through it.
- The declarative builder and the data source are alternatives; in SwiftUI the builder itself produces snapshots and deltas, and both paths converge on one scene store.
- Every delegate event carries a `SceneEpoch` (§4.6), so late events can be discarded safely by the caller.

**Delta-stream ownership, lifecycle, and backpressure (normative):**

1. **Ownership:** the stream is constructed by the app, which holds the continuation (the app is the producer). The SDK offers a factory `SceneDeltaStream.make(bufferingNewest: 64)` returning `(stream, continuation)` with the buffering policy preset. Hand-written `AsyncStream`s are allowed but must honour rule 3. The factory takes **no epoch parameter**: delta values carry no epoch field, epoch binding is enforced by the consumption lifecycle in rule 2, and a decorative parameter would imply a per-value check that does not exist.
2. **Lifecycle and epoch:** one return value of `updates(for:)` is bound to one `SceneEpoch`. On scene detach or epoch change the SDK stops consuming (observable by the app through `continuation.onTermination`) and discards the residual buffer; on the next attach the SDK re-runs `initialScene` (full) followed by a new `updates(for:)`. The app **never** reuses the old continuation; yielding to a terminated stream is a harmless no-op.
3. **Backpressure:** an unbounded buffer under 60fps ownship updates is a memory risk, so the policy is `.bufferingNewest(n)` (factory default 64) and the SDK's consumption loop performs **drain-and-coalesce** at each frame boundary — successive upserts for one `ComponentID` collapse to the newest, and a revision discontinuity falls back to a full snapshot per §4.6. Dropping intermediate deltas is by design; applications must not depend on every delta being applied.

### 3.4 Selection and query (public v0 minimum plus internal draft)

- `didSelect` delivers a typed `NavigationFeature` (an enum over domain objects), never a layer id or raw feature JSON.
- `func features(at: ScreenPoint) async -> [NavigationFeature]` is public v0 (point query only); area and predicate queries stay internal draft. The query continuation carries the same bounded-wait discipline as frame waits (ledger accounting, exactly-once resume, bounded timeout).

### 3.5 Errors and health (public v0)

```swift
public struct OperationalMapHealth: Sendable, Equatable {
    public var surface: SurfaceHealth               // running / degraded(reason) / lost
    public var content: [ContentID: ContentHealth]  // fresh / stale / expired / unknown
    public var capabilities: CapabilityReport       // negotiation outcome and degradation detail
}

public enum MapOperationalIssue: Error, Sendable {   // not @frozen; adding a case during 0.x
    case capabilityIncompatible(component: ComponentID, missing: CapabilitySet)
    case surfaceLost(reason: SurfaceLossReason)      // is a minor event
    // Landed once the offline pipeline supplied real failure paths, which is the
    // condition its deferral was recorded against:
    case contentActivationFailed(ContentID, ActivationFailure)
    //   ActivationFailure = .acknowledgementTimedOut
    //                     | .confirmationFailed(ActivationConfirmationFailure)
    //                     | .rejected(reason:)
    //   The confirmation reason is itself typed (.applyRejected / .epochChanged /
    //   .surfaceNotAttached) rather than a stringified description.
}
```

Principle: **safety-relevant failures are always reported explicitly; silent degradation is never allowed** (D4).

### 3.6 API stability

- SemVer; the `public v0` surface is guarded by `swift-api-digester` in CI (03 §2). The digester has been demonstrated to report a deliberate breaking change rather than idling green, and accepted breakages are itemized with justification in an allowlist.
- `internal draft` types stay at `package` access level or in underscored modules and must pass an example-derived review before being published.

---

## 4. Data design

### 4.1 Space: NavigationPosition / NavigationVolume (public v0 core)

```swift
public struct NavigationPosition: Sendable, Equatable {
    public var horizontal: HorizontalCoordinate   // value + explicit CRS, never implied
    public var vertical: VerticalCoordinate
    public var uncertainty: PositionUncertainty   // .unknown is an explicit case; its vertical
                                                  // accuracy uses the explicit two-state
                                                  // VerticalAccuracy(.known/.unknown), never an
                                                  // Optional

    /// Convenience initializer (its implicit semantics are part of the frozen example):
    /// CRS defaults to WGS84 and uncertainty defaults to the explicit `.unknown` —
    /// these are defaults, not omissions.
    public init(latitude: Double, longitude: Double, vertical: VerticalCoordinate)
}

public enum VerticalCoordinate: Sendable, Equatable {
    case msl(Measurement<UnitLength>)
    case agl(Measurement<UnitLength>)
    case ellipsoidal(Measurement<UnitLength>)
    case flightLevel(Int)
    case chartDatum(Measurement<UnitLength>)      // chart datum
    case depth(Measurement<UnitLength>)           // positive downward
    case unknown                                  // ⚠️ not an Optional nil
}
```

**Unknown semantics (01 §2.10):** `unknown` is an explicit case. What an altitude filter returns for `.unknown` is decided by **safety policy** (conservatively visible by default), and downstream code cannot filter it away with `if let`. `Optional<VerticalCoordinate>` appears in no public type.

```swift
// As landed (write-back, 2026-09-02). The sketch above this line previously named only
// NavigationVolume; the supporting types below were unnamed and are recorded here in the
// shape that shipped.
public struct HorizontalRing: Sendable, Equatable {   // implicitly closed: the last vertex
    public var vertices: [HorizontalCoordinate]       // joins the first; callers never repeat it
    public var isDegenerate: Bool                     // fewer than three vertices
}
public struct PolygonGeometry: Sendable, Equatable {
    public var outer: HorizontalRing
    public var holes: [HorizontalRing]
    public var isDegenerate: Bool
}
public enum HorizontalGeometry: Sendable, Equatable { case polygon(PolygonGeometry) }
public enum VolumeMode: Sendable, Equatable { case inclusion, exclusion }
public enum DataQuality: Sendable, Equatable { case authoritative, advisory, unknown }

public struct NavigationVolume: Sendable, Equatable {
    public var footprint: HorizontalGeometry
    public var lower: VerticalCoordinate      // may be .unknown
    public var upper: VerticalCoordinate
    public var effectivity: TemporalExtent
    public var mode: VolumeMode
    public var quality: DataQuality
    public var hasUnknownVerticalBound: Bool
}
```

One representation for airspace, temporary restrictions, geofences, maritime restricted areas, hazards, and mission corridors.

Three decisions in the landed shape are worth stating, because they are not evident from the field list.

- **A degenerate ring is readable, not rejected.** A ring with fewer than three vertices constructs
  successfully and reports `isDegenerate`. Refusing it at construction would make a malformed
  declaration *disappear* at the boundary, which is the silent-loss failure this SDK exists to avoid;
  malformation is a validation finding that must be reportable, not an initialiser that returns nil.
- **`HorizontalGeometry` is an enum with one case in v0.** Polygon is all that is published; the
  enum is the extension point for later geometries, and it being an enum rather than a protocol keeps
  the type `Equatable` and `Sendable` without existential cost.
- **`DataQuality.unknown` is a first-class answer, not a missing value.** A declaration whose
  provenance is unknown is still a declaration; safety policy treats it conservatively rather than
  filtering it away. `hasUnknownVerticalBound` exists for the same reason on the vertical axis: a
  volume with an unknown bound is potentially relevant at every altitude, never absent.

`effectivity` reuses `TemporalExtent` unchanged, including its two structural Optionals
(`represented`, `cycle`) — nil there means *absence* (no represented instant, no cycle), which §4.2's
discipline permits; what it forbids is nil standing for *unknown*, which is why `validity` is an
explicit `ValidityPeriod` and both vertical bounds are `VerticalCoordinate` rather than optionals.

### 4.2 Time model (public v0 core; motivation in 01 §2.4)

```swift
// Different meanings are different types: implicit mixing fails to compile, and cross-meaning
// conversion is funnelled into named initializers that can be audited by grep.
public struct RepresentedTime: Sendable, Equatable { public let instant: Date }  // what moment
public struct GeneratedAt:     Sendable, Equatable { public let instant: Date }  // produced
public struct InstalledAt:     Sendable, Equatable { public let instant: Date }  // installed

public struct ObservedAt: Sendable, Equatable {
    public let instant: Date
    public init(instant: Date)                                // normal construction
    public init(assumingObservation installed: InstalledAt)    // the only named downgrade path
}

public enum ValidityPeriod: Sendable, Equatable {
    case permanent                            // explicitly permanent, never expressed by nil
    case interval(DateInterval)
    case unknown                              // ⚠️ evaluated conservatively; never treated as
}                                             //   permanent

public struct TemporalExtent: Sendable, Equatable {
    public var validity: ValidityPeriod
    public var represented: RepresentedTime?  // nil = the presentation does not vary with the
                                              // timeline (atemporal: a structural state, not
                                              // unknown; the cursor has no effect on it)
    public var cycle: ContentCycle?           // nil = the content has no cycle concept
}

public enum DataFreshness: Sendable, Equatable {
    case current
    case stale(since: Date)
    case expired(at: Date)
    case unknown                              // ⚠️ explicit case; rendering policy is
}                                             //   conservative for unknown
```

- Radar replay, hazard notices, temporary restrictions, tides, currents, and predicted tracks all share one `RepresentedTime` timeline.
- Safety content with `validity == .unknown` is evaluated conservatively (visible, with freshness reported as unknown) and is **never** treated as `.permanent`.
- Optional discipline: every `Optional` in a public type must have a documented structural nil meaning (as annotated above); any dimension whose meaning includes "unknown" uses an explicit enum case instead.
  - **Scope of that rule: data types.** `VerticalCoordinate.unknown` and `ValidityPeriod.unknown` are data — the unknown is part of what the value *means*, so it earns a case.
  - **Enums that double as a `throws(E)` vocabulary are excluded.** When a type is both a stored fact and the error type of a typed throw, a case added to express "unknown" becomes a value the thrower can never produce, and every `switch` at the throw site must handle an impossible case. `RejectionReason` is such a type: it is the error of `Validator.validate() throws(RejectionReason)` *and* a record kept in the registry. Its unknown is therefore carried as `generationPreviouslyRejected(GenerationID, RejectionReason?)`, whose structural nil means "rejected by a version that did not record a reason". The distinction is that the unknown here is a fact about **recording**, not about **judgement** — the validator always knows why it rejected; only history may not. (Ruled 2026-09-02.)
- **Accurate statement of protection strength:** wrapper types eliminate *implicit* mixing — direct assignment or argument passing does not compile. The `.instant` accessor is an explicit escape hatch that cannot be removed (real observations must be constructed from a `Date`). Cross-meaning conversion is therefore funnelled into a named initializer, so every downgrade is visible in a diff, greppable, and reviewable. **This is an audit mechanism, not a prohibition.**

### 4.3 Moving entities: MovingEntity (public Core type from P6; see the revision note below)

```swift
public struct EntityID: Hashable, Sendable { … }   // public v0 (needed for follow)

// internal draft — not published before it is frozen
package struct MovingEntity: Sendable, Equatable {
    package var id: EntityID
    package var kind: EntityKind        // ownship / air traffic / vessel / uas / ground / sar
    package var state: KinematicState   // position, heading, course, speed, vertical speed, turn rate
    package var track: TrackHistory
    package var prediction: PredictedPath?  // nil = no prediction product exists for this entity
                                            // (a structural absence, unrelated to uncertainty)
    package var dataAge: ObservedAt     // typed, not a bare Date
    package var uncertainty: PositionUncertainty
}
```

Maritime domain models additionally require navigation status and CPA/TCPA; those enter the maritime profile as internal drafts.

*Landed shape (write-back, 2026-09-03).*

```swift
public enum EntityKind { case ownship, airTraffic, vessel, uas, ground, searchAndRescue }
public enum Direction  { case degreesTrue(Double), unknown }   // normalised at use — see below
public enum Speed      { case metersPerSecond(Double), unknown }      // .knots(_:) .kilometersPerHour(_:)
public enum VerticalRate { case metersPerSecond(Double), unknown }    // .feetPerMinute(_:), positive up
public enum TurnRate   { case degreesPerSecond(Double), unknown }     // positive clockwise
public struct KinematicState { position; heading: Direction; course: Direction
                               groundSpeed: Speed; verticalRate: VerticalRate
                               turnRate: TurnRate; observedAt: ObservedAt }
public struct TrackHistory   { samples: [KinematicState]; capacity: Int }   // memory only
public enum PredictedPath    { case none, declared([NavigationPosition]) }
public struct MovingEntity   { id: EntityID; kind; state; track; prediction }
public struct StalenessPolicy { staleAfter: Duration; dropAfter: Duration } // no default
```

Two improvements over the sketch, both adopted from the landed form (03 §7).

- **The quantity types are enums, not structs with an `unknown` flag.** Each stores one canonical unit
  in its payload — metres per second, degrees per second — with named constructors converting at the
  boundary (`.knots(_:)`, `.feetPerMinute(_:)`) so no caller converts by hand. Making unknown a *case*
  rather than a field means an unknown speed has no numeric value to read at all, where a struct would
  have left a `Double` sitting next to a flag for someone to use without checking it. This is the same
  reason `VerticalCoordinate.unknown` is a case.
- **`Direction` accepts any degree value and is normalised where it is used** — *to be implemented in the traffic component; nothing consumes `Direction` yet.* Normalising in the
  initialiser would either reject inputs a source legitimately produces or quietly alter what the
  caller supplied; deferring it keeps the stored value exactly what was observed.

  One consequence has to be handled rather than merely noted: `degreesTrue(0)` and `degreesTrue(360)` are the same direction but not `==`, so a source alternating between the two spellings would look like a change. **The normalisation therefore belongs in the signature derivation, not in `==`.** Structural equality on the stored value stays structural — that is what makes "store what was observed" true — while the derived signature canonicalises the angle, because the signature answers *does this need redrawing*, which is a question about meaning. The two already differ deliberately elsewhere: `observedAt` is part of the value and excluded from the signature for the same class of reason. Without this, the highest-frequency component in the system takes a spurious update every time a source respells north.

*Specification revised for the traffic component (2026-09-03).* The sketch above predates the aviation phase and 04 §3.2 supersedes it in four places, **replaced rather than dropped**, each for a reason recorded there: `MovingEntity` becomes a published Core type rather than an internal draft, since a traffic component the application declares cannot be built from a type the application cannot name; `prediction` becomes a `PredictedPath` case set rather than an Optional, because "no prediction offered" is structural absence that deserves a name; `dataAge` folds into `KinematicState.observedAt`, so the observation time travels with the observation instead of beside it; and `uncertainty` folds into `position`, which already carries it. The landed shapes are written back here once the Core item lands, and where the landed form differs from either sketch, the landed form wins (03 §7).

### 4.4 Content authority: ContentAuthority (public v0)

```swift
public enum ContentAuthority: Sendable, Equatable {
    case localAuthoritative(RefreshPolicy)   // base data, terrain, safety datasets
    case remoteAllowed
    case hybrid(HybridPolicy)
}
```

Type-level guarantee (01 §4.3, criterion 6): the render source type for locally authoritative content is `ActivatedGeneration`, while a network fetcher produces `StagedDownload`. The latter does not satisfy the render pipeline's input type, so **network content cannot reach rendering without passing the activation protocol**.

**What the application can ask, and what it cannot.** v0 exposes no entry point for enumerating installed generations. This is a deliberate minimum, and it is workable only because the two states an application actually needs to distinguish are reported as *distinguishable benign signals* rather than inferred from a destructive probe:

- Staging a generation that is already active throws `generationAlreadyExists(GenerationID)`.
- Staging a generation that was previously rejected throws `generationPreviouslyRejected(GenerationID, RejectionReason)`.

Neither raises an operational issue — the first is not a failure, and the second was already reported when the rejection happened. Both are thrown **before any copy or hashing**, so asking costs nothing. This is the point of the design: an application that must decide whether to retry gets an explicit answer instead of paying for a full re-stage to discover it.

**Rejection is a persistent fact and a rejected identity is spent.** The registry keeps the rejected record and its `RejectionReason`; the SDK neither forgets a rejection nor backs off on the application's behalf. A corrected package is a *new generation* and must carry a new `GenerationID` — the identifier names bytes, not intent, so reusing it for different content would make the rejection record a lie. Consequently `health.content` reports freshness, not existence: it answers "how current is what is installed", never "is anything installed".

### 4.5 Identity model (ADR-001; 01 §2.3)

```swift
public protocol SceneComponent: Sendable {
    /// mount/unmount lifecycle identity. Same id = continuation of the same component.
    var componentID: ComponentID { get }
    /// Signature derived from all fields. A change means an update is required.
    var definitionSignature: DefinitionSignature { get }
    /// Rendering representation: the erased wrapper derives presentation from the component
    /// itself rather than requiring callers to attach `& Sendable` at erasure time.
    var presentation: PresentationFragment { get }
    /// Timeline evaluation (defaulted): a pure function of the cursor, where the default
    /// implementation means "the cursor has no effect" (atemporal is structural, not unknown).
    func definitionSignature(at cursor: RepresentedTime?) -> DefinitionSignature
    func presentation(at cursor: RepresentedTime?) -> PresentationFragment
}
```

- Two independent requirements, with **no fallback** such as `definitionSignature = hash(componentID)`.
- `DefinitionSignature` is derived from stored properties by macro or codegen; omissions are caught by exhaustive tests in NaviMapTesting.
- Reconciler semantics: id disappears → unmount; id appears → mount; same id with changed signature → update; both unchanged → no-op.

### 4.6 Scene snapshot / delta and epoch (public v0)

```swift
public struct NavigationSceneSnapshot: Sendable, Equatable {
    public var epoch: SceneEpoch          // surface attach generation + scope generation
    public var revision: SceneRevision    // monotonically increasing
    public var components: [AnySceneComponent]
    public var timeline: SceneTimeline    // current represented-time cursor
}

public struct NavigationSceneDelta: Sendable, Equatable {
    public var baseRevision: SceneRevision
    public var revision: SceneRevision
    public var changes: [SceneChange]     // upsert(AnySceneComponent) / remove(ComponentID) / timeline(…)
}
```

- Pure values, `Sendable` and `Equatable` — the only form allowed to cross actor boundaries (D6).
- **`AnySceneComponent` equality (normative):** the value-semantics erasure box holds `Sendable` closures, which are not comparable; `==` is therefore defined as equal `componentID` **and** equal `definitionSignature` — exactly what the reconciler needs, no more. Snapshot and delta equality derive from this; comparing rendering closures has no meaning here.
- `SceneEpoch` combines the surface attachment generation with the scope generation; deltas and events with a mismatched epoch are rejected, so stale routing is structurally impossible.
- If a delta's `baseRevision` does not chain, the SDK requests a full snapshot (self-healing without accumulating drift), and pending deltas from the broken chain are discarded rather than leaking into the new scene.

### 4.7 Persisted data

| Data | Form | Location |
|---|---|---|
| Viewport session | Single-file atomic write (temp file + rename) with a schema version | `Library/Application Support/NaviMapKit/viewport.v1` |
| Content generations | `content/<contentID>/generations/<gen>/…` plus a SQLite registry holding the generation state machine | the same `content/` root |
| Staging | `content/<contentID>/staging/<uuid>/`, reconciled against the registry at startup with orphans removed | the same `content/` root |

The registry is the single authority for generation state (§7.4); when directory contents and the registry disagree, the registry wins and the directory is cleaned — the key to crash recovery (01 §2.6).

---

## 5. Interface design (capability / concurrency / provider isolation)

### 5.1 Capability protocol family (`package` level; the manifest is public v0)

```swift
// Fine-grained driver capabilities (package level, invisible to applications)
package protocol MapSurfaceDriving { … }
package protocol CameraProjectionDriving { … }
package protocol VectorPresentationDriving { … }
package protocol RasterPresentationDriving { … }
package protocol TerrainPresentationDriving { … }
package protocol VolumePresentationDriving { … }
package protocol EntityPresentationDriving { … }
package protocol FeatureQueryDriving { … }
package protocol OfflineResourceDriving { … }
package protocol SnapshotDriving { … }
package protocol CustomRenderPassDriving { … }

public struct CapabilityManifest: Sendable, Equatable {  // public v0 (health reporting)
    public var supported: CapabilitySet
    public var extensions: [CapabilityExtensionID]
}
```

Component declaration (static metadata on `SceneComponent`):

```swift
public struct CapabilityRequirement: Sendable, Equatable {
    public var required: CapabilitySet
    // Reading note: CapabilitySet.missing(from: required) returns the gap relative to
    // `required` (required − self), not what `self` is missing.
    public var optional: CapabilitySet
    public var degradation: DegradationPolicy   // .allow(fallback:) / .forbid
}
```

Negotiation has three outcomes: `satisfied` / `degraded(applied fallbacks)` / `incompatible`. When `degradation == .forbid` and a capability is missing, `MapOperationalIssue.capabilityIncompatible` is reported explicitly — safety data is never silently hidden. The core render plan keeps stable base primitives while advanced capabilities arrive as capability extensions; there is no lowest-common-denominator flattening (D4).

### 5.2 Concurrency model (explicit constraints, D6)

**Global setting:** every target uses Swift 6 language mode with strict concurrency (`swiftLanguageModes: [.v6]`), effective from day one with no transition period.

**Actor boundary table (normative):**

| Component | Isolation | Notes |
|---|---|---|
| `NaviMap` view / `NaviMapHandle` / data source / delegate | `@MainActor` | UI boundary |
| Scene store (desired state + revision) | `@MainActor` | Receives snapshots and deltas; the sole minting point for published revisions |
| Reconciler core (diff computation) | `nonisolated` pure functions | All inputs and outputs are `Sendable` values |
| Render-plan execution | `@MainActor` (driver requirement) | The driver may dispatch internally |
| Content preparation (tiles, decoding, validation, SQLite) | `ContentPreparationActor` (dedicated actor and executor) | Where the "no main-thread disk or network" contract is realized |
| Generation manager state machine | A type isolated to `ContentPreparationActor` (not its own actor) | The only writer of the persisted registry. **Sharing the registry's isolation domain is the point:** a logical operation spans several registry calls (read record → decide → flip the current pointer → lease the predecessor), and a separate actor would let another domain interleave between them, losing that atomicity. Do not "correct" this back to a distinct actor. |
| Surface-driver acknowledgement | `async` methods returning from the driver's isolation | See §7.3 |

**Sendable inventory (normative):** snapshots, deltas, every §4 data type, `RenderPlan`, `CapabilityManifest`, event and error types — all `Sendable + Equatable` pure values. **Reference types never cross boundaries**; `AnySceneComponent` uses value-semantics type erasure (a `Sendable` closure plus value payload), not a class box.

**Cross-boundary protocol:** scene store (main) → reconciler (pure function) → driver (main) → acknowledgement (async, back to the generation-manager actor). Every hop carries values only. The delta stream is constructed and owned by the application, with the SDK as consumer; ownership, epoch lifecycle, and buffering follow the three normative rules in §3.3.

### 5.3 Provider isolation (compile-time plus CI, D3)

1. **Compile time:** `_PrimaryVectorRuntime` uses an access-level `internal import` of the renderer SDK. Any public declaration referencing a renderer type fails to compile. A renderer import anywhere else in the repository is rejected by a CI grep.
2. **CI symbol-graph scan:** `swift symbolgraph-extract` runs over every public product, and a script asserts that zero symbols reference renderer modules (03 §2).
3. **Naming discipline:** no provider enum and no vendor-named module in the public surface; runtime selection happens through internal assembly, and the profile decides the default runtime.

---

## 6. Compliance design

### 6.1 Code licensing

| Dependency / reference | License | Constraint and enforcement |
|---|---|---|
| Commercial vector renderer SDK (current default runtime) | Commercial terms | Using it inside the internal runtime of a private SDK consumed by first-party applications is ordinary in-application use. **If NaviMapKit is ever distributed to third parties, the vendor's SDK redistribution and token terms must be re-evaluated** (each host application uses its own access token; the SDK embeds none), and required attribution/telemetry behaviour stays inside the runtime with an attribution API surfaced upward |
| MapLibre Native | BSD-2 | May be depended on and referenced; a future MapLibre runtime only needs the copyright notice preserved |
| OpenCPN | **GPL v2** | **Conceptual reference only for domain modelling (AIS, CPA/TCPA, navigation status) — not one line of code and not one data-structure definition is copied.** A review checklist item |
| QGroundControl | GPL v3 / partly Apache | Same: conceptual reference only |
| Cesium Native | Apache 2.0 | May be referenced or depended on; preserve NOTICE |
| Apple MapKit | Closed source | Public API shape referenced only |

### 6.2 Data compliance

- **Cyclic aeronautical data:** `ContentCycle` models the effective cycle explicitly; content past its cycle without an update becomes `DataFreshness.expired` and is marked conservatively at render time rather than silently continuing to count as current. Short-cycle safety content differs from long-cycle data only in `RefreshPolicy`; the activation protocol is identical.
- **Multi-product hydrographic standards (maritime):** electronic charts, bathymetry, water level, and surface currents are modelled as **mutually independent content products** (as the standards themselves are) and may be active simultaneously; there is no single "all-purpose chart".
- **Redistribution of licensed datasets:** dataset licensing is the responsibility of the content pipeline on the application side. The SDK provides the content-authority mechanism and embeds no licensed data.
- **Disclaimer boundary:** this SDK is a situational-awareness tool, not a certified navigation source. Documentation and API naming avoid implying certified status.

### 6.3 Privacy

- The SDK neither collects nor uploads position data: ownship and traffic data are injected by the application, and track history is memory-only with a configurable length cap.
- Viewport session persistence stores camera state only, never user tracks.
- Renderer telemetry follows the application's own configuration, with the switch surfaced upward; a privacy manifest ships with the SDK declaring any required-reason API usage.

---

## 7. Detailed subsystem design

### 7.1 Scene reconciler

The reconciler keeps the validated core of a desired/actual split: generation gating for attach and surface, revision guards that reject stale applications, and an accept-check before marking a revision applied. The upgrades over that core are:

1. desired state is a component tree (a `NavigationSceneSnapshot`), not a flat struct;
2. the diff output is a component-level mount/update/unmount sequence following the identity/signature rules of §4.5, in a deterministic order (unmount → mount → update, each group ordered by id);
3. surface rebuild (style reload, controller recreation) resets the actual state and replays the tree in full, with zero business-layer participation (01 §2.5);
4. **it is the only write path** — no "invalidate and resync" seam is provided (01 §2.2).

```swift
package struct ReconcilePlan: Sendable, Equatable {
    package var epoch: SceneEpoch
    package var operations: [ReconcileOp]   // mount / update / unmount, stably ordered
    package var revision: SceneRevision
}
```

### 7.2 Render-plan execution

`ReconcilePlan` → a provider-neutral `RenderPlan` (base primitives plus capability-extension payloads) → the driver translates it into renderer source/layer operations. Render identity (the renderer-side layer and source ids) is maintained inside the driver and is invisible in the public surface.

### 7.3 Surface-driver contract and acknowledgement

```swift
@MainActor package protocol MapSurfaceDriving: AnyObject {
    var manifest: CapabilityManifest { get }
    /// `SurfaceHosting` is an opaque host protocol — the runtime target stays free of UIKit,
    /// and the concrete UIKit host lives inside the renderer target.
    func attach(to host: any SurfaceHosting, epoch: SceneEpoch) async throws
    /// loadStarted / becameReady events: the formal readiness channel for the reconciler.
    /// `becameReady` fires only after verifying the loaded style matches the target, so the
    /// view's initial default style cannot fake readiness.
    var surfaceEvents: AsyncStream<SurfaceEvent> { get }
    func apply(_ plan: RenderPlan, epoch: SceneEpoch) async throws -> ApplyAcknowledgement
    func updateCamera(_ pose: CameraPose, animated: Bool) async
    func detach() async
}

package struct ApplyAcknowledgement: Sendable, Equatable {
    package var epoch: SceneEpoch
    package var appliedRevision: SceneRevision
    package var confirmedAt: ContinuousClock.Instant
}
```

- **Base render primitives (three in v0):** `setBasemap` / `upsertEntityMarker` / `removeEntityMarker`; extensions arrive as capability extensions rather than widening the enum (ADR-002 §5).
  - *First explicit expansion:* a **polyline primitive** (the rendering substrate for route paths). Rationale: lines, points, and basemaps are baseline capabilities of every candidate runtime, so this belongs to the stable base set rather than to a capability extension. Every future expansion of the base set requires the same explicit decision record.
  - *Second explicit expansion:* `upsertEntityMarker` gains a `label: String?` parameter — a parameter on the existing marker primitive family, not a new case. A labelled marker renders as a point plus haloed text legible over light and dark basemaps; without a label the original entity image is used.
  - *Third explicit expansion:* `setContentSource(ContentID, ContentSourceLocation)` — binds an activated generation directory (or nothing) as a content source. It is a **base primitive with no capability gate**: offline authoritative content is a founding decision (D7), and the type-level guarantee that `ActivatedGeneration` is rendering's only entry (ADR-003 §C.9) requires every runtime to understand generation content, so a gated version would leave that guarantee with nowhere to land. Every runtime implements it; the manifest gains no entry.
    **Permanently `package`-level, not "publication deferred":** render primitives and the driver protocol family never enter the public surface under D3, because provider isolation depends on the application never seeing render primitives. That is a different thing from deferring the *freezing* of genuinely public types.
  - *Fourth explicit expansion:* `upsertArea` / `removeArea` — a **filled area** primitive, the substrate for airspace and restriction footprints. Rationale matches the polyline case: filled polygons are a baseline capability of every candidate runtime, so this belongs to the stable base set rather than to a capability extension. Conditions carried over from the previous three: dual implementation in the fake driver and the primary runtime, failure-path tests before the happy path, and the frozen example exercising it first. The manifest gains no entry.
    **Operation granularity is part of this decision, not the component's.** The area operation is keyed per volume — component id plus volume address, as the labelled marker family already is — because a volume collection's *identity* is the collection while a volume entering or leaving it is an *update*. Keying per collection would retransmit the whole set on every change, and the executor's inverse ledger could not remove only the volumes that left.
    **True volumetric rendering stays a capability extension.** What this primitive draws is a footprint; depicting a volume's vertical extent is a separate capability that a runtime may lack, negotiated rather than assumed.
- **Acknowledgement semantics:** the driver confirms that the plan has entered its render state (sources and layers installed, first frame scheduled). The default runtime anchors "first frame scheduled" to an observable next-frame render event rather than guessing internal timing (mitigating risk R2). Acknowledgements and applies with a mismatched epoch are rejected.
- **Failure path for pending waits:** frame-wait continuations are accounted in a ledger on the driver, where removal-to-claim guarantees exactly-once resume. `detach()` resumes every pending wait with a detached result **before** tearing down the surface (the apply side then throws `notAttached`), and each frame wait carries a bounded 8-second timeout aligned with the offline acknowledgement timeout, after which it throws an acknowledgement-timeout failure. The sequence attach → apply (awaiting a frame) → detach can therefore never hang.

### 7.4 Offline content generation state machine (failure paths complete)

Each generation's state machine in the registry (SQLite):

```
downloading → staged → validating → validated → activating → active → retiring → deleted
                                        │            │
                                        ▼            ▼
                                    rejected    activationFailed → (rollback) → previous active
```

**Normative rules:**

1. **Validation** (staged → validated): checksum, schema, and coverage must all pass before activation; on failure the entry becomes `rejected` and the staging directory is deleted.
2. **Atomic activation:** a filesystem rename switches the `current` link and the registry is updated in a single transaction; the registry is authoritative — **the symlink is derived** and is rebuilt unconditionally during startup reconciliation (rule 5), with any inconsistency overwritten.
3. **Render confirmation:** after activation the content change is submitted to the reconciler and an `ApplyAcknowledgement` covering that generation is awaited. **Until confirmation the previous generation stays `active(leased)` and cannot be deleted.**
4. **Acknowledgement timeout** (8s default, configurable) → the state becomes `activationFailed` and **rolls back automatically**: the registry points back to the previous generation, a rollback render plan is submitted, and the new generation returns to `staged` (retryable) or `rejected` by policy. There is no stable resting state of "activated but unconfirmed".
5. **Killed mid-activation:** at startup the generation manager reconciles — registry entries in `activating` or `retiring` are treated as unfinished, so `activating` rolls back to the previous `active`, `retiring` with a confirmed successor completes its deletion, incomplete `downloading` remnants are discarded as untrustworthy, staging directories without a registry entry are removed as orphans, and a directory left behind by a `rejected`/`deleted` record is removed. Reconciliation runs on `ContentPreparationActor` and **never on the main thread**.
   **This reconciliation is startup-only, and that is a precondition, not an incidental fact:** it assumes no work is in flight. Wired to a runtime reconciliation the same logic would delete downloads and staging directories belonging to operations currently running — the identical code turns from clearing garbage into interrupting live work purely by when it is invoked.
6. **Regional candidates:** a generation may take effect for its own scope while its predecessor stays leased until an in-region render confirms it; the lease is recorded in the registry and survives restart.
7. Network downloaders produce only `StagedDownload` (the type-level guarantee in §4.4), so no path can feed a network response directly into a render plan.

### 7.5 Viewport persistence and restoration

- `flushViewport()` is public v0 and **anchored on `NaviMapHandle`** — the public surface contains no global session singleton (the shape rejected in 01 §3.1). The SDK performs one lightweight flush on `didEnterBackground`, **wrapped in a background task** so a suspend race cannot lose it, and never persists continuously. The common path relies on the automatic flush; the explicit call exists for applications with additional needs.
- Restoration ordering (guaranteed by the scene lifecycle state machine): `restore viewport (no animation)` strictly precedes `default camera` and `first GPS follow activation`; GPS follow takes over only when there is no restored viewport or the user explicitly selects follow.
- **Follow-tick replay:** a position that arrives before attach completes must not be silently dropped. The coordinator records the last entity positions and replays the follow tick **after** restore once attach completes, preserving restore-before-GPS ordering; without this, follow never centres on first launch.
- **`.fit` persistence:** the session persists only free/follow. When the current intent is `.fit`, the **resulting free pose** is persisted — fit is an action, so the result is stored rather than the intent (the same philosophy the removed restore factory expressed: action and restoration states collapse to real state at the boundary). If a flush happens before fit completes (its size gate not yet satisfied), the previously effective pose is persisted.
- **Why restore never blocks the main thread (normative).** Reading the session is queued on the serial IO queue and awaited; the main thread must not wait on it synchronously. The reason is stronger than "the file is small": with a shared serial queue **the caller does not necessarily wait for its own read** — a save queued earlier (from the previous session's flush) can be ahead of it, so the block duration is set by queue history, not by the size of this operation. This is what refutes the intuition that a small synchronous read is harmless.
  *Recorded:* a bounded, documented exemption for this one file was drafted and rejected — the assertion hook's only in-scope disk surface was this one, so exempting it would have shipped the hook with zero coverage on its first day.
- **`.fit` versus restore precedence:** an explicit `.fit` intent in this session **outranks** persisted restoration. Mechanically, restore (if any) applies first without animation and the `.fit` intent then recomputes and takes over per "recomputed on every arrival at `.fit`" — net effect: fit wins. This is design, not an implementation accident; any implementation that changes this ordering is a violation.
- Storage: `ViewportSessionStore` writes a versioned DTO atomically (temp file + rename). An unrecognized schema version is discarded in favour of the default camera — never a crash, never a partial restore.

### 7.6 Timeline (SceneTimeline)

- One `RepresentedTime` cursor per scene; weather replay, hazard-notice effectivity, tides and currents, and predicted tracks all evaluate against it.
- Component evaluation is a pure function of the cursor (`presentation(at:)` and `definitionSignature(at:)` in §4.5). Cursor movement changes the derived signature of time-sensitive components, so the reconciler emits an ordinary update through the existing decision table — **there is no second path for timeline updates** — and the executor evaluates the presentation at the same cursor, so plan and rendering never diverge on which cursor they used. Components that are atemporal are immune by default implementation.
- A `nil` cursor means live. Content whose `validity` has expired is reported through `DataFreshness` rather than silently disappearing (the conservative-safety principle).
- **Scope of the sentence above (clarified 2026-09-03):** it governs **content staleness** — data that has aged about something that still exists. It does **not** govern a declared volume's `effectivity`, which says whether the thing exists at the reference instant at all; a restriction that has ended is not shown, and conservative treatment covers the unknown rather than the known-expired (04 §3.1).
- **Live mode materialises the reference rather than leaving it absent:** the store evaluates with `timeline.cursor ?? RepresentedTime(instant: clock.now())` at publish and accept, on an injected clock, so components stay pure functions of a reference that always exists. The reference is recorded with the revision, and **replay reproduces it rather than re-sampling** — replay is a regression mechanism, so a replayed revision must render exactly as it was certified. Live re-evaluation is scheduled at the next effectivity boundary rather than on a periodic tick, so there is no idle polling and no arbitrary lateness constant in the semantics. Effectivity intervals are **half-open** (`start <= t < end`): a wake-up scheduled on the end boundary must find the volume no longer effective, or the transition it was scheduled for could never take effect. **Known limitation (v0):** the boundary is a wall-clock instant while the wait itself is monotonic — the delay is computed as a difference from the current `Date` and then slept on a monotonic clock — so a system time change between scheduling and waking makes the two disagree and the re-evaluation fires early or late by that amount. It cannot be missed entirely, because every publish reschedules from the current reference, and the guard requires the recorded boundary to still be the current plan. v0 does not correct for clock adjustment; anchoring both the boundary and the wait to one clock is the fix when it is needed.
- **Deferred parameter:** an earlier sketch of this evaluation took a `freshness:` argument alongside the cursor. It is deliberately **deferred until the offline content pipeline lands**: wiring real `DataFreshness` belongs to that pipeline, and adding a placeholder parameter now would violate the standing discipline that parameters are designed against real mechanisms (the same rule that defers `contentActivationFailed` in §3.5). The cursor leg is implemented; the freshness leg arrives with the pipeline.

---

## 8. Design commitments checklist

A self-contained checklist of the commitments this design makes; each row states where the commitment is realized and how it is verified.

| # | Commitment | Realized in | Verified by |
|---|---|---|---|
| 1 | Minimal public API derived from a frozen example; unproven objects stay internal drafts | §3 (`public v0` / `internal draft` annotations), D5 | The frozen ideal example must compile unchanged; API digester |
| 2 | Explicit concurrency: Sendable inventory, actor boundaries, strict concurrency from day one | §5.2 | Language mode v6 in every target; CI assertion |
| 3 | Provider isolation enforced by the compiler plus CI, not by convention | §5.3 | Access-level imports; provider-isolation and symbol-graph jobs |
| 4 | Offline activation has complete failure paths (acknowledgement timeout, kill mid-activation) | §7.4 rules 4 and 5 | Failure-path tests written first in the offline phase |
| 5 | Conservative visibility for unknown states is executable, not a promise | §4.1, §4.2 (explicit unknown cases) | The parameterized test matrix in 03 §5.3 |
| 6 | Background flush wrapped in a background task; restoration animation-free and correctly ordered | §7.5 | Restoration-path tests; kill-and-restore verification |
| 7 | The reconciler is the only write path | §1.3, §7.1 | Public and package surface audit; historical failure-class regressions |
| 8 | Identity and definition signature stay separate | §4.5, ADR-001 | Exhaustive signature tests; no fallback derivation exists |
| 9 | Time semantics typed: implicit mixing blocked, explicit conversion audited | §4.2 | Negative compile tests plus the conversion-call-site report (03 §5.4) |
