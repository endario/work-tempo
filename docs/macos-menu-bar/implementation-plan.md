# SourceTempo macOS Menu-Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a local native macOS menu-bar client that reads SourceTempo reports immediately, tracks multiple Git roots one at a time, and refreshes the selected workspace through the existing collector.

**Architecture:** A dependency-free Swift package separates report math, persistence, process execution, and refresh policy into `SourceTempoCore`; a thin SwiftUI executable renders `MenuBarExtra` and Swift Charts. The Python collector remains the sole owner of Git traversal and metric definitions through schema-version-1 JSON.

**Tech Stack:** Swift 6, SwiftUI, Swift Charts, AppKit, XCTest, Python 3.10+, Git, GitHub Actions macOS runner.

**Spec:** `docs/macos-menu-bar/design.md`

## Global Constraints

- Target macOS 14 or newer and Apple Silicon for the local MVP.
- Keep the Swift package dependency-free outside Apple frameworks.
- Do not change Python metric definitions or report schema in this milestone.
- Use the selected workspace only; do not compute a cross-workspace aggregate.
- Exclude documentation from pace, churn, net-growth, and source-LOC metrics.
- Drop the report's generated-date bucket before 30/30 churn comparison.
- Use two collector workers; first collection is attended and untimed, routine refresh times out after 120 seconds.
- Preserve the last successful report across refresh failures.
- Run only one collector process at a time and drop timer/wake triggers while one is active.
- Keep the repository private and unlicensed.

---

## Task 1: Report Contract And Momentum Math

**Files:**
- Create: `macos/Package.swift`
- Create: `macos/Sources/SourceTempoCore/ReportDocument.swift`
- Create: `macos/Sources/SourceTempoCore/MomentumSummary.swift`
- Create: `macos/Tests/SourceTempoCoreTests/ReportDocumentTests.swift`
- Create: `macos/Tests/SourceTempoCoreTests/MomentumSummaryTests.swift`

**Interfaces:**
- Produces: `ReportDocument.decode(data:) throws -> ReportDocument`
- Produces: `ReportDocument.closedDayRange -> Range<Int>?`
- Produces: `MomentumSummary.init(report:)`
- Produces: `PaceState` cases `ready(share:)`, `insufficientHistory`, `newActivity`, and `noRecentActivity`
- Produces: `TrendPoint { label, code, test, docs }`

- [x] **Step 1: Create the Swift package manifest and failing decoder tests**

Use a macOS 14 package with `SourceTempoCore`, `SourceTempoMenuBar`, and `SourceTempoCoreTests` targets. In `ReportDocumentTests`, generate schema-version-1 JSON with `JSONSerialization` and assert:

```swift
let report = try ReportDocument.decode(data: makeReportData())
XCTAssertEqual(report.workspace.title, "Fixture")
XCTAssertEqual(report.series.loc.last, 220)
XCTAssertThrowsError(try ReportDocument.decode(data: makeReportData(schemaVersion: 2)))
```

- [x] **Step 2: Run the decoder test and verify RED**

Run: `cd macos && swift test --filter ReportDocumentTests`

Expected: compilation fails because `ReportDocument` does not exist.

- [x] **Step 3: Implement the minimal report model and validation**

Decode only the used version-1 fields:

```swift
public struct ReportDocument: Decodable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: String
    public let workspace: WorkspaceReport
    public let period: PeriodReport
    public let series: MetricSeries

    public static func decode(data: Data) throws -> Self
}
```

Reject non-version-1 documents, non-daily reports, mismatched used-series lengths, and invalid `generatedAt` date prefixes with typed `ReportError` cases. Unknown JSON keys remain ignored.

- [x] **Step 4: Run decoder tests and verify GREEN**

Run: `cd macos && swift test --filter ReportDocumentTests`

Expected: all decoder tests pass.

- [x] **Step 5: Write failing closed-window and pace tests**

Cover these behaviors with 61 generated labels and fixed arrays:

```swift
XCTAssertEqual(summary.currentChurn, 300)
XCTAssertEqual(summary.previousChurn, 150)
XCTAssertEqual(summary.netGrowth, 90)
XCTAssertEqual(summary.pace, .ready(share: 2.0 / 3.0))
```

Also assert that a stale report drops its own generated-date label, fewer than 60 closed labels is insufficient, leading zero LOC is insufficient, previous zero/current non-zero is new activity, both zero is no activity, docs never enter churn, and leading-zero trend points are omitted.

