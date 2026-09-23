# Work Tempo

Work Tempo tracks source-code momentum across a Git workspace and its related repositories. It produces terminal summaries, a self-contained HTML report, and optional schema-versioned JSON for other local tools.

It measures:

- Source and test LOC snapshots over time.
- Added plus deleted source churn by month or day.
- Language composition and per-repository contribution.
- Documentation LOC and churn as separate informational metrics.


The optional native macOS menu-bar app opens on an aggregate of all tracked workspaces. Its menu-bar value and primary dashboard metric show source churn per day over the trailing closed days — 30 by default, configurable in Settings. An individual workspace remains selectable from the header.

Repository comparison and component classification are outside Work Tempo's scope.

## Requirements

- Python 3.10 or newer.
- Git 2.30 or newer.

Work Tempo has no Python runtime dependencies outside the standard library.

## Install

```bash
pipx install work-tempo   # or: pip install work-tempo
```

For local development:

```bash
git clone https://github.com/endario/work-tempo.git
cd work-tempo
python3 -m venv .venv
.venv/bin/pip install -e .
```

Then run it from any Git repository:

```bash
work-tempo
```

The current directory is the default workspace. Analyze another checkout with:

```bash
work-tempo --root ~/projects/my-app
```

Without installation, use:

```bash
PYTHONPATH=src python3 -m work_tempo --root ~/projects/my-app
```

## Reports

The default report covers the latest 18 monthly periods and writes HTML under the workspace-specific user cache directory. The exact path is printed after each run.

```bash
# Monthly history with explicit outputs
work-tempo --root ~/projects/my-app \
  --html /tmp/work-tempo.html \
  --json /tmp/work-tempo.json

# Daily view for the latest 30 days
work-tempo --root ~/projects/my-app --period day --days 30

# Terminal and JSON only
work-tempo --root ~/projects/my-app --no-html --json /tmp/work-tempo.json

# Optional three-month LOC forecast using the last six completed months
work-tempo --root ~/projects/my-app --forecast
```

Period boundaries use the active system timezone, falling back to UTC. The resolved timezone is included in JSON and HTML report metadata.

## Workspace Scope

Work Tempo always considers the parent Git repository. It also discovers usable initialized submodules declared in `.gitmodules` and can aggregate additional repositories configured outside the workspace.

Create a personal configuration:

```bash
work-tempo --root ~/projects/my-app --init-config
```

This writes `~/projects/my-app/.work-tempo.local.json`, which should remain untracked. For shared workspace policy, generate or maintain `~/projects/my-app/.work-tempo.json` instead.

Configuration layers are applied in this order:

1. Built-in generic defaults.
2. Tracked `.work-tempo.json`.
3. Untracked `.work-tempo.local.json`, or the file passed with `--config`.

Later keys replace earlier keys. Arrays replace rather than append. Each file is validated on its own before merging: an unknown key, a wrong type, or an unsupported `schema_version` is an error that names the key and file, so a typo cannot silently change the numbers.

Config files declare `"schema_version": 1` or `2` (missing means 1). `test_file_markers`, the filename infixes that mark a test file, needs version 2; `--init-config` writes version 2. A version-2 file is rejected by older releases instead of being miscounted. Existing caches are recomputed once after upgrading. Run `work-tempo --init-config` to write every supported field with its default, or read [src/work_tempo/defaults.json](src/work_tempo/defaults.json).

Additional repositories use paths relative to the main checkout:

```json
{
  "schema_version": 1,
  "extra_repos": [
    {
      "label": "client-app",
      "path": "../client-app"
    },
    {
      "label": "shared-sdk",
      "path": "packages/shared-sdk"
    }
  ]
}
```

Only actual Git repository roots are counted. Missing or uninitialized configured repositories are reported and skipped.

## Counting Model

LOC snapshots count newline-delimited tracked source files from the last commit available at each period cutoff. Source and tests are separated using conventional test directories and test/spec/e2e filename patterns.

