# App Settings (macOS menu-bar app)

Status: draft, pre-critic
Scope: `macos/Sources/WorkTempoCore`, `macos/Sources/WorkTempoMenuBar`

## Problem

Three timing values that shape what the app tracks and how often it refreshes
are hardcoded Swift constants, duplicated as independently-defaulted
parameters in several places, with no persistence and no UI:

| Value | Current | Where |
| --- | --- | --- |
| History window (collected + charted) | 184/185 days | `HistoryWindow.chartClosedDays`/`.collectorDays` (`PortfolioMomentum.swift`), consumed by `CollectorClient`, `DashboardSnapshot`, `PortfolioMomentum` |
| Headline rolling window | 30 days | Hardcoded in `MomentumSummary.swift:82`; duplicated as a UI fallback default in `DashboardSnapshot.swift:85,178` |
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
- Routine refresh timeout stays a hardcoded internal constant, but changes
  from 120s to 300s as a one-line drive-by fix in `RefreshCoordinator.swift`
  (unrelated to the settings mechanism; done in the same PR because the file
  is already touched).
- Per-workspace counting policy (`.work-tempo.json` / `.work-tempo.local.json`)
  is untouched — this is a separate, pre-existing config surface (collector
  counting rules, not app-level timing) and out of scope.

## Data model

```swift
public struct AppSettings: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var historyDays: Int          // default 184
    public var headlineWindowDays: Int   // default 30
    public var refreshCadenceSeconds: Int // default 3_600

    public static let `default` = AppSettings(
        schemaVersion: 1,
        historyDays: 184,
        headlineWindowDays: 30,
        refreshCadenceSeconds: 3_600
    )
}
```

`collectorDays` (the `--days` argument, one more than `historyDays` for the
open/current day) is derived, not stored.

**Invariant:** `headlineWindowDays <= historyDays`. Enforced at the UI layer
(the headline picker only offers options `<= historyDays`, and lowering
history auto-clamps a too-large headline selection) and defensively at
`AppSettings.load()` (an out-of-invariant value loaded from disk is clamped
to `historyDays`).

## UI

A native SwiftUI `Settings` scene (`WorkTempoApp` gains a second scene
alongside `MenuBarExtra`), opened via a gear-icon button added to
`DashboardView`'s header action row (beside refresh/add), calling the
`openSettings` environment action.

Three `Picker` rows, fixed presets (no free-text entry, so invalid values
can't be entered through the UI):

- **History**: 1 month (30d) / 3 months (90d) / 6 months (185d, default) / 12 months (365d)
- **Headline window**: 7d / 14d / 30d (default) / 60d / 90d, filtered to `<= historyDays`
- **Refresh cadence**: 15m / 30m / 1h (default) / 2h / 4h

Each row shows one line of help text (what it affects). A "Restore Defaults"
button resets all three to `AppSettings.default`.

## Persistence

New `SettingsStore`, mirroring `WorkspaceStore`'s existing pattern exactly:

- `~/Library/Application Support/WorkTempo/settings.json`
- Atomic write: temp file, `FileHandle.synchronize()`, `replaceItemAt`/`moveItem`
- `schemaVersion` field, currently `1`

Difference from `WorkspaceStore`: an unsupported `schemaVersion`, missing
file, or JSON decode failure all fall back to `AppSettings.default` rather
than throwing. Settings corruption must not block the app from launching;
`WorkspaceStore`'s throw-and-show-error-banner behavior is appropriate for
workspace state (losing workspace list, reports is user-visible data loss
worth surfacing) but not for a handful of timing knobs with sane defaults.

## Plumbing

`HistoryWindow`'s static enum (`PortfolioMomentum.swift`) is removed. Its
two values become properties derived from an `AppSettings` value threaded
explicitly as a parameter through the five call sites that currently read
the constants or redeclare a default:

- `CollectorClient.collect` / `CollectorRequest` — `--days` argument
- `RefreshCoordinator.init` — `staleInterval` and `requiredDayCount`, both
  now sourced from the one `AppSettings` value (collapsing the
  independently-defaulted `3_600` literals)
- `MomentumSummary.init` — replaces the hardcoded `30` in the rolling-window
  calculation
- `DashboardSnapshot`'s two initializers — replaces the `30`/`3_600`/`86_400`
  fallback defaults (86,400 stays a literal per Non-goals; the other two
  become settings-derived)
- `PortfolioMomentum.build` / `.chart(for:)` — replaces `HistoryWindow.chartClosedDays`

One `AppSettings` value passed down each call chain, not three scattered
`Int`/`TimeInterval` parameters — matches the existing pattern where the
Python collector's counting policy is "a `Config` built once per run... and
passed to the functions that count" (`architecture.md`).

`AppModel` owns the live `AppSettings`, loaded at `start()` alongside
workspace state.

## Apply behavior

On Settings save, `AppModel`:

1. Persists the new `AppSettings` via `SettingsStore`.
2. Cancels and restarts `timerTask` with the new cadence.
3. Reconstructs `RefreshCoordinator` with the new `staleInterval`/`requiredDayCount`.
4. Triggers an immediate `requestRefresh(.manual)` scoped to `.all`.

A grown history window makes every existing cached report's `dayCount` fall
short of the new `requiredDayCount`, which is already exactly the condition
`RefreshCoordinator.unattendedTarget` treats as "needs refresh" — no new
re-collection logic needed. A shrunk history window needs no special
handling: the collector and chart already slice to whatever window is
requested.

## Testing

- New `SettingsStoreTests`: round-trip, missing file → default, unsupported
  schema → default, corrupt JSON → default, invariant clamp on load.
- `AppSettings.default` regression test: asserts it reproduces today's exact
  values (184/185/30/3,600) — a behavior-preservation guard for the
  refactor, not just a data-shape check.
- Existing `RefreshCoordinatorTests`, `MomentumSummaryTests` (if present),
  `DashboardSnapshotTests`, `CollectorClientTests`, `PortfolioMomentumTests`
  audited for the new `AppSettings` parameter on each affected initializer.

## Open questions for critic

- Is threading one `AppSettings` value through five call sites the right
  shape, or should `RefreshCoordinator`/`CollectorClient` take narrower,
  purpose-specific values instead (avoids each call site depending on
  fields it doesn't use)?
- Is "clamp silently" the right failure mode for an out-of-invariant loaded
  settings file, or should it be surfaced (like `WorkspaceStore`'s schema
  error) even though it's not blocking?
