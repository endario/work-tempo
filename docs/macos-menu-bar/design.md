# SourceTempo macOS Menu-Bar Design

> Historical MVP design. The aggregate scope, metric, collection, and presentation decisions are superseded by [`../aggregate-momentum/design.md`](../aggregate-momentum/design.md).

## Purpose

SourceTempo's first native client turns the existing collector into an always-available view of source momentum across several independent Git workspaces. The menu-bar surface answers three questions without opening a terminal:

- How much authored source exists now?
- How much source changed over the latest 30 days?
- Is the latest 30-day pace higher or lower than the preceding 30 days?

Documentation remains visible but informational. It is excluded from the source LOC, churn, net-growth, and pace calculations.

## Scope

The local MVP includes:

- A native macOS menu-bar app with no Dock icon.
- A data-rich SwiftUI popover.
- Multiple independently configured Git workspace roots.
- Immediate rendering from the last successful report.
- Attended first collection plus background and manual refresh through the installed `source-tempo` CLI.
- Per-workspace selection with the last selection restored on launch.
- Current source LOC split into code and tests, documentation LOC, latest 30-day churn, latest 30-day net growth, and a relative pace gauge.
- A 60-day source-LOC trend and workspace status rows.
- Add/remove workspace controls and clear error states.
- A local unsigned `.app` build suitable for installation on the current Mac.

The MVP excludes:

- Repository comparison and component classification.
- Arbitrary productivity targets, streaks, scores, or notifications.
- A non-Git directory that implicitly discovers child repositories. A directory such as `~/projects` is represented by adding each Git root it contains.
- Bundled Python, signing, notarization, auto-update, launch at login, telemetry, accounts, and hosted storage.
- Cross-platform UI.

## Approaches Considered

### Native SwiftUI app invoking the existing CLI

This is the selected approach. `MenuBarExtra`, Swift Charts, native file selection, and platform storage produce the smallest macOS-native surface. The collector remains the single owner of Git traversal and metric definitions. The process boundary is the existing schema-versioned JSON report.

The immediate trade-off is a local dependency on an installed `source-tempo` executable. That dependency is explicit and diagnosable. Public distribution can later bundle the collector without changing the app's report contract.

### Python status-bar app

A Python UI would share a runtime with the collector and reduce process-launch plumbing. Packaging, native menu-bar behavior, Swift Charts quality, accessibility, and a future notarized distribution path would all be weaker. It also risks coupling UI responsiveness to collection work.

### Web or cross-platform shell

Tauri or Electron would create a plausible cross-platform path but add a second frontend toolchain and packaging surface before cross-platform support is required. A macOS-only product should use the platform's native menu-bar and lifecycle APIs first.

### Launch agent with a read-only menu app

A `launchd` agent could own scheduling and leave the app as a pure report reader. That reduces process-lifecycle code and keeps reports fresh while the app is closed, but it introduces a second installed component and a control path for manual refresh. The local MVP deliberately keeps collection in the app because the signed public product will need to own its bundled collector and diagnostics. The collector boundary keeps a future launch-agent implementation possible without changing report decoding.

### One configured aggregate collector root

One Git root could list every other workspace under `extra_repos`, producing a single deduplicated report. This would erase each workspace's tracked `.source-tempo.json` policy and make one arbitrary repository own the user's global workspace list. SourceTempo therefore keeps independent roots independent. The MVP does not sum them; users switch between workspaces.

## Architecture

The repository gains one Swift package with a testable core library and a thin app executable:

```text
macos/
  Package.swift
  Sources/
    SourceTempoCore/
      ReportDocument.swift
      MomentumSummary.swift
      Workspace.swift
      CollectorResolver.swift
      CollectorClient.swift
      RefreshCoordinator.swift
      WorkspaceStore.swift
      WorkspaceController.swift
      DashboardSnapshot.swift
    SourceTempoMenuBar/
      SourceTempoApp.swift
      AppModel.swift
      MenuBarLabel.swift
      DashboardView.swift
      TrendChart.swift
      PaceGauge.swift
      DebugPreview.swift
  Tests/
    SourceTempoCoreTests/
scripts/
  build-macos-app.sh
```

`SourceTempoCore` owns JSON decoding, momentum calculations, workspace persistence, executable discovery, process execution, and refresh coordination. Executable discovery and process execution are separate small types so a bundled public collector replaces resolution policy without rewriting the client. Clock and process-running protocols make scheduling, single-flight behavior, timeout, wake refresh, and staleness testable without importing SwiftUI. `SourceTempoMenuBar` owns application lifecycle and presentation.

