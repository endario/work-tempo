# App Settings (macOS menu-bar app)

Status: post-critic round 1, converging
Scope: `macos/Sources/WorkTempoCore`, `macos/Sources/WorkTempoMenuBar`

## Problem

Three timing values that shape what the app tracks and how often it refreshes
are hardcoded Swift constants, duplicated as independently-defaulted
parameters in several places, with no persistence and no UI:

| Value | Current | Where |
| --- | --- | --- |
| History window (collected + charted) | 184/185 days | `HistoryWindow.chartClosedDays`/`.collectorDays` (`PortfolioMomentum.swift`), consumed by `CollectorClient`, `DashboardSnapshot`, `PortfolioMomentum` |
| Headline rolling window | 30 days | Hardcoded in `MomentumSummary.swift:82`; duplicated as a UI fallback default in `DashboardSnapshot.swift:85,178`, **and as the aggregate gate/slice in `PortfolioMomentum.build` (`.swift:237,239`)** |
| Refresh cadence / staleness threshold | 3,600s | `AppModel`'s timer loop (poll interval); independently re-defaulted as `staleInterval` in `RefreshCoordinator.init` and in both `DashboardSnapshot` initializers |

The aggregate (All Workspaces) staleness threshold (86,400s, `DashboardSnapshot.swift:152`),
the routine-refresh timeout, and collector worker count are explicitly kept
out of scope — see Non-goals.

## Goals

- Let the user configure history window, headline window, and refresh
  cadence from a native Settings UI, without editing JSON by hand.
- Default values reproduce today's exact behavior — upgrading is a no-op
  until the user opens Settings.
- Unify refresh cadence and staleness threshold into one setting (they
  already shared a literal value; keeping them separately-defaulted was
  incidental, not intentional).

## Non-goals

- Aggregate (24h) staleness threshold stays a hardcoded internal constant,
  unaffected by this work.
- Collector worker count stays hardcoded (pure performance tuning, no
  user-visible meaning).
- Routine refresh timeout changes from 120s to 300s, but as its own
  standalone one-line PR — unrelated to the settings mechanism, and kept
  out of this feature's diff per the repo's own surgical-change convention
  (critic round 1 flagged bundling it as scope creep on the settings PR).
- Per-workspace counting policy (`.work-tempo.json` / `.work-tempo.local.json`)
  is untouched — this is a separate, pre-existing config surface (collector
  counting rules, not app-level timing) and out of scope.
- The young-repository perpetual-recollection behavior in
  `RefreshCoordinator.unattendedTarget` (see Known limitation below) is not
  fixed here.

## Data model

```swift
public struct AppSettings: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var historyDays: Int           // default 184
    public var headlineWindowDays: Int    // default 30
    public var refreshCadenceSeconds: Int // default 3_600

    public static let `default` = AppSettings(
        schemaVersion: 1,
        historyDays: 184,
        headlineWindowDays: 30,
        refreshCadenceSeconds: 3_600
    )
}
```

`historyDays: 184` matches `HistoryWindow.chartClosedDays` exactly (critic
round 1 caught a draft that mislabeled the History preset as "185d,
default" — 185 is `collectorDays`, one more than `historyDays` for the
open/current day; the preset label is fixed below to remove that
contradiction). `collectorDays` stays derived, never stored.

**Invariant:** `headlineWindowDays <= historyDays`. Enforced at the UI layer
(the headline picker only offers options `<= historyDays`, and lowering
history auto-clamps a too-large headline selection).

