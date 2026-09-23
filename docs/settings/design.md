# App Settings (macOS menu-bar app)

Status: post-critic round 3 (cap reached), converged — build
Scope: `macos/Sources/WorkTempoCore`, `macos/Sources/WorkTempoMenuBar`

## Problem

Three timing values that shape what the app tracks and how often it refreshes
are hardcoded Swift constants, duplicated as independently-defaulted
parameters in several places, with no persistence and no UI:

| Value | Current | Where |
| --- | --- | --- |
| History window (collected + charted) | 184/185 days | `HistoryWindow.chartClosedDays`/`.collectorDays` (`PortfolioMomentum.swift`), consumed by `CollectorClient`, `DashboardSnapshot`, `PortfolioMomentum` |
| Headline rolling window | 30 days | Hardcoded in `MomentumSummary.swift:82`; duplicated as a UI fallback default in `DashboardSnapshot.swift:85,178`, **and as the aggregate gate/slice in `PortfolioMomentum.build` (`.swift:237,239`)** |
| Refresh cadence / staleness threshold | 3,600s | `AppModel`'s timer loop (poll interval); independently re-defaulted as `staleInterval` in `RefreshCoordinator.init` |

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
- The deeper fix to young-repository recollection — the collector reporting
  its earliest available day, so "short" means the requested window
  extends past actual history rather than merely `dayCount < required` — is
  not attempted here (see Known limitation). This design does add a cheap
  frequency throttle on the existing behavior, since the fix is two lines
  using a value this design already threads through the same struct.

## Data model

```swift
public struct AppSettings: Codable, Equatable, Sendable {
    public var historyDays: Int           // default 184
    public var headlineWindowDays: Int    // default 30
    public var refreshCadenceSeconds: Int // default 3_600

    public static let `default` = AppSettings(
        historyDays: 184,
        headlineWindowDays: 30,
        refreshCadenceSeconds: 3_600
    )
}
```

No `schemaVersion` field (dropped after critic round 2 flagged it as
speculative on four fully-clamped integers): a future shape change is
already covered by "decode failure → default," and there is no second
schema to migrate between yet. `WorkspaceStore`'s `schemaVersion` earns its
keep because that file is substantial, human-inspected, evolving data;
`AppSettings` is three bounded integers where decode-failure-to-default
already is the versioning story.

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
`refreshCadenceSeconds` to `900...14_400` (15m...4h). Clamping order
matters (critic round 2): `historyDays` clamps first, then
`headlineWindowDays` clamps against that **already-clamped** `historyDays`
— clamping headline against the raw, unclamped value could produce an
empty range (e.g. a hand-edited `{historyDays: 0, headlineWindowDays: 90}`
would clamp headline to `7...0`). Clamping, not rejecting, per the existing
reasoning below (a state the UI cannot produce doesn't need an error
banner).

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

Each row shows one line of help text (what it affects). The refresh-cadence
row's help text reads "checks about every N" rather than promising an exact
interval (critic round 2, Beyond scope): `AppModel` also refreshes on
launch and on `NSWorkspace.didWakeNotification`, outside the timer
entirely, so actual frequency is cadence-plus-wake-events, not cadence
alone. A "Restore Defaults" button resets all three to `AppSettings.default`.

## Persistence

**Changed from round 1 (critic-recommended simplification):** `UserDefaults`
instead of a hand-rolled JSON file store. The round-1 draft mirrored
`WorkspaceStore`'s atomic-write-plus-temp-file pattern, but that pattern
earns its cost for `WorkspaceStore` because workspace state is substantial
data worth being human-inspectable on disk (the workspace list, selected
scope, alongside a `Reports/` directory of raw JSON). `AppSettings` is
three small integers with a platform primitive built for exactly this: atomicity,
corruption handling, and a standard test seam (`UserDefaults(suiteName:)`)
all come from the OS instead of ~80 lines of temp-file/replace-item code
and its own corruption-path tests.

