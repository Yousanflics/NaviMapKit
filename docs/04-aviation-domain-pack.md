# P6 — Aviation domain pack: component design and publication order

Status: proposal for review. Written against the phase task list in 03 §4-P6 and the review rubric
recorded on 2026-09-02. Nothing here is published until the batch that carries it lands.

## 1. The list is not nine components

03 §4-P6 names airspace, airports, procedures, traffic, weather, routes, measurement, selection, and
altitude filtering. Treating all nine as scene components would be wrong, and expensive: most of them
are not per-frame declarations at all. They divide by *where the data comes from* and *what changes
between frames*:

| Item | Nature | Path |
|---|---|---|
| Airspace, temporary restrictions | Declared volumes, change on effectivity | **Scene component** over `NavigationVolume` |
| Traffic | Streamed positions, change every frame | **Scene component** over `MovingEntity` |
| Airports, procedures | Bulk reference data, changes per AIRAC cycle | **Content generation** (offline pipeline) |
| Weather | Bulk raster, changes per observation, replayed | **Content generation** + a cursor-driven selection |
| Routes | Already published (`RoutePath`); corridor/constraint are drafts | Component extension |
| Measurement, selection, altitude filtering | Read the scene, declare nothing | **Interaction facility**, not a component |

Two consequences follow immediately.

**Airports, procedures and weather are blocked on a second content family.** The offline pipeline
ships exactly one family, `geojson-overlay`, which validates a feature collection and mounts it as a
single GeoJSON source. Airports and procedures are the same shape and can use it as-is at small
volume; weather cannot — it is tiled raster with a time dimension, and needs the tile-archive family
that P5 deliberately did not build. Sequencing that ignores this will strand the weather batch
half-finished.

**Measurement, selection and altitude filtering must not become components.** A component that exists
to answer questions about other components inverts the reconciler's data flow and would need to
observe the scene it is part of. They belong on the handle, beside the existing
`features(at:) async -> [NavigationFeature]` (02 §3.4), which is already the published precedent.

## 2. Method

D5, unchanged from P5: **extend the frozen example by one component, then publish that component.**
A batch that does not change the example publishes nothing. Only what the example needs reaches
`public v0`; everything else stays at `package` level as an internal draft, outside SemVer (02 §3).
Each batch carries its own failure-path tests before its happy path, as P5 required.

**Correction to this proposal's first premise (2026-09-02).** An earlier draft of this document, and
the ruling that commissioned it, both stated that the primitives these components need already exist.
That was read out of 02's specification blocks and is **false in code**. Verified against this tree:
`NavigationVolume`, `MovingEntity`, `HorizontalGeometry` and `DataQuality` have no declaration
anywhere in `Sources` — `MovingEntity`'s only occurrence is inside a comment. Of the primitives named
below, only `RepresentedTime` and `NavigationPosition` are real. The design document ran ahead of the
code, and reading a specification block as though it were a delivery is exactly the mistake this
phase must not build on.

Therefore **every component below carries a dependency column**: each primitive it needs is either
*exists (at a SHA)* or *to be implemented (from a 02 §x specification)*. A primitive in the second
state lands as its **own reviewed item** — implemented, frozen, entered into the digester baseline,
and passed by both review seats — *before* the component that consumes it. This is the same treatment
the three base-primitive expansions received in P5, and it follows from the rule below rather than
being an exception to it.

Where a capability is genuinely absent from a runtime it is negotiated through
`CapabilityRequirement`, never by flattening the base surface (ADR-002 §5). A component that needs a
new *render* primitive is an ADR-002 §5 extension raised and ruled **separately** — it does not get
folded into a component definition.

## 3. Components

### 3.1 Airspace and temporary restrictions

```swift
// Public declaration type — a plain struct, as Ownship / RoutePath / OfflineOverlay are.
public struct AirspaceVolumes: Sendable {
    public var id: String                    // caller's collection identity, e.g. "class-b"
    public var volumes: [NavigationVolume]
    public var appearance: VolumeAppearance
    public var capability: CapabilityRequirement
}
// package struct AirspaceVolumesComponent: SceneComponent — the mapped component.
```

**Why the conformance is not public.** Every published declaration type today is a plain `Sendable`
struct mapped to a `package` component, and `SceneComponent.presentation` is itself `package`
(verified against this tree). Declaring `AirspaceVolumes: SceneComponent` publicly would freeze both the
protocol conformance and a package-level associated surface into the digester baseline, which is a
larger commitment than the component needs and inconsistent with the three types already shipped.

- **Primitive:** `NavigationVolume` (02 §4.1), the single representation for airspace, restrictions,
  geofences, hazards and corridors.
- **Dependency: to be implemented.** `NavigationVolume`, `HorizontalGeometry` and `DataQuality` are
  specifications only; none exists in `Sources` as of this tree. They land as a Core item of their own,
  frozen and in the digester baseline, before this component. `HorizontalGeometry` v0 is polygon only
  (outer ring plus holes).
- **Render primitive: needs an ADR-002 §5 extension.** Filled areas require `upsertArea`/`removeArea`,
  the fourth explicit base-set expansion, on the same conditions as the previous three. True volumetric
  rendering stays a capability extension; v0's depiction is footprint plus altitude labelling. That
  extension is ruled separately from this component. **Its operation granularity belongs to that
  ruling and matters here:** because identity is the *collection* and a volume entering or leaving it
  is an update, the executor must diff inside the component. So the operation is keyed per volume
  (component id plus volume address, as labelled entity markers already are) rather than per
  collection — otherwise every change retransmits the whole set, and the ledger's inverse cannot
  remove only the volumes that left.
- **Identity:** `componentID` is derived from `id` — the *collection*, not the individual volume. A
  volume appearing or disappearing inside the set is an update, not a mount/unmount, because the
  reconciler's unit of lifecycle is the declaration the application makes.
- **Signature:** every stored property, including each volume's `lower`/`upper`/`effectivity`/`mode`
  and `quality`. Altitude bounds must be inside the signature: a volume whose floor changes is a
  different volume to a pilot, and omitting it would silently skip the update.