- [x] **Step 6: Run momentum tests and verify RED**

Run: `cd macos && swift test --filter MomentumSummaryTests`

Expected: compilation fails because `MomentumSummary` does not exist.

- [x] **Step 7: Implement momentum calculation and compact formatting**

Use report-label indices rather than wall-clock dates. Drop the final index when `period.labels.last == generatedAt.prefix(10)`, then take exactly 60 closed indices. Sum the first 30 as previous and second 30 as current. Add `MetricFormatter.compact(_:)` for menu values such as `999`, `1.2K`, and `1.18M`.

- [x] **Step 8: Run all Swift tests and commit**

Run: `cd macos && swift test`

Commit:

```text
feat: add SourceTempo report model

Assisted-by: OpenAI Codex (GPT-5)
```

## Task 2: Workspace Persistence And Collector Resolution

**Files:**
- Create: `macos/Sources/SourceTempoCore/Workspace.swift`
- Create: `macos/Sources/SourceTempoCore/WorkspaceStore.swift`
- Create: `macos/Sources/SourceTempoCore/CollectorResolver.swift`
- Create: `macos/Tests/SourceTempoCoreTests/WorkspaceStoreTests.swift`
- Create: `macos/Tests/SourceTempoCoreTests/CollectorResolverTests.swift`

**Interfaces:**
- Produces: `Workspace(root: URL) throws`
- Produces: `WorkspaceState { schemaVersion, roots, selectedRoot }`
- Produces: `WorkspaceStore.load()`, `save(_:)`, `reportURL(for:)`
- Produces: `CollectorResolver.resolve(explicit:) throws -> URL`

- [x] **Step 1: Write failing workspace-store tests**

Tests use a temporary Application Support directory and assert canonical root deduplication, schema-version-1 round trip, selected-root preservation, deterministic report-path digest, atomic replacement, and version rejection.

- [x] **Step 2: Run workspace tests and verify RED**

Run: `cd macos && swift test --filter WorkspaceStoreTests`

Expected: compilation fails because workspace types do not exist.

- [x] **Step 3: Implement workspace and state storage**

Canonicalize with `resolvingSymlinksInPath().standardizedFileURL`. The canonical path is identity. Store:

```json
{
  "schemaVersion": 1,
  "roots": ["/absolute/git/root"],
  "selectedRoot": "/absolute/git/root"
}
```

Use a temporary sibling file, `FileHandle.synchronize()`, and `FileManager.replaceItemAt` or `moveItem` for atomic save. Name reports with the first 12 lowercase hex characters of SHA-256(canonical path).

- [x] **Step 4: Run workspace tests and verify GREEN**

Run: `cd macos && swift test --filter WorkspaceStoreTests`

- [x] **Step 5: Write failing resolver tests**

Inject home directory, environment PATH, and executable predicate. Assert order: explicit override, `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, then PATH. Assert the missing error contains every searched location.

- [x] **Step 6: Implement resolver and verify GREEN**

Run: `cd macos && swift test --filter CollectorResolverTests`

- [x] **Step 7: Run all Swift tests and commit**

Commit:

```text
feat: persist SourceTempo workspaces

