# NaviMapKit — Analysis and Plan

- Document: 01 of 03 (analysis and plan → detailed design → implementation details)
- Status: Accepted baseline
- Naming: the repository, Swift package, umbrella module, and every public module use the **NaviMapKit** name with the `Navi` prefix. No legacy-name compatibility aliases exist. "4D Navigation Map Platform" is product positioning only.

This document answers four questions: **what it is, what it solves, why, and how.**

---

## 1. What it is

### 1.1 One sentence

NaviMapKit is an independent **4D navigation map platform**: a map SDK whose first-class citizens are position (including vertical space), time, motion state, and data authority. Vector renderers — a commercial one today, an open-source one or an in-house Metal renderer later — are internal runtime implementations only and never appear in the public API.

The target developer experience is a working operational map in a few lines:

```swift
import NaviAviationMapKit

NaviMap(viewport: $viewport, profile: .aviation(.ifr)) {
    NavigationBasemap(.operational)
    Ownship(source: ownshipFeed)
    FlightPlan(plan)
    Airspace(dataSource: airspaceSource)
    OperationalWeather(timeline: weatherTimeline)
}
```

### 1.2 What it is and is not

| Is | Is not |
|---|---|
| A navigation-semantics SDK whose first-class citizens are ownship, airspace, route plans, hazards, and moving entities | A general-purpose GIS SDK exposing point/line/polygon/source/layer as its business API |
| A provider-neutral platform: zero renderer types in the public API and symbol graph | A thin wrapper over one vector renderer |
| Three domain profiles (aviation, maritime, UAS) sharing one core and runtime | Three separate map engines |
| Offline authoritative content (`ContentAuthority`) as a core mechanism | A map with a single global "online/offline mode" switch |
| One surface driver owning camera, projection, render loop, and GPU surface | A toolbox where several engines draw into the same view |
| An independent downstream dependency: applications import one profile module and upgrade by version | A directory inside an application repository |

Composition happens at the capability and scene-component level. Each map scene has exactly one surface driver; other capabilities join through the render plan, a custom render pass, or resource provision. Otherwise camera matrices, hit testing, query results, and frame synchronization lose coherence.

### 1.3 Boundaries (explicitly out of scope for v0)

- Not a 3D game engine. High-precision WGS84 and the separation of resource fetching from render-resource preparation are worth absorbing; becoming a general 3D engine is not.
- Not turn-by-turn road navigation; road-oriented data models are explicitly not adopted.
- v0 does not freeze the public API of all fourteen first-class objects (see the example-first decision, D5).
- No style-JSON business API. Once style JSON becomes the business contract it cannot evolve.

---

## 2. What it solves

Each item below is a failure class observed in production operational-mapping software, paired with the specific SDK mechanism that removes it. These are concrete defect classes, not generic architectural virtues.

### 2.1 Renderer types permeate the business layer

**Symptom.** In a mature aviation application, well over a hundred source files import the renderer SDK directly, dozens of them inside feature modules; a single map view controller accumulates dozens of feature extensions; a coordinator grows past a thousand lines holding the renderer's callbacks directly.

**Consequence.** A renderer upgrade becomes a whole-repository migration; renderer replacement or A/B evaluation is impossible; business tests must drag in the full map stack.

**Mechanism.** Zero provider types in the public API, enforced at compile time by access-level imports and in CI by a symbol-graph scan (02 §5.3). The business layer depends only on a profile module; renderer code exists solely in the internal runtime target.

### 2.2 A second path that mutates runtime state

**Symptom.** A layer subsystem needed four rounds of rework on one defect: an implicit visibility diff missed same-id definition changes; a manual rebuild seam was added; that seam bypassed the render policy; the next version's teardown missed deleted definitions; the next missed a cache side effect. **The single root cause was the existence of a second path, outside the reconciler, able to mutate runtime layer state.**

**Mechanism and acceptance criterion.** **Outside the scene reconciler, no API can mutate runtime layer state.** All change is an immutable snapshot/delta submission that the reconciler turns into mount/update/unmount. The SDK ships no "refresh this layer" seam.

### 2.3 Identity conflated with definition equality

**Symptom.** A layer type whose `==` was deliberately id-only made "the definition changed" checks semantically incapable of firing.

**Mechanism.** ADR-001 pins two distinct concepts as two independent protocol requirements, leaving no room for a convenient `==` fallback: **identity** (`ComponentID`) drives mount/unmount lifecycle; **definition signature** (derived from all fields) drives update.

