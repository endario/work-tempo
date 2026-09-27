# Remote-Main Collection and Cutoff Cache Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement sequentially; each task begins with a failing test. Review source selection and cutoff caching separately if the whole-diff gate does not converge.

**Goal:** Measure every counted repository at its best-effort-fetched `origin/main` tip and eliminate per-cutoff Git subprocesses on warm refreshes.

**Architecture:** The Python collector fetches and pins one source OID per repository, passes it through churn and snapshot lookup, and aborts report publication on collection errors. Its private cache uses a repository identity in every key and memoizes cutoff answers under the pinned OID. Additive report provenance lets the macOS app show fetch fallbacks.

**Tech Stack:** Python 3.10+ standard library, Git 2.30+, Swift 6/macOS 14+.

**Spec:** [design.md](design.md)

**Execution note:** Local Adastra runs showed sequential network attempts dominated warm refreshes, so fetching now uses bounded four-way concurrency. The process-group cancellation and HTML fallback notice were added after executable regression tests. See the design for measured outcomes.

## Global constraints

- No Python runtime dependencies; no Git operation reads the checked-out HEAD for metrics.
- Fetch `+refs/heads/main:refs/remotes/origin/main` with 8-second per-repo and 45-second per-workspace limits; preserve the last-fetched ref on failure.
- A counted repo without `origin/main` fails the whole collection; no local-HEAD fallback or partial report.
- Cache schema 5, additive report schema 1 metadata, old saved reports still decode.
- Existing snapshot and churn definitions stay unchanged; source selection changes, not metric formulas.
- Run Python/Swift suites and local Git-fixture E2E before `/ship`.

## Review focus

- Remote rewinds: a force-push updates the tracking ref and forces a full churn rescan (Task 1/2).
- A fetch timeout or cancellation leaves no child Git/SSH process and falls back to the stored ref (Task 1).
- A lookup/counting failure after source capture leaves the last JSON/HTML report intact (Task 3).
- An old display label reused for a different checkout cannot reuse churn or snapshot counts (Task 2/3).
- A successful report produced from a last-fetched ref visibly warns in individual and aggregate app scopes (Task 4).

---

### Task 1: Bounded source fetch and pinning

**Files:** Modify `src/work_tempo/cli.py` (Git helpers near `git_head`); test `tests/test_cli.py`.

**Interfaces:** `fetch_source(repo: Path, timeout_seconds: float) -> str` returns `fetched`, `failed`, or `timed_out`; `source_oid(repo: Path) -> str` resolves `refs/remotes/origin/main` or raises a sanitized error. A workspace-level caller tracks 45 seconds and marks unattempted repos `budget_skipped`.

- [ ] Add a temporary bare remote fixture with distinct local HEAD and remote main. Add failing tests: force-push the bare main and assert `fetch_source` moves `origin/main` backwards; a failing fetch returns failure and leaves the old OID; a missing ref raises without using HEAD.
- [ ] Run `PYTHONPATH=src python3 -m unittest tests.test_cli -q`; confirm failures are missing source helpers, not fixture setup.
- [ ] Implement the helper using a forcing refspec, `GIT_TERMINAL_PROMPT=0`, disabled askpass, stdin `/dev/null`, bounded four-way fetching and POSIX process-group termination on timeout/cancel. Do not expose raw stderr or remote URLs. Preserve Windows direct-child timeout semantics explicitly.
- [ ] Add a stalling local transport test that checks the fetch timeout and child cleanup, plus a workspace budget/rotation test using a short real deadline. Check `--no-cache` does not persist a cursor.
- [ ] Run the targeted tests until green, then the full Python suite.

### Task 2: Remote-tip churn and repository-safe cache identity

**Files:** Modify `src/work_tempo/cli.py` (`collect_churn_by_period`, `collect_churn_cached`, cache helpers, `main`); test `tests/test_cli.py`.

**Interfaces:** Resolve all source OIDs before collection; `collect_churn_by_period(..., revision: str, rev_range: str | None = None)` always appends the pinned OID or range to Git log; `collect_churn_cached(..., source_oid: str, repo_identity: str, ...)` keys by identity plus policy/timezone/period. `repository_identity(repo: Path) -> str` includes resolved checkout path and Git directory.

- [ ] Add failing tests with local HEAD ahead of `origin/main`: cold and warm churn exclude HEAD-only changes; a force-pushed remote ref rescans; a fast-forward delta uses `old_oid..new_oid` rather than `old_oid..HEAD`. Include two repos with the same display label and distinct identities.
- [ ] Run the targeted unittest cases and confirm old HEAD-based behavior fails them.
- [ ] Implement source capture, Git log revision arguments, incremental ranges, identity-based churn keys and cache schema 5. Reuse the pinned OID in every branch, including `--no-cache`.
- [ ] Run targeted tests and the full Python suite. Keep the first-run cold cache behavior explicit in CLI output.