Assisted-by: OpenAI Codex (GPT-5)
```

## Task 3: Collector Process And Refresh Coordination

**Files:**
- Create: `macos/Sources/SourceTempoCore/CollectorClient.swift`
- Create: `macos/Sources/SourceTempoCore/RefreshCoordinator.swift`
- Create: `macos/Tests/SourceTempoCoreTests/CollectorClientTests.swift`
- Create: `macos/Tests/SourceTempoCoreTests/RefreshCoordinatorTests.swift`

**Interfaces:**
- Produces: `CollectorRequest { workspace, reportURL, timeout }`
- Produces: `CollectorClient.collect(_:) async throws -> ReportDocument`
- Consumes: Swift task cancellation to terminate an active collector process group
- Produces: `RefreshCoordinator.select(root:)`, `request(trigger:reportGeneratedAt:now:lowPower:)`, and `finish()`
- Consumes: `ReportDocument.decode(data:)`

- [x] **Step 1: Write failing collector argument and preflight tests**

Use a temporary executable shell fixture and temporary Git repository. Assert exact arguments:

```text
--root <root> --period day --days 61 --workers 2 --no-html --json <path>
```

Assert missing paths and subdirectories that are not repository roots fail before the collector launches. Assert non-zero exit returns only a bounded final diagnostic.

- [x] **Step 2: Run collector tests and verify RED**

Run: `cd macos && swift test --filter CollectorClientTests`

- [x] **Step 3: Implement process execution and cancellation**

Use `/usr/bin/git -C <root> rev-parse --show-toplevel` for preflight. Launch `Process`, redirect stdout to `/dev/null`, redirect stderr to an app-owned temporary file, call `setpgid(pid, pid)` immediately after launch, and terminate with `kill(-pid, SIGTERM)` followed by `SIGKILL` after a bounded grace period. Decode the report only after exit zero. Routine requests race process completion against a 120-second clock; first-run requests use no timeout.

- [x] **Step 4: Verify collector GREEN including child termination**

The timeout fixture spawns a child process and writes both PIDs. After cancellation, assert neither PID exists. Run: `cd macos && swift test --filter CollectorClientTests`.

- [x] **Step 5: Write failing refresh-coordinator tests**

Assert manual first run starts untimed, stale launch/timer/wake starts with timeout, fresh reports are skipped, Low Power Mode suppresses timer/wake but not manual, a second trigger during flight is dropped, and `finish()` permits the next request.

- [x] **Step 6: Implement the actor coordinator and verify GREEN**

Use an actor with one selected root and one in-flight token. The coordinator returns a value-only `RefreshPlan` and never imports SwiftUI or AppKit.

- [x] **Step 7: Run all Swift tests and commit**

Commit:

```text
feat: run and schedule SourceTempo collection

Assisted-by: OpenAI Codex (GPT-5)
```

## Task 4: Cached Menu-Bar Surface

**Files:**
- Create: `macos/Sources/SourceTempoMenuBar/SourceTempoApp.swift`
- Create: `macos/Sources/SourceTempoMenuBar/AppModel.swift`
- Create: `macos/Sources/SourceTempoMenuBar/MenuBarLabel.swift`
- Create: `macos/Sources/SourceTempoMenuBar/DashboardView.swift`
- Create: `macos/Sources/SourceTempoMenuBar/TrendChart.swift`
- Create: `macos/Sources/SourceTempoMenuBar/PaceGauge.swift`
- Create: `macos/Sources/SourceTempoCore/DashboardSnapshot.swift`
- Create: `macos/Tests/SourceTempoCoreTests/AppSnapshotModelTests.swift`

**Interfaces:**
- Consumes: workspace state, saved reports, `MomentumSummary`, `RefreshCoordinator`, and `CollectorClient`
- Produces: `@MainActor AppModel: ObservableObject`
- Produces: `DashboardSnapshot` value model for deterministic UI state

- [x] **Step 1: Write failing snapshot-model tests**

Assert cached, empty, refreshing, stale, failed-with-cache, insufficient-history, new-activity, and no-activity snapshots expose the exact values and accessibility labels the views consume.

- [x] **Step 2: Run snapshot tests and verify RED**

Run: `cd macos && swift test --filter AppSnapshotModelTests`

- [x] **Step 3: Implement the snapshot model and verify GREEN**

Keep display derivation in `SourceTempoCore/DashboardSnapshot.swift`, outside SwiftUI. The menu label exposes source LOC plus refresh/stale state. Pace copy uses the four `PaceState` cases without describing productivity.

- [x] **Step 4: Build the SwiftUI menu app**

Use `MenuBarExtra` with `.menuBarExtraStyle(.window)`. Build a 430-point-wide dashboard with:

- Title row, workspace picker, refresh and add icon buttons.
- Circular pace gauge with absolute current/previous churn.
- Four equal metric columns: source LOC, code, tests, docs.
- Swift Charts 60-day code/test area and line plot.
- Workspace rows and a compact footer with remove and quit actions.

Use system typography, SF Symbols, blue code, amber tests, neutral docs, and semantic positive/negative colors. Do not nest cards or add tutorial copy.

- [x] **Step 5: Build and run all tests**

Run:

```bash
cd macos
swift test
swift build -c release
```

- [x] **Step 6: Commit cached UI**

```text
feat: add SourceTempo menu bar dashboard

