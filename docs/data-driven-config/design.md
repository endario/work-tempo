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

1. Read the layer and check its `schema_version`. A missing `schema_version` means version 1.
2. Validate keys against that version's allowlist: unknown keys are errors naming the key and file. Version 1 allows today's keys and **rejects** `test_file_markers`; version 2 allows the version-1 keys plus `test_file_markers`.
3. Validate each value with the existing `_string_list` / `_string_dict` / `_extra_repo_list` checks.
4. Overlay validated layers in order: `defaults.json`, tracked `<root>/.source-tempo.json`, local file or `--config`. A later top-level key replaces the earlier value; lists replace. A partial version-1 workspace layer may overlay a version-2 defaults layer. `schema_version` is not part of the overlay.

Classification moves onto `Config` as methods: `language_for_path`, `documentation_language_for_path`, `source_kind_for_path`, `is_generated_or_minified`, `should_count_path`, `should_count_documentation_path`, `is_doc_only_repo`, and `signature(include_vendor)`. These are exactly the functions that read the globals today, and they move onto the object that owns the data. A separate `Classifier` type is not added: it would add a type without a second consumer.

Only the orchestration functions that need policy take a `config: Config` parameter: `list_repos`, `partition_skipped_repos`, `count_snapshot`, `collect_churn_by_period`, `collect_churn_cached`, `_snapshot_task` (which receives the `Config`, not a dict to re-apply), and `main`. Report building receives the scalar `report_title`, not the `Config`.

### Schema version 2 and `test_file_markers`

The four infix markers become the config key `test_file_markers`, defaulting to today's values. Adding a counting key under version 1 would let an older installation read a shared `.source-tempo.json`, ignore the key, and report different numbers. So the key exists only in schema version 2, and a file that declares version 1 (or nothing) and uses the key is rejected, not accepted by a combined allowlist:

- `--init-config` writes `schema_version: 2`.
- A version-1 file lacks the key and gets the default, which is the old behaviour.
- An older installation refuses a version-2 file with its existing "unsupported config schema_version" error instead of miscounting.

### Cache stability

`Config.signature` covers only the counting-policy fields (not `report_title`, extra repositories, or excluded submodules, matching today's payload). Its canonical payload is today's plus `test_file_markers`. Every existing cache therefore misses once. `CACHE_SCHEMA_VERSION` is not bumped: changed policy already selects fresh entries by hash. The `DOC_ONLY_REPO_NAMES` default change on the parent commit causes a cold start regardless.

### Delivery

Three PRs, each provable on its own so a failure is attributable to packaging, the dependency refactor, or the compatibility migration. Each is branched from `main` after the open-source-preparation branch lands; none carries its changes.

1. **Defaults as data.** Add `defaults.json` (schema-version-1 keys only; no `report_title`, no `test_file_markers`) and package-data metadata. The existing module constants are populated from it; `default_config_data()` and `--init-config` read it. Delete `examples/source-tempo.json` and update every reference to it (README and `docs/architecture.md`). Add permanent CI that builds the wheel and sdist, installs each into a clean venv, and runs `source-tempo --init-config` in a temporary repository.
2. **Explicit `Config`, behaviour preserved.** Introduce `Config` and `load_config` with today's loading semantics (schema version 1, merge as it is now), move classification onto it, thread it through the orchestration functions, pass `Config` to workers, delete the globals and `apply_workspace_config`, and migrate tests off module reloads and global assignment.
3. **Strict, versioned configuration.** Per-layer validation, version-specific key allowlists, unknown-key errors, schema version 2, and `test_file_markers`. Ships with a release note, because older installations will reject version-2 files.

## Acceptance criteria

PR 1:
- `defaults.json` loads to the previous constants, and the pre-change cache signature is reproduced.
- The wheel and sdist both contain `defaults.json`, and an installed copy runs `--init-config`; this runs in CI on every change.
- The default constants load at import, so a missing or malformed `defaults.json` makes the import fail with a `RuntimeError` naming the file. A test runs the module in a subprocess with the file absent and asserts a non-zero exit and that message on stderr. (PR 2 replaces the constants with `Config`; from then on the same fault stops the run at startup with `error: packaged defaults unreadable: …` and exit code 1.)

PR 2:
- No default list/dict/set literal remains in `cli.py`, and `git grep -n "^\s*global "` in `src/` is empty.
- Report JSON for a fixed fixture repository is identical before and after (excluding `generatedAt`), cold and warm cache, and the cache signature is unchanged.
- `Config` round-trips through `pickle`, and `--workers 2` under the `spawn` start method yields the same report as `--workers 1`.
- Tests contain no module reloads for config and no assignments to policy globals.

PR 3:
- Every combination in the version matrix behaves as specified: missing version, v1 with `test_file_markers` (rejected), v2 with it, v1 layer over v2 defaults, and a bad tracked layer that a good local layer cannot mask. Errors occur before any repository is traversed.
- Unknown keys, bad types, and unsupported versions in any layer are errors.
- The signature payload equals the old payload plus `test_file_markers`, and a test pins the resulting hash.
- `test_file_markers` is overridable.

## Decisions taken

- Unknown config keys are errors, not warnings, since a silent typo corrupts a metrics tool.
- `examples/source-tempo.json` is deleted rather than kept in sync by a test.
- Classification lives on `Config`, without a separate `Classifier` or nested config types.
- `source_kinds` (`code`, `test`) stay in code: they are part of the report contract.
