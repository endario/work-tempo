# Data-Driven Configuration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make counting policy explicit data (packaged defaults, an immutable `Config`, strict versioned loading) with no ambient global state.

**Architecture:** Three serial PRs off `main`, each independently provable: (1) defaults move into a packaged `defaults.json`; (2) an immutable `Config` replaces the module globals with behaviour unchanged; (3) per-layer validation, config schema version 2, and configurable `test_file_markers`.

**Tech Stack:** Python 3.10+ standard library, `unittest`, setuptools package data, GitHub Actions.

**Spec:** [design.md](design.md)

## Global Constraints

- Runtime dependencies stay the Python standard library and `git`.
- Report JSON and metric definitions do not change in any PR.
- Existing suite command: `PYTHONPATH=src python3 -m unittest discover -s tests`.
- Python 3.10 must keep working: no syntax or stdlib newer than 3.10.
- Each PR is branched from `main` and merged before the next starts.
- Attribution trailer on every commit: `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`.

Pre-change cache signatures (pinned by PR 1, recorded from `main` at `1c506bf`): `filter_signature(include_vendor=False) == "d1d7d3a40ab93799"`, `filter_signature(include_vendor=True) == "000ce7a2e8d2c03c"`.

---

# PR 1: Defaults as data

Branch `refactor/defaults-as-data`. No behaviour change.

### Task 1: Pin current behaviour

**Files:**
- Modify: `tests/test_cli.py` (add tests to the existing `TestCase` class that holds `test_doc_only_repo_names_participate_in_cache_signature`)

- [ ] **Step 1: Add the signature pin and the defaults-parity test**

```python
    def test_default_policy_signature_is_pinned(self) -> None:
        tempo = load_script("tempo_signature_pin_test", "src/source_tempo/cli.py")
        self.assertEqual(tempo.filter_signature(include_vendor=False), "d1d7d3a40ab93799")
        self.assertEqual(tempo.filter_signature(include_vendor=True), "000ce7a2e8d2c03c")

    def test_packaged_defaults_match_module_constants_and_init_config(self) -> None:
        tempo = load_script("tempo_packaged_defaults_test", "src/source_tempo/cli.py")
        packaged = json.loads((REPO_ROOT / "src/source_tempo/defaults.json").read_text(encoding="utf-8"))
        self.assertEqual(tempo.default_config_data("x"), {**packaged, "report_title": "x"})
        self.assertNotIn("report_title", packaged)
        constants = {
            "language_by_ext": tempo.LANGUAGE_BY_EXT,
            "exclude_exts": tempo.EXCLUDE_EXTS,
            "documentation_by_ext": tempo.DOCUMENTATION_BY_EXT,
            "doc_only_repo_names": tempo.DOC_ONLY_REPO_NAMES,
            "language_by_name": tempo.LANGUAGE_BY_NAME,
            "exclude_dirs": tempo.EXCLUDE_DIRS,
            "vendor_dirs": tempo.VENDOR_DIRS,
            "exclude_submodules": tempo.EXCLUDE_SUBMODULES,
            "extra_repos": tempo.EXTRA_REPOS,
            "generated_or_minified_markers": tempo.GENERATED_OR_MINIFIED_MARKERS,
            "generated_or_minified_suffixes": tempo.GENERATED_OR_MINIFIED_SUFFIXES,
            "generated_or_minified_names": tempo.GENERATED_OR_MINIFIED_NAMES,
            "test_dir_names": tempo.TEST_DIR_NAMES,
            "test_file_exact_stems": tempo.TEST_FILE_EXACT_STEMS,
            "test_file_lower_prefixes": tempo.TEST_FILE_LOWER_PREFIXES,
            "test_file_lower_suffixes": tempo.TEST_FILE_LOWER_SUFFIXES,
            "test_file_case_suffixes": tempo.TEST_FILE_CASE_SUFFIXES,
        }
        for key, value in constants.items():
            with self.subTest(key=key):
                if isinstance(value, dict):
                    self.assertEqual(value, packaged[key])
                else:
                    self.assertEqual(sorted(value), sorted(packaged[key]))
```

- [ ] **Step 2: Run the pin test against the current code**

