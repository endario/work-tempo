# Aggregate Momentum Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make SourceTempo default to one overlap-safe All Workspaces dashboard with a trailing-30-day churn rate in the hero and menu bar, plus faithful 90-day LOC-by-language and split-churn charts.

**Architecture:** Decode the collector's complete report partitions, adapt individual reports and portfolio-aligned reports into one `MomentumInput`, and derive all metrics through `MomentumSummary`. Persist an explicit display scope, schedule workspace refreshes as a bounded sequential queue, and keep aggregation in Swift so each workspace retains its own collector policy.

**Tech Stack:** Python 3 standard library collector, Swift 6, SwiftUI, Swift Charts, XCTest, unittest.

**Spec:** `docs/aggregate-momentum/design.md`

## Global Constraints

- One contributor cohort and one closed-day watermark govern every aggregate metric.
- Refuse aggregate output when repository paths overlap or report timezones differ.
- Retain 120 daily labels; display 90 closed days and append the current open day only when every contributor shares it.
- Source churn excludes documentation and the current open day.
- Keep report and workspace schema version 1 through additive fields.
- Keep the app dependency-free outside Apple frameworks and preserve `LSUIElement=true`.

---

### Task 1: Shared Momentum Input

**Files:**
- Modify: `macos/Sources/SourceTempoCore/MomentumSummary.swift`
- Modify: `macos/Sources/SourceTempoCore/ReportDocument.swift`
- Modify: `macos/Tests/SourceTempoCoreTests/MomentumSummaryTests.swift`
- Modify: `macos/Tests/SourceTempoCoreTests/TestReportFactory.swift`

**Interfaces:**
- Produces: `MomentumInput`, `MomentumSummary.init(input:)`, `MomentumSummary.init(report:)`, and `dailyChurn`.
- Preserves: existing pace, net-growth, and current/previous churn semantics except that the daily average becomes explicit.

- [ ] Add failing tests proving `dailyChurn == currentChurn / 30`, the open day is excluded, pre-creation zeros remain calendar inactivity, and report/input initializers agree.
- [ ] Run `swift test --package-path macos --filter MomentumSummaryTests` and confirm the new assertions fail.
- [ ] Add `MomentumInput` with aligned labels, generated date, LOC/kind/churn arrays, and make `init(report:)` only adapt report data before forwarding to `init(input:)`.
- [ ] Run the focused tests and the complete Swift suite.
- [ ] Commit the no-parallel-metric-engine seam.

### Task 2: Complete Report Contract And Cache Checkpoints

**Files:**
- Modify: `macos/Sources/SourceTempoCore/ReportDocument.swift`
- Modify: `macos/Tests/SourceTempoCoreTests/ReportDocumentTests.swift`
- Modify: `macos/Tests/SourceTempoCoreTests/TestReportFactory.swift`
- Modify: `src/source_tempo/cli.py`
- Modify: `tests/test_cli.py`

**Interfaces:**
- Produces: decoded `scope.repositories`, `timeline`, `series.language`, `addedByKind`, and `deletedByKind` with alignment validation.
- Produces: `checkpoint_cache(path, cache, completed, total)` used after churn and every snapshot progress batch.

- [ ] Add failing Swift tests for the new fields and each misaligned nested series.
- [ ] Add failing Python tests proving an intermediate cache checkpoint is atomic and contains newly completed snapshot entries.
- [ ] Extend report decoding and validation without changing report schema version.
- [ ] Save cache after churn and each 20-snapshot or final progress batch in serial and parallel collection paths.
- [ ] Run focused Python and Swift contract tests, then both complete suites.
- [ ] Commit the collector/report boundary.

### Task 3: Explicit Aggregate Scope

**Files:**
- Modify: `macos/Sources/SourceTempoCore/Workspace.swift`
- Modify: `macos/Sources/SourceTempoCore/WorkspaceController.swift`
- Modify: `macos/Sources/SourceTempoCore/WorkspaceStore.swift`
- Modify: `macos/Tests/SourceTempoCoreTests/WorkspaceStoreTests.swift`
- Modify: `macos/Tests/SourceTempoCoreTests/WorkspaceControllerTests.swift`

**Interfaces:**
- Produces: `DisplayScope.all`, `DisplayScope.workspace(Workspace)`, optional persisted `selectedScope`, `WorkspaceController.selectAll()`, and `WorkspaceControllerState.scope`.
- Preserves: `selectedRoot` writes for workspace selection; `nil` remains only an on-disk compatibility value.

- [ ] Add failing tests for legacy-state migration to All, aggregate/workspace round trips, add-without-scope-change, remove behavior, and empty-list distinction.
- [ ] Run focused workspace tests and confirm failures.
- [ ] Implement explicit in-memory scope and additive schema-v1 persistence.
- [ ] Run focused and complete Swift suites.
- [ ] Commit scope persistence and controller behavior.

### Task 4: Overlap-Safe Portfolio Aggregation

**Files:**
- Create: `macos/Sources/SourceTempoCore/PortfolioMomentum.swift`
- Modify: `macos/Sources/SourceTempoCore/DashboardSnapshot.swift`
- Create: `macos/Tests/SourceTempoCoreTests/PortfolioMomentumTests.swift`
- Modify: `macos/Tests/SourceTempoCoreTests/AppSnapshotModelTests.swift`
- Modify: `macos/Tests/SourceTempoCoreTests/TestReportFactory.swift`

