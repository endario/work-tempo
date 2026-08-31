# SourceTempo Extraction Implementation Plan

**Goal:** Extract the reusable LOC history collector into a private, installable personal repository that tracks source momentum across configurable Git roots.

**Architecture:** Preserve the proven collector in one standard-library Python module behind package entry points. Rename tool-owned configuration and artifacts, move defaults into workspace-safe user cache storage, and verify metrics with focused unit tests plus a hand-computed Git fixture.

**Tech Stack:** Python 3.10+, Git 2.30+, `unittest`, GitHub Actions.

**Spec:** `docs/architecture/design.md`

## Global Constraints

- Runtime dependencies are limited to the Python standard library and Git executable.
- No Adastra, QuikSync, or Open-RMF scope or branding may remain outside the provenance note.
- Repository comparison and component classification are excluded.
- The repository remains private and carries no open-source license during extraction.
- HTML and JSON must adapt the same strict-JSON-safe report document.

## Task 1: Package And Provenance

**Files:**
- Create `pyproject.toml`
- Create `src/source_tempo/__init__.py`
- Create `src/source_tempo/__main__.py`
- Create `src/source_tempo/cli.py`
- Create `PROVENANCE.md`
- Create `.gitignore`

**Produces:** `source-tempo` console entry point and `python -m source_tempo` module entry point, both calling `source_tempo.cli.main() -> int`.

- [ ] Copy the merged generic collector into `src/source_tempo/cli.py`.
- [ ] Rename report, configuration, cache, and default output identities to SourceTempo.
- [ ] Default `--root` to `Path.cwd()` at invocation time.
- [ ] Record the source revision and excluded migration scope in `PROVENANCE.md`.
- [ ] Add package metadata without an open-source license declaration.
- [ ] Verify `PYTHONPATH=src python -m source_tempo --help` exits successfully.

## Task 2: Safe Artifacts And Strict Report Data

**Files:**
- Modify `src/source_tempo/cli.py`
- Create `tests/test_cli.py`

**Produces:** `workspace_artifact_dir(root: Path) -> Path`, `default_cache_path(root: Path) -> Path`, and `default_html_path(root: Path) -> Path`.

- [ ] Add failing tests asserting macOS and XDG cache roots are outside the analyzed repository and isolated by canonical workspace path.
- [ ] Implement user-cache path resolution and workspace-key derivation.
- [ ] Change CLI `--html` handling so omission selects the workspace-specific default while `--no-html` disables HTML output.
- [ ] Change the cache default to the same workspace-specific artifact directory.
- [ ] Add a failing test that report data serializes using `json.dumps(document, allow_nan=False)`.
- [ ] Make JSON and embedded HTML payload serialization reject non-finite values.
- [ ] Run `python -m unittest tests.test_cli -v`.

## Task 3: Generic Configuration And Collector Contracts

**Files:**
- Modify `tests/test_cli.py`
- Modify `src/source_tempo/cli.py` only where extracted assumptions fail.

**Produces:** Portable contracts for layered configuration, repo discovery, source/test/docs classification, timeline rendering, forecasting, atomic writes, and worktree handling.

- [ ] Port the generic LOC-history tests and replace file-loader imports with `from source_tempo import cli` or isolated module reloads where global configuration is mutated.
- [ ] Remove every comparison test and every Adastra workspace-policy assertion.
- [ ] Assert built-in defaults contain no organization-specific repositories or exclusions.
- [ ] Assert tracked configuration loads before the local or explicit override layer and lists replace earlier lists.
- [ ] Run the complete unit suite and fix only portability regressions.

## Task 4: Hand-Computed Git Fixture

**Files:**
- Modify `tests/test_cli.py`

**Produces:** An end-to-end fixture whose expected LOC and churn totals are derived directly from committed file contents.

- [ ] Create a temporary Git repository with dated commits containing one Python source file, one Python test file, and one Markdown document.
- [ ] Invoke `cli.main()` with daily bucketing, one worker, no cache, and explicit temporary HTML and JSON paths.
- [ ] Assert exact source LOC, test LOC, documentation LOC, additions, deletions, and churn values in the JSON document.
- [ ] Invoke a cached run twice and assert equivalent metric and breakdown sections.
- [ ] Change a counting-policy configuration value and assert the cached run reflects the new policy.
- [ ] Run the complete unit suite.

## Task 5: User Documentation And CI

**Files:**
- Create `README.md`
- Create `.github/workflows/test.yml`
- Create `examples/source-tempo.json`
- Modify `.gitignore`

**Produces:** Install, configuration, execution, cache-clearing, and report-consumption guidance.

- [ ] Document editable installation and direct module invocation.
- [ ] Document single-root, submodule, and configured extra-root operation.
- [ ] Document code/test/docs metric semantics and current-timezone bucketing.
- [ ] Generate the example configuration from `--init-config`, then remove all machine-specific paths.
- [ ] Add CI for supported Python versions using `python -m unittest discover -s tests -v`.
- [ ] Run a case-insensitive tree scan for prohibited product-specific terms, allowing only `PROVENANCE.md` and architecture records.

## Task 6: Repository Publication

**Files:**
- No product files beyond verified fixes.

**Produces:** Private `endario-org/source-tempo` repository with reviewed initial commit on `main`.

- [ ] Run unit tests, module compilation, CLI help, and a representative report against the SourceTempo repository itself.
- [ ] Inspect generated HTML in a browser and verify title, charts, and artifact path.
- [ ] Commit with accurate Codex assistance attribution.
- [ ] Create the private GitHub repository in `endario-org` using the `endario` account token without changing the global GitHub CLI account.
- [ ] Push a feature branch, open a PR, run independent review, and address verified findings.
- [ ] Merge the PR and verify the local `main` branch matches the remote default branch.
