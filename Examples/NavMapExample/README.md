# NavMapExample

`NavMapExampleIdeal.swift` is the frozen v0 API acceptance artifact: the
ideal calling code, written before the API existed. Changes to the frozen
file require explicit review confirmation.

The app target compiles the frozen file **unmodified** — building this
project IS the v0 API acceptance test. `NavMapPerfHarness` is a separate
measurement rig (sustained-60fps follow-camera verification); it is not
part of the frozen artifact.

## Running

```sh
export MAPBOX_PUBLIC_TOKEN=pk.…   # your Mapbox public token
xcodegen                          # generates NavMapExample.xcodeproj (gitignored)
open NavMapExample.xcodeproj
```

The token is resolved from the environment when xcodegen runs and lands
only in the generated (gitignored) project — never commit a token. The
committed `Info.plist` references it as the `$(MAPBOX_PUBLIC_TOKEN)` build
setting.

## What to verify

- Cold launch renders the operational basemap with the ownship marker at
  the simulated position, camera following it (no code beyond the frozen
  file).
- Background the app (flushes the viewport session), kill it, relaunch:
  the camera restores to the last pose without animation, strictly before
  any follow tick.