### Task 3: Snapshot source and publication invariant

**Files:** Modify `src/work_tempo/cli.py` (`find_commit_at`, snapshot cache key, `main`, snapshot workers); test `tests/test_cli.py`.

**Interfaces:** `find_commit_at(repo: Path, cutoff_iso: str, source_oid: str) -> str | None`; snapshot keys include `repository_identity`, commit and counting policy. Errors from churn, cutoff lookup, archive or worker count abort before HTML/JSON writes.

- [ ] Add failing end-to-end tests where local HEAD and remote main contain different source LOC; assert all snapshot and churn totals follow remote main in serial and parallel modes. Seed existing HTML/JSON outputs, inject each Git failure in turn, and assert nonzero exit plus unchanged files. Assert a counted submodule with no remote-main ref fails as a whole.
- [ ] Run the targeted tests; verify they expose HEAD snapshot selection and partial-report publication.
- [ ] Route each cutoff query through the pinned OID. Replace warn-and-continue branches with a sanitized fatal error; wait for all worker results before writing either output. Keep atomic report writes.
- [ ] Run targeted and full Python suites; check old schema-4 data starts cold without parsing errors.

### Task 4: Provenance and visible fallback

**Files:** Modify `src/work_tempo/cli.py` (`ReportInput`, `build_report_data`, CLI summary); `macos/Sources/WorkTempoCore/ReportDocument.swift`, `DashboardSnapshot.swift`, `PortfolioMomentum.swift`; test `tests/test_cli.py`, `macos/Tests/WorkTempoCoreTests/ReportDocumentTests.swift`, `AppSnapshotModelTests.swift`, `PortfolioMomentumTests.swift`.

**Interfaces:** Each `scope.repositories` entry gains optional `sourceRef`, `sourceOid`, `fetchOutcome`; old reports decode with nil fields. Dashboard notices append fetch fallback to existing portfolio warning.

- [ ] Add failing Python assertions for per-repo source OID/ref/outcome on fetched, failed and budget-skipped runs; ensure reports do not contain raw fetch stderr. Add Swift decode and individual/aggregate notice tests, including an existing aggregate warning.
- [ ] Run the targeted Python and Swift tests and confirm missing metadata/notice failures.
- [ ] Thread source provenance into the report, decode optional Swift fields, and reuse the existing notice banner. Do not change JSON schema version or add a new UI surface.
- [ ] Run full Python and Swift suites and `swift build -c release` in `macos/`.

### Task 5: Persistent cutoff memo and CLI timings

**Files:** Modify `src/work_tempo/cli.py` (schema-5 cache and snapshot loop); test `tests/test_cli.py`.

**Interfaces:** `commit_at[repo_identity] = {source_oid, cutoffs: {exact_iso: commit_or_null}}`; `cached_commit_at(repo, cutoff, source_oid, identity, cache) -> (str | None, bool)` uses a cached null as a hit and never caches Git errors.

- [ ] Add failing tests for zero cutoff Git calls on the second run; cached null; new cutoff; changed source OID with a backdated commit; a ref moving mid-query; `--no-cache`; old schema-5 cache without the optional section.
- [ ] Run targeted tests and verify the warm-run Git-call assertion fails against current code.
- [ ] Implement the lookup memo and checkpoint it after the lookup pass, before snapshot workers. Query the captured OID on misses, not the moving ref. Print cutoff hit/miss and fetch/lookup elapsed times in CLI output.
- [ ] Run targeted and full Python suites. Benchmark warm Adastra runs with an isolated cache, recording total, fetch and cutoff timings without a CI timing assertion.

### Task 6: Documentation and local E2E

**Files:** Modify `README.md`, `docs/architecture.md`, `docs/macos-app.md`, and `docs/cache/design.md` where implementation differs; retain this plan as execution record.

- [ ] Document the strict `origin/main` requirement and remedies for local-only/master-default repos; describe best-effort fetch, fallback provenance and cache schema cold start. Put any release note in the release/PR narrative; the repo has no changelog file.
- [ ] Run `PYTHONPATH=src python3 -m unittest discover -s tests -v`, `python3 -m compileall -q src tests`, `cd macos && swift test && swift build -c release`.
- [ ] Run a local bare-remote E2E: cold, warm, remote advance, remote rewind, forced fetch failure, and missing-ref failure; compare JSON to hand-derived totals and inspect notice data. Run the source CLI against Adastra with an isolated cache/output path, then repeat for a warm measurement. Do not use `--clear-cache` on the user's app cache.
- [ ] Inspect the final diff and run `/code-review` self pre-pass, then the mandatory independent review. Invoke `/ship` only after local verification succeeds.
