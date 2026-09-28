# macOS Menu-Bar App

A native menu-bar client for the collector, showing source momentum across several independent Git workspaces. The collector owns Git traversal and metric definitions; the app invokes the installed `work-tempo` CLI and reads its schema-versioned JSON. See [architecture.md](architecture.md) for the collector.

Requirements: macOS 14+, Apple Silicon, Swift 6, and a `work-tempo` executable. Build and install steps are in the [README](../README.md).

## Design choices

- **Native SwiftUI over the existing CLI**, rather than a Python status-bar app or a Tauri/Electron shell. `MenuBarExtra`, Swift Charts, native file selection, and platform storage give the smallest native surface, and the report JSON is the only contract between the two halves. The cost is a dependency on an installed `work-tempo`, which the app diagnoses explicitly.
- **Collection runs inside the app**, not in a separate `launchd` agent. A second installed component and a refresh control path aren't worth it yet; the collector boundary keeps that option open.
- **Per-workspace reports, aggregated in memory**, rather than one combined collector invocation. A combined run applies one root's counting policy to every repository, so it would erase each workspace's own `.work-tempo.json`. Per-workspace reports stay the auditable source.
- **Individual Git roots only.** A parent directory of checkouts is represented by adding each Git root. The collector remains responsible for each root's configuration, submodules, and extra repositories.

## Structure

```text
macos/Sources/
  WorkTempoCore/        pure logic, no SwiftUI or AppKit
    ReportDocument        schema-version-1 report decoding
    MomentumSummary       headline math for one report (MomentumInput)
    PortfolioMomentum     aggregation across workspaces, chart timeline
    Workspace, WorkspaceStore, WorkspaceController   scope, persistence, orchestration
    CollectorResolver, CollectorClient               find and run the CLI
    RefreshCoordinator    scheduling policy
    DashboardSnapshot     view-ready state
  WorkTempoMenuBar/     app lifecycle and presentation
    AppModel, DashboardView, MomentumHero, ChurnCharts, MenuBarLabel, DebugPreview
```

Executable discovery and process execution are separate types so a bundled collector only replaces resolution policy. Clock and process abstractions make scheduling, single-flight behavior, timeouts, wake refresh, and staleness testable without SwiftUI. The Swift package depends only on Apple frameworks.

`DebugPreview` is compiled only in debug builds. With `WORK_TEMPO_PREVIEW=1` it renders the dashboard in an ordinary window for deterministic screenshots.

## Workspaces and state

A workspace is identified by its canonical Git root, and the same root cannot be added twice. Its display name is the root directory name. State lives under `~/Library/Application Support/WorkTempo/`:

- `workspaces.json`: schema version 1, ordered roots, the selected scope (`selectedScope`: `all` or a root path), and `selectedRoot` for older readers. Written atomically. State without `selectedScope` opens on All Workspaces.
- `Reports/<digest of root>.json`: the last successful raw report for each workspace.

In memory the scope is a `DisplayScope` enum, `all` or `workspace(Workspace)`. Removing a workspace never touches its repository, and All Workspaces cannot be removed.

## Collection

For a workspace the app runs:

```text
work-tempo --root <root> --period day --days 366 --workers 2 --no-html --json <report-path>
```

`--days` is `historyDays + 1` from the user's configured history window (default 365, so 366), not a fixed constant.

The executable is looked up in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, then the inherited `PATH`; fixed user locations win over an ambient GUI `PATH`. Collection never runs on the main actor, and stdout/stderr are bounded in memory.

366 daily labels cover twelve calendar months (at most 365 closed days plus the open day) at the default history window; the actual count follows the configured History setting, even when workspaces were last collected on different days.