- **Time:** each volume carries `effectivity: TemporalExtent`, evaluated against the scene cursor
  (02 §7.6). A volume outside the cursor's extent is not rendered — a *definitional* absence, not a
  failure, so it raises no issue. **`validity == .unknown` renders**, conservatively, on the same
  principle as an unknown altitude: unknown effectivity is not evidence of irrelevance. Stated
  explicitly because the sentence above admits the opposite reading.
- **Cursor hooks: exist.** `definitionSignature(at:)` and `presentation(at:)` are already on
  `SceneComponent` in this tree and are what effectivity evaluation hangs off; nothing new is needed
  for the time dimension itself.
- **Unknown:** `lower`/`upper` may be `.unknown`; `.unknown` is displayed conservatively (treated as
  potentially relevant at the current altitude) and never silently filtered. This follows the existing
  rule for `VerticalCoordinate` (02 §4.1) rather than inventing a second one.
- **Capability and degradation:** volumetric rendering is the capability at issue. The policy is the
  *application's* to choose, because only it knows whether a flattened depiction is acceptable for its
  operation, so `capability` is a stored property rather than a fixed internal decision. The default
  is `.allow(fallback: .footprintWithAltitudeLabels)` — draw the footprint and label the volume's own
  lower and upper bounds, so the reader gets the altitudes rather than the SDK silently choosing a
  slice. (An earlier draft called this `.footprintAtCursorAltitude`, which was wrong twice over: the
  cursor carries *time*, not altitude, and picking any single altitude to depict would be the SDK
  making an operational judgement it has no basis for.) A reported degradation is not a silent one, so
  this satisfies fail-visible. An application that would rather show nothing than a flattened
  restriction sets `.forbid` and receives `MapOperationalIssue.capabilityIncompatible`.
- **Dependency: the negotiator needs extending.** `CapabilityRequirement` and `DegradationPolicy` do
  not exist in `Sources` in this tree, and `CapabilityReport.degraded` — though declared — is never
  written anywhere outside its initialiser. So today the degraded path is defined but unreachable:
  negotiation can only report `incompatible`. That extension lands as its **own item** before this
  component, not inside it.
  *Worth naming, because it is the same shape as the gate failures recorded in 03 §5.4:* a field that
  is always empty reads exactly like "this never happened". `degraded` staying empty currently means
  "not implemented", but nothing distinguishes that from "no degradation occurred" — so the item that
  fills it should also make the difference legible.

#### Public surface as ruled (2026-09-03)

```swift
public struct AirspaceVolume: Sendable { public var address: String; public var volume: NavigationVolume }
public enum VolumeAppearance: Sendable { case controlled, restricted, prohibited, danger }
public struct AirspaceVolumes: Sendable {
    public init(_ id: String, volumes: [AirspaceVolume],
                appearance: VolumeAppearance,
                capability: DegradationPolicy = .allow(fallback: .footprintWithAltitudeLabels))
}
```

Four decisions, each of which rejected a simpler-looking alternative for a reason worth keeping.

- **An ordered array, not a dictionary.** `address` supplies the stable per-volume key the area
  primitive needs, so inserting into the middle still emits one `upsertArea` rather than retransmitting
  the set. A dictionary would supply that too — and discard declaration order. Draw order is
  meaningful here: layered Class B shelves and overlapping restrictions are ordinary, and with
  translucent fills which volume covers which is visible. Keying a dictionary and sorting for
  determinism would make z-order alphabetical by identifier, which is arbitrary rather than intended.
  Declaration order is draw order, as it is everywhere else in a declarative surface.
- **Appearance carries only what is presentational.** An earlier draft also had `temporary` and
  `advisory`. Both restate what the volume already carries — bounded `effectivity` *is* temporary, and
  `DataQuality.advisory` already records confidence — so they would give one fact two sources that can
  contradict each other (`appearance: .temporary` on a permanent `effectivity`). Temporality and
  confidence influence styling by **derivation** from `effectivity` and `quality`; the application does
  not declare them twice.
- **`capability` is a `DegradationPolicy`, not a `CapabilityRequirement`.** Required and optional are
  fixed for airspace (base primitives, and `volumeRendering` respectively); the only genuine choice is
  the policy. Publishing the whole requirement would freeze fields an application should not be
  setting. The component derives the full requirement internally.
- **Address defects are declaration defects.** `DeclarationDefect` gains `duplicateAddress` and
  `emptyAddress`. An empty address must not be silently replaced by a synthesised key such as
  `componentID/0:` — a synthesised identity looks exactly like one the application supplied, which
  makes it the hardest kind to diagnose later. For `duplicateAddress` the contract is written down
  rather than left to implementation: **the reported address identifies the colliding key, the earlier
  occurrence renders normally, and the later one is dropped.** Two volumes sharing an identifier can
  have entirely different shapes, so which survives has consequences; anyone changing that rule should
  know they are changing a decided semantic.

#### Effectivity in live mode: the reference instant always exists (ruled 2026-09-03)

A component's presentation is a pure function of a time reference, so it may not read the clock itself
— the same declaration would render differently on each evaluation and its signature would no longer
mean anything. But live mode has no cursor, which appears to leave effectivity unevaluable there, and
live is the ordinary case.

The resolution keeps the component pure and materialises the reference outside it: **the store
evaluates with `timeline.cursor ?? RepresentedTime(instant: clock.now())`**, sampling once per new publish
(declaration change, attach, cursor change, content binding), with the clock injected so tests can drive it. **Replay does not re-sample.** The reference is
recorded with the revision and reproduced when that revision is replayed, because replay is the
project's regression mechanism (03 §5) and a re-sampled clock would render a recorded scene at a
different instant than the one it was certified at — the same revision would stop meaning the same
thing. Sampling is for producing a revision; reproduction is for re-emitting one. `nil` still means live; nothing about
its meaning changes, it simply stops being an absent value inside the component. The component
therefore has no nil branch at all: outside the interval it does not draw, and `.unknown` or
`.permanent` does.