Run: `PYTHONPATH=src python3 -m unittest tests.test_cli -k signature_is_pinned -v`
Expected: PASS (it pins today's behaviour). The parity test fails until Task 2 (`defaults.json` does not exist yet).

### Task 2: `defaults.json` and the loader

**Files:**
- Create: `src/source_tempo/defaults.json`
- Modify: `src/source_tempo/cli.py:46-187` (constants), `cli.py:189-210` (`default_config_data`)
- Modify: `pyproject.toml`

- [ ] **Step 1: Generate `defaults.json` from the current code**

```bash
python3 - <<'EOF'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("old", "src/source_tempo/cli.py")
m = importlib.util.module_from_spec(spec); sys.modules["old"] = m; spec.loader.exec_module(m)
data = m.default_config_data()
del data["report_title"]
open("src/source_tempo/defaults.json", "w", encoding="utf-8").write(json.dumps(data, indent=2, sort_keys=True) + "\n")
EOF
```

Expected: the file exists, has `schema_version: 1`, has no `report_title`, and `doc_only_repo_names` is `[]`.

- [ ] **Step 2: Replace the constant literals with a loader**

In `cli.py`, delete the literal definitions of `LANGUAGE_BY_EXT`, `EXCLUDE_EXTS`, `DOCUMENTATION_BY_EXT`, `DOC_ONLY_REPO_NAMES`, `LANGUAGE_BY_NAME`, `TEST_DIR_NAMES`, `TEST_FILE_EXACT_STEMS`, `TEST_FILE_LOWER_PREFIXES`, `TEST_FILE_LOWER_SUFFIXES`, `TEST_FILE_CASE_SUFFIXES`, `EXCLUDE_DIRS`, `VENDOR_DIRS`, `EXCLUDE_SUBMODULES`, `EXTRA_REPOS`, `GENERATED_OR_MINIFIED_MARKERS`, `GENERATED_OR_MINIFIED_SUFFIXES`, `GENERATED_OR_MINIFIED_NAMES` (keep `SOURCE_KINDS`, `REPORT_TITLE`, and the schema-version constants). Keep the explanatory comments that describe what each rule means by moving them to the docs, not the code. Add, where the deleted block was:

```python
DEFAULTS_PATH = Path(__file__).with_name("defaults.json")


def load_packaged_defaults() -> dict:
    try:
        raw = json.loads(DEFAULTS_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"packaged defaults unreadable: {DEFAULTS_PATH}: {exc}") from exc
    if not isinstance(raw, dict):
        raise RuntimeError(f"packaged defaults must be a JSON object: {DEFAULTS_PATH}")
    return raw


_DEFAULTS = load_packaged_defaults()

LANGUAGE_BY_EXT: dict[str, str] = dict(_DEFAULTS["language_by_ext"])
EXCLUDE_EXTS = set(_DEFAULTS["exclude_exts"])
DOCUMENTATION_BY_EXT: dict[str, str] = dict(_DEFAULTS["documentation_by_ext"])
DOC_ONLY_REPO_NAMES: set[str] = set(_DEFAULTS["doc_only_repo_names"])
LANGUAGE_BY_NAME: dict[str, str] = dict(_DEFAULTS["language_by_name"])
TEST_DIR_NAMES = set(_DEFAULTS["test_dir_names"])
TEST_FILE_EXACT_STEMS = set(_DEFAULTS["test_file_exact_stems"])
TEST_FILE_LOWER_PREFIXES = tuple(_DEFAULTS["test_file_lower_prefixes"])
TEST_FILE_LOWER_SUFFIXES = tuple(_DEFAULTS["test_file_lower_suffixes"])
TEST_FILE_CASE_SUFFIXES = tuple(_DEFAULTS["test_file_case_suffixes"])
EXCLUDE_DIRS = set(_DEFAULTS["exclude_dirs"])
VENDOR_DIRS = set(_DEFAULTS["vendor_dirs"])
EXCLUDE_SUBMODULES: set[str] = set(_DEFAULTS["exclude_submodules"])
EXTRA_REPOS: list[dict[str, str]] | None = list(_DEFAULTS["extra_repos"])
GENERATED_OR_MINIFIED_MARKERS = tuple(_DEFAULTS["generated_or_minified_markers"])
GENERATED_OR_MINIFIED_SUFFIXES = tuple(_DEFAULTS["generated_or_minified_suffixes"])
GENERATED_OR_MINIFIED_NAMES = set(_DEFAULTS["generated_or_minified_names"])
```

`SOURCE_KINDS` and `REPORT_TITLE` stay where they are; keep the definitions order valid (`Path` and `json` are already imported at the top of the module).

- [ ] **Step 3: Make `default_config_data` read the packaged file**

```python
def default_config_data(report_title: str | None = None) -> dict:
    return {**load_packaged_defaults(), "report_title": report_title or REPORT_TITLE}
```

- [ ] **Step 4: Ship the file as package data**

Append to `pyproject.toml`:

```toml
[tool.setuptools.package-data]
source_tempo = ["defaults.json"]
```

- [ ] **Step 5: Run the suite**

Run: `PYTHONPATH=src python3 -m unittest discover -s tests`
Expected: all tests pass, including both Task 1 tests.

- [ ] **Step 6: Prove parity with the old code**

Run the same comparison the old constants would give: load `git show main:src/source_tempo/cli.py` as a module and the new one, and compare every constant listed in the parity test plus `filter_signature` for both `include_vendor` values.
Expected: no differences.

### Task 3: Fail-fast test for a missing or malformed file

**Files:**
- Modify: `tests/test_cli.py`

- [ ] **Step 1: Write the test**

```python
    def test_missing_or_malformed_packaged_defaults_fail_at_import(self) -> None:
        source = REPO_ROOT / "src/source_tempo/cli.py"
        for label, content in (("missing", None), ("malformed", "{not json")):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as tmp:
                copy = Path(tmp) / "cli.py"
                copy.write_bytes(source.read_bytes())
                if content is not None:
                    (Path(tmp) / "defaults.json").write_text(content, encoding="utf-8")
                result = subprocess.run(
                    [sys.executable, str(copy), "--help"], capture_output=True, text=True
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("packaged defaults unreadable", result.stderr)
                self.assertIn("defaults.json", result.stderr)
```

- [ ] **Step 2: Run it**

Run: `PYTHONPATH=src python3 -m unittest tests.test_cli -k packaged_defaults_fail -v`
Expected: PASS.

### Task 4: Delete the example file and update references

**Files:**
- Delete: `examples/source-tempo.json`
- Modify: `README.md` (the "See examples/source-tempo.json" sentence), `docs/architecture.md` (layout block and the `--init-config` paragraph)

- [ ] **Step 1: Delete and re-point**

```bash
git rm examples/source-tempo.json
```

README: replace the sentence with `Run \`source-tempo --init-config\` to write every supported field with its default, or read [src/source_tempo/defaults.json](src/source_tempo/defaults.json).`

`docs/architecture.md`: replace `examples/source-tempo.json` in the layout block with `src/source_tempo/defaults.json  every default rule (package data)`, and replace the link in the `--init-config` paragraph with a link to `../src/source_tempo/defaults.json`.

- [ ] **Step 2: Confirm nothing still points at the deleted file**

Run: `git grep -n "examples/source-tempo"`
Expected: no output.

### Task 5: Permanent artifact CI

**Files:**
- Modify: `.github/workflows/test.yml`

- [ ] **Step 1: Add a job**

```yaml
  package:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97 # v7.0.0
        with:
          python-version: "3.13"
      - name: Build sdist and wheel
        run: |
          python -m pip install build
          python -m build --outdir dist
      - name: Install each artifact and run it
        run: |
          for artifact in dist/*.whl dist/*.tar.gz; do
            python -m venv "$RUNNER_TEMP/venv"
            "$RUNNER_TEMP/venv/bin/pip" install --quiet "$artifact"
            work="$(mktemp -d)"
            git init --quiet "$work"
            "$RUNNER_TEMP/venv/bin/source-tempo" --root "$work" --init-config
            test -s "$work/.source-tempo.local.json"
            rm -rf "$RUNNER_TEMP/venv" "$work"
          done
```

- [ ] **Step 2: Reproduce it locally for both artifacts**

Run the two commands above against a scratch venv (`pip wheel .` and `python -m build --sdist`, if `build` is installed; otherwise `python setup.py sdist` is not used, so install `build` in a scratch venv).
Expected: both installed copies write `.source-tempo.local.json`.

### Task 6: Commit and ship PR 1

- [ ] **Step 1: Commit** (`refactor: load default counting policy from packaged data`), push, open a draft PR (title as the commit subject; body: one sentence of what changed), self pre-pass, run `independent-review --pr <n> --round 1/3` at `--tier standard`, fix verified findings, merge.

---

# PR 2: Immutable `Config`

Branch `refactor/config-object`, from `main` after PR 1 lands. Behaviour and loading semantics unchanged.

### Task 7: `Config`, `load_config`, and classification methods

**Files:**
- Modify: `src/source_tempo/cli.py`
- Modify: `tests/test_cli.py`

**Interfaces:**
- Produces:
  - `@dataclass(frozen=True) class Config` with fields `report_title: str`, `language_by_ext: dict[str, str]`, `exclude_exts: frozenset[str]`, `documentation_by_ext: dict[str, str]`, `doc_only_repo_names: frozenset[str]`, `language_by_name: dict[str, str]`, `exclude_dirs: frozenset[str]`, `vendor_dirs: frozenset[str]`, `exclude_submodules: frozenset[str]`, `extra_repos: tuple[dict[str, str], ...]`, `generated_or_minified_markers: tuple[str, ...]`, `generated_or_minified_suffixes: tuple[str, ...]`, `generated_or_minified_names: frozenset[str]`, `test_dir_names: frozenset[str]`, `test_file_exact_stems: frozenset[str]`, `test_file_lower_prefixes: tuple[str, ...]`, `test_file_lower_suffixes: tuple[str, ...]`, `test_file_case_suffixes: tuple[str, ...]`.
  - Methods with the current bodies of the same-named module functions, reading `self` instead of globals: `language_for_path(path)`, `documentation_language_for_path(path)`, `doc_only_artifact_language_for_path(path)`, `is_doc_only_repo(repo)`, `source_kind_for_path(path)`, `is_generated_or_minified(path)`, `should_count_path(path, include_vendor=False)`, `should_count_documentation_path(path, include_vendor=False)`, `signature(include_vendor) -> str`.
  - `load_config(root: Path, explicit_path: Path | None, no_config: bool) -> Config` and `default_config(report_title: str = "SourceTempo") -> Config` (packaged defaults only).

- [ ] **Step 1: Write failing tests**

```python
    def test_config_classifies_from_its_own_data(self) -> None:
        tempo = load_script("tempo_config_object_test", "src/source_tempo/cli.py")
        base = tempo.default_config()
        custom = dataclasses.replace(base, language_by_ext={".zz": "Zed"}, test_dir_names=frozenset({"checks"}))
        self.assertEqual(custom.language_for_path("a/b.zz"), "Zed")
        self.assertIsNone(custom.language_for_path("a/b.py"))
        self.assertEqual(custom.source_kind_for_path("checks/x.zz"), "test")
        self.assertEqual(base.source_kind_for_path("checks/x.py"), "code")

    def test_config_signature_matches_pre_refactor_pin(self) -> None:
        tempo = load_script("tempo_config_signature_test", "src/source_tempo/cli.py")
        config = tempo.default_config()
        self.assertEqual(config.signature(include_vendor=False), "d1d7d3a40ab93799")
        self.assertEqual(config.signature(include_vendor=True), "000ce7a2e8d2c03c")

    def test_config_round_trips_through_pickle(self) -> None:
        tempo = load_script("tempo_config_pickle_test", "src/source_tempo/cli.py")
        config = tempo.default_config()
        self.assertEqual(pickle.loads(pickle.dumps(config)), config)
```

Add `import dataclasses` and `import pickle` to the test module imports.

- [ ] **Step 2: Run them to see them fail**

Run: `PYTHONPATH=src python3 -m unittest tests.test_cli -k config_ -v`
Expected: FAIL with `AttributeError: ... has no attribute 'default_config'`.

- [ ] **Step 3: Implement `Config`**

Add `from dataclasses import dataclass` to the imports. Add the dataclass after `load_packaged_defaults`, with the fields above. Implement `build_config(defaults: dict, layers: dict, report_title: str) -> Config`: start from `defaults`, overlay `layers` per top-level key (same per-key replacement as today), validate each present key with the existing `_string_dict` / `_string_list` / `_extra_repo_list` helpers, reject `schema_version != CONFIG_SCHEMA_VERSION` exactly as `apply_workspace_config` does, and return `Config(...)` with lists converted to the field types above (`report_title` from `layers["report_title"]` when present, else the argument). Implement:

```python
def default_config(report_title: str = REPORT_TITLE) -> Config:
    return build_config(load_packaged_defaults(), {}, report_title)


def load_config(root: Path, explicit_path: Path | None, no_config: bool) -> Config:
    layers = {} if no_config else load_workspace_config_layers(root, explicit_path)
    return build_config(load_packaged_defaults(), layers, default_report_title_for_root(root))
```

Move the bodies of the eight classification functions onto `Config` methods, replacing each global with the matching `self.` field, and move the `filter_signature` payload construction to `Config.signature` unchanged. Keep `path_parts` as a module function.

- [ ] **Step 4: Run the tests**

Run: `PYTHONPATH=src python3 -m unittest tests.test_cli -k config_ -v`
Expected: PASS.

- [ ] **Step 5: Commit** `refactor: add immutable Config carrying counting policy`.

### Task 8: Thread `Config`, delete the globals

**Files:**
- Modify: `src/source_tempo/cli.py`, `tests/test_cli.py`

**Interfaces:**
- Consumes: `Config` and its methods (Task 7).
- Produces new signatures:
  - `list_repos(root, config, include_vendor=False, include_non_product=False)`
  - `partition_skipped_repos(root, config, skipped_repos)`
  - `count_snapshot(repo, commit, config, include_vendor=False)`
  - `collect_churn_by_period(repo, config, include_vendor=False, rev_range=None, report_tz=None, include_docs=True, period="month")`
  - `collect_churn_cached(...)` gains `config` as its first policy argument, passed through to `collect_churn_by_period`
  - `snapshot_cache_key(label, commit, config, include_vendor)` and `churn_cache_key(label, config, include_vendor, report_tz, period)` if they call `signature` (verify by reading them; they call `filter_signature` today, so they take `config`)
  - `_snapshot_task(args: tuple[str, str, bool, Config])`
  - `build_report_data` / `_render_html` keep taking the scalar `report_title` and are not given `Config`.

- [ ] **Step 1: Migrate callers**

Callers, from `grep -nw`: `language_for_path` (720, 852), `documentation_language_for_path` (730, 856), `is_doc_only_repo` (855, 863, 928), `doc_only_artifact_language_for_path` (854), `source_kind_for_path` (874, 933), `is_generated_or_minified` (718, 728), `should_count_path` (860, 863, 928, 932), `should_count_documentation_path` (862, 934), `filter_signature` (599, 603), `effective_extra_repos` (768, 782, 2379). Convert each to the `config.` method or field and add the parameter to the enclosing function. Replace `effective_extra_repos()` with `config.extra_repos`, and the `EXCLUDE_SUBMODULES`/`EXCLUDE_DIRS`/`VENDOR_DIRS` reads in `list_repos` and `partition_skipped_repos` with the matching `config.` fields.

- [ ] **Step 2: Rewrite `main`**

Replace the `global REPORT_TITLE` block and the `apply_workspace_config(...)` call with:

```python
    try:
        config = load_config(root, explicit_config_path, args.no_config)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
```

Pass `config` to `list_repos`, `partition_skipped_repos`, `collect_churn_cached`, `count_snapshot`, and into the `_snapshot_task` argument tuple in place of `workspace_config`; pass `report_title=config.report_title` to `build_report_data`. `--init-config` still writes `default_config_data(default_report_title_for_root(root))`.

- [ ] **Step 3: Delete the globals**

Delete every policy constant definition and `_DEFAULTS` from module scope, `apply_workspace_config`, `effective_extra_repos`, the module-level `REPORT_TITLE` mutation, and the `global` statements. `SOURCE_KINDS`, `CONFIG_SCHEMA_VERSION`, and `REPORT_SCHEMA_VERSION` remain.

Run: `git grep -nE "^\s*global " -- src`
Expected: no output.

- [ ] **Step 4: Migrate the tests**

Tests that reload the module for policy or assign policy globals (`DOC_ONLY_REPO_NAMES`, `EXCLUDE_SUBMODULES`, `EXTRA_REPOS`, `REPORT_TITLE`; about 30 references) build a config instead:

```python
config = dataclasses.replace(tempo.default_config(), doc_only_repo_names=frozenset({"documentation"}))
snap = tempo.count_snapshot(repo, commit, config)
```

Calls to the changed signatures pass `tempo.default_config()` where they passed nothing. `test_doc_only_repo_names_participate_in_cache_signature` compares `default_config().signature(False)` with a `replace`d config's. Drop `try/finally` global restoration.

- [ ] **Step 5: Add the report-equivalence and parallel tests**

```python
    def test_workers_and_serial_runs_report_identically(self) -> None:
        tempo = load_script("tempo_workers_equivalence_test", "src/source_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "fixture"
            repo.mkdir()
            git = lambda *args, **kw: subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True, **kw)
            git("init", "-b", "main")
            git("config", "user.email", "test@example.com")
            git("config", "user.name", "Test User")
            git("config", "commit.gpgsign", "false")
            (repo / "src").mkdir()
            (repo / "tests").mkdir()
            (repo / "src" / "app.py").write_text("print('one')\n", encoding="utf-8")
            (repo / "tests" / "test_app.py").write_text("def test_one():\n    assert True\n", encoding="utf-8")
            git("add", ".")
            git("commit", "-m", "initial")

            def run_report(workers: int) -> dict:
                json_path = Path(tmp) / f"workers-{workers}.json"
                argv = [
                    "source-tempo", "--root", str(repo), "--period", "day", "--days", "3",
                    "--workers", str(workers), "--no-cache", "--no-html", "--json", str(json_path),
                ]
                with mock.patch.object(sys, "argv", argv), redirect_stdout(io.StringIO()):
                    self.assertEqual(tempo.main(), 0)
                document = json.loads(json_path.read_text(encoding="utf-8"))
                document.pop("generatedAt")
                return document

            self.assertEqual(run_report(1), run_report(2))
```

Keep the existing fixture test unchanged; this test builds its own small repository.

- [ ] **Step 6: Prove equivalence with the pre-change code**

Run the CLI from `main` and from the branch on this repository with `--no-cache --json` to two files under the scratchpad, remove `generatedAt` from both, and diff them.
Expected: identical.

- [ ] **Step 7: Spawn check**

Run the `--workers 2` test with `multiprocessing.set_start_method("spawn", force=True)` in a subprocess (macOS default).
Expected: PASS.

- [ ] **Step 8: Run the full suite and commit** `refactor: pass Config explicitly instead of mutating globals`.

### Task 9: Update docs and ship PR 2

- [ ] **Step 1:** Update `docs/architecture.md` (configuration section) to say the policy is an immutable `Config` loaded once per run. Commit, push, draft PR, self pre-pass, `independent-review --pr <n> --round 1/3 --tier standard` (use `--tier heavy` if the diff exceeds the smell threshold), fix, merge.

---

# PR 3: Strict, versioned configuration

Branch `refactor/config-schema-v2`, from `main` after PR 2 lands.

### Task 10: Per-layer validation and version-specific allowlists

**Files:**
- Modify: `src/source_tempo/cli.py`, `tests/test_cli.py`

**Interfaces:**
- Consumes: `build_config`, `load_config`, `default_config` (PR 2).
- Produces: `validate_layer(raw: dict, source: str) -> dict` returning the layer without `schema_version`; `CONFIG_KEYS_V1: frozenset[str]` (today's keys plus `report_title`); `CONFIG_KEYS_V2 = CONFIG_KEYS_V1 | {"test_file_markers"}`; `SUPPORTED_CONFIG_VERSIONS = (1, 2)`.

- [ ] **Step 1: Write the failing tests** (one per row of the version matrix, each writing files into a temporary git repository and calling `tempo.load_config`)

```python
    def test_config_version_matrix(self) -> None:
        tempo = load_script("tempo_version_matrix_test", "src/source_tempo/cli.py")
        cases = [
            ("missing version, v1 keys", {"test_dir_names": ["checks"]}, None),
            ("v1 with test_file_markers", {"schema_version": 1, "test_file_markers": [".t."]}, "test_file_markers"),
            ("missing version with test_file_markers", {"test_file_markers": [".t."]}, "test_file_markers"),
            ("v2 with test_file_markers", {"schema_version": 2, "test_file_markers": [".t."]}, None),
            ("unknown key", {"schema_version": 1, "test_dir_name": ["checks"]}, "test_dir_name"),
            ("unsupported version", {"schema_version": 3}, "schema_version"),
            ("bad type", {"schema_version": 1, "test_dir_names": "checks"}, "test_dir_names"),
        ]
        for label, layer, expected_error in cases:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                (root / ".source-tempo.json").write_text(json.dumps(layer), encoding="utf-8")
                if expected_error is None:
                    tempo.load_config(root, None, False)
                else:
                    with self.assertRaisesRegex(ValueError, expected_error):
                        tempo.load_config(root, None, False)

    def test_bad_tracked_layer_is_not_masked_by_a_good_local_layer(self) -> None:
        tempo = load_script("tempo_masking_test", "src/source_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".source-tempo.json").write_text(json.dumps({"schema_version": 3}), encoding="utf-8")
            (root / ".source-tempo.local.json").write_text(json.dumps({"schema_version": 1}), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "schema_version"):
                tempo.load_config(root, None, False)

    def test_v1_layer_may_overlay_v2_defaults(self) -> None:
        tempo = load_script("tempo_v1_over_v2_test", "src/source_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".source-tempo.json").write_text(json.dumps({"test_dir_names": ["checks"]}), encoding="utf-8")
            config = tempo.load_config(root, None, False)
            self.assertEqual(config.test_dir_names, frozenset({"checks"}))
            self.assertEqual(config.test_file_markers, tempo.default_config().test_file_markers)
```

- [ ] **Step 2: Run to see them fail.** Expected: FAIL (no `test_file_markers`, no strictness).

- [ ] **Step 3: Implement.** `validate_layer` reads `schema_version` (missing means 1), raises `ValueError(f"unsupported config schema_version {v!r} in {source}")` when not in `SUPPORTED_CONFIG_VERSIONS`, raises `ValueError(f"unknown config key {key!r} in {source}")` for any key outside that version's allowlist (so `test_file_markers` in a v1 layer reports the key name), and returns the layer without `schema_version`. `load_workspace_config_layers` returns the list of `(source_path, raw_layer)` pairs; `load_config` validates each layer before overlaying them in order onto the packaged defaults (which are v2). `build_config` no longer checks versions.

- [ ] **Step 4: Run the matrix tests.** Expected: PASS.

- [ ] **Step 5: Commit** `feat: validate each config layer against its schema version`.

### Task 11: `test_file_markers`, schema v2, cache signature

**Files:**
- Modify: `src/source_tempo/defaults.json`, `src/source_tempo/cli.py`, `tests/test_cli.py`, `README.md`, `docs/architecture.md`

- [ ] **Step 1: Write the failing tests**

```python
    def test_test_file_markers_are_configurable(self) -> None:
        tempo = load_script("tempo_markers_test", "src/source_tempo/cli.py")
        base = tempo.default_config()
        self.assertEqual(base.source_kind_for_path("a/widget.spec.ts"), "test")
        custom = dataclasses.replace(base, test_file_markers=(".check.",))
        self.assertEqual(custom.source_kind_for_path("a/widget.spec.ts"), "code")
        self.assertEqual(custom.source_kind_for_path("a/widget.check.ts"), "test")

    def test_signature_payload_is_old_payload_plus_markers(self) -> None:
        tempo = load_script("tempo_signature_v2_test", "src/source_tempo/cli.py")
        payload = tempo.default_config().signature_payload(include_vendor=False)
        self.assertEqual(payload["test_file_markers"], [".test.", ".spec.", ".e2e.", ".cy."])
        self.assertEqual(
            tempo.default_config().signature(include_vendor=False),
            "PIN_HASH",  # replace PIN_HASH with the value the first run prints, then re-run
        )
```

Compute the hash once with the implemented code, paste it into the test, and confirm the payload with `test_file_markers` removed still hashes to `d1d7d3a40ab93799`.

- [ ] **Step 2: Implement.** Add `"test_file_markers": [".test.", ".spec.", ".e2e.", ".cy."]` and set `schema_version` to `2` in `defaults.json`; add the `test_file_markers: tuple[str, ...]` field; replace the literal tuple in `source_kind_for_path` with `self.test_file_markers`; split `Config.signature` into `signature_payload` (the dict) and `signature` (its hash) and include the new key; set `CONFIG_SCHEMA_VERSION = 2` for what `--init-config` writes. `CACHE_SCHEMA_VERSION` is unchanged.

- [ ] **Step 3: Run the full suite.** Expected: PASS, including PR 1's parity test updated to expect the new key.

- [ ] **Step 4: Docs and release note.** In `README.md` and `docs/architecture.md`, document the version matrix, that unknown keys are errors, and that a version-2 file is rejected by older installations. Add a "Changes" entry stating that existing caches are recomputed once and that config files declaring `schema_version: 2` require this version or newer.

- [ ] **Step 5: Commit** `feat: make test-file markers configurable under config schema 2`.

### Task 12: Ship PR 3

- [ ] **Step 1:** Push, draft PR, self pre-pass, `independent-review --pr <n> --round 1/3 --tier heavy` (public config contract), fix, merge. Update `docs/data-driven-config/design.md` status if any decision moved.