`AppSettings` encodes to one `Data` blob under a single `UserDefaults` key
(`"AppSettings"`). A missing key or decode failure falls back to
`AppSettings.default` — settings corruption must not block the app from
launching, unlike `WorkspaceStore`'s throw-and-show-error-banner behavior
(appropriate there because losing the workspace list is user-visible data
loss worth surfacing; not appropriate here for a handful of timing knobs
with sane defaults).

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
- `MomentumSummary.init` takes a narrow `maxWindowDays: Int` **input**
  parameter, replacing the literal `30` inside the existing
  `max(0, closedEnd - 30)` cap calculation (`MomentumSummary.swift:82`).
  Named distinctly from the type's existing `public let windowDays: Int`
  **output** property (critic round 3): that property is already a
  *derived* value — `max(1, closedEnd - currentStart)`, bounded by
  `firstTrackedDay` so the window never starts before the workspace had any
  source or churn (`docs/macos-app.md:72`) — not a passthrough of the cap.
  Renaming the parameter to match the output property would have read as
  "assign the input onto the property," silently dropping that bound; the
  derivation itself is unchanged, only its literal `30` becomes
  `maxWindowDays`. Stays a pure computation with no dependency on
  `AppSettings` or persistence.
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
- **All three widened parameters above are required, with no default
  value** (critic round 2) — `staleInterval`, `requiredDayCount`,
  `maxWindowDays`/`windowDays` on the affected initializers take no
  `= 3_600`/`= 30` fallback. A default value would silently reintroduce the
  exact duplication this design exists to collapse at the next call site
  (a future test or caller that omits the argument); every call site,
  including tests, passes the value explicitly, and `AppSettings.default`
  becomes the single place today's numbers are pinned.
- `README.md`'s "up to thirty" description of the menu-bar headline metric,
  and `docs/macos-app.md`'s own pins on the same numbers (lines 47–59:
  `--days 185` and the hourly schedule; 88–92: the 30-label momentum gate
  and 184-day chart window; 111: the no-timeout rule) — both need the same
  update, tracked under Testing/doc-refresh below (critic round 3: the
  architecture doc is the fuller contract, `README.md` is its short copy).

`AppSettings` — the struct itself, its defaults, clamp-on-load, and the
`UserDefaults` read/write — lives in **`WorkTempoCore`**, beside
`WorkspaceStore` (critic round 3): `macos/Package.swift` only exposes a
`WorkTempoCoreTests` target, so code living in the `WorkTempoMenuBar`
executable isn't importable by tests. It stays confined there and in the
Settings scene — it does not leak into `WorkTempoCore`'s pure computation
types (`MomentumSummary`, `PortfolioMomentum`), which keep taking bare
`Int`s.

`AppModel` owns the live `AppSettings` as a stored property, loaded at
`start()` — see Launch binding, below.

## Launch binding (critic round 3, blocking)

Round 1 and round 2 only specified how settings apply on Settings *save*.
`AppModel.init` currently builds `coordinator` from a default
`RefreshCoordinator()` (its own constant defaults), and `start()` fires
`requestRefresh(.launch)` and starts a hardcoded-3,600s `timerTask` without
ever reading persisted settings. As specified through round 2, a value
saved in one session would sit unused until the user reopened Settings and
hit Save *again* in every subsequent session — persistence would exist but
never actually take effect on its own.

Fix: `AppModel` loads `AppSettings` (a synchronous `UserDefaults` read) and
stores it as a property before doing anything else. The default
`coordinator: RefreshCoordinator` parameter expression becomes
`RefreshCoordinator(settings: AppSettings.load())` (a small convenience
initializer deriving `staleInterval`/`requiredDayCount`), so the
production zero-argument `AppModel()` path is correctly configured from
first construction; tests keep injecting their own coordinator directly,
unaffected. `start()`'s `timerTask` reads the loaded `refreshCadenceSeconds`
for its sleep duration instead of the literal `3_600`.

## Apply behavior

On Settings save, `AppModel`:

1. Persists the new `AppSettings` to `UserDefaults` and updates the stored property.
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