**A rule was nearly applied to a question it was not written for.** An earlier reading of this problem
cited §7.6 — expired content is reported rather than silently disappearing — to argue that expired
volumes should be drawn in live mode. That sentence governs **content staleness**: an expired chart
cycle is old data about something that still exists, so showing it with a freshness signal beats
showing nothing. An expired `effectivity` is the opposite case — data about something that *no longer
exists*. Drawing an ended restriction as current, or one that begins next week as present today, is
not conservatism; it is wrong, and it defeats the reason `effectivity` exists. Conservative treatment
covers the **unknown**, never the **known-expired**. This is the same failure as `degraded` being asked
two questions and `RejectionReason` serving two judges: **a rule stretched to a question it was not
designed to answer.**

**Re-evaluation is owned by the store, and is boundary-scheduled rather than periodic.** In live mode
the store takes the smallest effectivity boundary greater than the current reference across all
declared volumes and schedules exactly one re-publish at that instant on the injected clock,
recomputing the next boundary after it passes. No boundary means nothing is scheduled; a non-nil
cursor means nothing is scheduled. A periodic tick was rejected for two reasons: it spins when there is
no boundary to cross, and it writes an arbitrary constant ("at most 60 s late") into the semantics.
Boundary scheduling is exact, idles at zero cost, and leaves only the injected clock's precision as a
limit. Because the derived signature includes the effective set, crossing a boundary produces an
ordinary update and everything else is a no-op — no second path for time.

  **Effectivity intervals are half-open: `start <= t < end`.** This was found by the boundary test
  rather than by reading: `DateInterval.contains` includes its end instant, so a volume re-evaluated
  exactly at its end was still "effective" and would never be removed — the scheduled wake-up landed
  precisely on the one instant that could not act on it. Closing the interval at the start and opening
  it at the end makes the end boundary the moment the volume disappears, which is what a scheduled
  transition is for. A mechanism that fires exactly on a boundary needs the boundary's own inclusion
  rule to be deliberate; the two decisions are not independent.

#### `degraded` cannot express a component that falls back without cause

`appliedFallback != nil` with an empty missing-optional set means a component drew the fallback while
every capability it asked for was present. Writing `degraded[id] = []` for that case is not a small
untidiness: the key's presence asserts the component degraded, and its empty value asserts nothing was
missing. It fails the same test as the two failures before it — **a report is evidence only when the
absence of an entry means as much as its presence** — and this is that rule's third face, after a
permanently empty map (absence meaningless) and a stale entry (presence meaningless).

The cause is that one field is being asked two questions. `degraded` answers *which capabilities were
missing*, not *whether the depiction was reduced*. Almost always those coincide, which is why the
difference is invisible; a component falling back with full capabilities is exactly where they part.
So no entry is written — there is no missing capability to attribute it to — and the condition is
reported as an operational issue instead, because it is a **component defect**. A DEBUG assertion may
accompany that, but cannot replace it: in release the contradiction would otherwise be invisible, and
what it affects is how safety content is depicted.

Its test sits beside the two from 3a, and the three together pin all three faces: a component that
**ignores `offering` and draws in full** must leave `degraded` empty (presence must mean something); a
component that **falls back on the base set** must produce a non-empty entry visible through the
delegate and health (absence must mean something); and a component that **falls back on a fake
offering everything** must leave `degraded` empty *and* raise a component-defect issue (an entry must
not exist without a cause to attribute it to).

#### Malformed volumes: reported, not skipped, not refused (ruled 2026-09-03)

A declared collection can contain a volume that is degenerate or mixes coordinate reference systems.
Three dispositions were considered and the middle one is the ruling: the malformed volume **is not
drawn**, **every valid volume in the collection still is**, and the defect is reported once through the
delegate as `MapOperationalIssue.declarationRejected(ComponentID, address: String, DeclarationDefect)`.

- Silently skipping it violates fail-visible.
- Refusing it at `AirspaceVolumes.init` was rejected for a specific reason: §4.1 deliberately makes a
  degenerate ring **readable rather than unconstructible**, so that a malformed declaration does not
  vanish at the boundary. Refusing one layer up reinstates exactly that disappearance, with the same
  net effect on the caller. It would undo a decision taken one step earlier.
- Dropping the *whole collection* over one bad volume was never on the table: it discards valid safety
  data, which is worse than the defect being reported.

`DeclarationDefect` is its own small public enum (`degenerateRing`, `mixedReferenceSystems`) and
deliberately **not** `RejectionReason`. The reusable rule, worth stating once because it recurs:
**before reusing an error enum, ask whether it is the vocabulary of some `throws(E)`; if it is, a new
judge needs its own vocabulary.** `RejectionReason` is the content family validator's typed throw, so
adding a declaration defect to it would either place a case the validator can never throw into the
throw site's exhaustive switches, or force an honest defect into a dishonest `.schema`. The stronger
argument is what comes after: once reuse is established, the *next* declaration-layer defect gets
appended to it, and that is the change that genuinely alters the throws vocabulary.

Deduplication keys on `(componentID, volume address, defect)`, not on the revision — two malformed
volumes in one revision are two facts, and revision-keyed deduplication would let the first swallow the
second. An unchanged declaration set is already a reconciler no-op, so nothing re-reports on
re-evaluation.

#### Degradation must be reported from what was drawn (ruled 2026-09-03)

The component chooses between the full and fallback depiction; the report says whether it degraded.
If those are two independent computations they can disagree in both directions — a report claiming a
degradation that never happened, or a degraded depiction reported as clean — and the failure mode is
safety content whose visibility does not match its report.

They are therefore one computation. `PresentationFragment` carries
`appliedFallback: DegradationFallback?` — nil meaning **the full depiction was drawn**, a structural
absence rather than an unknown, and documented in those words at the property. That is the single
decision point. `SceneStore.accept()` and the executor call the same `presentation(at:offering:)` with
the same `offering = manifest.supported`, and `degraded[id]` is *projected from the fragment* rather
than recomputed. Under `.forbid` the presentation is never called and the outcome is `incompatible`
directly, which makes the contradictory state — a fragment reporting a fallback under a policy that
forbids one — structurally unreachable rather than something a runtime assertion has to catch.

