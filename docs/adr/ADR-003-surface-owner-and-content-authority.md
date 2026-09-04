# ADR-003: Surface Ownership and Content Authority

- Status: Accepted (2026-08-30)
- Date: 2026-08-30
- Decision sources: docs/01-analysis-and-plan.md §2.2 / §2.5 / §2.6 / D2 / D7; docs/02-detailed-design.md §1.2 / §1.3 / §4.4 / §7.1 / §7.3 / §7.4
- Amendment policy: once accepted, revise by appending amendments rather than rewriting the body (docs/03-implementation-details.md §4-P0)

## Context

Two field-observed failure histories motivate this ADR.

**History one — a second write path beside the reconciler (§2.2).** A production map layer subsystem went through four rounds of rework on a single defect: an implicit visibility-diff reconcile missed same-id definition changes; a manual rebuild seam was added; the seam's first version bypassed the render policy (reviving remote layers while the network was blocked); the second version walked the new catalog for teardown and missed definitions that had been deleted; the third missed a cache side effect. All four rounds had one root cause: **a second code path, outside the reconciler, that could mutate runtime layer state.** As long as that path exists, someone will eventually take it.

**History two — half-activated offline content (§2.6).** An early activation mechanism had no defined failure paths: what happens when the acknowledgement never arrives, and what happens if the process is killed mid-activation, were both unanswered. Half-activation is the most common way offline data goes wrong.

## Decision

### A. Surface ownership (D2)

1. **Each `NaviMap` scene binds exactly one `SurfaceDriver`**, which exclusively owns the camera, projection, render loop, and GPU surface. The SDK exposes no API for reaching the underlying view or graphics context.
2. Other capabilities join through exactly three channels: the render plan (declarative), a custom render pass (capability-gated), or resource provision (tile/asset providers). Mixing multiple engines into one view is forbidden — camera matrices, hit testing, and frame synchronization cannot stay consistent across engines.

### B. The reconciler is the only write path

3. **Outside the reconciler there is no public or internal API that can mutate runtime layer state.** Ad-hoc "invalidate and resync" or "rebuild layers" seams are not carried into this SDK — they are patches for a missing reconciler and are structurally prohibited here.
4. Data flow is strictly one-way: DataSource →(snapshot/delta)→ scene store →(desired revision)→ reconciler →(render-plan diff)→ surface driver →(ack/typed events)→ delegate. The SDK never mutates the application's stores; the application never reaches the renderer.
5. Surface rebuild (style reload, controller recreation) = reset actual state + full replay of the component tree, with zero business-layer participation (the structural answer to §2.5).
6. Every cross-boundary event and acknowledgement carries a `SceneEpoch`; mismatched epochs are rejected without exception (generalizing the stale-callback lesson).
7. **Stale applies converge by two mechanisms, not one.** Idempotent upserts make a re-applied plan harmless, but they do not undo state a *rejected* plan already installed: a driver can apply a plan that the reconciler then refuses as stale, leaving artifacts the reconciler never recorded and therefore never unmounts. So when building any plan the executor also emits inverse operations for every ledger entry absent from the desired scene, not only for explicit unmount operations. Upserts converge; removals only converge if they are derived from the difference.

### C. Content authority (D7)

8. **Offline authority is a property of content, not a global mode.** Each content item declares `ContentAuthority ∈ { localAuthoritative(RefreshPolicy), remoteAllowed, hybrid(HybridPolicy) }`; no global "online/offline map mode" switch exists in the SDK.
9. **Type-level isolation:** a network downloader produces `StagedDownload`; for locally authoritative content the render pipeline accepts only `ActivatedGeneration`. Network content that has not passed the activation protocol **cannot reach rendering as a matter of type** (01 §4.5, criterion 6).
10. Short-cycle safety content and long-cycle cyclic datasets differ only in `RefreshPolicy`; the activation protocol is identical.

### D. Generation activation protocol, including failure paths (02 §7.4)

