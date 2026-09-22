# App Settings (macOS menu-bar app) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let WorkTempo's macOS menu-bar app user configure three previously-hardcoded timing values — history window, headline rolling window, and refresh cadence — from a native Settings window, replacing scattered Swift literals with one persisted `AppSettings` value.

**Architecture:** Two self-contained PRs. PR 1 is a pure refactor — every hardcoded constant and independently-defaulted parameter becomes a required, explicitly-threaded parameter, wired at each call site to today's exact literal values via a new `AppSettings.default`. No UI, no persistence, no behavior change; guarded by a regression test asserting the defaults reproduce today's numbers exactly. PR 2 adds real persistence (`UserDefaults`), a native `Settings` scene, load-at-launch binding, apply-on-save, and a frequency floor on a pre-existing unbounded-recollection path that the new low-cadence presets would otherwise worsen.

**Tech Stack:** Swift 6, SwiftUI (`MenuBarExtra`, `Settings` scene), `UserDefaults`, XCTest.

**Spec:** [docs/settings/design.md](design.md) — read it alongside this plan; it carries the reasoning (three critic rounds) behind decisions this plan treats as settled, including two design corrections found only in the final round (an ineffective round-2 throttle fix, and a launch-binding gap).

## Global Constraints

- macOS 14+, Swift 6, package targets `.macOS(.v14)` (`macos/Package.swift:7`) — `openSettings`/`Settings` scene requires this floor, already met.
- No default parameter values on any of the widened signatures below (`staleInterval`, `requiredDayCount`, `maxWindowDays`, `windowDays`, `historyWindow`, `collectorDays`) — every call site, including tests, passes them explicitly. A default would silently reintroduce the literal-duplication this work exists to remove.
- `AppSettings` (the struct, `.default`, and in PR 2 `load()`/`save()`/clamping) lives in `WorkTempoCore`, not `WorkTempoMenuBar` — `macos/Package.swift:18` only exposes `WorkTempoCoreTests` as a test target; code in the executable target isn't importable by tests.
- The aggregate (All Workspaces) staleness threshold stays the literal `86_400` in `DashboardSnapshot.swift` — out of scope, untouched by either PR.
- Collector worker count (`"2"` in `CollectorClient.swift`) stays hardcoded — out of scope.
- The `RefreshCoordinator` routine-timeout bump (120s → 300s) and the per-workspace counting-policy config (`.work-tempo.json`) are explicitly **not** part of this plan.
- Every task's `swift build` / `swift test` must be run from `macos/` (`cd macos && swift build` / `cd macos && swift test`).

---

## PR 1: Behavior-preservation refactor

No settings surface, no persistence, no UI. Every task in this PR must leave the app's observable behavior byte-for-byte identical to today's — the regression test in Task 1 is what proves that, and every later task in this PR builds on it.

### Task 1: `AppSettings` value type with today's defaults

**Files:**
- Create: `macos/Sources/WorkTempoCore/AppSettings.swift`
- Test: `macos/Tests/WorkTempoCoreTests/AppSettingsTests.swift` (new file)

**Interfaces:**
- Produces: `AppSettings` (struct, `Codable, Equatable, Sendable`) with stored `historyDays: Int`, `headlineWindowDays: Int`, `refreshCadenceSeconds: Int`, and `static let default: AppSettings`. Every later task in this PR reads `AppSettings.default.<field>` as the single source of today's literals.

- [ ] **Step 1: Write the failing test**

```swift
// macos/Tests/WorkTempoCoreTests/AppSettingsTests.swift
import XCTest
@testable import WorkTempoCore

final class AppSettingsTests: XCTestCase {
    func testDefaultReproducesTodaysHardcodedValues() {
        XCTAssertEqual(AppSettings.default.historyDays, 184)
        XCTAssertEqual(AppSettings.default.headlineWindowDays, 30)
        XCTAssertEqual(AppSettings.default.refreshCadenceSeconds, 3_600)
        XCTAssertEqual(HistoryWindow(historyDays: AppSettings.default.historyDays).collectorDays, 185)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd macos && swift test --filter AppSettingsTests`
Expected: FAIL — `AppSettings` and `HistoryWindow(historyDays:)` don't exist yet (`HistoryWindow` is still the static enum from `PortfolioMomentum.swift`; Task 2 turns it into the instance value this test expects).

- [ ] **Step 3: Write minimal implementation**

```swift
// macos/Sources/WorkTempoCore/AppSettings.swift
import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var historyDays: Int
    public var headlineWindowDays: Int
    public var refreshCadenceSeconds: Int

    public init(historyDays: Int, headlineWindowDays: Int, refreshCadenceSeconds: Int) {
        self.historyDays = historyDays
        self.headlineWindowDays = headlineWindowDays
        self.refreshCadenceSeconds = refreshCadenceSeconds
    }

    public static let `default` = AppSettings(
        historyDays: 184,
        headlineWindowDays: 30,
        refreshCadenceSeconds: 3_600
    )
}
```

Leave the test failing for now — it also depends on Task 2's `HistoryWindow(historyDays:)`. Don't run it again until Task 2 is done; Task 2's own steps re-run it.

- [ ] **Step 4: Commit**

```bash
git add macos/Sources/WorkTempoCore/AppSettings.swift macos/Tests/WorkTempoCoreTests/AppSettingsTests.swift
git commit -m "$(cat <<'EOF'
feat(macos): add AppSettings with today's hardcoded defaults

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `HistoryWindow` becomes an instance value

**Files:**
- Modify: `macos/Sources/WorkTempoCore/PortfolioMomentum.swift:1-7`

**Interfaces:**
- Consumes: nothing new.
- Produces: `HistoryWindow` (struct, `Sendable`) with `init(historyDays: Int)`, `let chartClosedDays: Int`, `let collectorDays: Int`. Tasks 3, 6, 7, and the `AppModel`/`DashboardSnapshot` tasks in PR 1 and PR 2 all construct and read this.

- [ ] **Step 1: Replace the static enum**

Current code (`PortfolioMomentum.swift:1-7`):

```swift
import Foundation

public enum HistoryWindow {
    // Six consecutive calendar months can span 184 days (March through August).
    public static let chartClosedDays = 184
    public static let collectorDays = chartClosedDays + 1
}
```

Replace with:

```swift
import Foundation

public struct HistoryWindow: Sendable {
    public let chartClosedDays: Int
    public let collectorDays: Int

    public init(historyDays: Int) {
        chartClosedDays = historyDays
        collectorDays = historyDays + 1
    }
}
```

- [ ] **Step 2: Run the AppSettings test from Task 1**

Run: `cd macos && swift test --filter AppSettingsTests`
Expected: still FAIL to compile — `PortfolioMomentum.build`/`.chart(for:)` still reference the now-removed static members `HistoryWindow.chartClosedDays`. That's Task 3.

- [ ] **Step 3: Commit**

```bash
git add macos/Sources/WorkTempoCore/PortfolioMomentum.swift
git commit -m "$(cat <<'EOF'
refactor(macos): HistoryWindow becomes an instance value

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