**As landed (write-back).** `Capability.volumeRendering`; `DegradationFallback { footprintWithAltitudeLabels }`;
`DegradationPolicy { forbid, allow(fallback:) }`; `CapabilityRequirement { required, optional, degradation }`
with `.basePrimitives` and a `.forbid` default. A component declares its needs in **one place** —
`SceneComponent.capabilityRequirement` — and the pre-existing `requiredCapabilities` becomes a derived
default rather than a second declaration site, so the two can no longer disagree.
`PresentationFragment.appliedFallback` is `package`, not public: the fragment is internal machinery,
and the public evidence of degradation is `CapabilityReport.degraded`.

**One correction the tests forced, worth recording because it is the family we keep meeting.** The
first implementation updated `degraded` only for the components present in the incoming declaration, so
a component that stopped being declared left a **stale entry** behind — a report asserting a
degradation that no longer applied to anything on screen. `degraded` is therefore rebuilt wholesale on
each declaration. The empty-versus-stale distinction is the same one that made a permanently empty
`degraded` unreadable earlier: a report is only evidence if the absence of an entry is as meaningful as
its presence, and that is what the "component removed → cleared" test pins.

Two tests in opposite directions, and both are needed: a component that **ignores `offering` and draws
in full** must produce an empty `degraded`, and a component that **falls back on the base set** must
produce a non-empty one visible through the delegate and health. Either alone passes a constant
implementation. The second doubles as the build-time proof that the mechanism exists, which is why no
`negotiatesDegradation` flag is needed — a permanently true flag carries no more information than a
permanently empty field.

### 3.2 Traffic

```swift
public struct TrafficTargets: Sendable {          // plain struct, as above
    public var id: String
    public var source: AsyncStream<[TrafficTarget]>
    public var staleness: StalenessPolicy
    public var appearance: TrafficAppearance
}
```

- **Primitive:** `MovingEntity` (02 §4.3), whose `kind` includes air traffic. `TrafficTarget` is the
  aviation profile's specialisation, exactly as `Ownship` is today.
- **Dependency: to be implemented.** `MovingEntity` does not exist in `Sources` in this tree — its only
  occurrence is a comment. It lands as its own Core item before this component. `TrafficTarget` itself
  is likewise unimplemented: it is the aviation profile's specialisation, sitting in
  `NaviAviationMapKit` exactly as `Ownship` does, and is published with this component rather than
  with the Core item. `ObservedAt`,
  `RepresentedTime` and `NavigationPosition` **exist** and are reused unchanged.
- **Identity:** the *component* is the collection; individual targets are identified inside it by
  their own address so a target that drops out unmounts its own presentation without disturbing the
  rest.
- **Dependency: a new scene-element kind.** The existing `NavigationSceneElement.Kind.entityStream`
  carries a *single* `EntityID` with an `AsyncStream<NavigationPosition>` (verified against this tree);
  traffic is a **collection** stream. It needs a new kind that pumps the collection in the view layer
  and derives one component per target address, unmounting a target that leaves the set. That is a
  Kit-side item preceding this component.
- **Signature:** per derived target component — position, altitude, track, `quality`. **The stream
  itself never enters a signature**, exactly as `Ownship` handles it today. Deliberately excluded:
  smoothing and animation state, which are presentation and would make every frame an update.
- **Time — the point of substance here.** Every target position is an `ObservedAt`, never a
  `RepresentedTime`. The two are different types precisely so this cannot be blurred (02 §4.2), and
  traffic is where blurring it is most tempting and most dangerous: a five-minute-old target drawn as
  current is a hazard. `staleness` therefore names an explicit age at which a target is shown as stale
  and one at which it is dropped; there is no default that silently treats old data as fresh.
- **Unknown:** unknown altitude is `.unknown`, shown, and never filtered — a target at an unknown
  altitude is more dangerous than one at a known level, not less.

#### Types this component needs, and their shapes

None of these exist in `Sources` as of this tree — `EntityKind`, `KinematicState`, `TrackHistory`,
`PredictedPath`, `StalenessPolicy`, `TrafficTarget` and `MovingEntity` itself are all specification
only. `NavigationPosition`, `VerticalCoordinate`, `VerticalAccuracy`, `PositionUncertainty`,
`ObservedAt` and `EntityID` exist and are reused unchanged.

```swift
public enum EntityKind: Sendable, Equatable { case ownship, airTraffic, vessel, uas, ground, searchAndRescue }

public struct KinematicState: Sendable, Equatable {
    public var position: NavigationPosition   // carries its own uncertainty and .unknown vertical
    public var heading: Direction              // where the nose points
    public var course: Direction                // where the entity is going
    public var groundSpeed: Speed
    public var verticalRate: VerticalRate
    public var turnRate: TurnRate
    public var observedAt: ObservedAt         // never RepresentedTime
}
```

**Units are in the types, not in the field names or the documentation.** `Direction`, `Speed`,
`VerticalRate` and `TurnRate` each carry one canonical unit with named constructors (`.knots(_:)`,
`.metersPerSecond(_:)`, `.degreesTrue(_:)`, `.degreesPerSecond(_:)`) and an explicit `.unknown` case.
**`Direction`, not `Bearing`:** Core already publishes a frozen `Bearing { degreesTrue: Double }` for
the camera, which has no unknown and cannot gain one without changing a frozen type's meaning. Reusing
it would force this dimension's unknown back into an Optional — the thing §4.2 forbids — so the two
stay separate types, one for a camera angle that is always known and one for an observed direction that
may not be. A `Double` named `speed` invites the reader to guess, and a comment saying
"knots" is not checked by anything; this is the same discipline that made time a type rather than a
`Date` with a convention, applied to the dimension where confusing two units is a safety error rather
than a display bug.

**Heading and course are distinct and both required.** They differ by drift, and drift is exactly what
matters near terrain and in traffic separation; collapsing them into one field would silently pick one
meaning. Each may be `.unknown` independently — a target reporting position but not heading is
ordinary in ADS-B and must not be discarded for it.

**Unknown is an explicit case in every one of these, never an Optional** (02 §4.2). The rule's
boundary applies as ruled: these are data types, not the vocabulary of a typed throw, so the case is
correct here.