Assisted-by: OpenAI Codex (GPT-5)
```

## Task 5: Live Workspace Management And Refresh

**Files:**
- Modify: `macos/Sources/SourceTempoMenuBar/AppModel.swift`
- Modify: `macos/Sources/SourceTempoMenuBar/DashboardView.swift`
- Modify: `macos/Sources/SourceTempoMenuBar/SourceTempoApp.swift`
- Create: `macos/Sources/SourceTempoCore/WorkspaceController.swift`
- Modify: `macos/Tests/SourceTempoCoreTests/AppSnapshotModelTests.swift`

**Interfaces:**
- Consumes: `NSOpenPanel`, `NSWorkspace.didWakeNotification`, `ProcessInfo.isLowPowerModeEnabled`
- Produces: testable `WorkspaceController` add, select, remove, and refresh state transitions
- Produces: AppKit glue for manual refresh, launch refresh, hourly refresh, wake refresh, cancel, and quit

- [x] **Step 1: Add failing state-transition tests**

Test `WorkspaceController` directly: adding canonicalizes and selects a root, duplicate add is rejected, selection saves state and loads its cached report, removing selects a remaining root, refresh preserves prior data on failure, and late completion cannot overwrite a newly selected workspace's UI state.

- [x] **Step 2: Run tests and verify RED**

Run: `cd macos && swift test --filter AppSnapshotModelTests`

- [x] **Step 3: Implement workspace actions and refresh lifecycle**

Use `NSOpenPanel` for one directory at a time. First collection is explicit progress with cancel. Routine refresh preserves cached content, uses a 120-second timeout, and updates the report atomically on success. Register a one-hour timer and wake notification; both call the coordinator and are dropped when in flight or in Low Power Mode.

- [x] **Step 4: Verify GREEN and full build**

Run: `cd macos && swift test && swift build -c release`.

- [x] **Step 5: Commit live behavior**

```text
feat: manage and refresh SourceTempo workspaces

Assisted-by: OpenAI Codex (GPT-5)
```

## Task 6: Packaging, CI, Documentation, And Visual Verification

**Files:**
- Create: `scripts/build-macos-app.sh`
- Modify: `.github/workflows/test.yml`
- Modify: `.gitignore`
- Modify: `README.md`
- Modify: `docs/macos-menu-bar/design.md`
- Modify: `docs/macos-menu-bar/implementation-plan.md`

**Interfaces:**
- Produces: `dist/SourceTempo.app`
- Produces: optional local install at `/Applications/SourceTempo.app`

- [x] **Step 1: Add packaging script**

Build release, create `Contents/MacOS`, and generate an `Info.plist` with:

```text
CFBundleIdentifier = co.namespace.SourceTempo
CFBundleName = SourceTempo
CFBundleExecutable = SourceTempo
LSMinimumSystemVersion = 14.0
LSUIElement = true
```

Ad-hoc sign the local bundle and support `--install` using `ditto` to `/Applications/SourceTempo.app`.

- [x] **Step 2: Add macOS CI and documentation**

Add a `macos-latest` job running `swift test` and `swift build -c release` from `macos/`. Document requirements, build, install, first-run cost, workspace policy ownership, local CLI resolution, storage paths, and uninstallation. Ignore `macos/.build/` and `dist/`.

- [x] **Step 3: Package and validate bundle metadata**

Run:

```bash
scripts/build-macos-app.sh
plutil -p dist/SourceTempo.app/Contents/Info.plist
codesign --verify --deep --strict dist/SourceTempo.app
test "$(defaults read "$PWD/dist/SourceTempo.app/Contents/Info" LSUIElement)" = 1
```

- [x] **Step 4: Install and launch against real workspaces**

Install the app, exercise the actual add-workspace UI, load Adastra, Cloud Wing, Reborn, and SourceTempo, and verify each report matches a fresh CLI JSON run for source LOC, code, tests, docs, current churn, previous churn, and net growth.

- [x] **Step 5: Verify rendered pixels**

Capture the dashboard at native scale for populated, first-run, and error states; verify stale rendering through its deterministic snapshot model. Inspect the images and measure title-row vertical alignment, equal metric-column bounds, gauge labels, chart bounds, and longest workspace path. Check that no text overlaps or clips and that the app has no Dock icon.

- [x] **Step 6: Run complete project verification**

Run:

```bash
PYTHONPATH=src python3 -m unittest discover -s tests -v
python3 -m compileall -q src tests
cd macos && swift test && swift build -c release
cd .. && git diff --check
```

- [x] **Step 7: Refresh design/plan status and commit**

Record actual implemented behavior and measured verification without adding public-distribution claims.

```text
docs: document SourceTempo macOS app

Assisted-by: OpenAI Codex (GPT-5)
```

- [ ] **Step 8: Open a draft PR, run independent review, fix verified findings, re-review, merge, and clean the worktree**