**Interfaces:**
- Produces: `PortfolioMomentum.build(workspaces:reports:) -> Result<DashboardData, PortfolioError>`.
- Produces: `DashboardData` with current totals, shared `MomentumInput?`, `ChartTimeline?`, contributor count, total count, watermark, oldest generation date, and one warning.
- Errors: `.overlappingRepository(path:first:second:)` and `.mixedTimezones([String])`.

- [ ] Add failing tests for summed current totals, aligned 30/60/90-day values, one cohort, missing reports, overlap refusal, timezone refusal, language union/zero fill, current-open-day gating, and short-history chart unavailability.
- [ ] Run `swift test --package-path macos --filter PortfolioMomentumTests` and confirm failures.
- [ ] Implement common-label watermark selection and index-based summation into one synthetic `MomentumInput` and `ChartTimeline`.
- [ ] Refactor `DashboardSnapshot` to consume `DashboardData` for both individual and portfolio views; publish daily churn as `menuValue`.
- [ ] Run portfolio, snapshot, and complete Swift suites.
- [ ] Commit aggregation and snapshot presentation data.

### Task 5: Bounded Sequential Refresh

**Files:**
- Modify: `macos/Sources/SourceTempoCore/CollectorClient.swift`
- Modify: `macos/Sources/SourceTempoCore/RefreshCoordinator.swift`
- Modify: `macos/Tests/SourceTempoCoreTests/CollectorClientTests.swift`
- Modify: `macos/Tests/SourceTempoCoreTests/CollectorContractTests.swift`
- Modify: `macos/Tests/SourceTempoCoreTests/RefreshCoordinatorTests.swift`
- Modify: `macos/Sources/SourceTempoMenuBar/AppModel.swift`

**Interfaces:**
- Produces: collector `--days 120`.
- Produces: `RefreshTarget(workspace:generatedAt:dayCount:)` and `RefreshCoordinator.request(trigger:scope:targets:now:lowPower:) -> [RefreshPlan]`.
- Publishes: `refreshProgress` as current index, total, and workspace name.

- [ ] Add failing tests proving manual aggregate queues all, unattended aggregate chooses exactly one missing/short/oldest-stale target, individual scope chooses only its workspace, timeout depends on report completeness, low-power suppression, single-flight, and cancellation queue semantics.
- [ ] Run focused refresh and collector tests and confirm failures.
- [ ] Implement the pure queue planner and update `AppModel` to execute plans sequentially, continue after failure, stop on cancellation, and drop the queue on process exit.
- [ ] Run focused and complete Swift suites.
- [ ] Commit refresh orchestration.

### Task 6: Dashboard And Two Analytical Charts

**Files:**
- Modify: `macos/Sources/SourceTempoMenuBar/PaceGauge.swift`
- Modify: `macos/Sources/SourceTempoMenuBar/MenuBarLabel.swift`
- Modify: `macos/Sources/SourceTempoMenuBar/DashboardView.swift`
- Replace: `macos/Sources/SourceTempoMenuBar/TrendChart.swift`
- Modify: `macos/Sources/SourceTempoMenuBar/DebugPreview.swift`
- Modify: `macos/Tests/SourceTempoCoreTests/AppSnapshotModelTests.swift`

**Interfaces:**
- Produces: `LOCSnapshotChart`, `DailyChurnChart`, stable `LanguageColor`, aggregate picker/list row, contributor/watermark caption, and queue progress.
- Consumes: `DashboardSnapshot.dailyChurn`, `chartTimeline`, `scope`, and aggregate warning/error fields.

- [ ] Add or update snapshot-model assertions for hero copy, compact `/d` menu value, contributor caption, and extending-history states.
- [ ] Update the picker and workspace list so All Workspaces is the default selectable row and Remove remains disabled for it.
- [ ] Put the daily churn average inside the gauge, keep pace secondary, and switch workspace rows to daily rates.
- [ ] Implement language-stacked LOC with docs below axis and split added/deleted churn bars with docs below axis and the average rule.
- [ ] Keep header/footer fixed and make the dashboard body scroll within 760 points.
- [ ] Run complete Swift and Python suites, then build the debug preview and release app.
- [ ] Capture aggregate and individual screenshots at 430 points, measure ink alignment and chart-pixel visibility, and correct any overlap or clipped labels.
- [ ] Install `/Applications/SourceTempo.app`, launch it, verify the menu value matches the hero, and confirm no Dock icon.
- [ ] Commit the visual surface.

### Task 7: Documentation And Delivery

**Files:**
- Modify: `README.md`
- Modify: `docs/macos-menu-bar/design.md`
- Modify: `docs/aggregate-momentum/design.md`

**Interfaces:**
- Documents: aggregate default, daily-rate definition, overlap refusal, 120-day retention/90-day display, two charts, and refresh queue behavior.

- [ ] Update user-facing and predecessor design documentation without restating inferable implementation details.
- [ ] Run `git diff --check`, full Python tests, full Swift tests, and release app build.
- [ ] Perform an independent review, fix verified findings, rerun affected checks, and re-review when required.
- [ ] Open a concise PR, queue it, watch it merge, and remove the worktree/branch after the installed app is confirmed.
