# Device capture: cold start with content activation, 2026-09-02

The offline-phase exit capture: a cold start of the example application
whose first launch stages and activates a bundled overlay generation. The
criterion is that no file-system call on the SDK's content path (the
registry, staging, and generation directories) runs on the main thread.

## Setup

| Item | Value |
| --- | --- |
| Device | iPhone 15 Pro, iOS 26.2, developer mode on |
| Host | Xcode 26.6 (17F113), xctrace 16.0 |
| Application | NavMapExample, **Debug** configuration, automatic signing |
| SDK tree | exact `5ed2e38` (the example declares the overlay and installs the bundled generation on first launch) |
| Recorded | 2026-09-02 |

## Recording

`xctrace record --template 'File Activity' --device <udid> --all-processes --time-limit 16s`

System-wide recording, for the reason recorded in the pipeline-validation
note (process-targeted modes do not work against the device on this
host). Four seconds into the recording the application was relaunched
with `devicectl device process launch --terminate-existing`; the first
launch of this build copies the bundled generation to a temporary
directory, stages it through the handle, and activates it.

## Filter

1. `xctrace export --input <trace> --xpath '/trace-toc/run[@number="1"]/data/table[@schema="fs-syscall"]' --output <file>`.
2. `thread-info` gives the relaunched application `pid 1281` and its main
   thread `tid 0x1747c` (67537 decimal is the earlier capture's id; this
   one is 95356).
3. Two subsets are distributed, each with pid, thread, syscall, path,
   class, and the full backtrace:
   - the main-thread subset: every `fs-syscall` row on pid 1281 and the
     main thread, classified by call stack (`sdk`, `provider-attach`,
     `app-code`, `no-sdk-frame`);
   - the content-path subset: every row on pid 1281, any thread, whose
     path contains `/NaviMapKit/content/` or whose backtrace contains
     `GenerationRegistry`, `GenerationManager`, or `ContentFileSystem`.

## Result

Main-thread file-system syscalls of the application in the window: **3820**.

| Class | Rows | What it is |
| --- | --- | --- |
| SDK content or session path | 2 | `stat64` from path standardization inside `URL(fileURLWithPath:)`, reached from `ViewportSessionStore.default` and `ContentPipeline.defaultRoot()` as default arguments of the coordinator's initializer. Metadata only. |
| Provider attach (SDK frames present) | 174 | Provider map-view initialization through `PrimaryVectorSurfaceDriver.attach`: bundle reads, Metal shader bundle and compiler-hash lookups. Excluded by the criterion's scope, not because the stack is free of SDK code. |
| Application code | 0 | The example's copy of the bundled generation runs off the main thread. |
| No SDK frame | 3644 | Loader `fcntl` on the provider and application libraries (about 2900), Metal binary-archive caches, bundle stats. |
| Content path | **0** | No registry, staging, or generation file was touched from the main thread. |

Content-path rows across all threads of the application: **547** (registry
and its write-ahead log 263, staging 22, generations 16, the rest
classified by SDK frames), spread over five unnamed worker threads of the
preparation executor's dispatch pool; **none on the main thread**. The
calls are SQLite transaction work (`fcntl`, `pwrite`, `stat`, `fsync`) and
the generation directory operations.

The DEBUG main-thread I/O hook reported no violation. Two kinds of
evidence apply, as in the pipeline-validation note: explicit SDK disk
calls are covered by the hook; implicit Foundation stats are visible only
in a capture.

## Conclusion and follow-up

The exit criterion holds: the content path is served entirely off the
main thread, shown by the full syscall listing rather than a heuristic,
and reproducible from both distributed subsets. The two remaining SDK
rows are not on the content path; they come from forming a file URL on
the main thread, which standardizes the path with a stat. The commit that
lands this note keeps default paths as strings and forms URLs only on the
I/O queue or the preparation actor; a further capture of that build
verifies the count reaches zero and is recorded as an addendum below.

## Addendum: third capture, build with off-main URL formation