11. State machine: `downloading → staged → validating → validated → activating → active → retiring → deleted`, with branches `rejected` (validation failure) and `activationFailed` (rollback).
12. Activation requires all three validations to pass (checksum / schema / coverage); atomic activation = directory rename plus a single registry transaction, where **the registry is the sole authority and the symlink is derived**, rebuilt unconditionally during startup reconciliation.
13. After activation, wait for an `ApplyAcknowledgement` covering that generation; **the previous generation stays leased and undeletable until confirmation**.
14. **Acknowledgement timeout (8s default, configurable) → automatic rollback:** the registry points back to the previous generation, a rollback render plan is submitted, and the new generation returns to `staged` (retryable) or `rejected` by policy. There is no stable resting state of "activated but unconfirmed".
15. **Killed mid-activation → startup reconciliation:** `activating` entries roll back to the previous active generation; `retiring` entries whose successor already has a confirmation record complete their deletion; incomplete `downloading` remnants are discarded as untrustworthy; staging directories with no registry entry are removed as orphans; and a directory left behind by a `rejected`/`deleted` record is removed. Reconciliation runs on `ContentPreparationActor`, never on the main thread. **Startup-only is a precondition, not an incidental fact:** the sweep assumes no work is in flight, so the same logic wired to a runtime reconciliation would delete downloads and staging directories belonging to running operations.
16. Regional lease: a generation may take effect for its own scope while its predecessor stays leased until an in-region render confirms it; the lease lives in the registry and survives restart.

## Rejected alternatives

| Alternative | Why rejected |
|---|---|
| Allow multiple engines to draw into one view | Camera matrices, projection, hit testing, and frame synchronization inevitably diverge across engines (D2) |
| Keep an explicit rebuild/invalidate seam as an "escape hatch" | The four-round rework above is the complete natural history of that path; the escape hatch is itself the defect source, and its existence makes the "single write path" promise unverifiable |
| A global online/offline mode switch | Different content has different authority policy (base data locally authoritative vs weather remote-allowed); a global switch manufactures the ambiguous state described in §2.6 (D7) |
| Let network responses reach rendering, guarded by runtime checks | Runtime checks can be bypassed or forgotten; replaced by type-level isolation (`StagedDownload` ≠ `ActivatedGeneration`) so violations do not compile |
| Treat the symlink as the authority for activation state | Filesystem operations are not transactional; after a crash the symlink and the real state can diverge. A single registry authority with a derived symlink can always be reconciled |
| Leave activation failure to the caller (SDK only reports) | Half-activation is the most common offline incident shape; rollback and reconciliation must be built into the protocol, not homework for the integrator |

## Consequences

- **Positive:** the four-round defect class becomes structurally unreproducible (there is no second write path to take); offline content is always in one enumerable, well-defined state with deterministic recovery from both crashes and timeouts; style reload turns from "manually reinstall dozens of layers" into automatic replay.
- **Costs:** every rendering change must be expressed as a snapshot/delta — there is no "just tweak this one layer" shortcut (which is the point); the generation manager, registry, and reconciliation logic are the main implementation cost of P5; acknowledgement semantics depend on driver contract tests as a backstop (03, risk R2).
- **Constraint propagation:** capability fallbacks (ADR-002) must also be expressed through the render plan; the signature rules of ADR-001 are the input to this ADR's update semantics.

## Enforcement and verification

- Single write path: audit the public and `package` surfaces (symbol graph) for any state-mutating entry point outside the reconciler; the three regression scenarios from the rework history (same-id definition change, teardown completeness, cache side effects) live in NaviMapTesting as a P4 exit criterion (03 §4-P4).
- Failure paths: acknowledgement-timeout rollback, kill during `activating` followed by startup reconciliation, staging-orphan cleanup, and regional-lease persistence across restart — tests written first in P5 (03 §4-P5, at least one case each).
- Main-thread contract: accessing the registry or staging outside `ContentPreparationActor` trips a DEBUG assertion (03 §5.5).
- Surface-rebuild replay: a style-reload scenario test asserting the component tree is restored item by item with zero business-layer participation (03 §4-P4).