**Scheduling.**
- One collector process runs at a time. A launch, timer, or wake trigger arriving during a run is dropped, not queued.
- Unattended triggers (launch, timer, system wake) refresh one workspace per trigger: first any with no report, then any with too little history, then the stalest one older than the refresh cadence (default 1 hour, configurable in Settings), then ones whose last attempt failed. Unattended refresh is skipped in Low Power Mode. Manual refresh is always available.
- Manual refresh in All Workspaces runs every tracked workspace sequentially, showing the active workspace and `N of M` progress. A failure is recorded on that workspace and the sweep continues. Cancelling stops the active collector and drops the rest of the queue. A restart also drops it and never resumes a manual sweep on its own.
- A first collection (no report, or too little history) is attended, cancellable, and has no timeout. Routine refreshes time out after 300 seconds. Cancellation and timeout kill the collector's process group and leave the previous report untouched.

**Cache sharing.** The app shares the collector's cache with terminal runs. Writes are atomic, so concurrent runs cannot corrupt it; a last-writer race can only discard warmed entries and cause recomputation, never change values. The collector checkpoints its cache after churn and cutoff lookup, and after each snapshot batch, so an interrupted first run resumes instead of restarting. Cache schema 5 starts cold once after the upgrade.

**What collection touches.** For each counted repository, the collector best-effort fetches `origin/main` from its configured `origin` (up to four concurrent attempts, 8-second per-repo and 45-second per-workspace limits), updating the remote-tracking ref but not the checked-out branch or worktree. It then reads Git history locally at the captured ref. A failed fetch uses the last-fetched ref; if none exists, the report is not replaced. Fetch outcomes are stored with each repository in the report, and fallback is shown in the existing notice banner.

## Metrics

**Headline: source churn per day.**

```text
daily churn = (source additions + source deletions over the window) / days in window
```

The window is the trailing closed days — 30 by default, configurable in Settings and never more than the configured history window — starting no earlier than the first day the workspace had source or churn. Documentation churn and the current partial day are excluded. The second hero metric is net source LOC growth (additions minus deletions) over the same window. Both show their definitions in a tooltip.

The menu-bar item shows the same daily churn, compact, with a `/d` suffix (for example `12.3K/d`). It shows `--` before any report exists, a spinner glyph while refreshing, and a warning marker when data is stale or a refresh failed.

The composition summary shows the latest source LOC with its code and test components; documentation LOC is separate.

## Aggregation

All Workspaces sums per-workspace reports on a shared grid. One cohort governs the whole screen: every tracked workspace with a valid report. Totals, headline rate, and both charts use exactly that cohort; when some reports are missing the header says `N of M workspaces` rather than silently using a different subset.

Two guards refuse to sum rather than produce a wrong number:

- **Overlap.** If the same resolved repository path appears in two workspaces' `scope.repositories`, aggregation is refused and both workspaces and the path are named. Reports carry workspace-level series, so shared history cannot be deduplicated after the fact.
- **Timezone.** All contributors must have been collected under the same timezone; matching date strings from different day boundaries are never summed.

**Common watermark.** Every historical metric uses the minimum latest closed label across the cohort. The headline uses up to 30 labels ending there; charts use the trailing 365 closed labels, plus the open day only when every contributor has it. If the cohort lacks 30 common closed labels, the rate is unavailable; if it lacks the full chart window, the charts show the common history that exists. Contributors are never dropped to satisfy history.

**Summed series.** Source LOC (code and tests), documentation LOC, code and test additions and deletions, and documentation churn.

**Freshness** is judged per workspace. The aggregate header shows the oldest contributor's timestamp and warns only when a contributor is over 24 hours old, since one-at-a-time scheduling naturally leaves one workspace hours behind. A single-workspace view warns after one hour.

Individual and aggregate views share one metric input (`MomentumInput`); aggregation produces that same input on the common grid, so headline math is implemented once.

## Interface

A 430-point popover keeps its header and footer fixed. The middle grows to fit its content up to the display's visible height with room for those controls; on shorter screens, the middle scrolls.