```swift
public struct TrackHistory: Sendable, Equatable {
    public var samples: [KinematicState]   // oldest first
    public var capacity: Int               // caller-declared cap; memory only, never persisted
}
public enum PredictedPath: Sendable, Equatable {
    case none                              // no prediction offered — structural, not unknown
    case declared([NavigationPosition])    // supplied by the application
}
public struct StalenessPolicy: Sendable, Equatable {
    public var staleAfter: Duration        // depiction marks the target stale
    public var dropAfter: Duration         // target is removed
    public init(staleAfter: Duration, dropAfter: Duration)   // no default: see below
}
public struct TrafficTarget: Sendable, Equatable {
    public var address: String             // the caller's stable identity, as with AirspaceVolume
    public var entity: MovingEntity        // the Core model; EntityID is derived from address
}
```

**`StalenessPolicy` has no default, deliberately.** Every other parameter in this design carries a
default so the frozen example stays short; this one does not, because there is no age at which stale
traffic is *generally* safe to keep drawing. A default would be this SDK choosing a number for an
operation it knows nothing about, and the number would be invisible in the call site that inherited
it. Making it explicit costs the caller one line and makes the value reviewable.

**There is no dead-reckoning case.** An earlier draft had `.dead(reckoningFor:)`, which would have had
the SDK extrapolate a target's future position from its kinematics. That is the SDK making an
operational prediction, on the same line as choosing an altitude slice for the reader: extrapolation
quality depends on the target's dynamics and on context the SDK does not have — an aircraft in a turn
and one in level cruise are not the same problem — and a wrong traffic projection is a safety error,
not a cosmetic one. The application has that knowledge; if it wants a projection it computes one and
passes `.declared`. The SDK draws what it is told, exactly as it neither fetches content nor invents a
position.

**`PredictedPath.none` is structural absence, not unknown** — the application is not offering a
prediction, which is different from a prediction whose value is unknown. That reading is why it is a
case rather than an Optional, and why `TrackHistory` empty is likewise not "unknown history".

#### Signature and presentation state

The derived signature covers `address`, `kind`, and the whole of `state` **except** `observedAt`, plus
`predicted` and `history.capacity`. Deliberately excluded, and each for a reason:

- **`observedAt`** — including it would make every received report an update even when nothing moved,
  which defeats the reconciler's no-op path on the highest-frequency component in the system. Staleness
  is derived from it against the evaluation reference at presentation time; it changes what is *drawn*
  without changing what is *declared*.
- **`history.samples`** — a trail is a depiction of past states, and every one of those states was
  already a declaration in its own right. Putting the samples in the signature would make each new
  report re-signature the whole trail.
- **Any smoothing, interpolation or animation state** — presentation, not declaration, and the reason
  the reconciler has one update path rather than a second one for motion.

The staleness split follows from that, with a consequence that is easy to get wrong: `dropAfter`
removes the target, so it changes the effective set and belongs in the signature, exactly as an airspace
volume leaving its interval does. `staleAfter` only changes the *depiction* — but a depiction change
still has to reach the screen, and the reconciler propagates nothing when the signature is unchanged.
Scheduling a re-evaluation at the stale boundary is therefore not sufficient on its own: it would wake
up, derive the same signature, and no-op.

So the **derived staleness state** — a discrete `fresh` / `stale` value, not `observedAt` itself —
enters the signature. This is the same move as the effective-set bitmap for airspace: the continuous
quantity stays out, because it changes on every report and would defeat the no-op path, while the
discrete state derived from it goes in, because it changes only at the boundary, which is precisely
when something must be redrawn. `nextTransition(after:)` then returns the smallest of each target's
`observedAt + staleAfter` and `observedAt + dropAfter` that is greater than the reference, and both
boundaries are half-open on the same rule as effectivity.

#### Acceptance condition: duplicate component identities must not trap (ruled 2026-09-03)

Four call sites build `Dictionary(uniqueKeysWithValues:)` keyed by `componentID`, and neither
`setComponents` nor the coordinator's `pushComponents` deduplicates — static, entity-stream and
collection components are concatenated as they are. A repeated identity therefore **traps**. Traffic is
the first feature to derive component identities from application-supplied strings, so an address
colliding with ownship or with another collection would crash the map. That is the worst available
failure for this SDK: not one piece of safety content missing, but all of it, by way of the process
dying over an application data collision.

The traffic component may not land without this closed. Four conditions:

1. **Deduplicate at `SceneStore.accept()`, not in the coordinator** — the common entry for both `setComponents` and `applyExternalSnapshot`. The store is the single write
   path; the coordinator is only one producer, and the data-source route's `initialScene` snapshot can
   carry a repeated identity without passing through the coordinator at all. Fixing the producer would
   leave the other door open.
2. **First occurrence wins**, and the later one does not enter the scene — the same rule as
   `duplicateAddress` within a collection, for the same reason: one collision must not discard the
   valid components around it.
3. **Report once as `MapOperationalIssue.duplicateComponent(ComponentID)`**, deduplicated by set
   difference as declaration defects are. Deliberately *not* `declarationRejected`: that carries a
   `component:` field and an address, which is the vocabulary of one declaration inside one component,
   whereas this conflict is *between* two components and neither owns it — pointing the field at the
   winner or the loser would both be wrong.
4. **Reachability, as measured rather than reasoned.** The first account of this said the trap was
   unreachable because `.collectionStream` had no producer. That was a statement about one door. The
   data-source route reaches the store through `applyExternalSnapshot` without passing the coordinator
   at all, and executing that path on the pre-fix tree produced
   `Fatal error: Duplicate values for key: 'ComponentID(...)'`. **It was a live defect, not a future
   risk**, present before any traffic feature existed.

   The way it hid is worth more than the crash. A first attempt to reproduce it — with the surface not
   yet ready — saw *both* components enter the desired snapshot and no trap at all, because the keyed
   dictionaries are only built in `reconcilePlan()`. So the crash is **conditional on surface
   readiness**: it stays silent in exactly the situations where tests usually run, and fires on a real
   device after the surface comes up, in front of a user. A conditional trap is worse than an
   unconditional one, because "the tests did not crash" is evidence of nothing. Reading the source told
   two reviewers the path existed; only running it revealed the *condition*, and the defect lived in the
   condition.

