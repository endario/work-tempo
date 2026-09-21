# Architecture

Source Tempo has two parts: a Python collector that does all Git traversal and counting, and an optional macOS menu-bar app that reads the collector's JSON reports. See [macos-app.md](macos-app.md) for the app.

## Purpose

Source Tempo tracks source-code momentum across one Git workspace and any related repositories. It reports source and test LOC snapshots, language composition, monthly or daily churn, and documentation activity. Documentation is informational and never counts toward source LOC, growth, or churn.

The questions it answers: is authored source growing, how much work is replacing existing code, and which repositories and languages account for the movement.

## Boundaries

The collector owns:

- Git repository and initialized-submodule discovery, plus explicitly configured extra repositories.
- Source, test, language, documentation, snapshot, and churn classification.
- Period bucketing in the system timezone, with UTC fallback.
- A persistent incremental cache in the user's cache directory.
- Terminal, self-contained HTML, and schema-versioned JSON reports.
- Optional short-term LOC forecasting.

It deliberately does not own repository comparison, component taxonomy, remote analytics, accounts, telemetry, or hosted storage.

## Layout

```text
src/source_tempo/
  __main__.py     python -m source_tempo
  cli.py          collector, cache, report model, HTML renderer
  defaults.json   default rules (package data)
tests/test_cli.py
macos/            menu-bar app (Swift package)
scripts/build-macos-app.sh
```

`source-tempo` and `python -m source_tempo` both call `source_tempo.cli.main`. The collector uses only the Python standard library and the `git` executable (Python 3.10+, Git 2.30+).

The collector is one module on purpose. Split it when a focused test seam or real internal reuse calls for it; a second consumer of the JSON report is not a reason to reorganize it, because consumers talk to it across a process boundary.

## Workspace configuration

The CLI analyzes the current directory, or `--root` for another checkout. Configuration is layered:

1. Built-in generic defaults.
2. Tracked `<root>/.source-tempo.json`, the shared workspace policy.
3. Untracked `<root>/.source-tempo.local.json` for personal overrides.

`--config` replaces the local layer but the tracked layer still loads. `--no-config` disables both. Layers are validated one at a time, then merged per top-level key: a later key replaces the earlier value, and lists replace rather than append. Validation is version-specific: a file declaring `schema_version` 1 (or none) may use only the version-1 keys, and version 2 adds `test_file_markers`. Unknown keys and unsupported versions are errors.

`--init-config` writes the built-in defaults to the local file (refusing to overwrite without `--force-config`). [src/source_tempo/defaults.json](../src/source_tempo/defaults.json) is the single source of the defaults and shows every supported key: language mappings, source and vendor exclusions, test classification, documentation-only repository names, excluded submodules, generated-file markers, and extra repositories.

Counting policy belongs to the workspace being measured. It is a `Config` built once per run from `defaults.json` plus the layers above and passed to the functions that count, including the worker processes.

### Config schema versions

Each layer declares `schema_version` (missing means 1) and is checked against that version's key list before layers are merged, so a bad tracked file cannot be hidden by a valid local one and `schema_version` never takes part in the overlay.

| Declared version | Allowed keys |
| --- | --- |
| 1 or missing | the keys in `defaults.json` except `test_file_markers` |
| 2 | all keys, including `test_file_markers` |

A key that changes counting is only accepted under a version that older releases reject. Otherwise an older release would read the same shared `.source-tempo.json`, ignore the key, and report different numbers. A version-1 file may overlay the version-2 packaged defaults. The packaged defaults must declare the newest supported version, which `--init-config` writes.

## Counting model

- LOC snapshots count newline-delimited tracked files at the last commit available at each period cutoff, read with `git archive`.
- Source is split into code and tests using conventional test directories and test/spec/e2e filename patterns.
- Churn is added plus deleted lines from non-merge commits, grouped by author date and filtered through the same counting policy.
- Blank lines and comments count: the unit is physical lines, not semantic SLOC.
- Generated, minified, dependency, build, cache, scratch, and vendor-like paths are excluded by default.
- Only extensions in `language_by_ext` (and names in `language_by_name`) count as source; Markdown, JSON, YAML, TOML and similar formats are left out so the numbers reflect code.
- `doc_only_repo_names` lists repository directory names whose source-like files count as documentation rather than source. It is empty by default.

Replacing this engine with `scc`, `tokei`, or Linguist would change metric definitions, not just plumbing, so it is a separate decision from any refactor.

## Reports

The terminal report is the immediate view. HTML is written to the workspace's cache directory by default (`--html` overrides, `--no-html` disables). JSON is written only with `--json`.

The JSON document is raw and presentation-independent. It carries:

- Workspace identity, effective scope (per-repository paths), and timezone.
- Period labels and current-period timing metadata.
- Series for source LOC, LOC by kind, documentation LOC, churn, additions, and deletions.
- Latest repository and language breakdowns.
- Optional forecast metadata.

The HTML renderer consumes the same in-memory document that the JSON writer serializes, so the two cannot report different numbers. Serialization rejects non-finite values (`allow_nan=False`).

**Compatibility.** Reports use schema version 1. Additive fields may appear within version 1 and consumers must ignore unknown fields. Removing a field, changing its type or meaning, or changing period-series alignment requires a schema-version increment.

## Cache

Artifacts live under a per-workspace directory in the platform cache root:

| Platform | Root |
| --- | --- |
| macOS | `~/Library/Caches/SourceTempo` |
| Linux | `$XDG_CACHE_HOME/source-tempo` or `~/.cache/source-tempo` |
| Windows | `%LOCALAPPDATA%\SourceTempo\Cache` |

`SOURCE_TEMPO_CACHE_HOME` overrides the root. The directory is `<workspace-name>-<hash>`, where the hash covers the canonical root path and Git directory, so simultaneous workspaces never overwrite each other and analyzed repositories are never written to. `cache.json` and `report.html` sit side by side.

What keeps the cache correct:

- **Snapshot entries** are keyed by repository, commit, and the normalized effective counting policy, so a policy change selects fresh entries instead of returning stale counts.
- **Churn entries** also include the period kind and resolved timezone.
- **A cache schema change** invalidates the whole cache; unreadable or invalid data is treated as a cold start.
- **Rewritten history** (a cached commit that is no longer an ancestor) triggers a full churn rescan.
- **Writes** go to a temporary file and are atomically renamed, so concurrent readers never see a partial document.

## Timezone

Period boundaries use the active system timezone (`TZ`, then `/etc/localtime`, then `/etc/timezone`), falling back to UTC. The resolved timezone is recorded in report data and in churn cache keys. Changing the system timezone intentionally changes period boundaries and selects a separate churn entry.

## Testing

`tests/test_cli.py` runs with `unittest` and needs only Git. Beyond unit tests of classification, configuration, and formatting, it includes an end-to-end fixture: a temporary repository with dated commits whose expected source, test, documentation, and churn totals are computed by hand, run cold, warm, and after a counting-policy change. CI runs the suite on Python 3.10 and 3.13, plus the Swift package tests and a release build on macOS.
