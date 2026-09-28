# Accessible Charts Pilot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans or superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Make the Source LOC chart's dated code, test, and separate documentation counts navigable through macOS chart accessibility before extending the pattern.

**Architecture:** One chart-specific `AXChartDescriptorRepresentable` reads `ChartTimeline`; `SourceVolumeChart` attaches it using `.accessibilityChartDescriptor`. Its `updateChartDescriptor` must replace summary, axes, and series on a new timeline rather than leave stale values. No change to the chart geometry, the Core model, or the app's storage.

**Tech Stack:** Swift 6, SwiftUI, Swift Charts, Accessibility framework; macOS 14+.

**Spec:** [design.md](design.md), Sequencing after critic.

## Global Constraints

- The user-provided screenshots contain local data and must not be checked into a public repo.
- Use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for Swift commands; do not change the system-selected developer directory.
- Do not replace `/Applications/WorkTempo.app` or restart another session. Run a debug executable from this worktree.
- Documentation is separate from source; the below-axis plot coordinate is not its spoken value. If a saved report has an unexpected negative value, the descriptor must report it without calling it positive.

## Review Focus

- A new timeline after refresh must update spoken point values; a descriptor cached with old values fails.
- A partial open day must have a date and true current value, not be announced as a closed day.
- An empty or single-point timeline must not crash or invent values; `DashboardSnapshot.chartTimeline` suppresses charts when fewer than two closed days exist.
- The source total remains code plus tests; docs is never included in its series.
- A user with VoiceOver must hear positive docs counts and an explanation of their visual placement.

---

### Task 1: Source chart descriptor

**Files:**
- Create: `macos/Sources/WorkTempoMenuBar/ChartAccessibility.swift` — the `SourceChartDescriptor` value and its data-to-descriptor mapping.
- Create: `macos/Tests/WorkTempoMenuBarTests/SourceChartDescriptorTests.swift` and update `macos/Package.swift` — import the executable target to test the descriptor's real series and update path.
- Modify: `macos/Sources/WorkTempoMenuBar/ChurnCharts.swift:44-114` — attach the descriptor and keep the chart's existing plot/hover.

**Interfaces:** `SourceChartDescriptor(timeline: ChartTimeline): AXChartDescriptorRepresentable`; `makeChartDescriptor() -> AXChartDescriptor`; `updateChartDescriptor(_:)`. Consume `ChartTimeline.labels`, `codeLoc`, `testLoc`, `docLoc` and `currentProgress`; produce distinct `Code`, `Tests`, and `Docs` series at the actual positive values. The source chart summary explains the docs band below zero and the partial current day. A categorical date x-axis uses the existing label strings; avoid an index axis announced without dates.

- **Step 1: Record red baseline.** In the running debug chart, inspect accessibility with VoiceOver or Accessibility Inspector: the current `.accessibilityLabel("Code, test, and documentation lines over time")` exposes no per-date source series. If system accessibility permission blocks inspection, record that explicitly and use a direct descriptor probe for the implementation check, not a fabricated VoiceOver pass.
- **Step 2: Test the descriptor mapping RED, then implement.** A `WorkTempoMenuBarTests` target can import the executable: tests expect dated Code/Tests/Docs series with positive Docs for a valid timeline and new values after `updateChartDescriptor`. Run them with the descriptor absent to prove RED. Use `AXCategoricalDataAxisDescriptor(title: "Day", categoryOrder: timeline.labels)` and `AXNumericDataAxisDescriptor(title: "Lines", range: Double(minimum)...Double(maximum), gridlinePositions: [], valueDescriptionProvider: { "\(Int($0)) lines" })`; build each series with `AXDataPoint(x: label, y: Double(value))`. Handle unexpected negative report values truthfully in the axis and summary rather than claiming every accepted report has positive counts. Summarize valid Docs as separate positive counts drawn below the visual baseline, and label an open day `To date` without repeating its date. Set the descriptor title `Lines over time`. In `updateChartDescriptor`, replace the descriptor's `summary`, `xAxis`, `yAxis`, and `series` from a freshly made descriptor; the default protocol implementation is a no-op. Run GREEN.
- **Step 3: Attach and compile.** Import `Accessibility`; add `.accessibilityChartDescriptor(SourceChartDescriptor(timeline: timeline))` to `SourceVolumeChart` without removing its `.accessibilityLabel` until the resulting tree is inspected. Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --package-path macos`; resolve actual SDK initializer signatures rather than assuming the standalone probe's spelling for every type.
- **Step 4: Verify behavior.** Run the debug build and inspect the real `AXAudiograph` payload in the app's accessibility tree: dated Code/Tests/Docs point values, positive Docs, the separation summary, and current partial day. Exercise descriptor replacement with a different timeline in the regression test; check a live scope change if accessible. Do not claim spoken VoiceOver behavior unless it was actually heard. If VoiceOver interprets the positive Docs series as physically above zero despite the summary, stop and switch to a separate positive Docs strip before expanding to the monthly chart; record the observation in this design doc.
- **Step 5: Regression and documentation.** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path macos` and release build. Update `docs/macos-app.md`'s interface/accessibility text with the actual verified behavior; do not claim VoiceOver tested if only descriptor construction was checked.
- **Step 6: Ship the pilot as its own reviewed PR.** Review, commit with truthful model attribution, push, run the independent review gate, address verified findings, and merge. The worktree branch is rebased onto the merged main before the second slice.

**Acceptance:** The existing chart stays visually unchanged; assistive navigation exposes dated source series with positive docs values and updates after data changes, or the pilot explicitly proves that the below-zero representation needs replacement before continuing.
