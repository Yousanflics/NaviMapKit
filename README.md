# NaviMapKit

A provider-neutral 4D navigation map platform for Swift. Position, vertical
space, time, motion, and data authority are first-class concepts; the map
rendering provider (Mapbox today) is an internal runtime detail that never
appears in the public API.

Built for aviation, maritime, and UAS applications where a map
is not a picture but an operational instrument: content freshness is
tracked, degraded states are explicit, and safety-relevant failures are
reported — never silently absorbed.

## Features

- **Declarative scenes** — declare basemap, ownship, routes; the SDK owns
  reconciliation, surface readiness, and replay across style reloads.
- **4D data model** — explicit coordinate reference systems, seven vertical
  reference cases, a time-semantics family that distinguishes represented,
  generated, installed, and observed time, and explicit `.unknown` states
  instead of optionals.
- **Viewport intents** — free camera, entity follow (course-up or
  north-up), and fit-to-positions framing with built-in layout gating;
  viewport sessions persist and restore across launches without animation.
- **Typed events** — viewport changes with user/program/restore source
  attribution, typed feature selection, capability and health reporting.
- **Capability negotiation** — components declare required capabilities;
  unsatisfiable content is refused fail-fast at scene construction and
  reported, never dropped.
- **Offline content with authority** — declare locally authoritative
  overlays with a freshness policy; staged generations are validated,
  activated atomically, confirmed by the renderer, and rolled back on any
  failure, with freshness reported through operational health.
- **Provider isolation, enforced** — one internal target imports the
  rendering provider; CI verifies no provider symbol reaches the public
  surface, and an API digester guards the public face against unreviewed
  breaking changes.

## Requirements

- iOS 18.0+
- Swift 6.0+ (strict concurrency, all targets)
- Xcode 16+

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Yousanflics/NaviMapKit.git", from: "0.1.0")
]
```

Then depend on the domain product for your application:

```swift
.product(name: "NaviAviationMapKit", package: "NaviMapKit")
```

A Mapbox download token in `~/.netrc` is required to resolve the internal
runtime dependency, and a public access token (`MBXAccessToken` in your
app's Info.plist) is required at runtime.

## Quick start

A complete moving-map screen — this is the SDK's frozen acceptance
artifact, compiled verbatim by the example app:

```swift
import NaviAviationMapKit
import SwiftUI

struct NavMapScreen: View {
    @State private var viewport: NavigationViewport =
        .follow(.ownship, .courseUp)

    private let ownshipFeed = SimulatedOwnshipFeed()

    var body: some View {
        NaviMap(
            viewport: $viewport,
            profile: .aviation(.ifr)
        ) {
            NavigationBasemap(.operational)
            Ownship(source: ownshipFeed.positions)
        }
    }
}
```

Route preview with framed camera and labeled endpoints:

```swift
NaviMap(viewport: $viewport, profile: .aviation(.ifr)) {
    NavigationBasemap(.operational)
    RoutePath(fixes, startLabel: "KSFO", endLabel: "KLAX")
}
// viewport = .fit(ViewportFit(positions: fixes,
//                             padding: .symmetric(horizontal: 56, vertical: 80),
//                             closestScale: MapScale(metersPerPoint: 40)))
```

Offline overlay content, staged from an unpacked generation directory the
app's downloader produced (feature collection plus manifest):

```swift
NaviMap(viewport: $viewport, profile: .aviation(.ifr), handle: handle) {
    NavigationBasemap(.operational)
    OfflineOverlay(.terminalObstacles,
                   authority: .localAuthoritative(RefreshPolicy(staleAfter: .seconds(28 * 86_400),
                                                                expiredAfter: .seconds(56 * 86_400))))
}
// let staged = try await handle.content.stage(.terminalObstacles, generation: GenerationID("2026-09"), directory: unpacked)
// try await handle.content.activate(staged)   // confirmed rendered, or thrown and reported once
```

## Products

| Product | Purpose |
| --- | --- |
| `NaviAviationMapKit` | Aviation profile |
| `NaviMapKit` | Core map view, scene store, viewport system |
| `NaviMapCore` | 4D data model: positions, time semantics, capabilities |
| `NaviMapScene` | Scene snapshots, deltas, components, reconciliation |
| `NaviMapRuntime` | Provider-neutral runtime contract |
| `NaviMapOffline` | Offline content authority: generations, registry, families |
| `NaviMapTesting` | Deterministic fakes for testing without a surface |

## Examples

- `Examples/NavMapExample` — the frozen acceptance app plus a performance
  harness (sustained 60 fps follow-camera verification). See its README
  for token setup with `xcodegen`.

## Status

Pre-1.0. The public surface is versioned from `v0.1.0` and guarded by an
API-breakage gate; breaking changes before 1.0 land only with an explicit,
reviewed allowlist entry.

## License

Apache License 2.0 — see [LICENSE](LICENSE).

That covers this package's own source. It does not extend to the rendering
runtime it resolves: the Mapbox Maps SDK for iOS is commercially licensed by
Mapbox, and a consumer of NaviMapKit obtains that licence and the tokens named
under Requirements directly from Mapbox. NaviMapKit embeds no credential of
any kind — every host application supplies its own.