`DebugPreview.swift` is compiled only in debug builds. It renders the same dashboard view in an ordinary window when `SOURCE_TEMPO_PREVIEW=1`, allowing deterministic screenshot and accessibility inspection without adding a window or Dock presence to the release app.

The executable uses `MenuBarExtra` with window style. `LSUIElement` in the packaged app's `Info.plist` suppresses its Dock icon. The Swift package remains dependency-free outside Apple frameworks.

## Workspace Model

Each workspace is identified by its canonical Git root; its display name is the root directory name. A versioned JSON envelope under `~/Library/Application Support/SourceTempo/workspaces.json` stores ordered roots and the selected root using atomic replacement. Reports are named with a digest of the canonical root. The report's `generatedAt` is the source of last-success timing.

The app accepts only individual Git roots. The same canonical root cannot be added twice. The collector remains responsible for that root's tracked configuration, submodules, and configured extra repositories. This preserves `.source-tempo.json` as the authoritative counting policy.

The app intentionally provides no cross-workspace total in the MVP. The collector report exposes checkout paths rather than stable repository identities and only exposes historical series at workspace level, so a correct overlap-aware aggregate cannot be constructed by the client. Adding stable repository identity to the report is a schema-additive collector enhancement for a later aggregate milestone.

## Collector Boundary

For the selected root the app invokes:

```text
source-tempo --root <root> --period day --days 61 --workers 2 --no-html --json <report-path>
```

The executable is resolved from an explicit override when supplied, then `~/.local/bin/source-tempo`, `/opt/homebrew/bin/source-tempo`, `/usr/local/bin/source-tempo`, and finally the inherited `PATH`. Fixed user-owned locations take precedence over an ambient GUI process path. The app never runs collection on the main actor.

Raw schema-versioned collector reports are stored under `~/Library/Application Support/SourceTempo/Reports/<workspace-id>.json`. On launch, the app decodes saved reports before scheduling refreshes. A failed refresh preserves the last successful report and attaches an error to the workspace. The popover renders its cached or empty state within 150 milliseconds and never waits for Git collection before becoming usable.

Only the selected workspace refreshes automatically. One collector process runs at a time, and a timer or wake event arriving during collection is dropped rather than queued. Adding a workspace starts an attended, cancellable first collection with visible progress, two workers, and no wall-clock timeout. Once a report exists, automatic refresh occurs on launch, once per hour, and after system wake when the last success is older than one hour. Routine refresh uses two workers and a two-minute timeout. Unattended timer and wake refreshes are skipped while macOS Low Power Mode is enabled; manual refresh remains available. Cancellation kills the collector process group and leaves the previous report untouched.

The app intentionally shares the collector's existing cache with terminal runs. Cache writes are atomic, so concurrent app and terminal collection cannot corrupt data; a last-writer race can discard newly warmed entries and cause later recomputation, but cannot change report values. The collector owns cache layout and macOS owns opportunistic cache eviction. App-owned workspace configuration and last-success reports remain in Application Support.

Collection performs local Git reads in the selected workspace on this schedule. The collector's `git log`, `git archive`, and repository-inspection commands do not intentionally invoke repository hooks or make network requests, although repository-local Git configuration still applies. The app shows the selected path, and removing a workspace stops its unattended collection without deleting source repositories.

### Measured workload

On the current Mac, an uncached run for 61 daily labels and 14 counted repositories computed 801 distinct snapshots in 199.08 seconds with four workers and reached 649 MB maximum RSS. A warm run using the shared collector cache and two workers completed in 16.33 seconds at 209 MB maximum RSS. These measurements set the MVP's conservative two-worker policy and two-minute routine-refresh timeout. The attended first run has no timeout because an interrupted cold run persists no partial cache progress.

## Metric Semantics

The menu-bar label shows the selected workspace's latest source LOC in compact notation, such as `1.18M`. A gauge symbol communicates pace direction without presenting churn as a context-free productivity number. The popover shows current and previous churn together; net growth remains secondary.

For the selected report:

- **Source LOC** is the latest `series.loc` value and excludes documentation.
- **Code LOC** and **Test LOC** are the latest values from `series.locByKind`.
- **Docs** is the latest `series.docLoc` value and is informational.
- **30-day churn** is the sum of the latest 30 completed daily source-churn values.
- **30-day net growth** is additions minus deletions across those completed days.
- **Previous churn** is the sum of the preceding 30 completed daily source-churn values.
- **Pace share** is `current / (current + previous)`. Equal non-zero periods render at 50%; above 50% means acceleration and below 50% means slowdown.