Churn is added plus deleted lines from non-merge commits, grouped by author date and filtered through the same current counting policy. Blank lines and comments count because WorkTempo measures physical source lines rather than semantic SLOC.

Generated, minified, dependency, build, cache, scratch, and vendor-like paths are excluded by default. Documentation is counted separately and does not contribute to source LOC, growth, or churn metrics.

## Cache

On macOS, artifacts default to:

```text
~/Library/Caches/WorkTempo/<workspace-name>-<workspace-key>/
```

Linux uses `$XDG_CACHE_HOME/work-tempo` or `~/.cache/work-tempo`. Set `WORK_TEMPO_CACHE_HOME` to override the root.

```bash
# Rebuild the workspace cache
work-tempo --clear-cache

# Run without reading or writing a cache
work-tempo --no-cache

# Use an explicit cache file
work-tempo --cache /tmp/work-tempo-cache.json
```

Snapshot cache entries include the commit and effective counting policy. Churn entries also include period kind and timezone. Rewritten history triggers a full churn rescan.

## JSON Compatibility

Reports currently use schema version 1. Additive fields may be introduced within version 1, and consumers must ignore unknown fields. Removing a field, changing its type or meaning, or changing period-series alignment requires a schema-version increment.

## Development

```bash
PYTHONPATH=src python3 -m unittest discover -s tests -v
python3 -m compileall -q src tests
```

### macOS menu-bar app

The local app requires macOS 14 or newer on Apple Silicon, Swift 6, and an installed `work-tempo` CLI. It resolves the collector from `~/.local/bin`, Homebrew locations, and then `PATH`.

Build an ad-hoc signed app bundle:

```bash
scripts/build-macos-app.sh
open dist/WorkTempo.app
```

Install the local build in `/Applications`:

```bash
scripts/build-macos-app.sh --install
open /Applications/WorkTempo.app
```

Use the plus button to add individual Git repository roots. Each workspace keeps its own `.work-tempo.json` and `.work-tempo.local.json` counting policy. The default All Workspaces scope rejects overlapping reports and mixed timezones. Historical metrics share a common closed-day watermark, while current totals use each contributing report's latest snapshot. Both charts keep code and test activity above the axis and informational documentation below it.

The app renders saved reports immediately. Collection is sequential, skips unattended work in Low Power Mode, uses two workers, and checkpoints the collector cache so an interrupted history extension can resume.

App state and saved reports live under:

```text
~/Library/Application Support/WorkTempo/
```

The collector's existing cache remains under `~/Library/Caches/WorkTempo/`, shared with terminal runs. Removing a workspace from the app does not alter its source repository. To uninstall, quit WorkTempo and remove `/Applications/WorkTempo.app`; remove the Application Support directory separately only when its saved workspace list and reports are no longer wanted.

Swift development checks:

```bash
cd macos
swift test
swift build -c release
```

## Design docs

- [Architecture](docs/architecture.md): the collector, configuration, counting model, and cache.
- [macOS app](docs/macos-app.md): scheduling, aggregation, and metric definitions.

## Releasing

Bump `version` in `pyproject.toml` in a pull request and merge it, then tag the merge commit `vX.Y.Z` and push the tag. The Publish workflow builds the package and uploads it to PyPI by trusted publishing, with no stored token.

## Contributing

`main` takes changes only through a pull request that passes the tests and the identity check. Every commit is authored and committed under `5214595+ren-diao@users.noreply.github.com` (or a bot's noreply address); an AI model may be credited with a `Co-authored-by` trailer. Turn the same check on locally with `git config core.hooksPath .githooks`.

## Authors

Ren Diao, co-authored with Claude (Anthropic).

## License

[MIT](LICENSE)

## 2mw2lt

Work Tempo is part of [2mw2lt](https://2mw2lt.com) — *Too Much Work, Too Little Time* — a steering partner that coordinates work across AI workers and trusted people. Its sibling [unlimited](https://github.com/endario/unlimited) reads AI-subscription usage.