The four `uniqueKeysWithValues` sites stay as they are. Rewriting them to `uniquingKeysWith` would
silently merge colliding identities, which converts a loud failure into exactly the quiet one this
design refuses; the duplicate is rejected and reported at the entrance instead.

#### Dependency: a collection scene-element kind (Kit side, to be implemented)

`NavigationSceneElement.Kind.entityStream` carries a single `EntityID` with an
`AsyncStream<NavigationPosition>`. Traffic is a **collection** stream, so it needs a kind that pumps
`AsyncStream<[TrafficTarget]>` in the view layer and derives one component per `address`, unmounting a
target that leaves the set. The stream itself never enters a signature, as with `Ownship` today.

### 3.3 Routes

`RoutePath` is already `public v0`. P6 adds nothing here until the example needs a corridor or a
constraint; those remain internal drafts in `NaviMapNavigation`. Recorded so the phase list does not
imply work that the example has not asked for.

## 4. Content generations, not components

### 4.1 Airports and procedures

Reference data on an AIRAC cycle: bulk, static between cycles, and exactly the shape the existing
`geojson-overlay` family validates. They are declared as `OfflineOverlay` content with
`ContentAuthority.localAuthoritative(RefreshPolicy(...))` whose `staleAfter`/`expiredAfter` are the
cycle boundaries, and they reach the map through the activation protocol already built in P5.
**Dependency: exists.** `OfflineOverlay`, `ContentAuthority`, `RefreshPolicy` and the `geojson-overlay`
family are all in `Sources` in this tree.

**Correction: airport labels needed a mechanism this section claimed was already delivered.** An
earlier version said airports "additionally need labelled point markers, which the second
base-primitive expansion already delivered". That conflated two different paths. The labelled marker
primitive (`upsertEntityMarker(…, label:)`) serves **declarative components**; content generations
reach the surface through `setContentSource`, where the provider builds fill, line and circle layers
from a `ContentLayerPlan` — and no text at all. Implementing airports against the sentence as written
would have produced an unlabelled airport layer.

The resolution keeps the classification rather than bending it. Treating airports as a declarative
component to reach the marker primitive would have overturned the reason they are content in the first
place — they change per AIRAC cycle, not per frame — so a label is not a reason to move a dataset
across that line. Instead the content path gained the layer type it was missing: `ContentLayerPlan`
carries a symbol layer, which is an extension *inside* the existing base primitive rather than a new
one, and touches no public surface.

**The label's source property is declared in `ContentManifest`, and that is the load-bearing part.**
Because the property is named in the manifest, the family validator checks it: a generation declaring a
label whose property is missing, empty, or not a string on every feature is **rejected as a schema
failure before activation** rather than activated and drawn with blank labels. That is the same
principle as the rest of the pipeline — content is judged fit before it reaches the screen — applied to
a field that would otherwise fail silently and look like a rendering bug.

One consequence follows from the validator being a **whole-file** contract, and integrators need it
stated: a generation that mixes airport points with runway lines is rejected outright if the line
features lack the declared label property, because "every feature carries it" admits no exceptions.
That is deliberate — a partially labelled dataset is exactly the silent half-failure the check exists
to prevent — but it means the label property must be present on every feature in the generation, or the
dataset must be split into two content identities. Choosing the identity boundary is therefore also
choosing the labelling boundary.



### 4.2 Weather

Weather is the one item that needs machinery P5 did not build: tiled raster with an observation time,
replayed against the scene cursor. It requires the **tile-archive content family** — a second family
alongside `geojson-overlay`, validating a tile archive and mounting it as a raster source. That family
is a phase item in its own right and should be built and reviewed *before* the weather batch begins,
not inside it.

The cursor semantics are already decided and must not be re-invented: one `RepresentedTime` cursor per
scene drives weather replay, hazard effectivity, and predicted tracks together (02 §7.6). Weather does
not carry a private clock.

**How the cursor reaches the data is an open decision, because the obvious answer breaks a P5
invariant.** An earlier draft of this section said weather "selects the generation whose observation
time the cursor falls in". That cannot work as written: the registry holds **one active generation per
`ContentID` by construction** — activation retires the previous one (`GenerationManager` takes
`records.first { $0.state == .active }` as the predecessor and moves it to `retiring`, verified
against this tree) — so there is no set of concurrently active generations to choose between. Two ways out:

- **Multiple concurrently active generations under one identity.** A large change to the state
  machine, the leases, and the activation protocol, for one content type's benefit.
- **One generation carrying every time slice, with the cursor selecting a slice inside the mount.**
  The invariant is untouched; the time dimension lives in the family's own format, which is where a
  tile archive already expects to carry it.

**Decided (2026-09-03), now that the family is being designed: one generation carries every slice.**
Multiple concurrently active generations would rewrite the state machine, the leases and the activation
protocol for one content type's benefit, and would put the one-active-generation property —
which the whole rollback and reconciliation design rests on — behind a per-family exception. Worth
naming precisely: that property holds **by construction**, not by enforcement. `GenerationManager`
takes `records.first { $0.state == .active }` and retires it; nothing in the type system or the schema
prevents two active rows. So it is a discipline the activation path keeps, which is exactly why a
second content type asking for an exception to it is expensive. Carrying
the time dimension inside the family's own format costs nothing structural, because a tile archive
already expects to hold it.

#### Specified, not yet in this tree

The shapes below were designed and reviewed, and they are **not part of the
published tree**: none of `TileGrid`, `ContentSlice`, `ContentFamilyDispatch`
or the `tileArchive` mount can be found in `Sources` here. They are recorded
as the agreed design so the work lands against a decided shape, and this
section becomes a write-back once it does. Everything below describes intent,
not something a reader can call today.

```swift
// Core — TileGrid is specified public here; it should be package (see below).
package struct TileGrid { tileSize, minZoom, maxZoom }
package enum ContentMount { case tileArchive(directory:, entry:, grid:, slices:) }   // pure declaration
package struct ContentSlice { directory, observedAt: ObservedAt, validFrom, validUntil }
package enum ContentSourceLocation { case prepared(ContentMount, slice: Int? = nil) }
```

