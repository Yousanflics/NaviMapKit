# ADR-001: 4D Spatial Model and Identity

- Status: Accepted (2026-08-30)
- Date: 2026-08-30
- Decision sources: docs/01-analysis-and-plan.md §2.3 / §2.4 / §2.10 / D1; docs/02-detailed-design.md §4.1 / §4.2 / §4.5 / §4.6
- Amendment policy: once accepted, revise by appending amendments rather than rewriting the body (docs/03-implementation-details.md §4-P0)

## Context

General-purpose map SDKs treat point/line/polygon/source/layer as their core vocabulary. In operational navigation software this produces three failure classes that have been observed in production aviation applications:

1. **Altitude, time, and data authority become "extra fields"** scattered across the business layer, mixed together without type protection. Two representative field failures: a hazard-notice feed whose offline timestamp was a constant placeholder, so the diff key lost its time component entirely; and a promoted tile source that reported its *installation* time as the data time, so content generated at 12:00 and installed at 18:00 was presented as 18:00 data.
2. **Identity conflated with definition equality.** A layer type whose `==` was deliberately id-only made every "the definition changed" check semantically incapable of firing (§2.3).
3. **Unknown expressed as `Optional`**, so `nil` was filtered away by a casual `if let` downstream and safety-relevant data disappeared silently in the less safe direction (§2.10).

## Decision

### 1. Navigation objects are the first-class citizens (D1)

The SDK's core types are `NavigationPosition` / `NavigationVolume` / `TemporalExtent` / `MovingEntity` / `PredictedPath` / `RoutePlan` / `RouteLeg` / `NavigationCorridor` / `NavigationConstraint` / `Hazard` / `NavigationAid` / `OperationalWeather` / `ContentAuthority` / `DataFreshness` — not source/layer/style. v0 exposes only the minimal subset derived from the frozen example (D5); the rest stay internal drafts, but **the internal implementation models them as these objects too**. "Internal draft" means "public signature not yet frozen"; it does not license implementing them in layer terms first and fixing it later.

> **Provenance note:** the closing restriction on "internal draft" is an interpretive addition made by this ADR (not stated explicitly in 01), accepted in design review.

### 2. Spatial model (02 §4.1)

- `NavigationPosition = horizontal (value + explicit CRS) + vertical + uncertainty`. The CRS travels with the value; Web Mercator is never implied.
- `VerticalCoordinate` is an explicit enum: `.msl / .agl / .ellipsoidal / .flightLevel / .chartDatum / .depth / .unknown`.
- `NavigationVolume = footprint + lower/upper (both may be .unknown) + effectivity + mode (inclusion/exclusion) + quality`, which uniformly expresses airspace, temporary restrictions, geofences, maritime restricted areas, hazards, and mission corridors.

### 3. Unknown is an explicit case, never `Optional` nil

Every dimension whose semantics include "unknown / uncertain" — vertical coordinate, data quality, freshness, validity, positional uncertainty — is expressed as an explicit enum case. Every `Optional` in a public type must have a documented **structural** nil meaning (for example `represented: RepresentedTime?` where nil means atemporal, or `prediction: PredictedPath?` where nil means no prediction product exists). Signatures such as `Optional<VerticalCoordinate>`, where nil could be read as "unknown", are banned from the public API and enforced by the `api-optionals` CI job (03 §5.4-3).

Evaluation of `.unknown` is decided by safety policy and defaults to conservatively visible; downstream code **cannot** filter it out with `if let`.

### 4. Time model: different meanings are different types (02 §4.2)

- Type family: `RepresentedTime` / `GeneratedAt` / `InstalledAt` / `ObservedAt` / `ValidityPeriod` / `ContentCycle` / `DataFreshness`.
- `ValidityPeriod` is a three-state explicit enum: `.permanent / .interval / .unknown`. `.unknown` evaluates conservatively and is **never** equivalent to `.permanent`.
- Accurate statement of protection strength: wrapper types eliminate **implicit** mixing (direct assignment or argument passing fails to compile); `.instant` is an escape hatch that cannot be removed; cross-meaning conversion is funnelled through named initializers such as `ObservedAt(assumingObservation:)`, so every downgrade is visible in a diff, greppable, and reviewable. **This is an audit mechanism, not a prohibition.**
- One `RepresentedTime` cursor per scene (02 §7.6); radar replay, hazard notices, temporary restrictions, tides, and predicted tracks all evaluate against the same cursor.

### 5. Identity and definition signature are two independent requirements (02 §4.5)

```swift
public protocol SceneComponent {
    var componentID: ComponentID { get }                  // mount/unmount lifecycle identity
    var definitionSignature: DefinitionSignature { get }   // derived from all fields; change = update
}
```

- **No fallback** deriving `definitionSignature` from the id or its hash is provided — conflating the two concepts is a trap teams fall into by default, so no room is left for it.
- Reconciler rules: id disappears → unmount; id appears → mount; same id with changed signature → update; both unchanged → no-op.
- `DefinitionSignature` is derived from stored properties by macro or codegen; missing fields are caught by exhaustive tests in NaviMapTesting.
- `AnySceneComponent.==` is defined as equal `componentID` **and** equal `definitionSignature` (closures never participate in equality; 02 §4.6).

## Rejected alternatives

| Alternative | Why rejected |
|---|---|
| source/layer/style as the business API (the mainstream renderer path) | Reproduces §2.1/§2.5: provider concepts bind the business layer and 4D semantics scatter into the app |
| Thin wrapper with renamed types | Renaming does not supply the missing 4D semantics |
| One `Date` type distinguished by field naming | Naming carries no compile-time protection; the two field failures in §2.4 are exactly where this path ends |
| Time wrappers that forbid all cross-meaning conversion (no `.instant`, no named init) | Real observations must be constructed from a `Date`, so the escape hatch cannot be removed; the promise would be unkeepable and would push conversions into more hidden forms |
| `Optional` for unknown | `nil` is silently filtered by `if let` and safety data disappears in the less safe direction (§2.10); "nil means permanent" is the same error class |
| `definitionSignature` defaulting to `hash(componentID)` | Restores identity/equality conflation and destroys the signature's ability to detect definition changes |
| Hand-written signatures per component | High risk of omitted fields with no compile-time detection; replaced by macro/codegen derivation plus exhaustive tests |

## Consequences

- **Positive:** both observed failure classes (time-semantics mixing, undetected same-id definition changes) are structurally blocked at the type level — implicit paths fail to compile, explicit paths stay auditable. Unknown values cannot be silently filtered. Aviation, maritime, and UAS domains share one spatial and temporal model.
- **Costs:** the type family and explicit enums are more verbose than bare `Date`/`Optional`; cross-meaning conversions must be written out (a feature, not a defect); `DefinitionSignature` derivation needs macro/codegen infrastructure (introduced in P2).
- **Constraint propagation:** all §4 data types must be `Sendable + Equatable` value types (02 §5.2); nothing in this ADR may introduce reference semantics.

## Enforcement and verification

- Implicit time mixing → negative compile tests in `CompilePolicyTests` (03 §5.4-1).
- Named downgrade conversion call sites → `scripts/report-time-conversions.sh` CI grep report (03 §5.4-2).
- No `Optional<VerticalCoordinate>` in the public API → the `api-optionals` job in `check-symbol-graph.py` (03 §5.4-3).
- Conservative visibility → the parameterized test matrix in 03 §5.3 (new unknown dimensions enter the matrix automatically).
- Signature completeness → exhaustive tests in NaviMapTesting.
