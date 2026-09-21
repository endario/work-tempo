# Data-driven configuration

## Problem

The collector's counting rules are configurable through `.source-tempo.json`, but the mechanism is not data-driven:

1. **Defaults are code.** ~17 module-level constants in `cli.py` (`LANGUAGE_BY_EXT`, `TEST_DIR_NAMES`, …) hold the defaults. `default_config_data()` re-serializes them for `--init-config`, and `examples/source-tempo.json` is a hand-kept copy. Three places describe one truth.
2. **Config is applied by mutating globals.** `apply_workspace_config` rebinds the constants with `global`, and `main` mutates `REPORT_TITLE` the same way. Consequences:
   - Every classification function reads ambient state; nothing in a signature says what policy it uses.
   - Process-pool workers rebuild the policy by re-running `apply_workspace_config` on a pickled dict (`_snapshot_task`), which only works because the config is re-applied in each child.
   - Tests reload the whole module (`load_script`) or assign globals directly (`DOC_ONLY_REPO_NAMES`, `EXCLUDE_SUBMODULES`, `EXTRA_REPOS`, `REPORT_TITLE`) and restore them in `finally`.
3. **Some rules are not configurable at all.** `source_kind_for_path` hardcodes the infix markers `.test.`, `.spec.`, `.e2e.`, `.cy.`, and the source kinds `("code", "test")`.

Goal: any policy that affects a number in a report is data a user can see and override, defaults included, and no function reads policy from ambient state.

## Non-goals

- The macOS app's policy constants (30-day window, 184-day chart window, 1h/24h staleness, 120s timeout, two workers, collector search paths). They are presentation/scheduling choices, not counting policy. Making them user-tunable is a separate request.
- Changing any metric definition, config file schema key names, or report JSON.
- Replacing the counting engine (see [architecture.md](../architecture.md)).

## Design

### Packaged defaults

`src/source_tempo/defaults.json` holds every default, in the existing config schema (`schema_version: 1`) plus one new key, `test_file_markers` (the four infixes above). It ships as package data and is read with `importlib.resources`. It is the only place defaults are written down.

`--init-config` writes this file (with `report_title` set from the root's name) to `.source-tempo.local.json`. `examples/source-tempo.json` is deleted; the README points at `defaults.json` and `--init-config`.

### Immutable `Config`

A frozen dataclass, `Config`, built once per run by `load_config(root, explicit_path, no_config)`:

1. Read `defaults.json`.
2. Overlay tracked `<root>/.source-tempo.json`.
3. Overlay the local file (or `--config`).

Overlay semantics are unchanged: a later top-level key replaces the earlier value; lists replace. Validation is the existing `_string_list` / `_string_dict` / `_extra_repo_list` checks, moved into the loader. Fields are tuples, frozensets, or read-only mappings, so a `Config` is hashable-in-spirit, cheap to pickle, and safe to share.

Classification becomes methods on `Config`: `language_for_path`, `documentation_language_for_path`, `source_kind_for_path`, `is_generated_or_minified`, `should_count_path`, `should_count_documentation_path`, `is_doc_only_repo`, and a `signature(include_vendor)` for cache keys. These are the functions that today read the globals; moving them onto the object that owns the data removes the parameter-threading problem for the leaf functions.

Callers that orchestrate (`list_repos`, `partition_skipped_repos`, `count_snapshot`, `collect_churn_by_period`, `collect_churn_cached`, `_snapshot_task`, `main`, report building) take a `config: Config` parameter. `_snapshot_task` receives the `Config` itself, not a dict to re-apply.

`REPORT_TITLE` becomes `Config.report_title`, defaulting to the root directory name when no layer sets it (today's behaviour).

### Cache stability

`filter_signature` keys the snapshot cache on the effective policy. `Config.signature` builds the same payload (same keys, same encoding) so an unchanged policy keeps its hash and existing caches stay valid. The new `test_file_markers` key is added to the payload; because its default matches the old hardcoded value, the only effect is one cold start for existing caches. `CACHE_SCHEMA_VERSION` is not bumped.

The `DOC_ONLY_REPO_NAMES` default already changed (to empty) on this branch's parent commit, so that cold start happens regardless.

### Delivery

Two PRs, so review stays small and the risky one is isolated:

1. **Defaults as data.** Add `defaults.json` and package-data metadata; the module-level constants are populated from it, so behaviour is untouched. Add `test_file_markers` (configurable, same default). `default_config_data()` returns the file. Delete `examples/source-tempo.json`. Tests: the loaded defaults equal the file; `--init-config` output equals it; the four markers are overridable.
2. **Immutable `Config`.** Introduce `Config` and `load_config`, move classification onto it, thread it through the orchestration functions, delete the globals and `apply_workspace_config`. Tests stop reloading the module and build a `Config` directly.

## Acceptance criteria

- `defaults.json` is the single source of defaults: no default list, dict, or set literal remains in `cli.py`, and `git grep -n "^\s*global "` in `src/` is empty.
- Every rule that affects a reported number can be overridden from config, including the test infix markers.
- Report JSON for a fixed fixture repository is byte-identical before and after (excluding `generatedAt`), cold and warm cache.
- `Config.signature` for the default policy differs from the pre-refactor hash only by the added `test_file_markers` field.
- A `Config` round-trips through `pickle`, and the parallel path (`--workers 2`) yields the same report as `--workers 1`.
- The full suite passes; tests contain no module reloads for config and no assignments to policy globals.
- `pip install .` (non-editable) into a clean venv finds `defaults.json` and runs `source-tempo --init-config`.

## Open questions

1. **Unknown keys.** Today, unknown config keys are silently ignored, so a typo (`test_dir_name`) does nothing. Options: keep ignoring; warn on stderr; error. Leaning warn-on-stderr, but it is new behaviour, so it is not in scope unless the critic argues for it.
2. **Keep `examples/source-tempo.json`?** Deleting it removes a drift risk but removes a file GitHub readers find easily. The alternative is keeping it and asserting in a test that it equals `defaults.json`.
3. **Classification as methods vs. a separate `Classifier`.** Methods on `Config` are the smaller change. A separate `Classifier` built from a `Config` would let the data object stay pure data, at the cost of one more type.
4. **`source_kinds` (`code`, `test`).** These are the report contract's kinds and are fixed by the JSON schema, so they stay in code. Confirm this is the right line between "policy" and "schema".
