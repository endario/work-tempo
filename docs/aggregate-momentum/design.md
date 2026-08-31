# Aggregate Momentum Design

> Supersedes the no-aggregate boundary in `docs/macos-menu-bar/design.md`. This milestone adds the overlap guard and common-watermark rules required to make that deferred view correct. The owner-requested churn-rate headline also supersedes the MVP's LOC-first menu metric.

## Goal

Make SourceTempo open on an honest portfolio-wide view of every tracked Git workspace. The primary tracker becomes source churn per day over the trailing 30 closed days. The dashboard restores both LOC snapshot and churn analysis over 90 days. Individual workspace inspection remains available.

## Metric Contract

The headline metric is the arithmetic mean of source churn across the trailing 30 closed calendar days:

```text
daily churn = sum(source additions + source deletions for 30 closed days) / 30
```

Documentation churn and the current partial day remain excluded. Zero-filled days before a repository existed correctly represent no churn in that tracked project during the calendar window. It is displayed compactly as, for example, `8.4K / day` in the hero and `8.4K/d` in the menu bar.

The existing current-versus-previous 30-day comparison remains secondary. Its arc and comparison copy provide direction, while the central hero value is the daily churn average. Net source LOC remains supporting context.

## Scope Model

The app has two display scopes:

- **All Workspaces**: the default after installation and when migrating current persisted state.
- **One workspace**: selected explicitly from the picker or workspace list.

Workspace state remains schema version 1 and gains an optional `selectedScope` field. Its absence identifies state written by the current release and deliberately overrides the prior selection with All Workspaces once. New state writes either `all` or a workspace root, and continues writing `selectedRoot` alongside it.

In memory, selection is an explicit `DisplayScope` enum with `all` and `workspace(Workspace)` cases. An empty workspace list remains an independent state. Aggregate selection never overloads `nil` or invents a sentinel path.

Adding a workspace keeps the current scope. Removing is available only for an individual workspace, not the aggregate scope.

## Aggregation

One contributor cohort governs the entire screen: every tracked workspace with a valid report. Current totals, headline rate, pace, both charts, and the contributor caption all use exactly that cohort. Missing reports produce one explicit `N of M workspaces` partial state; no surface silently selects a different subset.

Before aggregation, the client intersects `scope.repositories[].path` across reports. If the same resolved repository path appears under two tracked workspaces, the portfolio view refuses to sum and names both workspaces and the collision. The current report schema cannot deduplicate historical workspace-level series, so refusal is the only correct behavior.

All contributors must also report the same timezone. A mismatch refuses aggregation until those workspaces are refreshed under the active system timezone; matching date strings from different day boundaries are not summed.

Every historical metric uses one watermark: the minimum latest closed label across the cohort. The headline uses the 30 labels ending at that watermark; pace uses the 60 labels ending there; charts use the 90 labels ending there. The collector retains 120 daily labels so reports collected on different days can still cover that shared 90-day grid.

If the complete cohort lacks 30 common closed labels, the rate is unavailable. If it lacks 60, the rate remains valid but pace comparison is building. If it lacks 90, both charts show one extending-history state rather than dropping contributors or rendering a smaller portfolio. Current totals remain available because they use the same named cohort's latest snapshots.

For each eligible chart label, aggregation sums:

- source LOC by language, with low-share languages grouped into Other only for presentation;
- informational docs LOC;
- code and test additions;
- code and test deletions;
- informational docs churn.

Language keys are unioned across reports and absence means zero. Colors use a fixed table for common languages plus a stable hash fallback for the tail, rather than input order, so adding a repository cannot recolor an existing language.

Collection freshness is evaluated per workspace and never from an aggregate timestamp. The aggregate header reports the oldest contributor timestamp for transparency, but only shows a stale warning when a contributor is more than 24 hours old. This remains meaningful while the one-at-a-time scheduler naturally leaves the oldest of several repositories a few hours behind.

## Collection And Refresh

Collector requests change from `--days 61` to `--days 120`; the presentation selects 90 common closed days.

An existing Adastra 61-to-120-day cache extension was measured locally at 2 minutes 12 seconds and expanded the cache from 708 to 1,147 snapshots. Short-history and first collections remain untimed, visible, and cancellable; already-complete reports retain the normal timeout.

Before relying on cancellation, the collector checkpoints its atomic cache after churn collection and after each snapshot progress batch, so a cancelled extension resumes instead of restarting from zero. The measured command was `python3 -m source_tempo --root /Users/endario/adastra --period day --days 120 --workers 2 --no-html` on this macOS host on 2026-08-31.

In All Workspaces mode:

- Launch, hourly, and wake refresh at most one missing, shorter-than-120-day, or oldest stale workspace.
- Manual refresh selects every tracked workspace and shows the active workspace plus `N of M` queue progress.
- Workspaces run sequentially through the existing one-collector-at-a-time boundary.
- Cancellation stops the active collector and skips the remaining queue.
- A quit or restart drops the remaining in-memory queue; launch later selects one pending workspace normally and never auto-resumes a full manual sweep.
- A failure is recorded on that workspace and collection continues with the next workspace.
- Existing successful reports remain visible throughout collection.