(This commit will not build in isolation — `PortfolioMomentum.swift`'s own `build`/`chart(for:)` methods reference the removed static members. Task 3 fixes this immediately after; committing here keeps history readable without leaving `main`/the PR branch broken, since this PR only merges as a whole.)

---

### Task 3: `PortfolioMomentum.build`/`.chart(for:)` take `historyWindow`/`windowDays`, and the round-1 headline gate/slice gap is fixed

This is the fix for the bug critic round 1 found: `PortfolioMomentum.build` has its own hardcoded `30` (twice), independent of `MomentumSummary`'s. Without this task, the headline-window setting would be cosmetic for the All Workspaces view.

**Files:**
- Modify: `macos/Sources/WorkTempoCore/PortfolioMomentum.swift` (the `build` and `chart(for:)` static methods, and the `historyState`/chart construction inside `build`)

**Interfaces:**
- Consumes: `HistoryWindow` (Task 2), `MomentumSummary.init(input:maxWindowDays:)` (Task 4 — write this task's code now, it will not compile until Task 4 lands; that's expected and matches Task 2's pattern).
- Produces: `PortfolioMomentum.build(workspaces:reports:historyWindow:windowDays:) -> Result<PortfolioMomentum, PortfolioError>` and `PortfolioMomentum.chart(for:historyWindow:) -> ChartTimeline?`. `AppModel` (Task 8) and `AppSnapshotModelTests`/`PortfolioMomentumTests` (Task 9) call these.

- [ ] **Step 1: Update the two method signatures and every internal use of the removed static members**

Locate `public static func build(` in `PortfolioMomentum.swift`. Add two parameters:

```swift
public static func build(
    workspaces: [Workspace],
    reports: [Workspace: ReportDocument],
    historyWindow: HistoryWindow,
    windowDays: Int
) -> Result<PortfolioMomentum, PortfolioError> {
```

Inside that method, replace every `HistoryWindow.chartClosedDays` with `historyWindow.chartClosedDays`, and replace the two `30` literals (the momentum slice and its gate) with `windowDays`:

```swift
        guard !contributors.isEmpty else {
            return .success(PortfolioMomentum(
                contributorCount: 0,
                trackedCount: workspaces.count,
                totals: totals,
                watermark: nil,
                generatedAt: nil,
                warning: warning,
                momentum: nil,
                chart: nil,
                historyState: .extending(current: 0, required: historyWindow.chartClosedDays)
            ))
        }

        let commonClosed = commonClosedLabels(contributors.map(\.1))
        let momentumLabels = Array(commonClosed.suffix(min(windowDays, commonClosed.count)))
        let momentumInput = makeMomentumInput(reports: contributors.map(\.1), labels: momentumLabels)
        let aligned = momentumLabels.count >= windowDays
            ? AlignedMomentum(
                input: momentumInput,
                summary: MomentumSummary(input: momentumInput, maxWindowDays: windowDays)
            )
            : nil
        let chart = commonClosed.count >= 2
            ? makeChart(
                reports: contributors.map(\.1),
                closedLabels: Array(commonClosed.suffix(min(historyWindow.chartClosedDays, commonClosed.count)))
            )
            : nil

        return .success(PortfolioMomentum(
            contributorCount: contributors.count,
            trackedCount: workspaces.count,
            totals: totals,
            watermark: commonClosed.last,
            generatedAt: contributors.map { $0.1.generatedAt }.min(),
            warning: warning,
            momentum: aligned,
            chart: chart,
            historyState: commonClosed.count >= historyWindow.chartClosedDays
                ? .ready
                : .extending(current: commonClosed.count, required: historyWindow.chartClosedDays)
        ))
    }
```

Then `chart(for:)`:

```swift
    public static func chart(for report: ReportDocument, historyWindow: HistoryWindow) -> ChartTimeline? {
        let closed = closedLabels(report)
        guard closed.count >= 2 else { return nil }
        return makeChart(
            reports: [report],
            closedLabels: Array(closed.suffix(min(historyWindow.chartClosedDays, closed.count)))
        )
    }
```

- [ ] **Step 2: Commit**

```bash
git add macos/Sources/WorkTempoCore/PortfolioMomentum.swift
git commit -m "$(cat <<'EOF'
refactor(macos): thread historyWindow/windowDays through PortfolioMomentum

Fixes the round-1 gap where PortfolioMomentum.build's own momentum
slice and gate were hardcoded to 30, independent of MomentumSummary's
value — the headline-window setting would otherwise be cosmetic for
the All Workspaces view.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

(Still won't build — `MomentumSummary(input:maxWindowDays:)` doesn't exist until Task 4.)

---

### Task 4: `MomentumSummary` takes a `maxWindowDays` input, distinct from its `windowDays` output

Critic round 3 caught a naming collision risk: `MomentumSummary` already has a *derived* output property `windowDays` (bounded by `firstTrackedDay`, so a young workspace's window is naturally shorter than the cap). The new *input* parameter must have a different name, or an implementer could assign it straight onto the property and silently drop that bound.

**Files:**
- Modify: `macos/Sources/WorkTempoCore/MomentumSummary.swift:70-101`

**Interfaces:**
- Consumes: nothing new.
- Produces: `MomentumSummary.init(report: ReportDocument, maxWindowDays: Int)` and `.init(input: MomentumInput, maxWindowDays: Int)`. `PortfolioMomentum.swift` (Task 3, already written above) and `DashboardSnapshot.swift` (Task 6) call these; both are used throughout `MomentumSummaryTests.swift`, `PortfolioMomentumTests.swift`, and `AppSnapshotModelTests.swift` (Task 9 updates the call sites).

- [ ] **Step 1: Add the parameter to both initializers**

Current code (`MomentumSummary.swift:66-83`):

```swift
    public init(report: ReportDocument) {
        self.init(input: MomentumInput(report: report))
    }

    public init(input: MomentumInput) {
        sourceLOC = input.loc.last ?? 0
        codeLOC = input.codeLoc.last ?? 0
        testLOC = input.testLoc.last ?? 0
        docsLOC = input.docLoc.last ?? 0

        let closedEnd = input.labels.last == input.generatedDate
            ? max(0, input.labels.count - 1)
            : input.labels.count
        // Churn as well as lines: a first day that adds source and deletes it
        // again ends at zero LOC but is a day the workspace was worked on.
        let firstTrackedDay = (0..<closedEnd).first { input.loc[$0] > 0 || input.churn[$0] > 0 } ?? 0
        let currentStart = max(firstTrackedDay, max(0, closedEnd - 30))
        windowDays = max(1, closedEnd - currentStart)
```

Replace with:

```swift
    public init(report: ReportDocument, maxWindowDays: Int) {
        self.init(input: MomentumInput(report: report), maxWindowDays: maxWindowDays)
    }

    public init(input: MomentumInput, maxWindowDays: Int) {
        sourceLOC = input.loc.last ?? 0
        codeLOC = input.codeLoc.last ?? 0
        testLOC = input.testLoc.last ?? 0
        docsLOC = input.docLoc.last ?? 0

        let closedEnd = input.labels.last == input.generatedDate
            ? max(0, input.labels.count - 1)
            : input.labels.count
        // Churn as well as lines: a first day that adds source and deletes it
        // again ends at zero LOC but is a day the workspace was worked on.
        let firstTrackedDay = (0..<closedEnd).first { input.loc[$0] > 0 || input.churn[$0] > 0 } ?? 0
        let currentStart = max(firstTrackedDay, max(0, closedEnd - maxWindowDays))
        windowDays = max(1, closedEnd - currentStart)
```

The rest of the initializer (everything after `windowDays = max(1, closedEnd - currentStart)`) is unchanged — leave it exactly as it is.

- [ ] **Step 2: Run the AppSettings test**

Run: `cd macos && swift test --filter AppSettingsTests`
Expected: still FAIL to compile — `MomentumSummaryTests.swift`, `PortfolioMomentumTests.swift`, and `AppSnapshotModelTests.swift` all call the old no-parameter initializers. Task 9 fixes every test call site; don't chase individual compile errors before then.

- [ ] **Step 3: Commit**

```bash
git add macos/Sources/WorkTempoCore/MomentumSummary.swift
git commit -m "$(cat <<'EOF'
refactor(macos): MomentumSummary takes maxWindowDays, distinct from
its derived windowDays output

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `RefreshCoordinator` — required `staleInterval`/`requiredDayCount`, plus a `settings:` convenience initializer

**Files:**
- Modify: `macos/Sources/WorkTempoCore/RefreshCoordinator.swift:39-51`

**Interfaces:**
- Consumes: `AppSettings` (Task 1), `HistoryWindow` (Task 2).
- Produces: `RefreshCoordinator.init(staleInterval: TimeInterval, requiredDayCount: Int)` (no defaults) and `RefreshCoordinator.init(settings: AppSettings)`. `AppModel` (Task 8) and every `RefreshCoordinatorTests` case (Task 9) use one of these.

- [ ] **Step 1: Remove the defaults, add the convenience initializer**

Current code (`RefreshCoordinator.swift:39-51`):

```swift
public actor RefreshCoordinator {
    private let staleInterval: TimeInterval
    private let requiredDayCount: Int
    private var isRefreshing = false

    public init(
        staleInterval: TimeInterval = 3_600,
        requiredDayCount: Int = HistoryWindow.collectorDays
    ) {
        self.staleInterval = staleInterval
        self.requiredDayCount = requiredDayCount
    }
```

Replace with:

```swift
public actor RefreshCoordinator {
    private let staleInterval: TimeInterval
    private let requiredDayCount: Int
    private var isRefreshing = false

    public init(staleInterval: TimeInterval, requiredDayCount: Int) {
        self.staleInterval = staleInterval
        self.requiredDayCount = requiredDayCount
    }

    public init(settings: AppSettings) {
        self.init(
            staleInterval: TimeInterval(settings.refreshCadenceSeconds),
            requiredDayCount: HistoryWindow(historyDays: settings.historyDays).collectorDays
        )
    }
```

- [ ] **Step 2: Commit**

```bash
git add macos/Sources/WorkTempoCore/RefreshCoordinator.swift
git commit -m "$(cat <<'EOF'
refactor(macos): RefreshCoordinator requires staleInterval/requiredDayCount

Adds a settings: convenience initializer so call sites can construct
from an AppSettings value directly.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `DashboardSnapshot` — required `staleInterval`/`maxWindowDays`/`historyWindow` on the single-workspace initializer, `maxWindowDays` on the portfolio one

The single-workspace initializer calls both `MomentumSummary(report:...)` and `PortfolioMomentum.chart(for:...)` internally, so it needs three new parameters, not the two the design doc's summary table implies — a real dependency the design abstracted over. The portfolio initializer only needs one (its `windowDays` fallback when there's no momentum yet); the 86,400 aggregate staleness threshold stays a literal, out of scope.

**Files:**
- Modify: `macos/Sources/WorkTempoCore/DashboardSnapshot.swift:53-132` (single-workspace initializer) and `:134-195` (portfolio initializer)

**Interfaces:**
- Consumes: `MomentumSummary.init(report:maxWindowDays:)` (Task 4), `PortfolioMomentum.chart(for:historyWindow:)` (Task 3), `HistoryWindow` (Task 2).
- Produces: `DashboardSnapshot.init(workspace:report:refreshState:now:staleInterval:maxWindowDays:historyWindow:)` and `DashboardSnapshot.init(portfolio:refreshState:now:maxWindowDays:)`. `AppModel` (Task 8) and `AppSnapshotModelTests` (Task 9) call both.

- [ ] **Step 1: Update the single-workspace initializer's signature and body**

Current signature (`DashboardSnapshot.swift:53-59`):

```swift
    public init(
        workspace: Workspace?,
        report: ReportDocument?,
        refreshState: SnapshotRefreshState,
        now: Date,
        staleInterval: TimeInterval = 3_600
    ) {
```

Replace with:

```swift
    public init(
        workspace: Workspace?,
        report: ReportDocument?,
        refreshState: SnapshotRefreshState,
        now: Date,
        staleInterval: TimeInterval,
        maxWindowDays: Int,
        historyWindow: HistoryWindow
    ) {
```

Inside the same initializer, the "no report" early return (`DashboardSnapshot.swift:71-89`) sets `windowDays = 30` — change that one line to `windowDays = maxWindowDays`.

Further down, the code that builds the summary and chart (`DashboardSnapshot.swift:92, 118, 122`):

```swift
        let summary = MomentumSummary(report: report)
```

becomes:

```swift
        let summary = MomentumSummary(report: report, maxWindowDays: maxWindowDays)
```

and:

```swift
        let timeline = PortfolioMomentum.chart(for: report)
```

becomes:

```swift
        let timeline = PortfolioMomentum.chart(for: report, historyWindow: historyWindow)
```

and:

```swift
        historyMessage = chartTimeline == nil
            ? "Extending history to \(HistoryWindow.chartClosedDays) days"
            : nil
```

becomes:

```swift
        historyMessage = chartTimeline == nil
            ? "Extending history to \(historyWindow.chartClosedDays) days"
            : nil
```

- [ ] **Step 2: Update the portfolio initializer's signature and body**

Current signature (`DashboardSnapshot.swift:134-138`):

```swift
    public init(
        portfolio: PortfolioMomentum,
        refreshState: SnapshotRefreshState,
        now: Date
    ) {
```

Replace with:

```swift
    public init(
        portfolio: PortfolioMomentum,
        refreshState: SnapshotRefreshState,
        now: Date,
        maxWindowDays: Int
    ) {
```

The `windowDays` line inside it (`DashboardSnapshot.swift:178`):

```swift
        windowDays = summary?.windowDays ?? 30
```

becomes:

```swift
        windowDays = summary?.windowDays ?? maxWindowDays
```

Leave the `86_400` literal on the `stale` line (`:152`) untouched — that's the out-of-scope aggregate threshold.

- [ ] **Step 3: Commit**

```bash
git add macos/Sources/WorkTempoCore/DashboardSnapshot.swift
git commit -m "$(cat <<'EOF'
refactor(macos): DashboardSnapshot requires staleInterval/maxWindowDays/historyWindow

The single-workspace initializer also threads historyWindow through
to PortfolioMomentum.chart(for:) and its own historyMessage text — a
dependency the design doc's summary table didn't spell out.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: `CollectorClient`/`CollectorRequest` take an explicit `collectorDays`

**Files:**
- Modify: `macos/Sources/WorkTempoCore/CollectorClient.swift:4-14, 66-70`

**Interfaces:**
- Consumes: nothing new (a plain `Int`, not `HistoryWindow` — `CollectorClient` doesn't need to know about `HistoryWindow`'s existence, just the day count).
- Produces: `CollectorRequest.init(workspace:reportURL:timeout:collectorDays:)`. `AppModel` (Task 8) and `CollectorClientTests` (Task 9) construct these.

- [ ] **Step 1: Add the field**

Current code (`CollectorClient.swift:4-14`):

```swift
public struct CollectorRequest: Sendable {
    public let workspace: Workspace
    public let reportURL: URL
    public let timeout: Duration?

    public init(workspace: Workspace, reportURL: URL, timeout: Duration?) {
        self.workspace = workspace
        self.reportURL = reportURL
        self.timeout = timeout
    }
}
```

Replace with:

```swift
public struct CollectorRequest: Sendable {
    public let workspace: Workspace
    public let reportURL: URL
    public let timeout: Duration?
    public let collectorDays: Int

    public init(workspace: Workspace, reportURL: URL, timeout: Duration?, collectorDays: Int) {
        self.workspace = workspace
        self.reportURL = reportURL
        self.timeout = timeout
        self.collectorDays = collectorDays
    }
}
```

- [ ] **Step 2: Use it in the spawned arguments**

Current code (`CollectorClient.swift:66-73`):

```swift
        let arguments = [
            "--root", request.workspace.root.path,
            "--period", "day",
            "--days", String(HistoryWindow.collectorDays),
            "--workers", "2",
            "--no-html",
            "--json", request.reportURL.path,
        ]
```

Replace with:

```swift
        let arguments = [
            "--root", request.workspace.root.path,
            "--period", "day",
            "--days", String(request.collectorDays),
            "--workers", "2",
            "--no-html",
            "--json", request.reportURL.path,
        ]
```

- [ ] **Step 3: Commit**

```bash
git add macos/Sources/WorkTempoCore/CollectorClient.swift
git commit -m "$(cat <<'EOF'
refactor(macos): CollectorRequest carries an explicit collectorDays

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Wire `AppModel` to `AppSettings.default` at every call site

This is the task that actually makes the app compile again after Tasks 2–7 — `AppModel` is the sole production caller of everything widened so far.

**Files:**
- Modify: `macos/Sources/WorkTempoMenuBar/AppModel.swift`

**Interfaces:**
- Consumes: `AppSettings` (Task 1), `HistoryWindow` (Task 2), `RefreshCoordinator.init(settings:)` (Task 5), `PortfolioMomentum.build(...:historyWindow:windowDays:)` (Task 3), `DashboardSnapshot`'s two widened initializers (Task 6), `CollectorRequest(...:collectorDays:)` (Task 7).
- Produces: nothing new consumed elsewhere in PR 1 — this is the leaf. (PR 2's Task 14 revisits this same file for launch binding.)

- [ ] **Step 1: Add a `settings` property and a derived `historyWindow`**

In `AppModel.swift`, add a stored property alongside the existing ones (after `private let resolver: CollectorResolver`):

```swift
    private let settings: AppSettings = .default
```

And a computed property, placed near `private func aggregateRefreshState`:

```swift
    private var historyWindow: HistoryWindow {
        HistoryWindow(historyDays: settings.historyDays)
    }
```

- [ ] **Step 2: Update the `init`'s default `coordinator` parameter**

Current (`AppModel.swift:24-28`):

```swift
    init(
        store: WorkspaceStore = WorkspaceStore(),
        coordinator: RefreshCoordinator = RefreshCoordinator(),
        resolver: CollectorResolver = CollectorResolver()
    ) {
```

Replace with:

```swift
    init(
        store: WorkspaceStore = WorkspaceStore(),
        coordinator: RefreshCoordinator = RefreshCoordinator(settings: .default),
        resolver: CollectorResolver = CollectorResolver()
    ) {
```

- [ ] **Step 3: Thread `settings`/`historyWindow` through `apply(_:)` and `applyError(_:)`**

Current `apply(_:)` (`AppModel.swift:202-236`):

```swift
    private func apply(_ state: WorkspaceControllerState) {
        workspaces = state.workspaces
        scope = state.scope
        selectedWorkspace = state.selectedWorkspace
        selectedReport = state.selectedReport
        switch state.scope {
        case .all:
            let refreshState = aggregateRefreshState(state)
            switch PortfolioMomentum.build(
                workspaces: state.workspaces,
                reports: state.reportsByWorkspace
            ) {
            case let .success(portfolio):
                snapshot = DashboardSnapshot(
                    portfolio: portfolio,
                    refreshState: refreshState,
                    now: Date()
                )
            case let .failure(error):
                snapshot = DashboardSnapshot(
                    workspace: nil,
                    report: nil,
                    refreshState: .failed(error.localizedDescription),
                    now: Date()
                )
            }
        case let .workspace(workspace):
            snapshot = DashboardSnapshot(
                workspace: workspace,
                report: state.report(for: workspace),
                refreshState: state.refreshState(for: workspace),
                now: Date()
            )
        }
    }
```

Replace with:

```swift
    private func apply(_ state: WorkspaceControllerState) {
        workspaces = state.workspaces
        scope = state.scope
        selectedWorkspace = state.selectedWorkspace
        selectedReport = state.selectedReport
        switch state.scope {
        case .all:
            let refreshState = aggregateRefreshState(state)
            switch PortfolioMomentum.build(
                workspaces: state.workspaces,
                reports: state.reportsByWorkspace,
                historyWindow: historyWindow,
                windowDays: settings.headlineWindowDays
            ) {
            case let .success(portfolio):
                snapshot = DashboardSnapshot(
                    portfolio: portfolio,
                    refreshState: refreshState,
                    now: Date(),
                    maxWindowDays: settings.headlineWindowDays
                )
            case let .failure(error):
                snapshot = DashboardSnapshot(
                    workspace: nil,
                    report: nil,
                    refreshState: .failed(error.localizedDescription),
                    now: Date(),
                    staleInterval: TimeInterval(settings.refreshCadenceSeconds),
                    maxWindowDays: settings.headlineWindowDays,
                    historyWindow: historyWindow
                )
            }
        case let .workspace(workspace):
            snapshot = DashboardSnapshot(
                workspace: workspace,
                report: state.report(for: workspace),
                refreshState: state.refreshState(for: workspace),
                now: Date(),
                staleInterval: TimeInterval(settings.refreshCadenceSeconds),
                maxWindowDays: settings.headlineWindowDays,
                historyWindow: historyWindow
            )
        }
    }
```

Current `applyError(_:)` (`AppModel.swift:250-257`):

```swift
    private func applyError(_ message: String) {
        snapshot = DashboardSnapshot(
            workspace: selectedWorkspace,
            report: selectedReport,
            refreshState: .failed(message),
            now: Date()
        )
    }
```

Replace with:

```swift
    private func applyError(_ message: String) {
        snapshot = DashboardSnapshot(
            workspace: selectedWorkspace,
            report: selectedReport,
            refreshState: .failed(message),
            now: Date(),
            staleInterval: TimeInterval(settings.refreshCadenceSeconds),
            maxWindowDays: settings.headlineWindowDays,
            historyWindow: historyWindow
        )
    }
```

- [ ] **Step 4: Thread `collectorDays` through `requestRefresh`'s collect call**

Current (`AppModel.swift:170-174`):

```swift
                    let report = try await CollectorClient(executable: executable).collect(CollectorRequest(
                        workspace: plan.workspace,
                        reportURL: store.reportURL(for: plan.workspace),
                        timeout: plan.timeout
                    ))
```

Replace with:

```swift
                    let report = try await CollectorClient(executable: executable).collect(CollectorRequest(
                        workspace: plan.workspace,
                        reportURL: store.reportURL(for: plan.workspace),
                        timeout: plan.timeout,
                        collectorDays: historyWindow.collectorDays
                    ))
```

- [ ] **Step 5: Build the whole package**

Run: `cd macos && swift build`
Expected: still FAILS — `WorkTempoCoreTests` (Tasks 4, 3, 6, 7's test call sites) aren't updated yet. That's fine; `swift build` (not `swift test`) only compiles the two library/executable targets, not the test target, so this should actually succeed now. If it doesn't, the error will name the remaining call site — fix it before moving on, since Task 9 assumes production code already compiles clean.
Expected once actually run: **PASS** (zero errors) — `AppModel.swift` was the last production call site.

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/WorkTempoMenuBar/AppModel.swift
git commit -m "$(cat <<'EOF'
refactor(macos): wire AppModel to AppSettings.default at every call site

Production code now compiles clean end to end. Every value that was
a scattered literal or independently-defaulted parameter is sourced
from one AppSettings value, still fixed at .default until PR 2 adds
persistence and a way to change it.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Fix every test call site, using the compiler as the completeness check

Tasks 2–7 each left their own test files uncompiled on purpose — fixing them one signature at a time, cross-checking against the compiler, is more reliable than manually enumerating every call site up front. This task is the same four-step loop repeated per file: **grep for the old call shape, apply the one-line-different replacement shown below, rebuild, repeat until `swift test` compiles.**

**Files:**
- Modify: `macos/Tests/WorkTempoCoreTests/RefreshCoordinatorTests.swift`, `MomentumSummaryTests.swift`, `PortfolioMomentumTests.swift`, `AppSnapshotModelTests.swift`, `CollectorClientTests.swift`

**Interfaces:**
- Consumes: every signature from Tasks 2–7.
- Produces: nothing new — this task only makes existing tests compile and pass against the new signatures, with assertions unchanged (proving PR 1 is behavior-preserving).

- [ ] **Step 1: `RefreshCoordinatorTests.swift` — `RefreshCoordinator()` → `RefreshCoordinator(settings: .default)`**

Run: `grep -n 'RefreshCoordinator()' macos/Tests/WorkTempoCoreTests/RefreshCoordinatorTests.swift`

Every match (8 occurrences, at minimum lines 7, 42, 57, 71, 87, 116, 146, 169) is a bare `RefreshCoordinator()` — including `var coordinator = RefreshCoordinator()` reassignments inside a test. Replace each with `RefreshCoordinator(settings: .default)`, e.g.:

```swift
        let coordinator = RefreshCoordinator(settings: .default)
```

and

```swift
        coordinator = RefreshCoordinator(settings: .default)
```

- [ ] **Step 2: `MomentumSummaryTests.swift` — `MomentumSummary(report: report)` → add `maxWindowDays: 30`**

Run: `grep -n 'MomentumSummary(report: report)' macos/Tests/WorkTempoCoreTests/MomentumSummaryTests.swift`

Every match (6 occurrences) becomes:

```swift
        let summary = MomentumSummary(report: report, maxWindowDays: 30)
```

`30` matches every one of these tests' existing window-size assumptions (they were written against the old hardcoded `30`) — don't change it to any other value, or the existing assertions (e.g. `XCTAssertEqual(summary.windowDays, 30)`) will fail for the wrong reason.

- [ ] **Step 3: `PortfolioMomentumTests.swift` — `PortfolioMomentum.build(workspaces:reports:)` → add `historyWindow:windowDays:`**

Run: `grep -n 'PortfolioMomentum.build(' macos/Tests/WorkTempoCoreTests/PortfolioMomentumTests.swift`

Every match (7 occurrences) gets two arguments added. Worked example — current:

```swift
        let portfolio = try PortfolioMomentum.build(workspaces: [first, second], reports: reports).get()
```

becomes:

```swift
        let portfolio = try PortfolioMomentum.build(
            workspaces: [first, second],
            reports: reports,
            historyWindow: HistoryWindow(historyDays: 184),
            windowDays: 30
        ).get()
```

For the multi-line `PortfolioMomentum.build(workspaces: [first, second], reports: [` call forms, add the same two arguments (`historyWindow: HistoryWindow(historyDays: 184), windowDays: 30`) right before the closing `)` of the call, after the `reports:` dictionary literal closes. Apply this identically to every one of the 7 matches, including the two inside `testRefusesRepositoryOverlapAndMixedTimezones` (the `overlap` and `mixed` `let` bindings) and the one inside `testShortHistoryKeepsMetricsAndRendersCommonChartInterval` (which already asserts `historyState: .extending(current: 60, required: 184)` — that assertion is unaffected, since `historyWindow: HistoryWindow(historyDays: 184)` reproduces the same `184` it already expects).

- [ ] **Step 4: `AppSnapshotModelTests.swift` — both `DashboardSnapshot` initializers and `PortfolioMomentum.build`**

Run: `grep -n 'DashboardSnapshot(\|PortfolioMomentum.build(' macos/Tests/WorkTempoCoreTests/AppSnapshotModelTests.swift`

For every single-workspace `DashboardSnapshot(workspace:report:refreshState:now:)` call (7 occurrences), add the three new arguments. Worked example — current:

```swift
        let snapshot = DashboardSnapshot(
            workspace: workspace,
            report: nil,
            refreshState: .idle,
            now: Date(timeIntervalSince1970: 0)
        )
```

becomes:

```swift
        let snapshot = DashboardSnapshot(
            workspace: workspace,
            report: nil,
            refreshState: .idle,
            now: Date(timeIntervalSince1970: 0),
            staleInterval: 3_600,
            maxWindowDays: 30,
            historyWindow: HistoryWindow(historyDays: 184)
        )
```

For every portfolio `DashboardSnapshot(portfolio:refreshState:now:)` call (6 occurrences), add `maxWindowDays: 30`:

```swift
        let snapshot = DashboardSnapshot(
            portfolio: portfolio,
            refreshState: .idle,
            now: Date(timeIntervalSince1970: 0),
            maxWindowDays: 30
        )
```

For every `PortfolioMomentum.build(workspaces:reports:)` call inside this file (5 occurrences), apply the same `historyWindow: HistoryWindow(historyDays: 184), windowDays: 30` addition shown in Step 3.

- [ ] **Step 5: `CollectorClientTests.swift` — `CollectorRequest(workspace:reportURL:timeout:)` → add `collectorDays: 185`**

Run: `grep -n 'CollectorRequest(' macos/Tests/WorkTempoCoreTests/CollectorClientTests.swift`

Every match (6 occurrences) gets `collectorDays: 185` added, e.g.:

```swift
        let report = try await client.collect(CollectorRequest(
            workspace: workspace,
            reportURL: reportURL,
            timeout: .seconds(5),
            collectorDays: 185
        ))
```

`testCollectsReportWithExactArguments` (`CollectorClientTests.swift:31-47`) already asserts `"--days", "185"` in the captured argument list — leave that assertion untouched; it's what proves `collectorDays: 185` actually reached the spawned process.

- [ ] **Step 6: Build and run the full test suite**

Run: `cd macos && swift build && swift test 2>&1 | tail -60`
Expected: zero compile errors, all existing tests **PASS** with their original assertions unchanged (this is the behavior-preservation proof), plus the new `AppSettingsTests.testDefaultReproducesTodaysHardcodedValues` from Task 1.

If any test's assertion actually fails (not just a compile error), stop — that means a call site was given the wrong literal (something other than 184/30/3,600/185) and PR 1's no-behavior-change goal has been violated. Find and fix the mismatched literal; do not adjust the assertion to match.

- [ ] **Step 7: Commit**

```bash
git add macos/Tests/WorkTempoCoreTests/
git commit -m "$(cat <<'EOF'
test(macos): update every call site for the required-parameter refactor

All existing assertions are unchanged — this proves PR 1 has no
observable behavior change, only explicit parameters where literals
and defaults used to be.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Self pre-pass and open PR 1

**Files:** none (process task)

- [ ] **Step 1: Run the local code-review command over the diff**

Run: `/code-review` (Claude Code's own pre-pass, per engineering-sop S6). Apply any findings you verify; this is a filter before the independent round, not the gate itself.

- [ ] **Step 2: Push and open a draft PR**

```bash
git push -u origin settings/timing-config
gh pr create --draft --title "refactor(macos): thread history/headline/cadence as explicit parameters" --body "$(cat <<'EOF'
## Summary
PR 1 of 2 (see docs/settings/design.md and docs/settings/plan.md). Pure
refactor: every hardcoded timing constant and independently-defaulted
parameter becomes a required, explicitly-threaded value, wired at each
call site to today's exact literals via a new AppSettings.default. No
UI, no persistence, no behavior change.

## Test plan
- [ ] swift test passes with all existing assertions unchanged
- [ ] swift build succeeds with zero warnings introduced
EOF
)"
```

- [ ] **Step 3: Run the independent review gate**

Invoke the `independent-review` skill against this PR. Fix sensible findings on this branch, push, re-run, then mark the PR ready and merge per that skill's own procedure — do not ask before doing so (S6 is a mandatory gate, not a permission round).

---

## PR 2: Persistence, launch binding, UI, apply behavior, and the recollection floor

Everything below builds on PR 1 already being merged to `main`. Start this PR from an up-to-date `main`.

### Task 11: Start PR 2's branch

- [ ] **Step 1: Branch from the merged PR 1**

```bash
git checkout main
git pull
git checkout -b settings/persistence-ui
```

---

### Task 12: `AppSettings` gains `load()`/`save()` and clamp-on-load

**Files:**
- Modify: `macos/Sources/WorkTempoCore/AppSettings.swift`
- Modify: `macos/Tests/WorkTempoCoreTests/AppSettingsTests.swift`

**Interfaces:**
- Consumes: `Foundation.UserDefaults`.
- Produces: `AppSettings.load(userDefaults: UserDefaults = .standard) -> AppSettings`, `AppSettings.save(userDefaults: UserDefaults = .standard)`. `AppModel` (Task 14) and `SettingsView` (Task 17) call these — `load`/`save` are the only two methods on `AppSettings` that keep default parameter values, since they exist specifically so production code can omit `userDefaults:` while tests inject an isolated suite; this doesn't reintroduce the literal-duplication risk the "no defaults" rule guards against, because there's no second, divergent value a default could silently paper over here.

- [ ] **Step 1: Write the failing tests**

Add to `AppSettingsTests.swift`:

```swift
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "AppSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func testRoundTripsThroughUserDefaults() {
        let defaults = makeIsolatedDefaults()
        let saved = AppSettings(historyDays: 90, headlineWindowDays: 14, refreshCadenceSeconds: 1_800)

        saved.save(userDefaults: defaults)
        let loaded = AppSettings.load(userDefaults: defaults)

        XCTAssertEqual(loaded, saved)
    }

    func testMissingKeyFallsBackToDefault() {
        let defaults = makeIsolatedDefaults()

        XCTAssertEqual(AppSettings.load(userDefaults: defaults), .default)
    }

    func testCorruptDataFallsBackToDefault() {
        let defaults = makeIsolatedDefaults()
        defaults.set(Data("not json".utf8), forKey: "AppSettings")

        XCTAssertEqual(AppSettings.load(userDefaults: defaults), .default)
    }

    func testLoadClampsAllThreeFieldsToBounds() {
        let defaults = makeIsolatedDefaults()
        let outOfRange = AppSettings(historyDays: 1, headlineWindowDays: 999, refreshCadenceSeconds: 1)
        outOfRange.save(userDefaults: defaults)

        let loaded = AppSettings.load(userDefaults: defaults)

        XCTAssertEqual(loaded.historyDays, 30, "historyDays floors at 30")
        XCTAssertEqual(loaded.headlineWindowDays, 30, "999 clamps against the already-clamped historyDays of 30, not a fixed ceiling — headlineWindowDays has no static upper bound")
        XCTAssertEqual(loaded.refreshCadenceSeconds, 900, "refreshCadenceSeconds floors at 900 (15 minutes)")
    }

    func testHeadlineClampsAgainstPostClampHistoryNotRawHistory() {
        let defaults = makeIsolatedDefaults()
        // A hand-edited file with historyDays below the floor and a headline
        // that would be valid against the raw value but not the clamped one.
        let outOfRange = AppSettings(historyDays: 10, headlineWindowDays: 20, refreshCadenceSeconds: 3_600)
        outOfRange.save(userDefaults: defaults)

        let loaded = AppSettings.load(userDefaults: defaults)

        XCTAssertEqual(loaded.historyDays, 30)
        XCTAssertEqual(loaded.headlineWindowDays, 20, "20 is valid against the clamped historyDays of 30")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd macos && swift test --filter AppSettingsTests`
Expected: FAIL — `load`/`save` don't exist yet.

- [ ] **Step 3: Implement**

Append to `AppSettings.swift`:

```swift
private enum AppSettingsBounds {
    static let historyDays = 30...365
    static let headlineWindowDaysFloor = 7
    static let refreshCadenceSeconds = 900...14_400
}

public extension AppSettings {
    private static let userDefaultsKey = "AppSettings"

    static func load(userDefaults: UserDefaults = .standard) -> AppSettings {
        guard let data = userDefaults.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return .default
        }
        return decoded.clamped()
    }

    func save(userDefaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        userDefaults.set(data, forKey: Self.userDefaultsKey)
    }

    private func clamped() -> AppSettings {
        let clampedHistory = historyDays.clamped(to: AppSettingsBounds.historyDays)
        // Clamp order matters: headline clamps against the already-clamped
        // history, or a hand-edited {historyDays: 0, headlineWindowDays: 90}
        // file could clamp headline into an empty range.
        let clampedHeadline = headlineWindowDays.clamped(
            to: AppSettingsBounds.headlineWindowDaysFloor...clampedHistory
        )
        let clampedCadence = refreshCadenceSeconds.clamped(to: AppSettingsBounds.refreshCadenceSeconds)
        return AppSettings(
            historyDays: clampedHistory,
            headlineWindowDays: clampedHeadline,
            refreshCadenceSeconds: clampedCadence
        )
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd macos && swift test --filter AppSettingsTests`
Expected: PASS, all 6 cases (the Task-1 default test plus these 5).

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/WorkTempoCore/AppSettings.swift macos/Tests/WorkTempoCoreTests/AppSettingsTests.swift
git commit -m "$(cat <<'EOF'
feat(macos): AppSettings persists via UserDefaults with clamp-on-load

Missing key, decode failure, and out-of-bounds values all fall back
to (or clamp toward) AppSettings.default rather than throwing — a
corrupted settings file must not block the app from launching.
History clamps before headline clamps against it, so a hand-edited
file can't produce an empty valid range.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 13: `RefreshCoordinator`'s short-history branch gets a frequency floor

Critic round 2 proposed gating this branch on `staleInterval` alone; round 3 found that gate has no effect, since the timer already ticks at exactly that interval — "at most once per `staleInterval`" and "on every tick" are the same schedule. Round 3's fix (floor the short branch at `max(staleInterval, 3_600)`) is necessary but, written alone, not sufficient: the **stale branch immediately below it independently re-selects the same target**. That branch's `healthy.filter` runs over every healthy target, not just the ones the short branch rejected — so a short workspace old enough to clear the plain `staleInterval` (with no floor) is still selected there, still gets `timeout: nil` from `request()`'s own `dayCount < requiredDayCount` check (independent of which branch selected it), and the floor is bypassed entirely. Closing this needs the stale branch to also exclude short targets, so a short workspace can only ever be selected through the floored path.

**Files:**
- Modify: `macos/Sources/WorkTempoCore/RefreshCoordinator.swift:96-116`
- Modify: `macos/Tests/WorkTempoCoreTests/RefreshCoordinatorTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: no signature change — `unattendedTarget`'s internal behavior only.

- [ ] **Step 1: Write the failing test**

Add to `RefreshCoordinatorTests.swift`:

```swift
    func testShortHistoryBranchFloorsAtOneHourRegardlessOfLowerCadence() async throws {
        let now = Date(timeIntervalSince1970: 100_000)
        let workspace = try workspace("young")
        // A 15-minute cadence, with the workspace last collected 20 minutes
        // ago: naive `>= staleInterval` (900s) would re-select it. The
        // floor (max(900, 3_600) = 3_600) must not.
        let coordinator = RefreshCoordinator(staleInterval: 900, requiredDayCount: 185)

        let tooSoon = await coordinator.request(
            trigger: .timer,
            scope: .all,
            targets: [RefreshTarget(
                workspace: workspace,
                generatedAt: now.addingTimeInterval(-1_200),
                dayCount: 60
            )],
            now: now,
            lowPower: false
        )
        XCTAssertNil(tooSoon, "20 minutes since the last short collection is under the 1-hour floor")

        let pastFloor = await RefreshCoordinator(staleInterval: 900, requiredDayCount: 185).request(
            trigger: .timer,
            scope: .all,
            targets: [RefreshTarget(
                workspace: workspace,
                generatedAt: now.addingTimeInterval(-3_601),
                dayCount: 60
            )],
            now: now,
            lowPower: false
        )
        XCTAssertEqual(pastFloor?.map(\.workspace), [workspace], "past the 1-hour floor, the short branch still fires")
        XCTAssertNil(pastFloor?.first?.timeout, "the short branch stays untimed")
    }

    func testShortHistoryBranchUsesTheHigherCadenceWhenAboveTheFloor() async throws {
        let now = Date(timeIntervalSince1970: 100_000)
        let workspace = try workspace("young")
        // A 4-hour cadence: the floor formula is max(staleInterval, 3_600),
        // so at a cadence above the floor, the configured cadence wins.
        let coordinator = RefreshCoordinator(staleInterval: 14_400, requiredDayCount: 185)

        let withinCadence = await coordinator.request(
            trigger: .timer,
            scope: .all,
            targets: [RefreshTarget(
                workspace: workspace,
                generatedAt: now.addingTimeInterval(-7_200),
                dayCount: 60
            )],
            now: now,
            lowPower: false
        )
        XCTAssertNil(withinCadence, "2 hours since the last collection is under a 4-hour cadence")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd macos && swift test --filter RefreshCoordinatorTests`
Expected: FAIL — both new cases currently get a non-nil result even "too soon," because the short branch is still unconditional.

- [ ] **Step 3: Implement the floor, and exclude short targets from the stale branch**

Current code (`RefreshCoordinator.swift:96-117`):

```swift
    private func unattendedTarget(from targets: [RefreshTarget], now: Date) -> RefreshTarget? {
        let healthy = targets.filter { !$0.lastAttemptFailed }
        if let missing = healthy.first(where: { $0.generatedAt == nil }) {
            return missing
        }
        if let short = healthy.first(where: { $0.dayCount < requiredDayCount }) {
            return short
        }
        if let stale = healthy.filter({ target in
                target.generatedAt.map { now.timeIntervalSince($0) >= staleInterval } ?? true
            }).min(by: { lhs, rhs in
                (lhs.generatedAt ?? .distantPast) < (rhs.generatedAt ?? .distantPast)
            }) {
            return stale
        }
```

Replace with:

```swift
    private func unattendedTarget(from targets: [RefreshTarget], now: Date) -> RefreshTarget? {
        let healthy = targets.filter { !$0.lastAttemptFailed }
        if let missing = healthy.first(where: { $0.generatedAt == nil }) {
            return missing
        }
        // A workspace that can never fill the window (dayCount < required)
        // would otherwise be reselected unconditionally, forever. Floored at
        // today's fixed hourly rate regardless of a lower configured
        // cadence: a naive `>= staleInterval` gate has no effect on its own,
        // since the timer already ticks at exactly that interval.
        let shortFloor = max(staleInterval, 3_600)
        if let short = healthy.first(where: { target in
            target.dayCount < requiredDayCount
                && (target.generatedAt.map { now.timeIntervalSince($0) >= shortFloor } ?? true)
        }) {
            return short
        }
        // Short targets are excluded here, not just gated by the floor
        // above: this filter runs over every healthy target regardless of
        // dayCount, so without this exclusion a short-but-old-enough-by-
        // staleInterval-alone workspace would still be picked up through
        // this branch — bypassing the floor entirely, since request()'s own
        // timeout choice keys off dayCount < requiredDayCount independent of
        // which branch made the selection.
        if let stale = healthy.filter({ target in
                target.dayCount >= requiredDayCount
                    && (target.generatedAt.map { now.timeIntervalSince($0) >= staleInterval } ?? true)
            }).min(by: { lhs, rhs in
                (lhs.generatedAt ?? .distantPast) < (rhs.generatedAt ?? .distantPast)
            }) {
            return stale
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd macos && swift test --filter RefreshCoordinatorTests`
Expected: PASS — the two new cases, and every existing `RefreshCoordinatorTests` case unchanged (their `generatedAt` offsets are all well past 3,600s already, as verified during design review — see docs/settings/design.md, Resolved from round 3).

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/WorkTempoCore/RefreshCoordinator.swift macos/Tests/WorkTempoCoreTests/RefreshCoordinatorTests.swift
git commit -m "$(cat <<'EOF'
fix(macos): floor the short-history recollection branch at one hour

A staleInterval-only gate has no effect, since the timer ticks at
exactly that interval already. The stale branch immediately below
also has to exclude short targets, or it re-selects the same
workspace through its own unfloored check, bypassing the floor.
Together they decouple the unbounded no-timeout branch from the
cadence knob, so a 15-minute cadence preset can't turn a
permanently-short repository into a full recollection every 15
minutes.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 14: `AppModel` — launch binding and settings visibility

Fixes the gap critic round 3 found: as PR 1 leaves it, persisted settings would never actually take effect on their own across a relaunch, because `AppModel.init`/`start()` only ever construct from `.default`.

**Files:**
- Modify: `macos/Sources/WorkTempoMenuBar/AppModel.swift`

**Interfaces:**
- Consumes: `AppSettings.load()` (Task 12), `RefreshCoordinator.init(settings:)` (Task 5).
- Produces: `AppModel.settings: AppSettings` (readable, `private(set)`) — `SettingsView` (Task 17) reads this to seed its form.

- [ ] **Step 1: Make `settings` loaded and externally readable, `coordinator` mutable**

Current (`AppModel.swift:14-18`, after PR 1's Task 8 added `settings`):

```swift
    private let store: WorkspaceStore
    private let controller: WorkspaceController
    private let coordinator: RefreshCoordinator
    private let resolver: CollectorResolver
    private var refreshTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var wakeObserver: AnyCancellable?
    private var started = false
    private var selectedReport: ReportDocument?
    private let settings: AppSettings = .default
```

Replace with:

```swift
    private let store: WorkspaceStore
    private let controller: WorkspaceController
    private var coordinator: RefreshCoordinator
    private let resolver: CollectorResolver
    private var refreshTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var wakeObserver: AnyCancellable?
    private var started = false
    private var selectedReport: ReportDocument?
    private(set) var settings: AppSettings
```

- [ ] **Step 2: Load settings in `init`, before anything else uses them**

Current `init` (`AppModel.swift:24-35`, after PR 1):

```swift
    init(
        store: WorkspaceStore = WorkspaceStore(),
        coordinator: RefreshCoordinator = RefreshCoordinator(settings: .default),
        resolver: CollectorResolver = CollectorResolver()
    ) {
        self.store = store
        controller = WorkspaceController(store: store)
        self.coordinator = coordinator
        self.resolver = resolver
        snapshot = DashboardSnapshot(workspace: nil, report: nil, refreshState: .idle, now: Date())
        Task { [weak self] in await self?.start() }
    }
```

Replace with:

```swift
    init(
        store: WorkspaceStore = WorkspaceStore(),
        coordinator: RefreshCoordinator = RefreshCoordinator(settings: AppSettings.load()),
        resolver: CollectorResolver = CollectorResolver()
    ) {
        self.store = store
        controller = WorkspaceController(store: store)
        self.coordinator = coordinator
        self.resolver = resolver
        settings = AppSettings.load()
        snapshot = DashboardSnapshot(workspace: nil, report: nil, refreshState: .idle, now: Date())
        Task { [weak self] in await self?.start() }
    }
```

(The default `coordinator:` parameter expression and the `settings = AppSettings.load()` assignment each call `UserDefaults` independently — two reads of the same key at startup, both idempotent. Restructuring to share one read would need a static factory method for a saving that isn't worth the indirection here.)

- [ ] **Step 3: Read the loaded cadence in the timer loop**

Current `start()` (`AppModel.swift:106-128`):

```swift
    private func start() async {
        guard !started else { return }
        started = true
        do {
            apply(try await controller.load())
            requestRefresh(.launch)
        } catch {
            applyError(error.localizedDescription)
        }

        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3_600))
                guard !Task.isCancelled else { return }
                self?.requestRefresh(.timer)
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.requestRefresh(.wake) }
            }
    }
```

Replace with:

```swift
    private func start() async {
        guard !started else { return }
        started = true
        do {
            apply(try await controller.load())
            requestRefresh(.launch)
        } catch {
            applyError(error.localizedDescription)
        }

        startTimer()
        wakeObserver = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.requestRefresh(.wake) }
            }
    }

    private func startTimer() {
        let cadence = settings.refreshCadenceSeconds
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(cadence))
                guard !Task.isCancelled else { return }
                self?.requestRefresh(.timer)
            }
        }
    }
```

- [ ] **Step 4: Build**

Run: `cd macos && swift build`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/WorkTempoMenuBar/AppModel.swift
git commit -m "$(cat <<'EOF'
fix(macos): load persisted settings at launch, before first use

Previously only the settings-save path applied AppSettings; a value
saved in one session would sit unused until the user reopened
Settings and saved again in every subsequent session. AppModel now
loads AppSettings in init, before constructing its default
coordinator and before start()'s timer/launch-refresh.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 15: `AppModel` — apply-on-save, with the coordinator-capture race fixed

**Files:**
- Modify: `macos/Sources/WorkTempoMenuBar/AppModel.swift`

**Interfaces:**
- Consumes: `AppSettings.save()` (Task 12).
- Produces: `AppModel.applySettings(_ newSettings: AppSettings)` — `SettingsView` (Task 17) calls this from its Save button.

- [ ] **Step 1: Capture the coordinator at task start, instead of re-reading the property**

Current `requestRefresh` (`AppModel.swift:130-194`):

```swift
    private func requestRefresh(_ trigger: RefreshTrigger, scopeOverride: DisplayScope? = nil) {
        guard !workspaces.isEmpty, refreshTask == nil else { return }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

        refreshTask = Task { [weak self] in
            guard let self else { return }
            let state = await controller.state()
            let targets = state.workspaces.map { workspace in
                let report = state.report(for: workspace)
                let lastAttemptFailed: Bool
                if case .failed = state.refreshState(for: workspace) {
                    lastAttemptFailed = true
                } else {
                    lastAttemptFailed = false
                }
                return RefreshTarget(
                    workspace: workspace,
                    generatedAt: report.flatMap { Self.parseTimestamp($0.generatedAt) },
                    dayCount: report?.period.labels.count ?? 0,
                    lastAttemptFailed: lastAttemptFailed
                )
            }
            guard let plans = await coordinator.request(
                trigger: trigger,
                scope: scopeOverride ?? state.scope,
                targets: targets,
                now: Date(),
                lowPower: lowPower
            ) else {
                refreshTask = nil
                return
            }

            for (index, plan) in plans.enumerated() {
                guard !Task.isCancelled else { break }
                refreshProgress = "\(plan.workspace.displayName) · \(index + 1) of \(plans.count)"
                let ticket = await controller.beginRefresh(plan.workspace)
                apply(await controller.state())
                do {
                    let executable = try resolver.resolve()
                    let report = try await CollectorClient(executable: executable).collect(CollectorRequest(
                        workspace: plan.workspace,
                        reportURL: store.reportURL(for: plan.workspace),
                        timeout: plan.timeout,
                        collectorDays: historyWindow.collectorDays
                    ))
                    apply(await controller.succeedRefresh(ticket, workspace: plan.workspace, report: report))
                } catch CollectorError.cancelled {
                    apply(await controller.cancelRefresh(ticket, workspace: plan.workspace))
                    break
                } catch is CancellationError {
                    apply(await controller.cancelRefresh(ticket, workspace: plan.workspace))
                    break
                } catch {
                    apply(await controller.failRefresh(
                        ticket,
                        workspace: plan.workspace,
                        message: error.localizedDescription
                    ))
                }
            }
            refreshProgress = nil
            await coordinator.finish()
            refreshTask = nil
        }
    }
```

Replace with (two changes: capture `activeCoordinator` before the `Task`, and use it instead of `coordinator` at both points inside the task body):

```swift
    private func requestRefresh(_ trigger: RefreshTrigger, scopeOverride: DisplayScope? = nil) {
        guard !workspaces.isEmpty, refreshTask == nil else { return }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        // Captured here, not re-read from self.coordinator inside the task:
        // a settings save mid-flight can reassign self.coordinator, and
        // this task must keep finishing the instance it actually started
        // its request on.
        let activeCoordinator = coordinator
        let collectorDays = historyWindow.collectorDays

        refreshTask = Task { [weak self] in
            guard let self else { return }
            let state = await controller.state()
            let targets = state.workspaces.map { workspace in
                let report = state.report(for: workspace)
                let lastAttemptFailed: Bool
                if case .failed = state.refreshState(for: workspace) {
                    lastAttemptFailed = true
                } else {
                    lastAttemptFailed = false
                }
                return RefreshTarget(
                    workspace: workspace,
                    generatedAt: report.flatMap { Self.parseTimestamp($0.generatedAt) },
                    dayCount: report?.period.labels.count ?? 0,
                    lastAttemptFailed: lastAttemptFailed
                )
            }
            guard let plans = await activeCoordinator.request(
                trigger: trigger,
                scope: scopeOverride ?? state.scope,
                targets: targets,
                now: Date(),
                lowPower: lowPower
            ) else {
                refreshTask = nil
                return
            }

            for (index, plan) in plans.enumerated() {
                guard !Task.isCancelled else { break }
                refreshProgress = "\(plan.workspace.displayName) · \(index + 1) of \(plans.count)"
                let ticket = await controller.beginRefresh(plan.workspace)
                apply(await controller.state())
                do {
                    let executable = try resolver.resolve()
                    let report = try await CollectorClient(executable: executable).collect(CollectorRequest(
                        workspace: plan.workspace,
                        reportURL: store.reportURL(for: plan.workspace),
                        timeout: plan.timeout,
                        collectorDays: collectorDays
                    ))
                    apply(await controller.succeedRefresh(ticket, workspace: plan.workspace, report: report))
                } catch CollectorError.cancelled {
                    apply(await controller.cancelRefresh(ticket, workspace: plan.workspace))
                    break
                } catch is CancellationError {
                    apply(await controller.cancelRefresh(ticket, workspace: plan.workspace))
                    break
                } catch {
                    apply(await controller.failRefresh(
                        ticket,
                        workspace: plan.workspace,
                        message: error.localizedDescription
                    ))
                }
            }
            refreshProgress = nil
            await activeCoordinator.finish()
            refreshTask = nil
        }
    }
```

(`collectorDays` is also captured up front for the same reason: `historyWindow` is derived from `settings`, which `applySettings` is about to start mutating too.)

- [ ] **Step 2: Add `applySettings(_:)`**

Add this method near `toggleRefresh()`:

```swift
    func applySettings(_ newSettings: AppSettings) {
        settings = newSettings
        settings.save()
        timerTask?.cancel()
        startTimer()
        coordinator = RefreshCoordinator(settings: newSettings)
        requestRefresh(.manual, scopeOverride: .all)
    }
```

(If a refresh is already in flight, `requestRefresh`'s own `refreshTask == nil` guard silently defers this to the next timer tick — matching the existing "mid-refresh save" tolerance already established for the `dayCount < requiredDayCount` self-healing behavior; no special-casing needed here.)

- [ ] **Step 3: Build**

Run: `cd macos && swift build`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add macos/Sources/WorkTempoMenuBar/AppModel.swift
git commit -m "$(cat <<'EOF'
feat(macos): AppModel.applySettings persists, rebinds, and refreshes

requestRefresh now captures its coordinator (and the collector day
count) as task-local values instead of re-reading the mutable
properties mid-flight, so a settings save racing an in-progress
refresh can't call finish() on the wrong actor instance.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 16: `SettingsView` and the `Settings` scene

**Files:**
- Create: `macos/Sources/WorkTempoMenuBar/SettingsView.swift`
- Modify: `macos/Sources/WorkTempoMenuBar/WorkTempoApp.swift`

**Interfaces:**
- Consumes: `AppModel.settings` (Task 14), `AppModel.applySettings(_:)` (Task 15), `AppSettings.default` (Task 1).
- Produces: `SettingsView` — a SwiftUI view, instantiated by the new `Settings` scene.

- [ ] **Step 1: Write `SettingsView`**

```swift
// macos/Sources/WorkTempoMenuBar/SettingsView.swift
import WorkTempoCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var historyDays: Int
    @State private var headlineWindowDays: Int
    @State private var refreshCadenceSeconds: Int

    private static let headlineWindowOptions = [7, 14, 30, 60, 90]

    init(model: AppModel) {
        self.model = model
        _historyDays = State(initialValue: model.settings.historyDays)
        _headlineWindowDays = State(initialValue: model.settings.headlineWindowDays)
        _refreshCadenceSeconds = State(initialValue: model.settings.refreshCadenceSeconds)
    }

    private var headlineOptions: [Int] {
        Self.headlineWindowOptions.filter { $0 <= historyDays }
    }

    var body: some View {
        Form {
            Section {
                Picker("History", selection: $historyDays) {
                    Text("1 month (30d)").tag(30)
                    Text("3 months (90d)").tag(90)
                    Text("6 months (184d)").tag(184)
                    Text("12 months (365d)").tag(365)
                }
                .onChange(of: historyDays) { _, newValue in
                    if headlineWindowDays > newValue {
                        headlineWindowDays = Self.headlineWindowOptions
                            .filter { $0 <= newValue }
                            .last ?? Self.headlineWindowOptions[0]
                    }
                }
                Text("How far back Work Tempo collects and charts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Headline window", selection: $headlineWindowDays) {
                    ForEach(headlineOptions, id: \.self) { days in
                        Text("\(days)d").tag(days)
                    }
                }
                Text("The rolling window behind the churn/day and net growth hero metrics.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Refresh cadence", selection: $refreshCadenceSeconds) {
                    Text("15 minutes").tag(900)
                    Text("30 minutes").tag(1_800)
                    Text("1 hour").tag(3_600)
                    Text("2 hours").tag(7_200)
                    Text("4 hours").tag(14_400)
                }
                Text("Checks about every N in the background — Work Tempo also refreshes on launch and when your Mac wakes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Restore Defaults") {
                    historyDays = AppSettings.default.historyDays
                    headlineWindowDays = AppSettings.default.headlineWindowDays
                    refreshCadenceSeconds = AppSettings.default.refreshCadenceSeconds
                }
                Spacer()
                Button("Save") {
                    model.applySettings(AppSettings(
                        historyDays: historyDays,
                        headlineWindowDays: headlineWindowDays,
                        refreshCadenceSeconds: refreshCadenceSeconds
                    ))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
```

- [ ] **Step 2: Add the `Settings` scene**

Current `WorkTempoApp.swift`:

```swift
import AppKit
import WorkTempoCore
import SwiftUI

@main
struct WorkTempoApp: App {
    @StateObject private var model = AppModel()
#if DEBUG
    @NSApplicationDelegateAdaptor(DebugPreviewDelegate.self) private var previewDelegate
#endif

    var body: some Scene {
        MenuBarExtra {
            DashboardView(
                model: model,
                onRefresh: { model.toggleRefresh() },
                onAdd: { model.chooseWorkspace() },
                onRemove: { model.removeSelectedWorkspace() },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
        } label: {
            MenuBarLabel(snapshot: model.snapshot)
        }
        .menuBarExtraStyle(.window)
    }
}
```

Replace the `body` with:

```swift
    var body: some Scene {
        MenuBarExtra {
            DashboardView(
                model: model,
                onRefresh: { model.toggleRefresh() },
                onAdd: { model.chooseWorkspace() },
                onRemove: { model.removeSelectedWorkspace() },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
        } label: {
            MenuBarLabel(snapshot: model.snapshot)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
```

- [ ] **Step 3: Build**

Run: `cd macos && swift build`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add macos/Sources/WorkTempoMenuBar/SettingsView.swift macos/Sources/WorkTempoMenuBar/WorkTempoApp.swift
git commit -m "$(cat <<'EOF'
feat(macos): add the Settings window

Three preset Pickers (no free-text entry), headline window filtered
to <= the selected history window, Restore Defaults.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 17: Gear button in `DashboardView`, with the `LSUIElement` activation fix

`AppModel.chooseWorkspace()` already calls `NSApp.activate(ignoringOtherApps: true)` before presenting an `NSOpenPanel` — existing evidence that this `LSUIElement` (no Dock icon) app needs explicit activation for a raised window to come to the front reliably. `openSettings` alone is not enough to assume away; Task 20 verifies it manually.

**Files:**
- Modify: `macos/Sources/WorkTempoMenuBar/DashboardView.swift`

**Interfaces:**
- Consumes: SwiftUI's `\.openSettings` environment action (macOS 14+).
- Produces: nothing new consumed elsewhere.

- [ ] **Step 1: Add the environment action and `AppKit` import**

Current imports (`DashboardView.swift:1-2`):

```swift
import WorkTempoCore
import SwiftUI
```

Replace with:

```swift
import AppKit
import WorkTempoCore
import SwiftUI
```

Add the environment property, alongside the existing `let` properties in `DashboardView`:

```swift
struct DashboardView: View {
    @ObservedObject var model: AppModel
    let onRefresh: () -> Void
    let onAdd: () -> Void
    let onRemove: () -> Void
    let onQuit: () -> Void
    @Environment(\.openSettings) private var openSettings
```

- [ ] **Step 2: Add the gear button to the header**

Current header action row (`DashboardView.swift:50-58`):

```swift
                actionButton(
                    model.snapshot.isRefreshing ? "xmark" : "arrow.clockwise",
                    help: model.snapshot.isRefreshing ? "Cancel refresh" : "Refresh",
                    action: onRefresh
                )
                    .disabled(model.workspaces.isEmpty)
            }
            actionButton("plus", help: "Add workspace", action: onAdd)
        }
```

Replace with:

```swift
                actionButton(
                    model.snapshot.isRefreshing ? "xmark" : "arrow.clockwise",
                    help: model.snapshot.isRefreshing ? "Cancel refresh" : "Refresh",
                    action: onRefresh
                )
                    .disabled(model.workspaces.isEmpty)
            }
            actionButton("gearshape", help: "Settings", action: openSettingsWindow)
            actionButton("plus", help: "Add workspace", action: onAdd)
        }
```

Add the method near `chooseWorkspace`'s sibling helpers — place it right after the `header` computed property closes:

```swift
    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }
```

- [ ] **Step 3: Build**

Run: `cd macos && swift build`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add macos/Sources/WorkTempoMenuBar/DashboardView.swift
git commit -m "$(cat <<'EOF'
feat(macos): add a gear button that opens Settings

Explicit NSApp.activate before openSettings, matching the existing
precedent in AppModel.chooseWorkspace() for raising a window
reliably from this LSUIElement (no Dock icon) app.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 18: Doc refresh

**Files:**
- Modify: `README.md`
- Modify: `docs/macos-app.md`

**Interfaces:** none (documentation only).

- [ ] **Step 1: Update `README.md`**

Find the line in the "## Reports" or menu-bar description area referencing "up to thirty" (`README.md:13`, "Its menu-bar value and primary dashboard metric show source churn per day over the trailing closed days, up to thirty."). Update it to note the window is configurable:

```markdown
The optional native macOS menu-bar app opens on an aggregate of all tracked workspaces. Its menu-bar value and primary dashboard metric show source churn per day over the trailing closed days — 30 by default, configurable in Settings. An individual workspace remains selectable from the header.
```

- [ ] **Step 2: Update `docs/macos-app.md`**

Four places pin the old fixed numbers:

1. Collection command (around `docs/macos-app.md:47-49`, `work-tempo --root <root> --period day --days 185 ...`): add a sentence noting `185` is `historyDays + 1` from the user's configured history window (default 184), not a fixed constant.
2. "185 daily labels cover six calendar months..." (around `:53`): note this describes the default; the actual count follows the configured history window.
3. Scheduling section ("Unattended triggers... the stalest one older than an hour" — around `:57`): note the hour is the default refresh cadence, user-configurable, and that a workspace too short to ever fill its window is now floored at one recollection per hour regardless of a lower configured cadence.
4. Metrics section ("trailing closed days, up to 30" — around `:73`): note 30 is the default headline window, user-configurable, filtered to never exceed the configured history window.

Add a short new subsection (placed after "## Interface", before "## Errors and empty states") documenting the Settings window itself:

```markdown
## Settings

A native Settings window (gear icon in the popover header) configures
three values, persisted via `UserDefaults`:

- **History** — how far back the collector fetches and the charts
  display. Default 6 months (184 days).
- **Headline window** — the rolling window behind the churn/day and net
  growth hero metrics. Default 30 days, never more than the configured
  history window.
- **Refresh cadence** — how often the app checks for background
  refreshes, and how old a report can get before it's flagged stale.
  Default 1 hour. The app also refreshes on launch and when the Mac
  wakes, independent of this cadence.

Changing history or headline window triggers an immediate refresh
across every tracked workspace. A workspace whose Git history is
younger than the configured window is recollected at most once per
hour, regardless of a lower configured cadence — a permanently short
workspace does not become more expensive just because cadence dropped.
```

- [ ] **Step 3: Commit**

```bash
git add README.md docs/macos-app.md
git commit -m "$(cat <<'EOF'
docs: document the configurable history/headline/cadence settings

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 19: Manual verification pass

This is the one mechanism in this design nobody has executed before now (critic round 1's activation-risk flag, round 3's "verify before writing the rest of the form" recommendation) — do this before considering PR 2 done, not as an afterthought.

**Files:** none (manual verification, no code changes expected unless it fails)

- [ ] **Step 1: Build and launch the app**

```bash
cd macos
swift build -c release
open ../dist/WorkTempo.app 2>/dev/null || swift run WorkTempoMenuBar &
```

(Use `scripts/build-macos-app.sh` from the repo root for an ad-hoc-signed bundle if `swift run` doesn't produce a launchable menu-bar icon in your environment — see `README.md`'s macOS app section.)

- [ ] **Step 2: Verify the gear button opens, fronts, and closes the Settings window**

Click the menu-bar icon to open the popover, click the gear button. Confirm:
- The Settings window opens and comes to the front (not behind other windows) — this is the specific risk the `NSApp.activate` call in Task 17 exists to prevent. If it does NOT come to front reliably, that call needs to move earlier, or the scene needs to change from `Settings { }` to a manually-managed `Window { }` scene — do not consider this design converged until one of those actually works, per critic round 3's explicit fallback note.
- Changing a Picker value and clicking Save closes back to a live app (no crash, no hang).
- Reopening Settings shows the previously-saved values, not the defaults — confirms both persistence and the launch-binding fix from Task 14 (quit and relaunch the app entirely, then reopen Settings, to verify this survives a real relaunch, not just staying in the same process).

- [ ] **Step 3: Verify the young-repository throttle**

Create a throwaway Git repository with only a few days of commit history (fewer days than any history-window preset), add it as a workspace, and set Refresh cadence to 15 minutes. Confirm from Activity Monitor or Console logs that the collector process for that workspace does not run more than once per hour, even though cadence is 15 minutes — this is the Known Limitation's mitigated (not eliminated) behavior from Task 13; the workspace should still show as "extending history," just without a runaway collection loop.

- [ ] **Step 4: Note any findings**

If activation or persistence fails, fix it now — this task blocks the PR, not a follow-up. If everything passes, no commit is needed for this task; it's a verification gate.

---

### Task 20: Self pre-pass and open PR 2

**Files:** none (process task)

- [ ] **Step 1: Run the local code-review command over the diff**

Run: `/code-review`. Apply verified findings.

- [ ] **Step 2: Push and open a PR**

```bash
git push -u origin settings/persistence-ui
gh pr create --title "feat(macos): Settings window for history/headline/cadence" --body "$(cat <<'EOF'
## Summary
PR 2 of 2 (see docs/settings/design.md and docs/settings/plan.md, PR 1
already merged). Adds UserDefaults persistence, launch-time settings
binding, a native Settings window (three preset pickers, no free
text), apply-on-save, and a frequency floor on the pre-existing
young-repository recollection loop that lower cadence presets would
otherwise worsen.

## Test plan
- [ ] swift test passes
- [ ] Manual: gear button opens/fronts/closes Settings from a running LSUIElement build
- [ ] Manual: settings survive a full app relaunch
- [ ] Manual: a young test workspace at a low cadence recollects at most once per hour
EOF
)"
```

- [ ] **Step 3: Run the independent review gate**

Invoke `independent-review` against this PR. Fix sensible findings, push, re-run, then merge per that skill's procedure.

---

## Self-review notes (for the plan author, not a task)

- **Spec coverage:** every design-doc section (Data model, UI, Persistence, Plumbing, Apply behavior, Launch binding, Known limitation, Testing, Resolved-from-round-3 items) maps to a task above. The one design detail this plan had to resolve on its own — whether `AppSettings` (the plain struct) ships in PR 1 or waits for PR 2 — is settled in Task 1's placement: the struct and `.default` ship in PR 1 as the single named source of today's literals; `load()`/`save()`/clamping are added on top in Task 12 without changing the type's shape, so PR 1 never references `UserDefaults`.
- **Type consistency check:** `maxWindowDays` (input) vs. `windowDays` (output) is used consistently as named across Tasks 3, 4, 6, 8, 9, 16 — verified no task accidentally writes `windowDays:` where an input parameter was meant.
- **Ordering dependency:** Tasks 2–8 are written to be applied in order and will not individually compile in isolation (each depends on the next); Task 9 is the first point the whole package (including tests) compiles and passes. This is called out explicitly in each task's steps so an executor doesn't stop and debug a red build mid-sequence.