The selection sits where the ruling put it: **the mount is a pure declaration and the slice rides on
`ContentSourceLocation`**, so nothing in the activated artefact changes when time moves. Choosing that
over a `selected: Int?` inside the mount avoided a field whose meaning would have depended on which
code path produced the value.

Two parts of the manifest are worth noting because they are what make the rest checkable. The digest
is taken over **tiles sorted by path, with each tile's `z/x/y` name mixed in** — mixing the name in is
what makes a pair of transposed tiles a checksum failure rather than an identical digest. And the
validator's verdicts stay separable exactly as specified: a `tileCount` mismatch is `.schema`, a
correct count with a wrong digest is `.checksum`, and overlapping, empty, or misordered intervals are
`.schema`.

`ContentFamilyDispatch` selects validator and mounter from the manifest's `family`, with an unknown
family rejected as `.schema`. That is what keeps one generation manager serving every family rather
than growing a branch per content type — the second family being additive is the evidence P5's
abstraction held.

**`TileGrid` has no caller, so it should not be public.** Every planned use is inside package code
— the mount case, the family's mounter, the packer — and the batch does not touch the frozen example,
so nothing outside the SDK would be able to name it. That is the plainest form of a D5 violation: **a public entry
should have a first caller, and the example is what supplies one.** The rule earns its keep because a
published type is a commitment held for the life of 0.x whether or not anyone wanted it, and the
cheapest moment to notice that nobody did is before it ships. It becomes `package` and is published in
the batch where an application actually packs an archive.

**The acceptance condition becomes a real test when this lands.** A test asserts that the constructed
template ends in a literal `{z}/{x}/{y}.png`, carries the `file://` prefix, and contains no `%7B` —
and then asserts the counter-example directly, that `appendingPathComponent` *does* produce `%7B`. Pinning the wrong way beside the right one is what stops the next reader treating the odd-looking
string concatenation as something to tidy up.

#### The tile-archive family

- **`ContentMount` gains one case, and it does *not* carry the selection.** The enum is a closed set,
  one case per family, extended only by explicit decision (its own comment says so); this is that
  decision. `.tileArchive(directory:, entry:, slices: [SliceIndex])` — the archive plus the observation
  instants it contains, resolved at mount derivation from the manifest on the preparation actor, as the
  GeoJSON mount already is. **Which slice is current is presentation state, not part of the mount**: the
  mount is an immutable preparation product, and putting a moving selection inside it would make the
  activated artefact mutable and give two things authority over the same fact. So
  `ContentSourceComponent.presentation(at:)` picks the slice from `mount.slices` and hands that slice's
  location to `setContentSource`; the primitive and the types are untouched,
  `definitionSignature(at:)` carries the selected index, and `nextTransition(after:)` returns the next
  interval boundary. **The provider never sees time at all:** `ContentLayerPlan` receives the
  already-selected slice, so no renderer acquires a clock or a notion of which observation is current —
  the same isolation that keeps provider types out of the application's hands.
  **Dependency: to be implemented.** `ContentSourceComponent` today has neither a
  reference-parameterised signature nor a `nextTransition`; both arrive with this family.
- **The manifest declares the slices, so the validator can check them**, with a `tileCount` and a
  `sha256` per slice. The order matters and so do the two distinct verdicts: count the tiles first, then
  digest them. A count mismatch is a **`.schema`** rejection that can say *how many tiles are missing*;
  a correct count whose digest disagrees is a **`.checksum`** rejection. Collapsing both into one reason
  would throw away the only diagnostic that tells an operator whether they shipped an incomplete
  archive or a corrupted one. Slices out of monotonic order are also `.schema`. An archive declaring
  zero slices is valid content, exactly as an empty feature collection is — no observations is a real
  state, not a failure.
- **Confirmed by execution (2026-09-03): a local directory of PNG tiles does load.** A spike wrote four
  256×256 tiles at `z=1` into the app's temporary directory, pointed a raster source at
  `file://<dir>/{z}/{x}/{y}.png`, and the tiles rendered — `sourceDataLoaded … loaded=true`, no map
  loading errors, and the coverage band visible on screen exactly where tiles existed and absent where
  they did not. The format is settled by measurement, not assumption, which matters because a format
  baked into a manifest and a validator is not a local change afterwards.

  **Acceptance condition carried forward from how the spike first failed.** The first attempt built the
  template with `appendingPathComponent("{z}/{x}/{y}.png")`, which percent-encodes the braces to
  `%7Bz%7D`; the renderer then never substituted the placeholders and requested that literal path. The
  tool was not broken — a path-component API treats a template placeholder exactly as it treats a
  filename, and a template is not a path component. Because this is invisible until something fails to
  draw, the family carries a unit test asserting the constructed source's template still contains a
  literal `{z}/{x}/{y}`. Without it the trap returns silently the next time path building is
  refactored.
- **Each slice declares its `observedAt` and a half-open validity interval**, on the same rule as
  effectivity: `start <= t < end`, so a wake-up on a boundary finds the next slice rather than the one
  it is leaving.
- **A reference outside every slice's interval draws nothing, and says so.** It must **never** fall back
  to the nearest slice: presenting an observation from another time as if it were current is the same
  error as drawing an expired restriction, and worse here because a weather field carries no visible
  timestamp of its own. The content reports stale through `DataFreshness` — the channel §7.6 already
  assigns to expired content — so the absence is announced rather than silent. This is the safety rule
  of the section; the rest is mechanics.
- **Selecting a slice is an update, not an activation.** The cursor picks the slice whose interval
  contains it; that selection enters the derived signature, so crossing a slice boundary is an ordinary
  reconciler update on the existing mount. No re-activation, no second render path for time.
- **Slice boundaries are transitions in the sense 3c already defined.** `nextTransition(after:)`
  returns the next slice boundary alongside effectivity and staleness boundaries, and the half-open
  rule applies unchanged. This is the third distinct use of that mechanism, which is the evidence that
  it was not an airspace feature: **effectivity, staleness and observation slices are one problem —
  time changing what is selected.**
- **Out of scope, deliberately:** interpolation between slices. Blending two observations into a frame
  that was never observed is the SDK inventing weather, on the same line as dead reckoning; an
  application that wants it can declare finer slices.

## 5. Interaction facilities, not components

