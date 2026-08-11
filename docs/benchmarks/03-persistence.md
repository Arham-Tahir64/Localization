# Persistence testing and benchmark findings

Date: 2026-08-11
Scope: `MapLibrary`, `MapMetadata`, `ValidationStore`, `ValidationRecord`, and the map operations presented by `HomeView`. This report uses source inspection and deterministic synthetic fixtures only. It contains **no iPhone performance claims**.

## Evidence and current behaviour

| Area | Evidence | Finding |
| --- | --- | --- |
| Map discovery | `HouseMapper/Persistence/MapLibrary.swift:42-70` | `refresh()` creates the library, lists every non-hidden child, synchronously reads and decodes every candidate metadata file on the main actor, filters unsupported/malformed/mismatched UUID packages, sorts, and starts size loading. |
| Package save | `MapLibrary.swift:84-136` | Archive, metadata, and preview are written atomically into a staging directory on a detached task. The pre-existing final directory is then removed before staging is moved into place (`128-131`). This is not a replace-atomic package commit. |
| Rename/delete defense | `MapLibrary.swift:144-215`, `252-269` | Both operations resolve symlinks, require the resolved package to be directly below the resolved Maps directory, and require the folder UUID to equal the package ID. These checks prevent a forged/nested/symlinked package from being mutated. |
| Relocalization load | `MapLibrary.swift:218-228` | World-map bytes use `.mappedIfSafe` and decoding is detached, which avoids main-actor file read/decode time. Unlike rename/delete, this path does not validate the package directory or ID. |
| Size loading | `MapLibrary.swift:231-249`, `272-295` | One cancellable detached task enumerates every regular file in every discovered package. Cancellation is observed once per package and per enumerated item. The UI update is safely returned to the main actor. |
| Validation history | `HouseMapper/Persistence/ValidationStore.swift:46-119` | Both `refresh()` and `persist()` read/decode, sort, encode, and write on the main actor. Retention happens only after an unbounded JSON decode; each append sorts and rewrites the retained array. |
| UI coordination | `HouseMapper/Views/HomeView.swift:150-173` | The selected map row is disabled while its task is running, but `MapLibrary` itself does not serialize cross-call operations. Concurrent calls from future UI surfaces remain possible. |

## Added deterministic test coverage

`HouseMapperTests/PersistenceBenchmarkTests.swift` adds temporary-directory-only coverage for:

- discovery filtering for incomplete, malformed, mismatched-ID, and future-schema packages;
- symlink mutation rejection and preservation of an external package;
- failed rename recovery with original metadata intact;
- rapid refresh / superseded size-load task behavior and final snapshot size publication;
- 8 MiB synthetic `Data(..., .mappedIfSafe)` round-trip;
- malformed validation-history recovery after the next append;
- deterministic retention correctness at 10,000 synthetic records; and
- XCTest clock metrics for 100-package refresh and 10,000-record retention.

The test source is intentionally not accompanied by a `project.pbxproj` edit because this worker’s ownership excludes project files. It must be added to the `HouseMapperTests` source build phase during integration before CI/device execution.

**Integration status:** the orchestrator subsequently registered the test file,
rejected symlinks during discovery/load, made staging names unique, refused
destructive same-ID replacement, and generation-guarded size publication. See
`04-orchestrator-synthesis.md` for the resolution and deferred work.

## Test and benchmark execution status

`swiftc -parse HouseMapperTests/PersistenceBenchmarkTests.swift` succeeded, confirming Swift syntax.

Full XCTest execution was unavailable on this host: `xcodebuild` reports that the active developer directory is Command Line Tools rather than Xcode. A standalone Swift synthetic benchmark was also attempted, first sandboxed and then with the compiler-cache permission granted. It could not compile because Homebrew Swift 6.0.3 is paired with a macOS 26.3 SDK built for Apple Swift 6.2. The decisive compiler diagnostic was: `this SDK is not supported by the compiler`.

Therefore there are no raw timing samples to report. This is a toolchain limitation, not a test pass or an iPhone result. Run the added XCTest performance cases on an Xcode 16.4+ host and on a physical device after source inclusion.

## Ranked bottlenecks and risks

1. **P0 — symlinked package is discoverable and loadable.** `refresh()` uses paths without resolving or rejecting symlinks (`54-65`), and `loadWorldMap` directly reads `package.worldMapURL` (`218-228`). A UUID-named link to an external valid package appears in the map list and may be opened. Rename/delete refuse it, but discovery and loading should apply the same canonical-path validation. This is both a data-boundary and correctness issue.
2. **P1 — map package replacement can lose the prior valid map.** `save` removes `finalDirectory` before moving the staging directory (`128-131`). An interruption, full storage, or move failure after removal leaves neither version. Same-ID concurrent saves also share the same staging name and can delete one another’s staging directory (`95-102`).
3. **P1 — `refresh()` blocks the main actor in proportion to library size.** Directory enumeration, JSON reads, decoding, and sorting occur inside an `@MainActor` object (`42-68`). At 100+ maps, this competes with the Home screen rendering and gesture handling. It also does not request `isDirectoryKey` despite obtaining it.
4. **P1 — validation history permits unbounded input work.** A malformed or externally oversized history is fully read/decoded before retaining 100 records (`59-68`). On every append, it performs an `O(k log k)` full sort and atomically rewrites all retained data (`78-84`, `96-105`, `107-115`). Normal k=100 makes this modest, but cold-start migration of a large file remains a spike on the main actor.
5. **P2 — package-size work scales with all nested files after every refresh.** `packageSize` walks every regular file (`272-295`), and a refresh always restarts it (`69`, `231-249`), including rename where bytes did not change. Cancellation is cooperative, so already-running directory work is not preempted.
6. **P2 — world-map decode may have high peak memory.** `.mappedIfSafe` can reduce a copy for file loading, but secure unarchiving still materializes `ARWorldMap`; the mapped option is not a guarantee of zero-copy or low peak memory. This needs iPhone memory/thermal measurement rather than an assumed gain.

