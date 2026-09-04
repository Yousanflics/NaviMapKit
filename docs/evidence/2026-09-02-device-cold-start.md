# Device capture: cold start, 2026-09-02 (pipeline validation)

Validation of the capture pipeline for the offline-phase exit criterion
(no main-thread disk I/O on the SDK's content path) and a baseline of the
startup path before the first content family. The content path itself is
empty here. This record is superseded for the startup-path verdict by the
capture repeated after the fixes it motivated, and the exit capture is
taken once content can be staged and activated.

## Setup

| Item | Value |
| --- | --- |
| Device | iPhone 15 Pro, iOS 26.2, developer mode on |
| Host | Xcode 26.6 (17F113), xctrace 16.0 |
| Application | NavMapExample, **Debug** configuration, automatic signing |
| SDK tree | exact `d432440`, the build that raised the deployment target to iOS 18 |
| Recorded | 2026-09-02 |

## Recording

`xctrace record --template 'File Activity' --device <udid> --all-processes --time-limit 14s`

A system-wide recording was used because on this host the process-targeted
modes do not work against the device: `--launch` never returns after
"Launching process", and `--attach` by name or by pid reports that the
process cannot be found even while it runs. Four seconds into the
recording the application was force-relaunched with
`devicectl device process launch --terminate-existing`, so the window
contains a full cold start without manual interaction.

## Filter

1. `xctrace export --input <trace> --xpath '/trace-toc/run[@number="1"]/data/table[@schema="fs-syscall"]' --output <file>`
   (writing to a file; redirecting stdout crashes the exporter on tables of this size).
2. `thread-info` and `process-info` give the relaunched application
   `pid 1026` and its main thread `tid 0x107d1` (67537). The terminated
   instance `pid 885` is excluded.
3. Every `fs-syscall` row on that pid and thread is kept, with its full
   backtrace (all frames, innermost first). Rows are classified by call
   stack: `sdk` when an SDK frame is present outside the provider's attach,
   `provider-attach` when the SDK frame is the surface driver's attach or a
   provider frame is present, `no-sdk-frame` otherwise. The distributed
   subset carries the pid, thread, syscall, path, class, and backtrace
   columns, so the counts below can be recomputed from it.

## Result

Main-thread file-system syscalls of the application in the window: **868**.

| Class | Rows | What it is |
| --- | --- | --- |
| SDK content or session path | 2 | `ViewportSessionStore.default`: a `stat64` from `FileManager.urls(for:in:)` and an `lstat64` from an un-annotated `appendingPathComponent`. Metadata only, no reads. |
| Provider attach (SDK frames present) | 156 | Rows entering provider map-view initialization through `PrimaryVectorSurfaceDriver.attach`: bundle `Info.plist` reads, Metal shader bundle and compiler-hash lookups. These rows carry SDK frames; they are excluded by the criterion's scope (provider initialization is inherent to creating the map view), not because the stack is free of SDK code. |
| No SDK frame, symbolicated | 448 | Loader, UIKit scene-state restoration (`_UISceneUserActivityManager`, 31 rows including the directory creations and search-path lookups), the Metal shader cache (`MTLCompilerFSCache`, 259 rows on `functions.data` and `libraries.data`), provider framework bundle stats. |
| No SDK frame, unsymbolicated | 262 | Backtraces of unresolved addresses only, including 23 write-class calls (`ftruncate` 16, `write` 5, `rename` 2). Placed in this class for lack of evidence, not by positive attribution: no SDK symbol can be asserted or excluded for them. |
| Content path (registry, staging, generations) | 0 | No content existed yet. |

The DEBUG main-thread I/O hook reported no violation (a violation aborts
a Debug build; the application ran normally). Two kinds of evidence apply:
for explicit SDK disk calls (every `createDirectory`, `moveItem`, `write`,
`replaceSymbolicLink`, registry open, and session save is guarded), a
clean hook run is sufficient; for implicit Foundation stats such as
`FileManager.urls(for:in:)`, which have no guarded call site, only a
capture can attribute them. The `path` column of the export is unreliable
for a few rows (an exporter defect); classification uses backtraces only.

## Conclusion and follow-up

The two SDK rows are real: path computation through `FileManager.urls`
and an un-annotated path append perform metadata stats on the caller's
thread, outside the hook's coverage. Both default-path computations were
changed to pure string construction with explicit directory annotations
in the commit that lands this note; the next capture verifies zero SDK
rows. Provider initialization on the main thread is inherent to creating
the map view and is outside the content-path criterion; it is recorded
here so the baseline is honest. The exit criterion itself is evaluated by
a later capture covering a cold start plus one content activation.

## Artifacts

| Artifact | Location | SHA-256 |
| --- | --- | --- |
| Filtered subset with full backtraces (CSV, 1.6 MB) | attachment on the review thread, message `d7b7d492` | `d3eace8959d226fa11118ee279015c70bf23550f1fb137c41cd808016182bdee` |
| Earlier subset without full backtraces (CSV, 412 KB; superseded) | attachment on the review thread, message `5fdd60b8` | `e0154dc3e08ea6e6b58b4323990b64e610425389308ec4897c79a4196129267a` |
| Full trace (tar.gz, 72 MB, not distributed) | recording machine, `navmap-coldstart.trace.tgz` | `191d60c1433c57d41e9dbf1333faeba63c0dd64e5f920d904b5d803e7eb9f18a` |

## A note on the commit identifiers

The identifiers above name the trees these captures were recorded on, and
they are kept because substituting an identifier from this repository
would be false — no tree here is the one that was measured. They do not
resolve here, since this repository's history begins at publication; the
development history that contains them is kept in an offline mirror,
`navimapkit-history-20260903.git`.
