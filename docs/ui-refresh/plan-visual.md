# Dashboard Visual Refresh Implementation Plan

> **For agentic workers:** This plan guided the dashboard refresh; consult the current code before making follow-up changes.

**Goal:** Give the menu-bar popover a clear glance hierarchy while keeping both charts, metric semantics, and native interaction available.

**Architecture:** Restyle the existing `DashboardView` and `MomentumHero`; reuse the existing chart and hover implementation while improving chart titles, explanatory copy, and legends. Extend the verified Source chart accessibility descriptor pattern to monthly activity. Keep the snapshot's public metrics and all collector logic unchanged.

**Tech Stack:** Swift 6, SwiftUI, Swift Charts, Accessibility; macOS 14+.

**Spec:** [design.md](design.md). This plan follows a merged and verified [accessible chart pilot](plan-accessibility.md).

## Global Constraints

- Keep the 430-point popover width; let scroll content set its height up to a screen-safe cap, and scroll beyond it. Use light and dark native surfaces, no new dependency or image assets.
- Do not modify collector, report format, refresh semantics, `DashboardSnapshot.metrics`, menu-bar label, or Settings.
- Preserve `--` for unavailable figures and all error/partial/progress banners.
- No workspace-removal confirmation in this PR; it needs its own truthful cached-report disclosure and activation review.
- Use Xcode via `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; do not install this build over the user's app or restart their other sessions.

## Review Focus

- A very long workspace name must truncate without pushing timestamp/actions outside 430 points, and its full value must remain discoverable.
- Source must equal Code + Tests; Docs is separate and must not look additive with source.
- A negative net change must remain legible without red-as-judgment; a positive one must not imply software quality.
- Hover cards must remain readable when they extend below the hero over the summary.
- Partial-day / partial-month annotations and accessible data must remain current when scope or reports change.

---

### Task 1: Hero hierarchy

**Files:** Modify `macos/Sources/WorkTempoMenuBar/MomentumHero.swift:9-83`; verify in `DashboardView.swift:114-119`.

**Interfaces:** Consume the existing `DashboardSnapshot`; do not change `HeroSparkline`'s input arrays, tooltip rows, or open-day mapping. `metric` takes a visible `title: String` and `weight: Font.Weight` in addition to existing arguments. The churn title is `SOURCE CHURN`; growth title is `NET SOURCE CHANGE`; the shared context uses `LAST \(snapshot.windowDays) CLOSED DAYS` when momentum exists and `HEADLINE UNAVAILABLE` otherwise. Both figures use the same size for aligned baselines; weight and neutral foreground subordinate net growth. Its sparkline also uses neutral ink.

- **Step 1: Capture baseline behavior.** Note the current screenshot's unnamed `26K / DAY`, green `+638K / 30D`, and hover cards' placement; record no screenshot with local metrics in git.
- **Step 2: Change the hero layout.** Add the context line above the pair; label each metric before its figure, and keep each plot below its own figure. Use `.firstTextBaseline` alignment for value/unit rows, with system fonts and monospaced digits. Remove any help-only dependency for interpreting either figure, while preserving detailed help.
- **Step 3: Verify at 430 points.** Exercise zero, positive and negative growth using cached preview/test fixtures where available; hover first/last sparkline points and verify cards do not cover the figure or become clipped. Run the debug build, inspect ink bounds of heading/value/unit pairs, and adjust baseline alignment only if rendered ink requires it.

### Task 2: Header and composition

**Files:** Modify `macos/Sources/WorkTempoMenuBar/DashboardView.swift:31-152,212-224`.

**Interfaces:** Use `snapshot.metrics` by ids `source`, `code`, `tests`, `docs`; no Core type changes. `workspaceMenu` yields flexible bounded text with `.truncationMode(.middle)` and `.help` of the selected full display name. Header icon buttons retain callbacks and receive `.accessibilityLabel(help)`; remove `.focusable(false)`.

- **Step 1: Establish failure cases.** Check an exceptionally long workspace display name in the debug view and tab navigation through Refresh, Settings, and Add; note baseline clipping or skipped focus.
- **Step 2: Rebalance header width.** Keep the title and action buttons at intrinsic sizes; allow only the workspace chooser to compress. Keep `Updated …` visible and leave banners where they are; no duplicate status row.
- **Step 3: Replace the metric card.** Render source as an aggregate with Code + Tests grouped underneath or alongside it; mark Docs as `separate` in visible text. Present numerals in primary text ink and small color keys only where they map to charts. Use the existing metrics' `--` and labels. Do not perform arithmetic on compact formatted strings.
- **Step 4: Check focus and layout.** Verify mouse and keyboard activations, All versus individual scope, refresh/partial/error labels, footer, and the headline hover overlay across the summary. At 430pt measure rendered header and summary ink extents in both appearances. Build and run Swift tests.

### Task 3: Chart explanation and accessible monthly activity

**Files:** Modify `macos/Sources/WorkTempoMenuBar/DashboardView.swift:154-185,226-253,291-296`; `macos/Sources/WorkTempoMenuBar/ChurnCharts.swift:183-260`; extend `macos/Sources/WorkTempoMenuBar/ChartAccessibility.swift` from the pilot; add `macos/Tests/WorkTempoMenuBarTests/MonthlyChartDescriptorTests.swift`.

**Interfaces:** `MonthlyChartDescriptor(timeline: ChartTimeline): AXChartDescriptorRepresentable` consumes `timeline.monthlyChurn` and exposes six series named `Code added`, `Code removed`, `Tests added`, `Tests removed`, `Docs added`, `Docs removed`; x categories are year-month labels, y values are actual counts. `updateChartDescriptor` replaces the prior series/axes/summary when the timeline changes. Chart visual geometry, hover values, and partial-month width remain unchanged.

- **Step 1: Check baseline.** Confirm month bars' hover readouts and current-month partial width; check that the current chart has only a generic accessibility label.
- **Step 2: Write a failing descriptor test, then implement.** In `MonthlyChartDescriptorTests`, make a two-month `ChartTimeline` with distinct code/test/docs additions/removals, assert the descriptor's six named series expose literal positive monthly totals, calendar labels, and a current-month `To date` label. Assert `updateChartDescriptor` replaces prior values after a new timeline. Run the targeted test RED before adding `MonthlyChartDescriptor`. Map `timeline.monthlyChurn` into dated additions/removals per kind, preserving unexpected signed report values; summarize that docs is visually below zero only for separation. Set `isContinuous: false`; follow the pilot's update semantics and attach it to `MonthlyChurnChart`. Run targeted test GREEN.
- **Step 3: Clarify visible charts.** Title the charts `SOURCE LINES OVER TIME` and `MONTHLY ACTIVITY`; add a compact visible docs-separation note and a monthly `Added + removed, not net change` note.
- **Step 4: Validate both charts.** Hover first/last plot points, inspect each descriptor's dates/counts, switch scope or refresh and verify updated values, and check current partial periods. Measure tick/legend/title ink bounds and note spacing/overflow across dark and light screenshots. Run full Swift tests and release build; run Python collector tests and compile checks.

### Task 4: Content-sized popover with screen cap

**Files:** Modify `macos/Sources/WorkTempoMenuBar/DashboardView.swift:102-125`; use the existing debug preview to render light/dark captures without touching the installed app.

**Interfaces:** The inner dashboard `VStack` reports its intrinsic height through `onGeometryChange`, stored in a view-local `@State` property. The ScrollView viewport uses `DashboardView.viewportHeight(content:screenHeight:)`, which returns `min(content, max(180, screenHeight - 120))` points. Screen height comes from the key app window's screen when available; with no key app window, it falls back to the shortest connected screen to bound the viewport on smaller displays. The 430-point width and footer placement are unchanged. The state is necessary: a direct `frame(maxHeight:)` probe fit static content but the running app's parent proposed a smaller viewport and clipped the activity chart.

- **Step 1: Record RED.** The fixed 445-point scroll frame visibly clips the monthly axis and grouped legend in the rendered debug preview, while the screen's available height can hold the full content. A standalone `NSHostingView` sizing probe appeared to support `frame(maxHeight:)`, but the live app measured a taller content stack than its viewport; do not use that probe as evidence for the app.
- **Step 2: Size to measured content.** Attach `.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { dashboardContentHeight = $0 }` to the padded inner stack; set the ScrollView height using `viewportHeight(content:screenHeight:)` and prefer the key window's display for the screen cap. Do not introduce another window, a geometry preference key, or a chart selector.
- **Step 3: Verify GREEN.** Capture populated and empty/error/refreshing states at 430 points, dark and light. On a tall screen, both chart axes and the activity legend fit above the footer; on a smaller simulated cap, the body scrolls and footer remains visible. Measure rendered ink extents and ensure the height settles after a report or banner changes; an initial resize while cached state loads is expected. Run Swift tests and release build.

### Task 5: Ship the visual slice

**Files:** Update `docs/macos-app.md` and relevant README macOS paragraph; finalize `docs/ui-refresh/design.md` with verified outcome and any difference from the spec.

- **Step 1: Compare the actual result to Outcome.** A user should be able to answer the headline question from visible text without hover; both charts remain stacked and their keys/notes fit when the display has room, otherwise the body scrolls without hiding the footer. Record measured ink extents and disclose any unverified visual state.
- **Step 2: Review the entire diff.** Run the local code-review pre-pass, fix verified issues, open a draft PR, run the independent review gate, address findings, and merge after a ship-it verdict. Do not publish the user's data screenshot in the PR.
- **Step 3: Drain loose ends separately.** Decide whether the cached-report deletion confirmation warrants a second targeted PR or an issue; never add it to this visual diff. Remove only task-owned temporary files/processes; leave the user’s installed app and worktree intact unless asked otherwise.