## Recommended implementation order

1. **Canonicalize once and reject non-direct child directories during discovery and load.** Add a nonisolated helper that requires `isDirectory == true`, rejects `isSymbolicLink == true`, resolves the candidate, checks the canonical parent, and checks its UUID. Use it in `refresh`, `loadWorldMap`, rename, and delete. Expected mechanism: eliminates ambiguous package identities and prevents external content from entering the UI/open path. Regression risk: deliberately supported legacy symlink packages will disappear; document this as unsupported.
2. **Make save replacement recoverable.** Use a unique staging directory per attempt, fsync where platform APIs permit, retain the old package until a successful replacement is durably present, and use a small manifest/current-pointer or backup-and-rollback protocol. Do not delete `finalDirectory` before a recoverable commit. Expected mechanism: unchanged steady-state speed; removes the data-loss window. Regression risk: temporary disk amplification of roughly one map package and recovery cleanup complexity.
3. **Move discovery and metadata decoding off the main actor, then publish a generation-tagged result.** Snapshot the root URL and a generation counter, enumerate/decode in one detached task, and apply only if its generation is current. Request resource keys once and reject non-directories early. Expected mechanism: removes filesystem latency from Home UI; expected UI responsiveness improvement is proportional to number/size of metadata files, not a fixed percentage. Regression risk: stale publish and lifecycle bugs unless tests cover deletion/refresh races.
4. **Cache package sizes by stable package modification date/metadata revision.** Recalculate only new or changed packages; do not restart traversal on a rename. Keep cancellation and generation checks. Expected mechanism: reduces rename/refresh work from `O(total files)` to `O(changed files)`. Regression risk: inaccurate displayed size if external writers change a package without updating the invalidation key.
5. **Bound validation input and offload serialization.** Reject/read-limit history over a documented byte ceiling, decode/sort/encode off actor, use a monotonic insertion path for normally chronological appends, and publish the completed array on the main actor. Expected mechanism: removes UI stalls and changes normal append retention from sorting 100 entries to bounded insertion. Regression risk: out-of-order clock timestamps must retain the existing deterministic tie break; interrupted writes must preserve the last valid history.
6. **Instrument actual AR archive load/save.** Record archive byte count, save/read/unarchive durations, peak memory (Instruments), relocalization outcome, and thermal state. Expected mechanism: makes sidecar/cache decisions evidence-based. Regression risk: avoid logging raw location/map data outside the local validation policy.

## iPhone validation protocol

Use a release build on the iPhone 16 Pro. Disable debugger attachment for timed runs, keep the device on battery above 60%, record iOS build/device/storage state, and repeat each case at least 10 times after one warm-up. Report median, p90, min/max, and failures separately; never combine host and device results.

1. Prepare 1, 25, 100, and 250 valid synthetic packages (small metadata, representative archive/preview sizes), plus malformed, future-schema, and symlink fixtures only in an app test container.
2. Measure cold and warm Home-screen `refresh` wall time, main-thread hitch duration (Instruments Time Profiler), number of decoded packages, and size-task completion latency. Confirm latest-only generation behavior during rapid refresh/delete.
3. For 5, 25, and 100 MiB archive variants, measure `loadWorldMap` read time, unarchive time, resident-memory delta/peak, and thermal state. Confirm checksum/metadata identity and that invalid/symlinked packages cannot appear or load.
4. Simulate interrupted save stages (before final commit, during replacement, after commit before cleanup) using fault injection. Relaunch and verify that either the previous complete package or the newly complete package remains discoverable; never an incomplete one.
5. Seed validation histories at 100, 1,000, 10,000 records and at the byte ceiling. Measure app launch/refresh and append p90, verify newest-first stable tie behavior, recovery from corrupt JSON, and no visible Home/History UI hitch.
6. Run 20 save/open/relocalize cycles in representative rooms. Correlate persistence durations and archive sizes with mapping coverage, relocalization success, final pose confidence, memory warnings, and thermal throttling. Persistence speed must not be reported as localization accuracy.

## Handoff summary

Implement canonical package validation first, then a recoverable package commit. The primary performance work is moving refresh/history I/O off the main actor with generation-safe publishes; size caching follows once on-device profiling confirms its contribution. Add the new test file to the test target before executing the XCTest performance metrics.