### 2.4 Untyped time semantics, so stale data passes as current

**Symptom.** Two field failures: a hazard-notice feed whose offline timestamp was a constant placeholder, dropping the time component from its diff key; and a promoted source that reported installation time as data time, so 12:00 content installed at 18:00 was presented as 18:00 data.

**Mechanism.** The time model separates `representedTime` / `validity` / `observedAt` / `generatedAt` / `installedAt` / `cycle` / `freshness` — time is an intrinsic dimension of every navigation feature, not an extra field on a weather layer. The type system **blocks implicit mixing** at compile time, and cross-meaning conversion is funnelled through a single named initializer so every downgrade is greppable and reviewable.

### 2.5 Style reload destroys runtime state, forcing manual reinstallation

**Symptom.** After a style reload the application manually reinstalls dozens of layers, with generation gating used to suppress stale callbacks. Style reload destroying runtime state is a known property of vector renderers.

**Mechanism.** The declarative reconciler owns the desired state; a style or surface rebuild merely resets the actual state and the reconciler replays to the target automatically. The business layer neither observes nor participates.

### 2.6 Half-activated offline content

**Symptom.** An early activation mechanism had activate → confirm → retire in outline, but no defined failure paths: an acknowledgement timeout left the candidate activated with the old version still leased, and a process killed mid-activation had no consistency protocol. "Offline mode" remained a vague global concept.

**Mechanism.** `ContentAuthority` is declared per content item, with no global offline switch. Generation activation is an explicit state machine where **every state has a defined failure transition** (acknowledgement timeout → automatic rollback; killed mid-activation → startup reconciliation of staging; see 02 §7.4). Acceptance: locally authoritative content cannot render from the network, and old data cannot be deleted before the new generation is confirmed rendered.

### 2.7 Main-thread disk work blocking offline startup

**Symptom.** Offline startup paths perform tile-database enumeration and SQLite access on the main thread.

**Mechanism.** All tile and content preparation happens on workers; only `Sendable` values cross the boundary. The main-thread contract — no disk scans, no SQLite queries, no network waits, no tile-archive enumeration — is an executable test plus runtime assertions, not a sentence in a document.

### 2.8 Viewport restoration flicker and loss

**Symptom.** iOS termination callbacks are not guaranteed: killing a suspended app may skip them, while continuous persistence causes write amplification. Restoring through an animated camera API produces a launch jump, and restoring after the first GPS fix gets overwritten.

**Mechanism.** An explicit `flushViewport()` persists only at lifecycle boundaries; the background flush is wrapped in a background task so a suspend race cannot lose it. Restoration completes **before** the default camera and the first GPS follow, without animation, and the business layer never sees provider zoom — camera poses are expressed in scale, ground resolution, and framing intent, with provider zoom converted only inside the adapter.

### 2.9 One coordinator becomes the map's message bus

**Symptom.** A single coordinator holds the renderer callbacks, connectivity fallbacks, user-container replacement, asynchronous weather generation, and observed UI state at once.

**Mechanism.** The data source supplies immutable snapshots and deltas one way; the delegate emits user actions and operational state the other way. The SDK never mutates application stores and the application never calls the renderer, so no single object can become the map's bus.

### 2.10 Capability differences flattened to the lowest common denominator

**Symptom.** Renderer projections and CRS handling are often not separated from the renderer itself, and restricting an SDK to point/line/polygon for portability makes capabilities such as volumetric airspace permanently unreachable.

**Mechanism.** Fine-grained capability protocols, a capability manifest, and explicit degradation policy. Safety content may declare degradation **forbidden**: volumetric airspace requires volume rendering, and a runtime without it returns an explicit `incompatible` rather than silently hiding safety data. The companion hard rule: **safety objects with unknown altitude, unknown time, or unknown data state default to conservatively visible** — unknown is an explicit case, never `Optional` nil, so downstream code cannot filter it away with `if let`. This rule exists as a test matrix (capability degradation × unknown data state), not as a documentation promise.

---

## 3. Why (key decisions and rejected alternatives)

### 3.1 Research inputs

Apple MapKit is closed source, so only its public API was studied; MapLibre, a commercial vector renderer, QGroundControl, and OpenCPN were read as source.