Measurement, selection, and altitude filtering read the scene and declare nothing. They extend the
handle beside `features(at:)` (02 §3.4), which is `public v0` today and returns
`NavigationFeature`, an enum whose only case is `.entity(EntityID)`.

**Selection.** `NavigationFeature` needs a case per selectable kind, added as each lands:
`.volume(ComponentID, address: String)` for airspace and `.target(ComponentID, address: String)` for
traffic. The addresses are the ones the application declared — selection hands back the caller's own
identity rather than an internal one, which is the whole reason addresses are caller-supplied. The
enum is not `@frozen`; adding a case as a component becomes selectable is an addition, and an
application switching over it must handle the default. The driver protocol gains `areaHits(at:)`
alongside today's `entityHits(at:)` — `package`, with a synchronous fake implementation — and the
addresses are recovered from the hit `AreaID`s.

**Measurement.** Distance and bearing between two `NavigationPosition`s — and the model must be
named in the API, not chosen silently. A planar approximation and a great-circle computation disagree
by kilometres at airway range, so `GeodesicModel.distance(from:to:)` and
`GeodesicModel.initialBearing(from:to:)` name the model in the call itself, with no default, on the same reasoning as `StalenessPolicy`: **there is no value the SDK can pick that is
right for an operation it knows nothing about, and a silently planar "distance" is a safety error
rather than a rounding error.** v0 offers `.greatCircle` and `.rhumbLine`, because a measured track and
a flown track are different questions. **The result carries the model that produced it**, so a value
that travels — into a log, a label, a report — cannot be read later without knowing how it was
computed.

Both are **synchronous pure functions in Core**, not `async` calls on the handle: they read no scene
state and touch no surface, and making them handle facilities would imply they do. **Only selection
needs the handle**, because only it reads what is currently displayed.

**Altitude filtering** carries its own vertical reference — `AltitudeBand` is `.msl(feet)` or
`.flightLevel`, never a bare number — and **compares only within one reference**. A flight level is a
pressure altitude: the familiar 1 FL = 100 ft holds only at standard pressure and can be out by
thousands of feet in real conditions, so converting between them without an altimeter setting would be
guessing. Every incomparable pairing — flight level against MSL, and anything AGL, ellipsoidal, chart
datum or depth — resolves to **visible**, on the same side as `.unknown`, because the failure that
matters is hiding a volume that *is* in the band. Being shown something outside the band is a nuisance;
not being shown something inside it is a safety error, and the two are not symmetric. Conversion with a
real pressure setting waits for a version that has altimeter input.

It filters what is *displayed*, and a volume or target whose altitude is
`.unknown` is **never** removed by a filter — 02 §4.1 already states that downstream code cannot filter
`.unknown` away with `if let`, and an altitude filter is precisely the downstream code that would try.
Its acceptance test is the matrix of 01 §4.3 criterion 9 — lower and upper bound each ranging over
{inside the band, outside the band, `.unknown`} — with every cell containing an `.unknown` resolving to
visible, plus one row that exists to test the rule above rather than restate it: **the same numeric
value under a different reference must also resolve to visible.**

**Only selection is on the handle.** The three facilities land in three different places, and the
earlier version of this paragraph — "all three are `async` on the handle" — contradicted both of the
decisions above it. Measurement is a synchronous Core function, because it reads no scene state.
Altitude filtering is a **declarative component parameter**: `AirspaceVolumes(…, altitudeBand:)` and
the same on traffic, entering the derived signature so that changing the band is an ordinary redraw.
**There is deliberately no filter API on the handle** — a filter applied to components after the fact
would make the depiction stop being a function of the declaration, and would give the reconciler a
second writer. Selection alone needs the handle, because it alone asks what is *currently displayed*;
and it reads without mutating, for the same reason.

## 6. Publication order, with reasons

0. **The capability negotiator's degradation path** (`CapabilityRequirement`, `DegradationPolicy`,
   `DegradationFallback`, `Capability.volumeRendering`, and the `SceneComponent` requirements that carry
   them) lands **before** the airspace component, not after. `AirspaceVolumes.capability` is a stored
   property, so publishing the component first would freeze a public initialiser that then has to
   change. If the order is ever inverted, `capability` must be left out of the public struct entirely
   rather than stored and inert — a field that exists but cannot take effect is the same defect as
   `CapabilityReport.degraded` before it was populated.
1. **`NavigationVolume` + `HorizontalGeometry` + `DataQuality` as a Core item**, then the
   `upsertArea`/`removeArea` base-set extension, then **airspace and temporary restrictions**. Three
   steps, separately reviewed, not one batch. Airspace leads the components because it is the smallest
   one that exercises volumes, effectivity, `.unknown` altitudes and capability degradation together —
   the batch most likely to expose a design error while the surface is still small.
2. **`MovingEntity` as a Core item**, then **traffic**. Introduces streamed identity and the
   `ObservedAt` staleness discipline. Second because it depends on nothing from (1) but is larger, and
   because getting staleness wrong is easier to see once volumes are on screen.
3. **Airports and procedures.** Content, not components; proves the P5 pipeline carries a second
   real dataset with no new mechanism.
4. **Tile-archive content family**, then **weather**. Ordered last of the data work because weather is
   the only item that needs a new family, and building that family under the pressure of a weather
   batch is how shortcuts get taken.
5. **Measurement, selection, altitude filtering.** Interaction, last, because each one reads the
   components above and a filter written before there is anything to filter tends to encode the
   author's assumptions rather than the data's.

Route corridor and constraint stay internal drafts throughout unless the example asks for them.

## 7. What this proposal does not decide

- The concrete shape of `VolumeAppearance`, `TrafficAppearance`, and `StalenessPolicy` — deliberately
  left to the batch that publishes them, derived from the example, per D5.
- The full case set of `DataQuality`. 02 §4.1 fixes only that it contains `.unknown`. Candidates are
  `authoritative` / `advisory` / `unknown`, but the choice belongs to the Core item that implements and
  freezes the type, where it can be settled against the digester baseline in one decision rather than
  drifting across component batches.
- Whether the tile-archive family should also serve base cartography. That is a separate question
  about the basemap and should not be settled as a side effect of the weather batch.
