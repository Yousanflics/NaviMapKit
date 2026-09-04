# ADR-002: Capability Negotiation and Degradation

- Status: Accepted (2026-08-30)
- Date: 2026-08-30
- Decision sources: docs/01-analysis-and-plan.md §2.10 / D4; docs/02-detailed-design.md §3.5 / §5.1
- Amendment policy: once accepted, revise by appending amendments rather than rewriting the body (docs/03-implementation-details.md §4-P0)

## Context

Supporting multiple runtimes (a vector renderer today, an alternative open-source renderer or an in-house Metal renderer later) means capability differences are the normal state: volumetric rendering, terrain, custom render passes, and snapshotting will not all exist on every runtime at once. Two common paths are wrong:

1. **Lowest common denominator.** Restricting the SDK to point/line/polygon so every provider can satisfy it means advanced capabilities can never be built (§2.10).
2. **Silent degradation.** Quietly drawing nothing when a capability is missing. For safety-relevant content — volumetric airspace, temporary restrictions, hazards — this is the most dangerous failure mode: what the user cannot see, they also cannot know they cannot see.

## Decision

### 1. Capabilities are fine-grained protocols, not a provider enum

Runtime capabilities are split into a `package`-level protocol family (02 §5.1): `MapSurfaceDriving` / `CameraProjectionDriving` / `VectorPresentationDriving` / `RasterPresentationDriving` / `TerrainPresentationDriving` / `VolumePresentationDriving` / `EntityPresentationDriving` / `FeatureQueryDriving` / `OfflineResourceDriving` / `SnapshotDriving` / `CustomRenderPassDriving`. There is no `MapProvider` enum in the public surface — applications always program against capabilities, never against a vendor (the capability-side expression of D3).

### 2. Runtimes publish a CapabilityManifest; components declare a CapabilityRequirement

- Every runtime exposes `CapabilityManifest { supported, extensions }` (public v0, required for health reporting).
- Every scene component declares `CapabilityRequirement { required, optional, degradation }` as static metadata.
- `DegradationPolicy` has two states: `.allow(fallback:)` and `.forbid`.

### 3. Negotiation has three outcomes; safety content may never degrade silently

The negotiation result is one of `satisfied / degraded(applied fallbacks) / incompatible`:

- `satisfied`: rendered with full capability.
- `degraded`: the declared fallback is applied (for example a volume rendered as a 2D footprint with altitude annotation), and the degradation detail enters `OperationalMapHealth.capabilities`.
- `incompatible`: when `degradation == .forbid` and a required capability is missing, the component is not rendered **and must** be reported explicitly through `MapOperationalIssue.capabilityIncompatible(component:missing:)`. **There is no fourth state in which insufficient capability quietly draws nothing.**

### 4. Negotiation timing: fail fast at scene construction

> **Provenance note: this clause is a new decision made by this ADR.** 02 (§3.5/§5.1) defines the three outcomes and the reporting obligation but does not define *when* negotiation happens; "fail fast at construction, renegotiate on manifest change" was decided at ADR level and accepted in design review.

Capability validation happens before scene construction / component mount, never deferred to render time — an unsatisfiable combination surfaces explicitly on the first development run (an `incompatible` event plus a health report) instead of vanishing silently in some frame on a device. A manifest change (runtime hot-swap, external render target) triggers renegotiation, and any change in outcome is delivered through `didChange health`.

### 5. Stable base primitives plus capability extensions

The core render plan contains only the stable base primitives every runtime must support; advanced capabilities (volumes, terrain, custom passes) arrive through capability-extension payloads. Adding a capability means adding an extension — never changing the base primitives, never flattening the base surface downward (D4).

## Rejected alternatives

| Alternative | Why rejected |
|---|---|
| Lowest common denominator (SDK surface = intersection of all providers) | Advanced capabilities could never enter the SDK; volumetric airspace and terrain requirements are eliminated outright (§2.10) |
| A public `MapProvider` enum with per-vendor branching in the app | Provider names enter the public API, so switching implementations is a breaking change, and the app grows a thicket of `if provider == …` branches (D3, alternative A) |
| Silently hiding components when a capability is missing | Safety data invisible with no signal to the user — the primary red line of this SDK (02 §3.5) |
| Discovering missing capabilities at render time | Moves the failure point from development into an arbitrary frame at runtime; untestable and unannounceable |
| One large `RendererProtocol` holding every capability | Every new runtime is forced to stub all methods, and the real distinction "supports vector but not volumes" cannot be expressed |

## Consequences

- **Positive:** a new runtime implements only the protocol subset it can honour and reports its manifest truthfully; invisibility of safety data always carries an explicit signal; advanced capabilities evolve without being held back by the weakest runtime.
- **Costs:** component authors must reason about the required/optional/degradation triple for every component (a design burden that is also a design benefit); the negotiator itself needs test-matrix coverage (the capability dimension is already in 03 §5.3).
- **Constraint propagation:** `CapabilityManifest`, `CapabilityRequirement`, and the negotiation result types must be `Sendable + Equatable`; a fallback rendering is itself a legal render-plan output and must not introduce a second rendering path (consistent with the single write path in ADR-003).

## Enforcement and verification

- The conservative-visibility matrix in 03 §5.3: {unknown data dimensions} × {satisfied / degraded / incompatible} × {filter and timeline states}, asserting that safety components always end in {visible, explicit incompatible report} and never in silent hiding.
- The incompatible path for `.forbid` components: NaviMapTesting drives `FakeSurfaceDriver` with a trimmed manifest and asserts the event is delivered.
- No provider types in the public surface: the provider-isolation CI job (grep plus symbol graph, 03 §2).