The collector returns 61 labels. The app drops the trailing label when it equals the date prefix of the report's own `generatedAt`, then takes the final 60 closed labels; cached reports use the same rule rather than the app's current date. Fewer than 60 closed labels is insufficient history. The gauge also shows **insufficient history** when source LOC is zero at the beginning of the previous window, and **new activity** rather than 100% when previous churn is zero. Two inactive periods show **no recent activity**. The chart omits leading zero-LOC days so young repositories do not render a false vertical cliff from an invented zero baseline.

The gauge always displays both absolute churn values beside the ratio. The MVP does not invent a minimum activity threshold: a small comparison remains mathematically valid but visually small, while zero-baseline and incomplete-history cases receive explicit non-ratio states.

This gauge compares recent work with the same workspace's preceding period. It does not define a productivity target and does not mix documentation churn into source momentum.

## Interface

The menu-bar item uses a restrained gauge symbol followed by compact source LOC, such as `1.18M`. While refreshing it keeps the last value and adds a subtle progress state. A stale report adds a small warning marker to the menu item instead of presenting old data as current.

The popover is approximately 430 points wide and organized as an unframed work surface:

1. Header with SourceTempo, selected scope, last refresh, refresh action, and add-workspace action.
2. A prominent pace gauge with current and previous 30-day churn.
3. A compact metric row for source LOC, code, tests, and informational docs.
4. A 60-day source-LOC chart with code and test areas.
5. Workspace rows showing name, current LOC, 30-day churn, and refresh/error state.
6. Footer actions for removing the selected workspace and quitting the app.

Color is semantic and restrained: blue for code, amber for tests, neutral gray for docs, green for positive net growth, and red only for errors or negative net growth. The interface uses system typography, SF Symbols, accessibility labels, and reduced-motion behavior inherited from macOS.

## Error Handling

Errors are scoped to the affected workspace:

- Missing CLI: show the searched locations and keep cached data visible.
- Missing directory and non-Git root: preflight these states before invoking the collector and keep the workspace available for correction or removal.
- Non-zero collector exit: treat the collector error as opaque, retain the previous report, and show the final diagnostic line.
- Unsupported report schema: retain the file, show an upgrade error, and do not interpret its metrics.
- Corrupt saved report or workspace file: isolate that file, start with the remaining valid state, and surface recovery copy.
- Timed-out routine refresh: terminate the process group, preserve cached data, and mark the workspace stale.

Process stdout and stderr are bounded in memory. The app does not display terminal output as a normal workflow.

## Testing

Core tests use XCTest with fixed schema-version-1 fixtures. They cover:

- Report decoding and unsupported schemas.
- Current/previous closed 30-day windows, net growth, neutral inactivity, new activity, young repositories, and uneven history.
- Workspace round-trip persistence and duplicate-root prevention.
- Collector argument construction, fixed-path-before-`PATH` discovery, path preflight, successful output, timeout, process-group termination, and non-zero exit diagnostics.
- Refresh scheduling, tick coalescing, one-at-a-time execution, selected-workspace behavior, wake refresh, and staleness.

App-level verification includes:

- `swift test` and release build.
- A `macos-latest` CI job for Swift tests and release compilation alongside the existing Python matrix.
- Packaging into a valid `SourceTempo.app` with `LSUIElement` enabled.
- Launching the app against the locally installed collector.
- Confirming cached startup, background refresh, workspace add/remove, menu-bar label, trend rendering, errors, and no Dock icon.
- Screenshot inspection at the actual rendered size for clipping, alignment, and empty states.

## Graduation Path

The local CLI process is a replaceable `CollectorClient` implementation. Public distribution can bundle a signed collector and select it through the same executable-resolution interface. A later Xcode project can add signing, notarization, Sparkle or App Store updates, launch-at-login support, and universal builds without changing report decoding or momentum semantics.

Cross-platform clients can consume the same JSON contract. The native macOS implementation remains useful rather than becoming throwaway scaffolding.

## Acceptance Criteria

- The app launches as a menu-bar-only process and opens a responsive popover before collection finishes.
- A user can add any number of Git roots independently.
- A workspace uses its active `.source-tempo.json` policy without app-owned path rules.
- Last successful data remains available through collector failures and app restarts.
- The 30-day gauge compares source churn with the preceding 30 days and excludes docs.
- Code, tests, docs, net growth, and the 60-day trend match the collector's JSON report.
- The selected workspace refreshes without queue multiplication, and first collection can be cancelled without orphaning workers.
- The unsigned local `.app` builds, launches, and can be copied into `/Applications` without modifying the Python collector.