Recorded the same way against exact `1c28f9b`, the build that keeps
default paths as strings and forms file URLs only on the I/O queue or the
preparation actor (Debug configuration, pid 3108, main thread `0xafa03`). Content path: 177 rows, all off
the main thread; 176 on the preparation executor's worker threads and one
classified `provider-async-load`: the provider's own file-loading thread
reading the activated generation's feature collection, which is direct
evidence that the binding performs no synchronous I/O in the apply and
the provider loads the mount asynchronously as designed. Main thread: 4096 rows, of which the SDK class
is still 2: the same two default-argument sites, now reaching `stat64`
from inside the home-directory lookup itself. The lookup was therefore
deferred as well: the session store's default is an unresolved marker
resolved on the I/O queue, and the content root default is resolved on
the preparation actor; the coordinator's default arguments evaluate
nothing. A fourth capture of that build is recorded separately.

Third-capture artifacts, retained on the recording machine alongside
the full traces: main-thread subset
`navmap-third-mainthread-fs.csv` (SHA-256
`5f7ef2e939c2f9a55f8cdceef6e24485f6a9b003647e81b1f36c400e21d39189`),
content-path subset `navmap-third-content-path-all-threads.csv`
(`f975a290c270da4b7ead9ae48af7fd8d49f3e2e466b4037f7b81e6f0517c0567`),
full trace `navmap-third.trace.tgz`
(`1c8ac6661f07a2512c46f4bcda8fce6eb0d5dd2aed23ea40d3614518cc4c2760`).

## Addendum: fourth capture, build with deferred default resolution

Recorded the same way against exact `2277042`, the build whose
coordinator default arguments evaluate nothing: the session store's
default is an unresolved marker resolved on the I/O queue, and the content
root default is resolved on the preparation actor (Debug configuration,
pid 3222, main thread `0xb1f98`). Main thread: 3728 rows, SDK class
**0**; every row is loader `fcntl` on the provider and application
libraries, Metal binary-archive caches, or bundle stats with no SDK frame.
Content path: 302 rows, all off the main thread; 301 on the preparation
executor's worker threads and one on the provider's own file-loading
thread reading the activated generation's feature collection. The DEBUG
main-thread I/O hook reported no violation.

This closes the startup baseline: with the content path already served
off the main thread since the second capture, the SDK now performs no
main-thread disk access at all during cold start and activation, explicit
or implicit.

Fourth-capture artifacts, retained on the recording machine alongside
the full traces: main-thread subset
`navmap-fourth-mainthread-fs.csv` (SHA-256
`f1375f15a5922585911f86d29a668631add0fdf432f402c160f5741aac7c5138`),
content-path subset `navmap-fourth-content-path-all-threads.csv`
(`2a884584546bdb5a9159661505df3a23db4774edcebc00336225ee66e2f10b27`),
full trace `navmap-fourth.trace.tgz`
(`0a954e4cae39fa67cf8e4ec79194f0f627d9a48bc6e6985afdb17b332b151a49`).

## Artifacts

| Artifact | Location | SHA-256 |
| --- | --- | --- |
| Main-thread subset with full backtraces (CSV, 1.5 MB) | attachment on the review thread, message `448c3ce6` | `690f33c13d0fb1d598feae68d292f66156585b1eb676bfc2f9910d9f779dd910` |
| Content-path subset across all threads (CSV, 556 KB) | attachment on the review thread, message `8bebf8d6` | `107763f3f420673b1e735d3c660f2b2107c5a912934f104d70b9658c99226323` |
| Full trace (tar.gz, 61 MB, not distributed) | recording machine, `navmap-formal.trace.tgz` | `dc67523d6cc5f0341de86a206d9d1e678daed8d9b1acc6516dd6439e1f8b0452` |

## A note on the commit identifiers

The identifiers above name the trees these captures were recorded on, and
they are kept because substituting an identifier from this repository
would be false — no tree here is the one that was measured. They do not
resolve here, since this repository's history begins at publication; the
development history that contains them is kept in an offline mirror,
`navimapkit-history-20260903.git`.