In individual mode, the same rules apply to the selected workspace only. Low Power Mode continues to suppress unattended refresh but not manual refresh. Scheduling decisions use each workspace report's own timestamp; aggregate display timestamps never feed the scheduler. Refreshing all workspaces also executes Git under each repository's local Git configuration, which is accepted existing collector behavior multiplied across the explicit queue.

## Presentation

The header picker and workspace list both expose All Workspaces. Aggregate selection is visually distinct and cannot be removed.

The hero keeps the circular pace treatment but changes its hierarchy:

1. Trailing 30-day source churn per day in the center.
2. `30-day moving average` as the main label.
3. Current 30-day source churn and change versus the previous 30 days as supporting copy.
4. Net source LOC as the final supporting line.

The menu-bar item uses the same daily churn average as its primary value. The four metric columns continue to show current source, code, tests, and docs totals. Workspace rows replace total 30-day churn with the same per-day rate.

The dashboard carries both original analytical views:

1. **LOC Snapshot** is an area chart stacked by language, with stable language colors and a matching breakdown legend. Documentation LOC is an informational dashed guide below the axis and is excluded from source totals and pace.
2. **Daily Churn** is a stacked bar chart with code added, test added, code deleted, and test deleted above the axis. Documentation churn is informational below the axis and excluded from the headline rate. A horizontal rule connects the headline average to the underlying bars.

An individual chart appends the current open day after the 90 closed-day window. An aggregate chart appends it only when every contributor has that same open label; otherwise it remains stable through the common closed-day watermark. The open day's LOC point uses elapsed-day positioning, and its churn bar keeps the full day-width slot while filling only the elapsed fraction; the unelapsed remainder is a neutral track. The current open day is visible in charts but excluded from headline and pace calculations.

The different decompositions are deliberate and inherited from the original report: LOC answers which languages exist, while churn answers whether code or tests were added or deleted. Both charts retain explicit legends, compact date ticks, accessible series descriptions, and chart-specific empty states. The 430-point popover has a maximum 760-point body with a fixed header/footer and a vertically scrolling dashboard; both charts remain present together. The requested 90 daily columns are measured at Retina pixel density before acceptance, without precommitting to another display mode.

## Error And Empty States

- No tracked workspaces: retain the add-workspace empty state and `--` menu value.
- Tracked workspaces with no reports: show All Workspaces collecting/empty state.
- Partial aggregate: show one concise missing or failed banner and the single cohort count used across the screen.
- Overlapping repository paths or mixed report timezones: refuse aggregation and name the conflict.
- Aggregate refresh in progress: preserve current totals and show the active workspace and queue position.
- Fewer than 30 common closed labels: show `Building 30-day history`; fewer than 60 keeps the rate but withholds pace; fewer than 90 keeps metrics but shows one extending-history chart state.

## Alternatives Considered

### Sum cached reports without aggregate refresh

Smallest code change, but the default total would quietly mix reports of different ages. Rejected because the main number would look authoritative without being maintained as one product surface.

### Build one combined collector report

The collector already supports multiple repositories and would produce one naturally aligned report. It is rejected because a combined invocation applies one root configuration to every repository, while SourceTempo deliberately keeps include and exclude policy with each tracked workspace. Recounting a repository under another workspace's policy would make the portfolio internally consistent but semantically wrong. Per-workspace reports remain the auditable source.

### Recommended: typed in-memory aggregation

Introduce one synthetic in-memory metric input used by both individual and aggregate reports. `MomentumSummary.init(report:)` adapts a report into that input; aggregation produces the same input on the common grid and never implements pace math in parallel. This keeps metric semantics deterministic and preserves each workspace's counting policy.

The shared-input extraction lands first as a no-behavior-change refactor with existing tests green. Scope, report decoding, collector retention, queueing, and presentation then build on that verified seam in independently testable commits.

## Verification

Core tests must prove:

- Legacy state without `selectedScope` migrates to All Workspaces; explicit aggregate and workspace scopes round-trip in schema version 1.
- Aggregate current totals, rate, pace, and charts use one identical contributor cohort and one named watermark.
- Repository path overlap and mixed-timezone reports refuse aggregation with actionable conflicts.
- Aggregate history uses the fixed 90-day common closed grid and never drops a contributor to satisfy history.
- Daily churn excludes docs and the current partial day, divides by 30, and becomes the menu value.
- Rate and pace align every contributor to one common through-date; pre-creation zeros remain valid calendar-day inactivity.
- Individual and aggregate snapshots share the same metric semantics.
- LOC aggregation preserves language values and docs separately; churn preserves code and test additions and deletions plus docs separately.
- New decoded series participate in report alignment validation; absent language keys aggregate as zero.
- Launch, hourly, and wake refresh at most one missing, short, or stale report; manual refresh queues all with visible progress.
- Aggregate refresh is sequential, continues after one failure, and cancels the remaining queue.
- Collector arguments and the Python-to-Swift contract retain 120 days while charts select 90.
- Cache checkpoints survive collector cancellation after churn and snapshot progress batches.
- The partial current day stays out of headline math while rendering at elapsed-day width or position in both charts.

Visual verification uses the real menu-bar popover at 430 points wide with aggregate, individual, refreshing, partial, and empty states. Ink extents are measured for the hero value, picker row, metric columns, both chart labels and legends, and workspace rows. Chart segments are checked at Retina pixels, and the body stays within the 760-point scroll budget. The installed release app must publish the same daily rate in its menu-bar item and retain `LSUIElement=true`.