1. Header: scope menu (All Workspaces and each workspace), last refresh, refresh, Settings, and add-workspace. Long workspace names truncate in the header and remain available in the menu and tooltip.
2. Hero: labeled source churn per day and net source LOC change over the same closed-day window, each with a sparkline. Net change uses neutral ink because growth is not a quality verdict. The open day appears as a faded trailing segment marked to-date.
3. Composition: latest source LOC alongside its code and test components; documentation LOC is identified as separate.
4. **Source lines over time** chart: day-end code and test lines stacked above the axis, documentation below it under a dashed guide. Documentation uses the lower half to separate it from source, not as a negative source count. The chart stacks by kind, not language, because reports carry no per-language series.
5. **Monthly activity** chart: additions and removals by kind and calendar month, with the current month occupying only its elapsed fraction. A compact `+`/`-` legend names the kind; visible copy maps those signs to added and removed counts. The bars are not net growth.
6. Footer: remove the selected workspace, quit.

Both charts and the sparklines respond to the pointer with a readout. Where a readout shows churn it gives the total first, then the additions and removals it is made of. Chart accessibility descriptors expose dated code, test, and separate documentation values. Hue names the kind and lightness names the direction; the labels remain in text ink. The Dock icon is suppressed with `LSUIElement`.

## Settings

A native Settings window (gear icon in the popover header) configures
three values, persisted via `UserDefaults`:

- **History** — how far back the collector fetches and the charts
  display. Default 12 months (365 days).
- **Headline window** — the rolling window behind the churn/day and net
  growth hero metrics. Default 30 days, never more than the configured
  history window.
- **Refresh cadence** — how often the app checks for background
  refreshes, and how old a report can get before it's flagged stale in
  a single-workspace view. Default 1 hour. All Workspaces keeps a
  fixed 24-hour staleness threshold regardless of cadence. The app
  also refreshes on launch and when the Mac wakes, independent of this
  cadence.

Any Save that changes a setting triggers an immediate refresh across
every tracked workspace.

## Errors and empty states

Errors are scoped to the affected workspace and never discard the last good report.

| Situation | Behavior |
| --- | --- |
| No tracked workspaces | Add-workspace empty state, `--` in the menu bar |
| Tracked but no reports | Collecting state |
| Some reports missing or failed | One banner with the `N of M` cohort count |
| Overlapping repositories, mixed timezones | Aggregation refused; the conflict is named |
| Fewer than 30 common closed labels | Headline unavailable; charts show what exists |
| CLI not found | Lists the searched locations; cached data stays visible |
| Directory missing or not a Git root | Detected before invoking the collector; workspace stays for correction or removal |
| Collector exits non-zero or a counted repository lacks `origin/main` | Previous report kept; the final sanitized diagnostic line is shown |
| Fetch fails but a last-fetched `origin/main` exists | Report uses that ref; individual and aggregate notices identify the fallback |
| Unsupported report schema | File retained, upgrade error shown, metrics not interpreted |
| Corrupt state or report file | File isolated; remaining valid state loads |
| Routine refresh timeout | Process group killed, workspace marked stale |

## Testing

`swift test` in `macos/` runs XCTest against fixed schema-version-1 fixtures, covering report decoding, momentum windows (young repositories, uneven history, inactivity), aggregation rules (overlap, timezones, watermark, cohort consistency), persistence and scope migration, collector arguments and discovery, process timeout and termination, and refresh scheduling. A contract test checks that the collector's real JSON output decodes and retains 185 daily labels. CI runs the tests and a release build on `macos-latest`.

Visual changes are checked in the real popover at 430 points, with aggregate, individual, refreshing, partial, and empty states, measuring ink extents rather than trusting layout numbers.

## Distribution

The app is a local, ad-hoc-signed build. The local CLI process is one `CollectorClient` implementation; a signed bundled collector, notarization, auto-update, launch at login, and universal builds can be added through the same resolution interface without changing report decoding or metric semantics. Other clients can consume the same JSON contract.