| Source | Worth absorbing | Not to copy |
|---|---|---|
| Apple MapKit | Semantic camera positions expressed as intent (and distinguishing user-driven changes), declarative content builders, typed selection, delegate design, annotation/overlay separation | Closed basemap, uncontrollable offline resources, road-oriented data model |
| MapLibre Native | Separation of platform view / render loop / shared core, tile workers, immutable messages, source/layer model, offline regions, plugin layers | Style JSON as the business API, global offline singleton, Web Mercator binding (its own documented architectural debt) |
| Commercial vector renderer | Declarative content tree with mount/update/unmount reconciliation, viewport state machine, feature query, mature offline tile store | Provider type leakage, style reload destroying runtime state, SDK lifecycle bleeding into business code |
| Cesium Native | High-precision WGS84, 3D tile LOD, separation of resource fetching from render-resource preparation | Turning the whole SDK into a 3D engine |
| QGroundControl | Mission, geofence, rally point, altitude frame, terrain following, 3D bounding volumes | Binding map UI to mission control |
| OpenCPN | Domain model for AIS targets, tracks, CPA/TCPA, navigation status, charts, tides, currents | **GPL: concepts referenced only — not one line of code or data-structure definition is copied**; also its older global-state structure |

### 3.2 D1: navigation objects, not layers, are first class

**Rejected A:** source/layer/style as the business API — the path that produces §2.1 and §2.5, binding business code to provider concepts and scattering semantics (altitude filtering, timelines, CPA/TCPA) into the app.
**Rejected B:** a thin renaming wrapper — renaming does not supply missing 4D semantics.
**Adopted:** first-class objects (NavigationPosition, NavigationVolume, TemporalExtent, MovingEntity, PredictedPath, RoutePlan, RouteLeg, NavigationCorridor, NavigationConstraint, Hazard, NavigationAid, OperationalWeather, ContentAuthority, DataFreshness). Domain evidence: maritime scenes need navigation status, tracks, and CPA/TCPA rather than a moving icon; UAS scenes need mission semantics rather than polylines; multi-product hydrographic standards show a chart scene is composed of several independent content products.

### 3.3 D2: one surface driver owns the surface

**Rejected:** letting several engines draw into one view — camera matrices, projection, hit testing, and frame synchronization diverge.
**Adopted:** exactly one surface driver per scene owning camera, projection, render loop, and GPU surface; extensions arrive via render plan, custom render pass, or resource provision.

### 3.4 D3: provider neutrality enforced by the compiler, not by review

**Rejected A:** a public provider enum or vendor-named module — the vendor name enters the public API and switching implementations becomes a breaking change.
**Rejected B:** relying on review convention — the hundred-plus direct imports in the observed application are where that path ends.
**Adopted:** access-level imports (`internal import`) prevent provider types from appearing in public interfaces at compile time, backed by a CI scan of the public symbol graph. SwiftPM reality: a host that happens to import the renderer does not give the SDK its capability — the adapter must exist at compile time — so the profile module transitively depends on the default runtime, which internally depends on the renderer, leaving the application side unaware.

### 3.5 D4: capability negotiation, never a lowest common denominator

See §2.10. The core render plan holds only stable base primitives; advanced capabilities arrive as capability extensions. Components declare required and optional capabilities plus a degradation policy, and safety content that forbids degradation reports `incompatible` explicitly.

### 3.6 D5: example-first minimal public API (scope control)

**Risk (the largest in this plan):** fourteen first-class objects, capability negotiation, and three profiles form a huge API surface; freezing all of it in v0 guarantees rework.
**Adopted:** the "few lines for a working operational map" example is itself the first acceptance artifact — the ideal call site is written first and the minimal public API is derived from it. The v0 public surface holds only the viewport, basemap, ownship, one surface driver, and the offline generation manager. Everything else stays an internal draft, outside SemVer.

### 3.7 D6: Swift 6 strict concurrency from day one

Retrofitting strict concurrency costs an order of magnitude more than starting with it. Snapshots and deltas are `Sendable` value types; the data source and delegate are main-actor bound; tile and content preparation leave the main thread; the cross-actor protocol between reconciler and renderer acknowledgement is explicit (02 §5.2).

### 3.8 D7: offline authority is a content property, not a global mode

See §2.6. Short-cycle safety content and long-cycle cyclic data differ only in refresh policy; the activation protocol is identical. The network only updates locally authoritative content and can never become the render source directly.

### 3.9 D8: source package first, binary distribution evaluated later

Source distribution keeps debugging, profiling, and migration cheap. SemVer plus API-compatibility CI apply from the first tag; an XCFramework is evaluated only once the API is stable.

