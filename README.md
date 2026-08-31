# SourceTempo

SourceTempo tracks source-code momentum across a Git workspace and its related repositories. It produces terminal summaries, a self-contained HTML report, and optional schema-versioned JSON for other local tools.

It measures:

- Source and test LOC snapshots over time.
- Added plus deleted source churn by month or day.
- Language composition and per-repository contribution.
- Documentation LOC and churn as separate informational metrics.

Repository comparison and component classification are outside SourceTempo's scope.

## Requirements

- Python 3.10 or newer.
- Git 2.30 or newer.

SourceTempo has no Python runtime dependencies outside the standard library.

## Install

For local development:

```bash
git clone https://github.com/endario-org/source-tempo.git
cd source-tempo
python3 -m venv .venv
.venv/bin/pip install -e .
```

Then run it from any Git repository:

```bash
source-tempo
```

The current directory is the default workspace. Analyze another checkout with:

```bash
source-tempo --root ~/projects/my-app
```

Without installation, use:

```bash
PYTHONPATH=src python3 -m source_tempo --root ~/projects/my-app
```

## Reports

The default report covers the latest 18 monthly periods and writes HTML under the workspace-specific user cache directory. The exact path is printed after each run.

```bash
# Monthly history with explicit outputs
source-tempo --root ~/projects/my-app \
  --html /tmp/source-tempo.html \
  --json /tmp/source-tempo.json

# Daily view for the latest 30 days
source-tempo --root ~/projects/my-app --period day --days 30

# Terminal and JSON only
source-tempo --root ~/projects/my-app --no-html --json /tmp/source-tempo.json

# Optional three-month LOC forecast using the last six completed months
source-tempo --root ~/projects/my-app --forecast
```

Period boundaries use the active system timezone, falling back to UTC. The resolved timezone is included in JSON and HTML report metadata.

## Workspace Scope

SourceTempo always considers the parent Git repository. It also discovers usable initialized submodules declared in `.gitmodules` and can aggregate additional repositories configured outside the workspace.

Create a personal configuration:

```bash
source-tempo --root ~/projects/my-app --init-config
```

This writes `~/projects/my-app/.source-tempo.local.json`, which should remain untracked. For shared workspace policy, generate or maintain `~/projects/my-app/.source-tempo.json` instead.

Configuration layers are applied in this order:

1. Built-in generic defaults.
2. Tracked `.source-tempo.json`.
3. Untracked `.source-tempo.local.json`, or the file passed with `--config`.

Later keys replace earlier keys. Arrays replace rather than append. See [examples/source-tempo.json](examples/source-tempo.json) for every supported field.

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

Churn is added plus deleted lines from non-merge commits, grouped by author date and filtered through the same current counting policy. Blank lines and comments count because SourceTempo measures physical source lines rather than semantic SLOC.

Generated, minified, dependency, build, cache, scratch, and vendor-like paths are excluded by default. Documentation is counted separately and does not contribute to source LOC, growth, or churn metrics.

## Cache

On macOS, artifacts default to:

```text
~/Library/Caches/SourceTempo/<workspace-name>-<workspace-key>/
```

Linux uses `$XDG_CACHE_HOME/source-tempo` or `~/.cache/source-tempo`. Set `SOURCE_TEMPO_CACHE_HOME` to override the root.

```bash
# Rebuild the workspace cache
source-tempo --clear-cache

# Run without reading or writing a cache
source-tempo --no-cache

# Use an explicit cache file
source-tempo --cache /tmp/source-tempo-cache.json
```

Snapshot cache entries include the commit and effective counting policy. Churn entries also include period kind and timezone. Rewritten history triggers a full churn rescan.

## JSON Compatibility

Reports currently use schema version 1. Additive fields may be introduced within version 1, and consumers must ignore unknown fields. Removing a field, changing its type or meaning, or changing period-series alignment requires a schema-version increment.

## Development

```bash
PYTHONPATH=src python3 -m unittest discover -s tests -v
python3 -m compileall -q src tests
```

The repository remains private during extraction. See [PROVENANCE.md](PROVENANCE.md) for the source boundary and licensing status.
