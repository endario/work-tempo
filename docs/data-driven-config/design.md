# Data-driven configuration

## Problem

The collector's counting rules are configurable through `.source-tempo.json`, but the mechanism is not data-driven:

1. **Defaults are code.** ~17 module-level constants in `cli.py` (`LANGUAGE_BY_EXT`, `TEST_DIR_NAMES`, …) hold the defaults. `default_config_data()` re-serializes them for `--init-config`, and `examples/source-tempo.json` is a hand-kept copy. Three places describe one truth.
2. **Config is applied by mutating globals.** `apply_workspace_config` rebinds the constants with `global`, and `main` mutates `REPORT_TITLE` the same way. Consequences:
   - Every classification function reads ambient state; nothing in a signature says what policy it uses.
   - Process-pool workers rebuild the policy by re-running `apply_workspace_config` on a pickled dict (`_snapshot_task`).
   - Tests reload the whole module (`load_script`) or assign globals directly (`DOC_ONLY_REPO_NAMES`, `EXCLUDE_SUBMODULES`, `EXTRA_REPOS`, `REPORT_TITLE`) and restore them in `finally`.
3. **One counting rule is not configurable.** `source_kind_for_path` hardcodes the infix markers `.test.`, `.spec.`, `.e2e.`, `.cy.`.
4. **Config is loaded loosely.** Layers are merged with `dict.update` before validation, so a later layer's `schema_version` overwrites an earlier one's and an unsupported tracked file can be masked by the local file. Unknown keys are silently ignored, so a typo in a counting rule produces plausible but wrong numbers.

**Goal.** All workspace-controlled repository-scope and path-classification policy is explicit data, defaults included, and no function reads that policy from ambient state. Report-schema definitions (the `code`/`test` kinds, forecast horizon) and per-run CLI inputs (`--period`, `--include-vendor`, …) stay in code and flags.

## Non-goals

- The macOS app's policy constants (30-day window, 184-day chart window, staleness limits, timeout, worker count, collector search paths). Scheduling and presentation, not counting policy; a separate request if they should be user-tunable.
- Changing any metric definition or report JSON.
- Replacing the counting engine (see [architecture.md](../architecture.md)).

## Design

### Packaged defaults

`src/source_tempo/defaults.json` holds every default in the config schema. It is the only place defaults are written down. It is located with `Path(__file__).with_name("defaults.json")` and shipped as package data, so it resolves identically when running from source, with `PYTHONPATH=src`, when the module is loaded by file path (as the tests do today), editable, and from an installed wheel. Zip-imported installs are not supported.

`report_title` is **not** in the file: its default is the root directory name, which is dynamic. The loader derives it after all layers are overlaid; `--init-config` injects it when writing a user file.

`--init-config` writes `defaults.json` plus `report_title`. `examples/source-tempo.json` is deleted; the README points at `defaults.json` and `--init-config`.

A missing or malformed `defaults.json` is a packaging fault and fails fast with an error naming the file, not a silent fallback.

### `Config`

A frozen dataclass built once per run by `load_config(root, explicit_path, no_config)`. Fields are tuples and frozensets for list/set policy and plain dicts for the two mappings, copied defensively in the loader. The claim is shallow immutability plus "nothing mutates it after load", not deep immutability. It must pickle, and that is tested under the `spawn` start method (the macOS default) rather than assumed.

Loading, per layer, **before** merging:

1. Read the layer, check its `schema_version` (accepted: 1 and 2), reject unknown keys with an error naming the key and file, and validate each value with the existing `_string_list` / `_string_dict` / `_extra_repo_list` checks.
2. Overlay validated layers in order: `defaults.json`, tracked `<root>/.source-tempo.json`, local file or `--config`. A later top-level key replaces the earlier value; lists replace. `schema_version` is not part of the overlay.

Classification moves onto `Config` as methods: `language_for_path`, `documentation_language_for_path`, `source_kind_for_path`, `is_generated_or_minified`, `should_count_path`, `should_count_documentation_path`, `is_doc_only_repo`, and `signature(include_vendor)`. These are exactly the functions that read the globals today, and they move onto the object that owns the data. A separate `Classifier` type is not added: it would add a type without a second consumer.

Only the orchestration functions that need policy take a `config: Config` parameter: `list_repos`, `partition_skipped_repos`, `count_snapshot`, `collect_churn_by_period`, `collect_churn_cached`, `_snapshot_task` (which receives the `Config`, not a dict to re-apply), and `main`. Report building receives the scalar `report_title`, not the `Config`.

### Schema version 2 and `test_file_markers`

The four infix markers become the config key `test_file_markers`, defaulting to today's values. Adding a counting key under version 1 would let an older installation read a shared `.source-tempo.json`, ignore the key, and report different numbers. So the config schema becomes version 2:

- `--init-config` writes `schema_version: 2`.
- The loader accepts 1 and 2. A version-1 file lacks the key and gets the default, which is the old behaviour.
- An older installation refuses a version-2 file with its existing "unsupported config schema_version" error instead of miscounting.

### Cache stability

`Config.signature` covers only the counting-policy fields (not `report_title`, extra repositories, or excluded submodules, matching today's payload). Its canonical payload is today's plus `test_file_markers`. Every existing cache therefore misses once. `CACHE_SCHEMA_VERSION` is not bumped: changed policy already selects fresh entries by hash. The `DOC_ONLY_REPO_NAMES` default change on the parent commit causes a cold start regardless.

### Delivery

Two PRs, so the behaviour-preserving slice can be proved exact on its own.

1. **Defaults as data, no behaviour change.** Add `defaults.json` (no `report_title`, no `test_file_markers`) and package-data metadata. The existing module constants are populated from it; `default_config_data()` and `--init-config` read it; `examples/source-tempo.json` is deleted. Tests prove exact parity with the pre-change defaults and an unchanged cache signature. CI builds the wheel and sdist, installs each into a clean venv, and runs `source-tempo --init-config` in a temporary repository.
2. **`Config`, schema v2, strict loading.** Everything in the section above: `Config`, per-layer validation with unknown-key errors, `test_file_markers`, schema version 2, worker pickling, deletion of the globals and `apply_workspace_config`, and test migration off module reloads.

## Acceptance criteria

PR 1:
- `defaults.json` loads to exactly the previous constants (asserted against a snapshot of the old values), and the pre-change cache signature is reproduced.
- The wheel and sdist both contain `defaults.json`, and an installed copy runs `--init-config`.
- Missing or malformed `defaults.json` produces a clear error.

PR 2:
- No default list/dict/set literal remains in `cli.py`, and `git grep -n "^\s*global "` in `src/` is empty.
- Report JSON for a fixed fixture repository is identical before and after (excluding `generatedAt`), cold and warm cache.
- The signature payload equals the old payload plus `test_file_markers`, and a test pins the resulting hash.
- `Config` round-trips through `pickle` and `--workers 2` under `spawn` yields the same report as `--workers 1`.
- A file with an unknown key, a bad type, or an unsupported `schema_version` in any layer errors before any repository is traversed, and a bad tracked layer cannot be masked by a good local layer.
- `test_file_markers` is overridable, and a version-1 file still loads.
- Tests contain no module reloads for config and no assignments to policy globals.

## Decisions taken

- Unknown config keys are errors, not warnings, since a silent typo corrupts a metrics tool.
- `examples/source-tempo.json` is deleted rather than kept in sync by a test.
- Classification lives on `Config`, without a separate `Classifier`.
- `source_kinds` (`code`, `test`) stay in code: they are part of the report contract.