**Load-time validation (widened per critic round 1).** A hand-edited or
future-schema settings file can contain valid JSON with out-of-range values
that the UI could never produce — `refreshCadenceSeconds: 0` turns the
`AppModel` timer loop's `Task.sleep` into a hot loop hammering the
coordinator; `historyDays: 0` yields `collectorDays: 1` and a degenerate
chart. `AppSettings.load()` clamps **all three fields**, not just the
headline/history pair, to fixed bounds matching the preset ranges:
`historyDays` to `30...365`, `headlineWindowDays` to `7...historyDays`,
`refreshCadenceSeconds` to `900...14_400` (15m...4h). Clamping, not
rejecting, per the existing reasoning below (a state the UI cannot produce
doesn't need an error banner).

## UI

A native SwiftUI `Settings` scene (`WorkTempoApp` gains a second scene
alongside `MenuBarExtra`), opened via a gear-icon button added to
`DashboardView`'s header action row (beside refresh/add), calling the
`openSettings` environment action.

**Activation risk.** This app runs `LSUIElement` (no Dock icon, no regular
app menu). `AppModel.chooseWorkspace()` already calls
`NSApp.activate(ignoringOtherApps: true)` before presenting an
`NSOpenPanel` — existing evidence that windows raised from this app need
explicit activation to come to the front reliably in an accessory app. The
gear button's action does the same `NSApp.activate` call before
`openSettings`, and this gets a manual open/front/close verification pass
(not just a compile check) before the design is considered converged.

Three `Picker` rows, fixed presets (no free-text entry, so invalid values
can't be entered through the UI):

- **History**: 1 month (30d) / 3 months (90d) / **6 months (184d, default)** / 12 months (365d)
- **Headline window**: 7d / 14d / **30d (default)** / 60d / 90d, filtered to `<= historyDays`
- **Refresh cadence**: 15m / 30m / **1h (default)** / 2h / 4h

Each row shows one line of help text (what it affects). A "Restore Defaults"
button resets all three to `AppSettings.default`.

## Persistence

**Changed from round 1 (critic-recommended simplification):** `UserDefaults`
instead of a hand-rolled JSON file store. The round-1 draft mirrored
`WorkspaceStore`'s atomic-write-plus-temp-file pattern, but that pattern
earns its cost for `WorkspaceStore` because workspace state is substantial
data worth being human-inspectable on disk (the workspace list, selected
scope, alongside a `Reports/` directory of raw JSON). `AppSettings` is four
small integers with a platform primitive built for exactly this: atomicity,
corruption handling, and a standard test seam (`UserDefaults(suiteName:)`)
all come from the OS instead of ~80 lines of temp-file/replace-item code
and its own corruption-path tests.

`AppSettings` encodes to one `Data` blob under a single `UserDefaults` key
(`"AppSettings"`). Missing key, decode failure, or unsupported
`schemaVersion` all fall back to `AppSettings.default` — settings
corruption must not block the app from launching, unlike `WorkspaceStore`'s
throw-and-show-error-banner behavior (appropriate there because losing the
workspace list is user-visible data loss worth surfacing; not appropriate
here for a handful of timing knobs with sane defaults).

## Plumbing (narrowed per critic round 1)

The round-1 draft threaded one full `AppSettings` value through every
consumer, including pure computation code (`MomentumSummary`) that only
needs one field. Narrower shape:

- `HistoryWindow`'s static enum (`PortfolioMomentum.swift`) becomes a small
  instance value, `HistoryWindow(historyDays:)`, exposing `chartClosedDays`
  and `collectorDays` as before — call sites that only read those two
  values (`CollectorClient`/`CollectorRequest`, `PortfolioMomentum.build`,
  `.chart(for:)`) keep the same shape they read today, just instance-scoped
  instead of static.
- `MomentumSummary.init` takes a narrow `windowDays: Int` parameter,
  replacing the hardcoded `30` — it stays a pure computation with no
  dependency on `AppSettings` or persistence.
- **`PortfolioMomentum.build`'s two additional `30` literals**
  (`.swift:237,239` — the aggregate momentum slice and its
  `momentumLabels.count >= 30` gate) also become `windowDays`. Missed in
  round 1: without this, the headline-window setting would be cosmetic for
  the All Workspaces view — the slice and gate would stay fixed at 30
  regardless of what the user picked.
- `RefreshCoordinator.init` takes `staleInterval`/`requiredDayCount`
  directly (both now sourced from `AppSettings` at the `AppModel` call
  site, collapsing the independently-defaulted `3_600` literals into one
  value read once).
- `DashboardSnapshot`'s two initializers take `staleInterval` and
  `windowDays` parameters, replacing the `3_600`/`30` fallback defaults
  (86,400 stays a literal per Non-goals).
- `README.md`'s "up to thirty" description of the menu-bar headline metric
  needs the same update — tracked under Testing/doc-refresh below, not
  forgotten as a fourth silent consumer of the literal.

`AppSettings` itself (the full four-field struct) stays confined to
`AppModel`, the `UserDefaults` read/write, and the Settings scene — it does
not leak into `WorkTempoCore`'s pure computation types.

`AppModel` owns the live `AppSettings`, loaded at `start()` alongside
workspace state.

## Apply behavior

On Settings save, `AppModel`:

1. Persists the new `AppSettings` to `UserDefaults`.
2. Cancels and restarts `timerTask` with the new cadence.
3. Reconstructs `RefreshCoordinator` with the new `staleInterval`/`requiredDayCount`.
4. Triggers an immediate `requestRefresh(.manual)` scoped to `.all`.

A grown history window makes every existing cached report's `dayCount` fall
short of the new `requiredDayCount`, which is already exactly the condition
`RefreshCoordinator.unattendedTarget` treats as "needs refresh" — no new
re-collection logic needed. A shrunk history window needs no special
handling: the collector and chart already slice to whatever window is
requested.

**Edge case (named per critic round 1):** step 4 is silently dropped if a
refresh is already in flight (`AppModel.swift:131`, `refreshTask != nil`
guard). Saving settings mid-refresh delays the backfill until the next
timer tick rather than starting it immediately — acceptable, since the
`dayCount < requiredDayCount` condition keeps re-selecting the same
workspace on every subsequent tick until it's satisfied; the backfill isn't
lost, just deferred by up to one cadence interval.

## Known limitation (pre-existing, named not fixed)

`RefreshCoordinator.unattendedTarget` treats any workspace with
`dayCount < requiredDayCount` as needing refresh, with no timeout
(`RefreshCoordinator.swift:85`, `timeout: nil` on that branch). A workspace
whose Git history is younger than the configured window never reaches
`requiredDayCount` and is re-collected every cycle, indefinitely. This
already happens today for repositories younger than 186 days; offering a
365d history preset widens the affected population. Fixing this (the
collector would need to report its earliest available day, so "short"
means the requested window extends past actual history rather than merely
`count < required`) is out of scope for this design. The manual
verification pass (Testing, below) includes checking a young test
repository against the 365d preset to confirm the behavior is merely
wasteful, not broken.

## Testing

- New `AppSettingsTests`: `UserDefaults` round-trip (using a test suite
  name), missing key → default, corrupt/decode-failure → default,
  unsupported schema → default, clamp-on-load for all three fields
  (headline/history invariant and the three range bounds independently).
- `AppSettings.default` regression test: asserts it reproduces today's
  exact values (184/185/30/3,600) — a behavior-preservation guard for the
  refactor, not just a data-shape check.
- Existing `RefreshCoordinatorTests`, `DashboardSnapshotTests`,
  `CollectorClientTests`, `PortfolioMomentumTests` audited for the new
  parameters on each affected initializer; a `PortfolioMomentumTests` case
  specifically covers a non-default `headlineWindowDays` changing the
  aggregate gate/slice (the round-1 gap).
- Manual pass: gear button opens/fronts/closes the Settings window from the
  `LSUIElement` app (Activation risk, above); a young test workspace at the
  365d history preset behaves as described in Known limitation, not worse.
- `README.md`'s headline-metric description updated to match
  (doc-refresh, SOP S7).

## Resolved from round 1

- **Threading shape:** narrowed to instance-scoped `HistoryWindow` and a
  bare `windowDays: Int` on `MomentumSummary`, not a full `AppSettings`
  thread — see Plumbing.
- **Clamp silently vs. surface:** clamp silently confirmed correct — the
  invariant/range violation is only reachable by hand-editing state the
  Goals explicitly don't support through the UI; surfacing it would add an
  error-banner path for a state the UI cannot produce.
- **Persistence mechanism:** switched from a hand-rolled JSON file store to
  `UserDefaults` — see Persistence.
