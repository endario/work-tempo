# SourceTempo Extraction Design

## Purpose

SourceTempo tracks source-code momentum across one Git workspace and any configured related repositories. It reports source and test LOC snapshots, language composition, monthly or daily churn, and informational documentation activity without treating documentation as product-source churn. Its immediate decision surface is whether authored product source is growing, how much work is being replaced, and which repositories and languages account for that movement.

The initial product is a local command-line collector with self-contained HTML and versioned JSON reports. A native macOS menu-bar client can later consume the JSON contract without inheriting Git traversal or counting logic.

Repository comparison and component classification are not SourceTempo features. The Adastra/Open-RMF comparison remains in Adastra.

## Product Boundary

SourceTempo owns:

- Git repository and initialized submodule discovery.
- Explicit additional-root configuration for repositories outside the workspace tree.
- Source, test, language, documentation, snapshot, and churn classification.
- Period bucketing in the system timezone with UTC fallback.
- Persistent incremental caching under the user's platform cache directory.
- Terminal, self-contained HTML, and schema-versioned JSON reports.
- Monthly and daily history, partial-current-period rendering, and optional short-term LOC forecasting.

SourceTempo does not own:

- Adastra repository lists, excluded product modules, or branding.
- Open-RMF cloning, comparison, or component taxonomy.
- Remote analytics, accounts, telemetry, or hosted storage.
- A native macOS interface in this extraction milestone.

## Architecture

The first extraction keeps the proven collector as one Python module rather than combining migration with a broad internal rewrite. The repository uses a standard Python package so the collector can be installed and invoked consistently. Python 3.10 or newer and Git 2.30 or newer are supported.

```text
source-tempo/
  src/source_tempo/
    __init__.py
    __main__.py
    cli.py
  tests/
    test_cli.py
  docs/architecture/
  pyproject.toml
```

`source-tempo` and `python -m source_tempo` both call `source_tempo.cli.main`. The collector has no runtime dependencies outside the Python standard library and Git executable.

The package boundary is the first refactor seam. Internal collection, caching, and rendering modules should be extracted only when a focused test seam or internal reuse makes that separation useful. A macOS client consuming JSON over a process boundary is not itself a reason to reorganize the collector.

## Workspace Configuration

The CLI analyzes the current working directory by default and accepts `--root` for another checkout. Configuration is layered in this order:

1. Built-in generic defaults.
2. Tracked `<root>/.source-tempo.json` workspace policy.
3. Untracked `<root>/.source-tempo.local.json` for personal overrides.

An explicit `--config` replaces the default local layer but still loads the tracked workspace layer. Object keys override earlier keys; list values replace rather than append. `--no-config` disables both tracked and local configuration.

Configuration supports language mappings, source and vendor exclusions, test classification, documentation-only repository names, excluded submodules, and additional repositories. Built-in defaults contain no organization or product-specific paths.

Workspace-specific policy remains with the workspace being measured. SourceTempo does not copy Adastra's `.loc-history.json` or infer that policy from repository names.

## Outputs

The terminal report is the immediate operational view. HTML is written beneath the workspace-specific user cache directory by default. JSON is optional and uses schema version 1.

The JSON document remains raw and presentation-independent. It includes:

- Workspace identity and effective scope.
- Period labels and current-period timing metadata.
- LOC, documentation LOC, churn, additions, deletions, code/test, and language series.
- Latest repository and language breakdowns.
- Optional forecast model metadata.

The HTML renderer consumes the same JSON-safe in-memory document written by the JSON adapter. Serialization rejects non-finite numbers. This prevents the future menu-bar app and HTML report from receiving different metrics.

Schema version 1 permits additive fields. Consumers must ignore unknown fields. Removing a field, changing its meaning or type, or changing period-series alignment requires a schema-version increment.

## Cache Correctness

The default cache is stored under `~/Library/Caches/SourceTempo/<workspace-key>/` on macOS and the corresponding XDG cache directory on other Unix systems. The workspace key derives from the analyzed repository's canonical path and Git identity. The default HTML report lives alongside it, so simultaneous workspaces do not overwrite one another and analyzed repositories remain untouched.

Snapshot entries are keyed by repository, commit, and the normalized effective counting policy. Churn entries also include period kind and resolved timezone. Cache schema changes invalidate the whole cache; counting-policy changes select fresh entries; rewritten history triggers a full churn rescan. Invalid cache data is treated as a cold start. Writes use a temporary file and atomic replacement, so overlapping readers never observe a partial document.

The inherited default uses the active system timezone with UTC fallback. This matches local calendar intuition and the existing collector behavior. The resolved timezone is recorded in report data and cache keys; changing system timezone intentionally changes period boundaries and selects a separate churn cache entry.

## Inherited And New Decisions

The extraction preserves these working collector features: monthly and daily buckets, code/test and language classification, separate documentation metrics, submodule and extra-root aggregation, partial-current-period charts, incremental caching, optional three-month forecasting, active-system-timezone bucketing, terminal output, self-contained HTML, and schema-versioned JSON.

New decisions in SourceTempo are limited to package layout, product-owned filenames, current-directory default root, user-cache storage, safe default report location, compatibility policy, and repository documentation. Replacing the counting engine with `scc`, `tokei`, or Linguist is deliberately deferred because it would combine extraction with a metric-definition change.

## Migration

The implementation is a clean extraction from the Adastra LOC-history collector at merged revision `3b171abbc78bba208719113d6db6b8973a3e6b56`. History is intentionally not rewritten or imported because the old repository history contains unrelated company context. A provenance note records the source revision and the extraction boundary.

Migration changes are limited to:

- Product and package naming.
- Default root behavior and output/config/cache filenames.
- Standard package entry points.
- Removal of Adastra-only tests and configuration.
- Reworked test imports and portable fixtures.
- Public-facing documentation for setup and workspace configuration.

Metric definitions and chart behavior remain unchanged unless a portability test proves that a prior assumption was workspace-specific.

## Distribution Path

The repository is private during extraction. No open-source license is asserted until provenance and ownership are reviewed for public release. The provenance review covers source, tests, fixtures, generated examples, and documentation.

The local development path is an editable Python install. A later macOS app will use SwiftUI `MenuBarExtra` and invoke a bundled or separately installed collector to obtain schema-versioned JSON. Packaging Python into the app is deferred until the interface and refresh behavior are proven locally.

## Acceptance Criteria

- `source-tempo --root <repo>` works from outside the analyzed repository.
- The current directory is analyzed when `--root` is omitted.
- Multiple initialized submodules and configured extra repositories are aggregated.
- Generic defaults contain no Adastra, QuikSync, or Open-RMF scope.
- Documentation is reported separately from source LOC and churn.
- HTML and JSON are generated from one report document.
- Report data serializes with strict JSON semantics and no non-finite values.
- A hand-computed Git fixture verifies source, test, documentation, and churn totals.
- Warm-cache and cold-cache runs produce equivalent report metrics, including after a counting-policy change.
- The extracted generic test suite passes on the supported Python version.
- A representative multi-root fixture produces stable terminal, HTML, and JSON output.
- The new repository is created under the `endario-org` GitHub organization and remains private.