---

## 4. How

### 4.1 Architecture

```
Applications (aviation / maritime / UAS)
                  │
       Aviation / Maritime / UAS profile
                  │
        Navigation scene (4D business scene)
                  │
         Scene reconciler + render plan
                  │
       Capability negotiation / runtime
                  │
    ┌─────────────┼──────────────┐
 Surface       Offline        Query / snapshot
 driver        content        / telemetry
    │
Internal rendering implementations
```

Repository layout (one repository, one version, several products):

```
NaviMapKit
├── NaviMapKit            (umbrella)
├── NaviMapCore           (4D model, identity, time, capability types — no UI, no provider)
├── NaviMapScene          (snapshot/delta, components, reconciler)
├── NaviMapRuntime        (surface-driver contract, runtime assembly, render plan)
├── NaviMapOffline        (content authority, generation manager, staging/activation)
├── NaviMapNavigation     (route plan, corridor, constraint — internal draft)
├── NaviAviationMapKit    (aviation profile — the single import for aviation apps)
├── NaviMaritimeMapKit    (maritime profile — skeleton, proof phase)
├── NaviUASMapKit         (UAS profile — skeleton, proof phase)
├── NaviMapTesting        (test matrix, fake runtime, replay harness)
└── Internal
    ├── _PrimaryVectorRuntime   (the only target importing a renderer SDK)
    ├── _TileRuntimeBridge
    └── _RuntimeAssembly
```

### 4.2 Phases

The architecture is settled once; the code arrives incrementally. Exit criteria and rollback points per phase live in 03 §4.

| Phase | Content | Exit criterion (summary) |
|---|---|---|
| P0 | **Foundation ADRs**: freeze the 4D spatial model (including the identity/signature split), capability negotiation, and surface ownership plus content authority | Three ADRs reviewed and accepted |
| P1 | **Independent package**: repository, SemVer, strict concurrency, API-compatibility CI, symbol-graph scan, testing product, and the frozen ideal example | Green CI on the skeleton; ideal example frozen as an acceptance artifact |
| P2 | **Thin vertical slice (first milestone must render)**: viewport + basemap + ownship really rendering on the default runtime, including viewport flush and restore | Example renders on device/simulator; viewport restores without animation |
| P3 | **Runtime isolation**: query, snapshot, typed events, and the data-source channel land in the SDK; a real integration proves the public API in an application | Integration renders through SDK-only API with equivalent behaviour |
| P4 | **Declarative reconciler**: mount/update/unmount with stable identity, timeline-driven updates, and automatic replay after surface rebuild | Regression scenarios for the historical failure classes pass under a single write path |
| P5 | **Offline/content runtime**: generation state machine with unified staging, validation, activation, acknowledgement, and retirement | Failure-path tests green; no main-thread disk I/O on offline startup |
| P6 | **Aviation domain pack**: airspace, airports, procedures, traffic, weather, routes, measurement, selection, altitude filtering | Domain feature checklist passes |
| P7 | **Consumer cleanup**: integrating applications reach zero direct renderer imports | Audit script confirms zero |
| P8 | **Maritime/UAS proof**: AIS with CPA/TCPA, mission with 3D geofence, as independent demos | All three examples share one core and runtime |

### 4.3 Acceptance criteria (all testable; implementations in 03 §5)

1. Zero renderer imports in consuming feature and application layers (script audit).
2. Zero provider types in the public API and symbol graph (CI scan).
3. Exactly one surface owner per scene (type system plus assertion).
4. All updates flow through immutable snapshots/deltas; **no state-mutation path outside the reconciler** (API audit plus tests).
5. No disk scans, SQLite queries, network waits, or tile-archive enumeration on the main thread (runtime assertions plus test hooks).
6. Locally authoritative content cannot render from the network (network sources are type-unreachable from the render pipeline).
7. Old data survives until the new generation is confirmed rendered; acknowledgement timeouts roll back and interrupted activations recover (state-machine tests).
8. Camera restoration is animation-free and the business layer never sees provider zoom (no zoom in the API; restoration path tests).
9. Safety objects with unknown altitude, time, or data state default to visible (test matrix over capability degradation × unknown states).
10. The aviation, maritime, and UAS examples build on one shared core and runtime (CI builds all three).
11. A renderer upgrade changes only the SDK and reaches consumers through a version bump (dependency-direction audit).