**Concurrency note (critic round 3, follow-up):** `requestRefresh`'s task
body reads `coordinator` (an `AppModel` property) at two points — once to
call `.request(...)`, later to call `.finish()`. If step 3 reassigns
`self.coordinator` to a new actor while that task is between those two
points, `.finish()` would land on the *new* instance instead of the one
`.request()` was actually called against. Harmless in isolation (both
calls are idempotent, and the orphaned old instance is simply
unreferenced), but the in-flight task captures its coordinator as a local
`let` at the top of its body instead of re-reading the property, so the
race can't happen at all rather than relying on it being harmless.

## Known limitation, mitigated not fixed

`RefreshCoordinator.unattendedTarget`'s short-history branch
(`RefreshCoordinator.swift:101-103`) selects any workspace with
`dayCount < requiredDayCount` **unconditionally** — it never consults
`staleInterval`, unlike the stale branch immediately below it. A workspace
whose Git history is younger than the configured window never reaches
`requiredDayCount`, so today it's re-collected on every timer tick,
indefinitely, for repos younger than 186 days. Wider history presets (up to
365d) and a lower cadence floor (15m vs. the current fixed 1h) would
otherwise widen the affected population and, naively, the frequency too
(critic round 2, Strongest objection).

**Round-2 mitigation was ineffective (critic round 3 correction):** gating
the short branch on `now.timeIntervalSince(generatedAt) >= staleInterval`
does not throttle anything, because the timer already ticks exactly once
per `staleInterval` (they're the same value by construction) — the gate is
satisfied by the time the next tick arrives regardless, so "at most once
per `staleInterval`" and "on every tick" describe the identical schedule.
A 15-minute cadence would still fully recollect a permanently-short repo
roughly every 15 minutes, on the no-timeout path.

**Corrected mitigation, in scope:** the short branch requires
`now.timeIntervalSince(generatedAt) >= max(staleInterval, 3_600)` — floored
at today's fixed hourly rate regardless of the configured cadence. A
healthy repo still benefits from a 15-minute cadence on its bounded,
120-second-timeout path; a repo that can never fill the window is capped at
today's frequency no matter how low cadence is set. This decouples the
unbounded-collect branch from the cadence knob entirely, which is the
actual goal (not "throttle by the same number that's already the tick
rate"). **The fix also has to exclude short targets from the stale branch
immediately below it** (found while writing the implementation plan, after
this round closed): that branch's own `healthy.filter` runs over every
healthy target regardless of `dayCount`, so a short-but-old-enough-by-
`staleInterval`-alone workspace would still be re-selected through it,
bypassing the floor — `request()`'s timeout choice keys off
`dayCount < requiredDayCount` independent of which branch made the
selection, so that path still produces an unbounded collect. Three lines,
not two; see `docs/settings/plan.md`, Task 13, for the exact diff and a
test that fails against the two-line version to prove it. **This lands in
PR 2 only** (see Implementation sequencing) — it's an observable behavior
change (a short workspace refreshed via `.wake` or `.manual` shortly after
a prior short collection is no longer immediately re-selected), so it
doesn't belong in the no-op refactor PR even though the floor happens to
equal PR 1's literal value.

**Deferred, out of scope:** the collector reporting its earliest available
day, so "short" means the requested window extends past actual history
rather than merely `dayCount < required`, would stop the recollection
entirely instead of just capping its rate. Left for a future change. The
manual verification pass (Testing, below) includes checking a young test
repository against the 365d preset to confirm the capped behavior is
merely wasteful, not broken.

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
  aggregate gate/slice (the round-1 gap), and a `RefreshCoordinatorTests`
  case covers a short-history workspace recollected once, then not
  re-selected again before `staleInterval` elapses (the round-2 throttle).
- Manual pass: gear button opens/fronts/closes the Settings window from the
  `LSUIElement` app (Activation risk, above) — done **first** in PR 2,
  before the form is filled in, since it's the one mechanism in this
  design nobody has executed; a young test workspace at the 365d history
  preset behaves as described in Known limitation, not worse.
- `README.md`'s headline-metric description and `docs/macos-app.md`'s
  pinned numbers (days, schedule, gate, timeout) updated to match
  (doc-refresh, SOP S7).
- A hand-edited, in-range value that matches no preset (e.g.
  `historyDays: 100`) passes the clamp but selects no `Picker` option
  (critic round 3, follow-up). Accepted as-is: the UI can never write such
  a value, and adding a snap-to-nearest-preset rule for a state only a
  hand-edited file can reach is exactly the speculative handling this
  design otherwise avoids.

## Implementation sequencing

Two self-contained PRs, in order (critic round 2, sequencing corrected
round 3):

1. **Behavior-preservation refactor, no settings surface, no behavior
   change**: instance-scoped `HistoryWindow`, required (non-defaulted)
   `maxWindowDays`/`staleInterval`/`requiredDayCount` parameters, the
   `PortfolioMomentum.build` gate/slice fix, and the `README.md`/
   `docs/macos-app.md` updates — all exercised with today's exact literal
   values, guarded by the `AppSettings.default`-values regression test.
   Independently verifiable as a true behavioral no-op; de-risks the
   largest diff before any UI or persistence exists. The
   `unattendedTarget` throttle is **not** in this PR (critic round 3: it
   changes observable behavior on `.wake`/`.manual` triggers even at
   today's cadence value, so bundling it here would make the "no-op"
   claim false).
2. **`AppSettings` (in `WorkTempoCore`) + `UserDefaults` + launch binding +
   Settings scene + apply behavior + the `unattendedTarget` floor**, on top
   of plumbing that already accepts the values. Starts by verifying the
   `openSettings`/`NSApp.activate` mechanism opens, fronts, and closes the
   window from a running `LSUIElement` build before writing the rest of
   the form.

This isolates every actual behavior change — new defaults a user picks,
the recollection floor — to PR 2, where it's attributable to the feature
rather than hidden inside a refactor.

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

## Resolved from round 2

- **Young-repo recollection amplification:** a throttle was proposed on
  `unattendedTarget`'s short branch — but round 3 found the specific gate
  (`>= staleInterval`) had no actual effect, since the timer ticks at
  exactly that interval already. Corrected in round 3 — see Known
  limitation.
- **Defaulted parameters silently reintroducing drift:** all widened
  parameters are required, not defaulted — see Plumbing.
- **Clamp ordering:** `historyDays` clamps before `headlineWindowDays`
  clamps against it — see Data model.
- **`schemaVersion`:** dropped; decode-failure-to-default already covers
  the concern for three bounded integers — see Data model.
- **Reconstruct-on-save vs. a live settings provider:** reconstruct-on-save
  confirmed as the considered choice (Apply behavior) — a closure-based
  provider would spread settings reads across every timer tick to save one
  struct rebuild per save; explicitly not adopted.

## Resolved from round 3 (final round — cap reached, verdict: build)

- **Ineffective throttle:** floored at `max(staleInterval, 3_600)` instead
  of `staleInterval` alone, decoupling the unbounded short-history path
  from the cadence knob — see Known limitation. Moved to PR 2, since it's
  a real behavior change, not a no-op.
- **Settings never bound at launch:** `AppModel` now loads `AppSettings`
  before constructing its default `coordinator` and before `start()`'s
  timer/launch-refresh — see Launch binding. Without this, persistence
  would exist but never take effect on its own across a relaunch.
- **`MomentumSummary` parameter/property naming collision:** the new input
  is `maxWindowDays`, distinct from the existing derived output property
  `windowDays`, preserving the `firstTrackedDay` bound — see Plumbing.
- **`AppSettings` module placement:** lives in `WorkTempoCore` (the only
  test-importable target), not `WorkTempoMenuBar` — see Plumbing.
- **Doc-refresh scope:** `docs/macos-app.md`'s pinned numbers, not just
  `README.md`'s — see Plumbing, Testing.
- **Coordinator reassignment race:** the in-flight refresh task captures
  its coordinator as a local at task start instead of re-reading the
  property — see Apply behavior, concurrency note.
- **Leftover round-2 field-count references** ("four integers"/"four-field
  struct") corrected to three throughout.
