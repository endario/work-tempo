#!/usr/bin/env python3
"""Focused contracts for SourceTempo collection and reporting."""

from __future__ import annotations

import importlib.util
import io
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock
from zoneinfo import ZoneInfo


REPO_ROOT = Path(__file__).resolve().parents[1]


def load_script(name: str, rel_path: str):
    path = REPO_ROOT / rel_path
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def make_report_document(
    tempo,
    labels,
    loc_series,
    doc_loc_series,
    churn_series,
    doc_churn_series,
    added_series,
    deleted_series,
    loc_kind_series,
    churn_kind_series,
    added_kind_series,
    deleted_kind_series,
    language_series,
    repo_loc,
    language_loc,
    skipped_partition,
    include_vendor,
    report_tz,
    period,
    include_forecast=False,
    now=None,
):
    generated_at = now or datetime.now(report_tz)
    return tempo.build_report_data(
        tempo.ReportInput(
            root=REPO_ROOT,
            report_title=tempo.REPORT_TITLE,
            generated_at=generated_at,
            report_tz=report_tz,
            period=period,
            labels=labels,
            loc_series=loc_series,
            doc_loc_series=doc_loc_series,
            churn_series=churn_series,
            doc_churn_series=doc_churn_series,
            doc_added_series=doc_churn_series,
            doc_deleted_series=[0] * len(doc_churn_series),
            added_series=added_series,
            deleted_series=deleted_series,
            loc_kind_series=loc_kind_series,
            churn_kind_series=churn_kind_series,
            added_kind_series=added_kind_series,
            deleted_kind_series=deleted_kind_series,
            language_series=language_series,
            repo_loc=[
                (label, label, lines, docs, code, test, f"{label}-commit")
                for label, lines, docs, code, test in repo_loc
            ],
            language_loc=language_loc,
            skipped_partition=skipped_partition,
            include_vendor=include_vendor,
            include_non_product=False,
            include_forecast=include_forecast,
        )
    )


class LocAnalysisScriptTest(unittest.TestCase):
    def test_generic_defaults_have_no_workspace_specific_scope(self) -> None:
        tempo = load_script(
            "tempo_generic_defaults_test",
            "src/source_tempo/cli.py",
        )

        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(tempo.EXCLUDE_SUBMODULES, set())
            self.assertEqual(tempo.effective_extra_repos(), [])
            self.assertEqual(tempo.CONFIG_FILENAME, ".source-tempo.json")
            self.assertEqual(tempo.LOCAL_CONFIG_FILENAME, ".source-tempo.local.json")

    def test_workspace_artifacts_use_isolated_user_cache_paths(self) -> None:
        tempo = load_script("tempo_artifact_paths_test", "src/source_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            cache_root = Path(tmp) / "cache"
            first = Path(tmp) / "first"
            second = Path(tmp) / "second"
            first.mkdir()
            second.mkdir()

            with mock.patch.dict(
                os.environ,
                {"SOURCE_TEMPO_CACHE_HOME": str(cache_root)},
                clear=False,
            ):
                first_dir = tempo.workspace_artifact_dir(first)
                second_dir = tempo.workspace_artifact_dir(second)

                self.assertEqual(first_dir.parent, cache_root.resolve())
                self.assertEqual(tempo.default_cache_path(first).name, "cache.json")
                self.assertEqual(tempo.default_html_path(first).name, "report.html")
            self.assertNotEqual(first_dir, second_dir)
            self.assertNotEqual(first_dir, first)

    def test_default_report_title_uses_workspace_directory_name(self) -> None:
        tempo = load_script(
            "tempo_generic_title_test",
            "src/source_tempo/cli.py",
        )

        self.assertEqual(
            tempo.default_report_title_for_root(Path("/tmp/example-workspace")),
            "example-workspace",
        )

    def test_active_timezone_uses_system_zone_name(self) -> None:
        tempo = load_script("tempo_timezone_test", "src/source_tempo/cli.py")
        with mock.patch.dict(os.environ, {"TZ": "Asia/Tokyo"}, clear=False):
            active_timezone = tempo.active_timezone()
            self.assertEqual(getattr(active_timezone, "key", None), "Asia/Tokyo")
            self.assertEqual(tempo.timezone_signature(active_timezone), "Asia/Tokyo")

    def test_workspace_config_layers_tracked_then_local(self) -> None:
        tempo = load_script(
            "tempo_layered_config_test",
            "src/source_tempo/cli.py",
        )
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / tempo.CONFIG_FILENAME).write_text(
                json.dumps({"report_title": "Shared", "extra_repos": []}),
                encoding="utf-8",
            )
            (root / tempo.LOCAL_CONFIG_FILENAME).write_text(
                json.dumps({"report_title": "Personal"}),
                encoding="utf-8",
            )

            self.assertEqual(
                tempo.load_workspace_config_layers(root),
                {"report_title": "Personal", "extra_repos": []},
            )

    def test_explicit_config_replaces_default_local_layer(self) -> None:
        tempo = load_script(
            "tempo_explicit_config_test",
            "src/source_tempo/cli.py",
        )
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            explicit = root / "personal.json"
            (root / tempo.CONFIG_FILENAME).write_text(
                json.dumps({"report_title": "Shared"}),
                encoding="utf-8",
            )
            (root / tempo.LOCAL_CONFIG_FILENAME).write_text(
                json.dumps({"report_title": "Ignored"}),
                encoding="utf-8",
            )
            explicit.write_text(json.dumps({"report_title": "Explicit"}), encoding="utf-8")

            self.assertEqual(
                tempo.load_workspace_config_layers(root, explicit),
                {"report_title": "Explicit"},
            )

    def test_effective_extra_repos_uses_workspace_config(self) -> None:
        tempo = load_script("tempo_effective_config_test", "src/source_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tempo.apply_workspace_config({
                "extra_repos": [
                    {"label": "companion", "path": "../companion"},
                    {"label": "embedded", "path": "embedded"},
                ],
            })

            self.assertEqual(
                tempo.effective_extra_repos(),
                [
                    {"label": "companion", "path": "../companion"},
                    {"label": "embedded", "path": "embedded"},
                ],
            )

    def test_list_repos_keeps_non_product_submodules_out_and_adds_extra_repo(self) -> None:
        tempo = load_script("tempo_repos_test", "src/source_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            root = tmp_path / "workspace"
            root.mkdir()
            bridge = root / "modules" / "core"
            cockpit = root / "modules" / "prototype"
            launchpad = root / "modules" / "demo"
            status = root / "modules" / "status-site"
            consult = tmp_path / "companion"
            embedded = root / "embedded"
            for path in (bridge, cockpit, launchpad, status, consult, embedded):
                path.mkdir(parents=True)

            def fake_run(cmd, cwd=None):
                if cmd == [
                    "git",
                    "config",
                    "--file",
                    ".gitmodules",
                    "--get-regexp",
                    r"^submodule\..*\.path$",
                ]:
                    return "\n".join(
                        [
                            "submodule.bridge.path modules/core",
                            "submodule.modules/prototype.path modules/prototype",
                            "submodule.modules/demo.path modules/demo",
                            "submodule.modules/status-site.path modules/status-site",
                        ]
                    )
                if cmd == ["git", "remote", "get-url", "origin"] and cwd == root:
                    return "git@github.com:example/workspace.git"
                if (
                    cmd == ["git", "rev-parse", "--show-toplevel"]
                    and cwd is not None
                    and cwd.resolve() in {
                        bridge.resolve(),
                        cockpit.resolve(),
                        launchpad.resolve(),
                        status.resolve(),
                        consult.resolve(),
                        embedded.resolve(),
                    }
                ):
                    return str(cwd)
                return ""

            original_run = tempo.run
            original_extra_repos = tempo.EXTRA_REPOS
            original_excluded_submodules = tempo.EXCLUDE_SUBMODULES
            try:
                tempo.run = fake_run
                tempo.EXTRA_REPOS = [
                    {"label": "companion", "path": "../companion"},
                    {"label": "embedded", "path": "embedded"},
                ]
                tempo.EXCLUDE_SUBMODULES = {
                    "modules/prototype",
                    "modules/demo",
                    "modules/status-site",
                }
                repos, skipped = tempo.list_repos(root)
            finally:
                tempo.run = original_run
                tempo.EXTRA_REPOS = original_extra_repos
                tempo.EXCLUDE_SUBMODULES = original_excluded_submodules

            self.assertEqual(
                [label for label, _path in repos],
                ["(parent)", "modules/core", "companion", "embedded"],
            )
            self.assertIn("modules/prototype", skipped)
            self.assertIn("modules/demo", skipped)
            self.assertIn("modules/status-site", skipped)

    def test_list_repos_deduplicates_repeated_gitmodules_paths(self) -> None:
        tempo = load_script("tempo_duplicate_gitmodules_test", "src/source_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "workspace"
            bridge = root / "modules" / "core"
            bridge.mkdir(parents=True)

            def fake_run(cmd, cwd=None):
                if cmd == [
                    "git",
                    "config",
                    "--file",
                    ".gitmodules",
                    "--get-regexp",
                    r"^submodule\..*\.path$",
                ]:
                    return "\n".join(
                        [
                            "submodule.bridge.path modules/core",
                            "submodule.bridge.path modules/core",
                        ]
                    )
                if (
                    cmd == ["git", "rev-parse", "--show-toplevel"]
                    and cwd is not None
                    and cwd.resolve() == bridge.resolve()
                ):
                    return str(cwd)
                return ""

            original_run = tempo.run
            original_extra_repos = tempo.EXTRA_REPOS
            try:
                tempo.run = fake_run
                tempo.EXTRA_REPOS = []
                repos, skipped = tempo.list_repos(root)
            finally:
                tempo.run = original_run
                tempo.EXTRA_REPOS = original_extra_repos

        self.assertEqual([label for label, _path in repos], ["(parent)", "modules/core"])
        self.assertEqual(skipped, [])

    def test_list_repos_skips_missing_gitmodules_path(self) -> None:
        tempo = load_script("tempo_missing_gitmodules_path_test", "src/source_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "workspace"
            root.mkdir()

            def fake_run(cmd, cwd=None):
                if cmd == [
                    "git",
                    "config",
                    "--file",
                    ".gitmodules",
                    "--get-regexp",
                    r"^submodule\..*\.path$",
                ]:
                    return "submodule.bridge.path modules/core"
                return ""

            original_run = tempo.run
            original_extra_repos = tempo.EXTRA_REPOS
            try:
                tempo.run = fake_run
                tempo.EXTRA_REPOS = []
                repos, skipped = tempo.list_repos(root)
            finally:
                tempo.run = original_run
                tempo.EXTRA_REPOS = original_extra_repos

        self.assertEqual([label for label, _path in repos], ["(parent)"])
        self.assertEqual(skipped, ["modules/core"])

    def test_extra_repo_must_be_repo_root_not_plain_subdirectory(self) -> None:
        tempo = load_script("tempo_extra_repo_root_test", "src/source_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "repo"
            nested = root / "nested" / "companion"
            nested.mkdir(parents=True)
            subprocess.run(["git", "init", str(root)], check=True, capture_output=True)

            original_extra_repos = tempo.EXTRA_REPOS
            try:
                tempo.EXTRA_REPOS = [{"label": "companion", "path": "nested/companion"}]
                repos, skipped = tempo.list_repos(root)
            finally:
                tempo.EXTRA_REPOS = original_extra_repos

        self.assertEqual([label for label, _path in repos], ["(parent)"])
        self.assertEqual(skipped, ["companion"])

    def test_partition_skipped_repos_separates_skip_reasons(self) -> None:
        tempo = load_script("tempo_partition_test", "src/source_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "workspace"
            root.mkdir()

            def fake_run(cmd, cwd=None):
                if cmd == [
                    "git",
                    "config",
                    "--file",
                    ".gitmodules",
                    "--get-regexp",
                    r"^submodule\..*\.path$",
                ]:
                    return "\n".join(
                        [
                            "submodule.vendor.path _vendor/json-render",
                            "submodule.status.path modules/status-site",
                            "submodule.bridge.path modules/core",
                        ]
                    )
                return ""

            original_run = tempo.run
            original_extra_repos = tempo.EXTRA_REPOS
            original_excluded_submodules = tempo.EXCLUDE_SUBMODULES
            try:
                tempo.run = fake_run
                tempo.EXTRA_REPOS = [{"label": "companion", "path": "../companion"}]
                tempo.EXCLUDE_SUBMODULES = {"modules/status-site"}

                partition = tempo.partition_skipped_repos(
                    root,
                    ["_vendor/json-render", "modules/status-site", "modules/core", "companion"],
                )
            finally:
                tempo.run = original_run
                tempo.EXTRA_REPOS = original_extra_repos
                tempo.EXCLUDE_SUBMODULES = original_excluded_submodules

        self.assertEqual(partition["vendor_like"], ["_vendor/json-render"])
        self.assertEqual(partition["non_product"], ["modules/status-site"])
        self.assertEqual(partition["unavailable_submodule"], ["modules/core"])
        self.assertEqual(partition["unavailable_extra"], ["companion"])

    def test_extra_repo_config_overrides_default_repo_discovery(self) -> None:
        tempo = load_script("tempo_config_roundtrip_test", "src/source_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            root = tmp_path / "workspace"
            consult = tmp_path / "companion"
            custom = tmp_path / "custom-consult"
            root.mkdir()
            consult.mkdir()
            custom.mkdir()

            def fake_run(cmd, cwd=None):
                if cmd == ["git", "remote", "get-url", "origin"] and cwd == root:
                    return "git@github.com:example/workspace.git"
                if (
                    cmd == ["git", "rev-parse", "--show-toplevel"]
                    and cwd is not None
                    and cwd.resolve() in {consult.resolve(), custom.resolve()}
                ):
                    return str(cwd)
                return ""

            original_run = tempo.run
            original_extra_repos = tempo.EXTRA_REPOS
            try:
                tempo.run = fake_run

                tempo.apply_workspace_config({"extra_repos": []})
                repos, skipped = tempo.list_repos(root)
                self.assertEqual([label for label, _path in repos], ["(parent)"])
                self.assertEqual(skipped, [])

                tempo.apply_workspace_config(
                    {"extra_repos": [{"label": "custom-consult", "path": "../custom-consult"}]}
                )
                repos, skipped = tempo.list_repos(root)
                self.assertEqual([label for label, _path in repos], ["(parent)", "custom-consult"])
                self.assertEqual(skipped, [])
            finally:
                tempo.run = original_run
                tempo.EXTRA_REPOS = original_extra_repos

    def test_report_document_is_raw_complete_and_instance_driven(self) -> None:
        tempo = load_script("tempo_report_document_test", "src/source_tempo/cli.py")
        report = tempo.ReportInput(
            root=Path("/tmp/workspace"),
            report_title="Fixture LOC",
            generated_at=datetime(2026, 8, 15, 9, 30, tzinfo=timezone.utc),
            report_tz=timezone.utc,
            period="month",
            labels=["2026-08"],
            loc_series=[30],
            doc_loc_series=[5],
            churn_series=[12],
            doc_churn_series=[2],
            doc_added_series=[1],
            doc_deleted_series=[1],
            added_series=[8],
            deleted_series=[4],
            loc_kind_series={"code": [20], "test": [10]},
            churn_kind_series={"code": [7], "test": [5]},
            added_kind_series={"code": [5], "test": [3]},
            deleted_kind_series={"code": [2], "test": [2]},
            language_series={"Python <&": [30]},
            repo_loc=[('repo <& "', "/tmp/workspace", 30, 5, 20, 10, "abc123")],
            language_loc=[("Python <&", 30)],
            skipped_partition={
                "vendor_like": [],
                "non_product": [],
                "unavailable_submodule": [],
                "unavailable_extra": [],
            },
            include_vendor=False,
            include_non_product=False,
            include_forecast=False,
        )
        tempo.REPORT_TITLE = "Mutated global"

        document = tempo.build_report_data(report)

        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(document["workspace"]["title"], "Fixture LOC")
        self.assertEqual(document["period"], {"kind": "month", "labels": ["2026-08"]})
        self.assertEqual(document["series"]["loc"], [30])
        self.assertEqual(document["series"]["docAdded"], [1])
        self.assertEqual(document["series"]["docDeleted"], [1])
        self.assertEqual(document["latest"]["repositories"][0]["commit"], "abc123")
        self.assertEqual(document["latest"]["repositories"][0]["label"], 'repo <& "')
        self.assertEqual(document["series"]["language"][0]["language"], "Python <&")
        self.assertEqual(document["forecast"], [])

    def test_html_adapter_escapes_raw_document_labels(self) -> None:
        tempo = load_script("tempo_html_escape_test", "src/source_tempo/cli.py")
        document = make_report_document(
            tempo,
            ["2026-08"],
            [30],
            [5],
            [12],
            [2],
            [8],
            [4],
            {"code": [20], "test": [10]},
            {"code": [7], "test": [5]},
            {"code": [5], "test": [3]},
            {"code": [2], "test": [2]},
            {"Python <&": [30]},
            [('repo <& "', 30, 5, 20, 10)],
            [("Python <&", 30)],
            {"vendor_like": [], "non_product": [], "unavailable_submodule": [], "unavailable_extra": []},
            False,
            timezone.utc,
            "month",
        )
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "report.html"
            tempo.write_html(out, document)
            html = out.read_text(encoding="utf-8")

        data_json = html.split("const DATA = ", 1)[1].split(";\n", 1)[0]
        data = json.loads(data_json)
        self.assertEqual(data["repoLoc"][0]["repo"], "repo &lt;&amp; &quot;")
        self.assertEqual(data["languageSeries"][0]["language"], "Python &lt;&amp;")
        self.assertNotIn('repo <& "', data_json)

    def test_write_json_replaces_the_report_atomically(self) -> None:
        tempo = load_script("tempo_json_write_test", "src/source_tempo/cli.py")
        document = {"schemaVersion": 1, "workspace": {"title": "Fixture"}}
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "reports" / "source-tempo.json"
            output.parent.mkdir()
            output.write_text('{"stale": true}\n', encoding="utf-8")
            output.chmod(0o640)

            tempo.write_json(output, document)

            self.assertEqual(json.loads(output.read_text(encoding="utf-8")), document)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o640)
            self.assertEqual(list(output.parent.iterdir()), [output])

    def test_write_json_uses_process_default_mode_for_new_file(self) -> None:
        tempo = load_script("tempo_json_mode_test", "src/source_tempo/cli.py")
        current_umask = os.umask(0)
        os.umask(current_umask)
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "source-tempo.json"

            tempo.write_json(output, {"schemaVersion": 1})

            self.assertEqual(
                stat.S_IMODE(output.stat().st_mode),
                0o666 & ~current_umask,
            )

    def test_report_outputs_reject_non_finite_values(self) -> None:
        tempo = load_script("tempo_strict_json_test", "src/source_tempo/cli.py")
        document = make_report_document(
            tempo,
            ["2026-08"],
            [10],
            [1],
            [2],
            [0],
            [1],
            [1],
            {"code": [8], "test": [2]},
            {"code": [1], "test": [1]},
            {"code": [1], "test": [0]},
            {"code": [0], "test": [1]},
            {"Python": [10]},
            [("repo", 10, 1, 8, 2)],
            [("Python", 10)],
            {
                "vendor_like": [],
                "non_product": [],
                "unavailable_submodule": [],
                "unavailable_extra": [],
            },
            False,
            timezone.utc,
            "month",
        )
        document["series"]["loc"] = [float("nan")]

        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):
                tempo.write_json(Path(tmp) / "report.json", document)
            with self.assertRaises(ValueError):
                tempo.write_html(Path(tmp) / "report.html", document)

    def test_git_failures_are_not_returned_as_empty_metrics(self) -> None:
        tempo = load_script("tempo_git_failure_test", "src/source_tempo/cli.py")

        archive_failure = subprocess.CompletedProcess(
            args=["git", "archive"],
            returncode=1,
            stdout=b"",
            stderr=b"missing object",
        )
        with mock.patch.object(tempo.subprocess, "run", return_value=archive_failure):
            with self.assertRaisesRegex(RuntimeError, "missing object"):
                tempo.count_snapshot(Path("/tmp/repo"), "deadbeef")

        churn_failure = subprocess.CompletedProcess(
            args=["git", "log"],
            returncode=1,
            stdout="",
            stderr="repository unavailable",
        )
        with mock.patch.object(tempo.subprocess, "run", return_value=churn_failure):
            with self.assertRaisesRegex(RuntimeError, "repository unavailable"):
                tempo.collect_churn_by_period(Path("/tmp/repo"))

        cache = tempo.empty_cache()
        with (
            mock.patch.object(tempo, "git_head", return_value="abc123"),
            mock.patch.object(
                tempo,
                "collect_churn_by_period",
                side_effect=RuntimeError("transient failure"),
            ),
        ):
            with self.assertRaisesRegex(RuntimeError, "transient failure"):
                tempo.collect_churn_cached(
                    "repo",
                    Path("/tmp/repo"),
                    False,
                    cache,
                    timezone.utc,
                    "month",
                )
        self.assertEqual(cache["churn_repos"], {})

    def test_cli_rejects_non_positive_worker_count(self) -> None:
        tempo = load_script("tempo_worker_validation_test", "src/source_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            subprocess.run(["git", "init", "-b", "main"], cwd=repo, check=True, capture_output=True)
            argv = ["source-tempo", "--root", str(repo), "--workers", "0", "--no-html"]
            stderr = io.StringIO()
            with mock.patch.object(sys, "argv", argv), mock.patch.object(sys, "stderr", stderr):
                self.assertEqual(tempo.main(), 1)
            self.assertIn("workers must be >= 1", stderr.getvalue())

    def test_atomic_write_removes_temporary_file_when_flush_fails(self) -> None:
        tempo = load_script("tempo_json_failure_test", "src/source_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "source-tempo.json"

            with mock.patch.object(tempo.os, "fsync", side_effect=OSError("disk full")):
                with self.assertRaises(OSError):
                    tempo.write_json(output, {"schemaVersion": 1})

            self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_html_generated_badge_preserves_named_timezone(self) -> None:
        tempo = load_script("tempo_html_timezone_test", "src/source_tempo/cli.py")
        tokyo = ZoneInfo("Asia/Tokyo")
        document = make_report_document(
            tempo,
            ["2026-08"],
            [30],
            [5],
            [12],
            [2],
            [8],
            [4],
            {"code": [20], "test": [10]},
            {"code": [7], "test": [5]},
            {"code": [5], "test": [3]},
            {"code": [2], "test": [2]},
            {"Python": [30]},
            [("repo", 30, 5, 20, 10)],
            [("Python", 30)],
            {"vendor_like": [], "non_product": [], "unavailable_submodule": [], "unavailable_extra": []},
            False,
            tokyo,
            "month",
            now=datetime(2026, 8, 31, 15, 46, tzinfo=tokyo),
        )
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "report.html"
            tempo.write_html(output, document)
            html = output.read_text(encoding="utf-8")

        self.assertIn("Generated 2026-08-31 15:46 JST", html)

    def test_cli_json_and_html_share_one_report_document(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "fixture"
            root.mkdir()
            subprocess.run(["git", "init", str(root)], check=True, capture_output=True)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.name", "Test User"], cwd=root, check=True)
            subprocess.run(["git", "config", "commit.gpgsign", "false"], cwd=root, check=True)
            (root / "src").mkdir()
            (root / "tests").mkdir()
            (root / "src" / "main.py").write_text("answer = 42\nprint(answer)\n", encoding="utf-8")
            (root / "tests" / "test_main.py").write_text("assert 42 == 42\n", encoding="utf-8")
            (root / "README.md").write_text("# Fixture\n\nDocumentation.\n", encoding="utf-8")
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "commit", "-m", "fixture"], cwd=root, check=True, capture_output=True)
            tracked_config = root / ".source-tempo.json"
            local_config = root / ".source-tempo.local.json"
            tracked_config.write_text('{"report_title": "Shared"}\n', encoding="utf-8")
            local_config.write_text('{"report_title": "Personal"}\n', encoding="utf-8")

            json_output = Path(tmp) / "source-tempo.json"
            html_output = Path(tmp) / "source-tempo.html"
            result = subprocess.run(
                [
                    sys.executable,
                    str(REPO_ROOT / "src/source_tempo/cli.py"),
                    "--root", str(root),
                    "--months", "1",
                    "--workers", "1",
                    "--no-cache",
                    "--json", str(json_output),
                    "--html", str(html_output),
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            document = json.loads(json_output.read_text(encoding="utf-8"))
            html = html_output.read_text(encoding="utf-8")
            html_data = json.loads(html.split("const DATA = ", 1)[1].split(";\n", 1)[0])
            self.assertEqual(document["series"]["locByKind"]["code"], [2])
            self.assertEqual(document["series"]["locByKind"]["test"], [1])
            self.assertEqual(document["series"]["docLoc"], [3])
            self.assertEqual(html_data["loc"], document["series"]["loc"])
            self.assertEqual(html_data["docLoc"], document["series"]["docLoc"])
            terminal_row = next(
                line for line in result.stdout.splitlines()
                if line.startswith(document["period"]["labels"][-1])
            )
            self.assertIn("3 (3)", terminal_row)
            self.assertEqual(document["workspace"]["title"], "Personal")
            self.assertIn(
                f"Config: {root.resolve() / tracked_config.name}, {root.resolve() / local_config.name}",
                result.stdout,
            )
            self.assertIn("JSON report written to:", result.stdout)

    def test_init_config_defaults_to_personal_override(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "fixture"
            root.mkdir()
            subprocess.run(["git", "init", str(root)], check=True, capture_output=True)

            result = subprocess.run(
                [
                    sys.executable,
                    str(REPO_ROOT / "src/source_tempo/cli.py"),
                    "--root", str(root),
                    "--init-config",
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            local_config = root / ".source-tempo.local.json"
            self.assertTrue(local_config.exists())
            self.assertFalse((root / ".source-tempo.json").exists())
            self.assertIn(str(local_config), result.stdout)

    def test_html_reports_missing_extra_repo_without_calling_it_excluded_submodule(self) -> None:
        tempo = load_script("tempo_html_test", "src/source_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "report.html"

            document = make_report_document(
                tempo,
                ["2026-07"],
                [0],
                [0],
                [0],
                [0],
                [0],
                [0],
                {"code": [0], "test": [0]},
                {"code": [0], "test": [0]},
                {"code": [0], "test": [0]},
                {"code": [0], "test": [0]},
                {},
                [],
                [],
                {
                    "vendor_like": ["_vendor/json-render"],
                    "non_product": ["modules/status-site"],
                    "unavailable_submodule": ["modules/core"],
                    "unavailable_extra": ["companion"],
                },
                False,
                timezone.utc,
                "month",
            )
            tempo.write_html(out, document)

            html = out.read_text(encoding="utf-8")

        self.assertIn("Configured extra repos not found on disk: companion", html)
        self.assertIn("Declared submodules with no usable checkout: modules/core", html)
        self.assertIn(
            "Excluded submodules by default (vendor-like or non-product): "
            "_vendor/json-render, modules/status-site.",
            html,
        )
        self.assertNotIn(
            "Excluded submodules by default (vendor-like or non-product): "
            "_vendor/json-render, modules/status-site, companion.",
            html,
        )

    def test_monthly_chart_timeline_interpolates_current_open_month(self) -> None:
        tempo = load_script("tempo_timeline_test", "src/source_tempo/cli.py")
        timeline = tempo.chart_timeline_metadata(
            ["2026-06", "2026-07", "2026-08"],
            "month",
            timezone.utc,
            datetime(2026, 8, 4, 9, tzinfo=timezone.utc),
        )

        self.assertEqual(timeline["currentIndex"], 2)
        self.assertAlmostEqual(timeline["currentProgress"], 4 / 31)

    def test_daily_chart_timeline_interpolates_current_open_day(self) -> None:
        tempo = load_script("tempo_daily_timeline_test", "src/source_tempo/cli.py")
        timeline = tempo.chart_timeline_metadata(
            ["2026-08-30", "2026-08-31"],
            "day",
            timezone.utc,
            datetime(2026, 8, 31, 6, tzinfo=timezone.utc),
        )

        self.assertEqual(timeline["currentIndex"], 1)
        self.assertAlmostEqual(timeline["currentProgress"], 0.25)

    def test_chart_timeline_leaves_closed_months_at_full_tick(self) -> None:
        tempo = load_script("tempo_closed_timeline_test", "src/source_tempo/cli.py")
        timeline = tempo.chart_timeline_metadata(
            ["2026-05", "2026-06", "2026-07"],
            "month",
            timezone.utc,
            datetime(2026, 8, 4, 9, tzinfo=timezone.utc),
        )

        self.assertEqual(timeline["currentIndex"], None)
        self.assertEqual(timeline["currentProgress"], 1.0)

    def test_chart_timeline_keeps_last_day_visibly_open(self) -> None:
        tempo = load_script("tempo_last_day_timeline_test", "src/source_tempo/cli.py")
        timeline = tempo.chart_timeline_metadata(
            ["2026-06", "2026-07", "2026-08"],
            "month",
            timezone.utc,
            datetime(2026, 8, 31, 23, 59, tzinfo=timezone.utc),
        )

        self.assertEqual(timeline["currentIndex"], 2)
        self.assertLess(timeline["currentProgress"], 1.0)

    def test_html_embeds_current_month_timeline_metadata(self) -> None:
        tempo = load_script("tempo_timeline_html_test", "src/source_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "report.html"

            document = make_report_document(
                tempo,
                ["2026-06", "2026-07", "2026-08"],
                [100, 120, 130],
                [10, 12, 13],
                [5, 6, 7],
                [1, 1, 1],
                [4, 5, 6],
                [1, 1, 1],
                {"code": [80, 95, 100], "test": [20, 25, 30]},
                {"code": [4, 5, 6], "test": [1, 1, 1]},
                {"code": [3, 4, 5], "test": [1, 1, 1]},
                {"code": [1, 1, 1], "test": [0, 0, 0]},
                {"Python": [80, 95, 100], "TypeScript": [20, 25, 30]},
                [("(parent)", 130, 13, 100, 30)],
                [("Python", 100), ("TypeScript", 30)],
                {"vendor_like": [], "non_product": [], "unavailable_submodule": [], "unavailable_extra": []},
                False,
                timezone.utc,
                "month",
                now=datetime(2026, 8, 4, 9, tzinfo=timezone.utc),
            )
            document["timeline"] = {"currentIndex": 2, "currentProgress": 0.25}
            tempo.write_html(out, document)

            html = out.read_text(encoding="utf-8")

        data_json = html.split("const DATA = ", 1)[1].split(";\n", 1)[0]
        data = json.loads(data_json)
        self.assertEqual(data["timeline"]["currentIndex"], 2)
        self.assertEqual(data["timeline"]["currentProgress"], 0.25)
        self.assertIn("chart.dataX(i)", html)
        self.assertIn("chart.dataX(startIdx)", html)
        self.assertIn('fill="#e5eaf1"', html)
        self.assertIn("Remaining month not counted yet", html)

    def test_loc_forecast_projects_three_months(self) -> None:
        tempo = load_script("tempo_forecast_test", "src/source_tempo/cli.py")

        forecast = tempo.loc_forecast(
            ["2026-01", "2026-02", "2026-03", "2026-04", "2026-05", "2026-06"],
            [100, 150, 210, 280, 300, 315],
            report_tz=timezone.utc,
            now=datetime(2026, 12, 31, tzinfo=timezone.utc),
        )

        self.assertEqual(
            [point["month"] for point in forecast],
            ["2026-07", "2026-08", "2026-09"],
        )
        self.assertEqual([point["value"] for point in forecast], [358, 401, 444])

    def test_loc_forecast_uses_trailing_six_month_growth_rate(self) -> None:
        tempo = load_script("tempo_trailing_six_forecast_test", "src/source_tempo/cli.py")

        forecast = tempo.loc_forecast(
            [
                "2026-01",
                "2026-02",
                "2026-03",
                "2026-04",
                "2026-05",
                "2026-06",
                "2026-07",
                "2026-08",
                "2026-09",
                "2026-10",
            ],
            [500, 420, 440, 480, 530, 590, 660, 740, 800, 840],
            report_tz=timezone.utc,
            now=datetime(2026, 12, 31, tzinfo=timezone.utc),
        )

        self.assertEqual([point["value"] for point in forecast], [900, 960, 1020])

    def test_loc_forecast_clamps_deletion_month_to_flat_growth(self) -> None:
        tempo = load_script("tempo_deletion_forecast_test", "src/source_tempo/cli.py")

        forecast = tempo.loc_forecast(
            ["2026-01", "2026-02", "2026-03", "2026-04", "2026-05", "2026-06", "2026-07"],
            [900_000, 930_000, 960_000, 990_000, 1_020_000, 1_050_000, 600_000],
            report_tz=timezone.utc,
            now=datetime(2026, 12, 31, tzinfo=timezone.utc),
        )

        self.assertEqual([point["value"] for point in forecast], [600_000] * 3)

    def test_loc_forecast_ignores_current_partial_month_for_slope(self) -> None:
        tempo = load_script("tempo_partial_month_forecast_test", "src/source_tempo/cli.py")

        forecast = tempo.loc_forecast(
            ["2026-05", "2026-06", "2026-07"],
            [100, 150, 151],
            report_tz=timezone.utc,
            now=datetime(2026, 7, 2, tzinfo=timezone.utc),
        )

        self.assertEqual([point["value"] for point in forecast], [201, 251, 301])

    def test_loc_forecast_requires_a_completed_delta(self) -> None:
        tempo = load_script("tempo_short_forecast_test", "src/source_tempo/cli.py")

        self.assertEqual(
            tempo.loc_forecast(
                ["2026-07"],
                [100],
                report_tz=timezone.utc,
                now=datetime(2026, 12, 31, tzinfo=timezone.utc),
            ),
            [],
        )
        self.assertEqual(
            tempo.loc_forecast(
                ["2026-06", "2026-07"],
                [100, 101],
                report_tz=timezone.utc,
                now=datetime(2026, 7, 2, tzinfo=timezone.utc),
            ),
            [],
        )

    def test_monthly_html_does_not_advertise_loc_forecast_by_default(self) -> None:
        tempo = load_script("tempo_forecast_default_html_test", "src/source_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "report.html"

            document = make_report_document(
                tempo,
                ["2026-01", "2026-02", "2026-03"],
                [100, 120, 130],
                [10, 12, 13],
                [5, 6, 7],
                [1, 1, 1],
                [4, 5, 6],
                [1, 1, 1],
                {"code": [80, 95, 100], "test": [20, 25, 30]},
                {"code": [4, 5, 6], "test": [1, 1, 1]},
                {"code": [3, 4, 5], "test": [1, 1, 1]},
                {"code": [1, 1, 1], "test": [0, 0, 0]},
                {"Python": [80, 95, 100], "TypeScript": [20, 25, 30]},
                [("(parent)", 130, 13, 100, 30)],
                [("Python", 100), ("TypeScript", 30)],
                {"vendor_like": [], "non_product": [], "unavailable_submodule": [], "unavailable_extra": []},
                False,
                timezone.utc,
                "month",
            )
            tempo.write_html(out, document)

            html = out.read_text(encoding="utf-8")

        data_json = html.split("const DATA = ", 1)[1].split(";\n", 1)[0]
        data = json.loads(data_json)
        self.assertEqual(data["locForecast"], [])
        self.assertNotIn("forecast", data)
        self.assertNotIn("3-month forecast", html)
        self.assertNotIn("3-month LOC forecast", html)
        self.assertNotIn("LOC Snapshot forecast is informational only", html)

    def test_html_embeds_loc_snapshot_forecast_without_extending_history(self) -> None:
        tempo = load_script("tempo_forecast_html_test", "src/source_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "report.html"

            document = make_report_document(
                tempo,
                ["2026-01", "2026-02", "2026-03"],
                [100, 120, 130],
                [10, 12, 13],
                [5, 6, 7],
                [1, 1, 1],
                [4, 5, 6],
                [1, 1, 1],
                {"code": [80, 95, 100], "test": [20, 25, 30]},
                {"code": [4, 5, 6], "test": [1, 1, 1]},
                {"code": [3, 4, 5], "test": [1, 1, 1]},
                {"code": [1, 1, 1], "test": [0, 0, 0]},
                {"Python": [80, 95, 100], "TypeScript": [20, 25, 30]},
                [("(parent)", 130, 13, 100, 30)],
                [("Python", 100), ("TypeScript", 30)],
                {"vendor_like": [], "non_product": [], "unavailable_submodule": [], "unavailable_extra": []},
                False,
                timezone.utc,
                "month",
                True,
            )
            tempo.write_html(out, document)

            html = out.read_text(encoding="utf-8")

        data_json = html.split("const DATA = ", 1)[1].split(";\n", 1)[0]
        data = json.loads(data_json)
        self.assertEqual(data["months"], ["2026-01", "2026-02", "2026-03"])
        self.assertEqual(
            [point["month"] for point in data["locForecast"]],
            ["2026-04", "2026-05", "2026-06"],
        )
        self.assertEqual([point["value"] for point in data["locForecast"]], [145, 160, 175])
        self.assertEqual(len(data["locForecast"]), 3)
        self.assertEqual("3-month LOC forecast", data["forecast"]["label"])
        self.assertIn("Forecast", html)
        self.assertIn("docs shown as guide; 3-month forecast", html)
        self.assertIn("last 6 completed months, or all available completed months when fewer", html)
        self.assertIn("timelineLabels()", html)
        self.assertIn("forceLabelIndexes.includes(i)", html)
        self.assertIn("axis extends to LOC forecast horizon", html)
        self.assertIn("No churn projected beyond this point", html)

    def test_daily_html_does_not_advertise_monthly_loc_forecast(self) -> None:
        tempo = load_script("tempo_daily_forecast_html_test", "src/source_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "report.html"

            document = make_report_document(
                tempo,
                ["2026-07-29", "2026-07-30", "2026-07-31"],
                [100, 120, 130],
                [10, 12, 13],
                [5, 6, 7],
                [1, 1, 1],
                [4, 5, 6],
                [1, 1, 1],
                {"code": [80, 95, 100], "test": [20, 25, 30]},
                {"code": [4, 5, 6], "test": [1, 1, 1]},
                {"code": [3, 4, 5], "test": [1, 1, 1]},
                {"code": [1, 1, 1], "test": [0, 0, 0]},
                {"Python": [80, 95, 100], "TypeScript": [20, 25, 30]},
                [("(parent)", 130, 13, 100, 30)],
                [("Python", 100), ("TypeScript", 30)],
                {"vendor_like": [], "non_product": [], "unavailable_submodule": [], "unavailable_extra": []},
                False,
                timezone.utc,
                "day",
            )
            tempo.write_html(out, document)

            html = out.read_text(encoding="utf-8")

        data_json = html.split("const DATA = ", 1)[1].split(";\n", 1)[0]
        data = json.loads(data_json)
        self.assertEqual(data["locForecast"], [])
        self.assertNotIn("forecast", data)
        self.assertNotIn("3-month forecast", html)
        self.assertNotIn("3-month LOC forecast", html)
        self.assertNotIn("LOC Snapshot forecast is informational only", html)
        self.assertIn("docs shown as guide", html)

    def test_extra_repo_resolution_handles_parent_worktrees(self) -> None:
        tempo = load_script("tempo_worktree_repos_test", "src/source_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            worktree_root = tmp_path / "workspace" / ".worktrees" / "branch"
            consult = tmp_path / "companion"
            worktree_root.mkdir(parents=True)
            consult.mkdir()

            original_main_checkout_root = tempo.main_checkout_root
            try:
                tempo.main_checkout_root = lambda _root: tmp_path / "workspace"
                candidates = tempo.candidate_repo_paths(
                    worktree_root,
                    {"label": "companion", "path": "../companion"},
                )
            finally:
                tempo.main_checkout_root = original_main_checkout_root

            self.assertEqual(candidates[0], consult.resolve())

    def test_main_checkout_root_resolves_real_git_worktree(self) -> None:
        tempo = load_script("tempo_real_worktree_test", "src/source_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            main = Path(tmp) / "repo"
            worktree = Path(tmp) / "wt"
            subprocess.run(["git", "init", str(main)], check=True, capture_output=True)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=main, check=True)
            subprocess.run(["git", "config", "user.name", "Test User"], cwd=main, check=True)
            subprocess.run(["git", "config", "commit.gpgsign", "false"], cwd=main, check=True)
            (main / "README.md").write_text("test\n", encoding="utf-8")
            subprocess.run(["git", "add", "README.md"], cwd=main, check=True)
            subprocess.run(["git", "commit", "-m", "initial"], cwd=main, check=True, capture_output=True)
            subprocess.run(
                ["git", "worktree", "add", "-b", "branch", str(worktree)],
                cwd=main,
                check=True,
                capture_output=True,
            )

            self.assertEqual(tempo.main_checkout_root(worktree), main.resolve())

    def test_doc_only_repo_names_participate_in_cache_signature(self) -> None:
        tempo = load_script("tempo_doc_only_signature_test", "src/source_tempo/cli.py")
        original = tempo.DOC_ONLY_REPO_NAMES
        try:
            before = tempo.filter_signature(include_vendor=False)
            tempo.DOC_ONLY_REPO_NAMES = {"documentation", "manuals"}
            after = tempo.filter_signature(include_vendor=False)
        finally:
            tempo.DOC_ONLY_REPO_NAMES = original

        self.assertNotEqual(before, after)

    def test_documentation_repo_source_like_artifacts_count_as_docs(self) -> None:
        tempo = load_script("tempo_doc_repo_artifacts_test", "src/source_tempo/cli.py")
        for repo_name in ("documentation",):
            with self.subTest(repo_name=repo_name), tempfile.TemporaryDirectory() as tmp:
                repo = Path(tmp) / repo_name
                repo.mkdir()
                subprocess.run(["git", "init", str(repo)], check=True, capture_output=True)
                subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
                subprocess.run(["git", "config", "user.name", "Test User"], cwd=repo, check=True)
                subprocess.run(["git", "config", "commit.gpgsign", "false"], cwd=repo, check=True)
                (repo / "concepts").mkdir()
                (repo / "spikes").mkdir()
                (repo / "README.md").write_text("# Docs\nbody\n", encoding="utf-8")
                (repo / "concepts" / "mockup.html").write_text("<main>\n</main>\n", encoding="utf-8")
                (repo / "spikes" / "Probe.kt").write_text("fun main() {\n}\n", encoding="utf-8")
                (repo / "spikes" / "helper.py").write_text("print('docs helper')\n", encoding="utf-8")
                subprocess.run(["git", "add", "."], cwd=repo, check=True)
                subprocess.run(["git", "commit", "-m", "docs artifacts"], cwd=repo, check=True, capture_output=True)
                (repo / "spikes" / "Probe.kt").write_text("fun main() {\n  println(\"docs\")\n}\n", encoding="utf-8")
                (repo / "README.md").write_text("# Docs\nbody\nmore\n", encoding="utf-8")
                subprocess.run(["git", "add", "."], cwd=repo, check=True)
                subprocess.run(["git", "commit", "-m", "update docs artifacts"], cwd=repo, check=True, capture_output=True)
                commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()

                snap = tempo.count_snapshot(repo, commit)
                churn = tempo.collect_churn_by_period(repo, period="month")
                source_only_churn = tempo.collect_churn_by_period(repo, include_docs=False, period="month")

                self.assertEqual(snap.total, 0)
                self.assertEqual(snap.by_kind, {})
                self.assertEqual(snap.docs_total, 9)
                self.assertEqual(snap.docs_by_language["Markdown"], 3)
                self.assertEqual(snap.docs_by_language["HTML"], 2)
                self.assertEqual(snap.docs_by_language["Kotlin"], 3)
                self.assertEqual(snap.docs_by_language["Python"], 1)
                for by_kind in churn.values():
                    self.assertEqual(set(by_kind), {"doc"})
                self.assertEqual(source_only_churn, {})

    def test_cli_reports_hand_computed_history_and_invalidates_policy_cache(self) -> None:
        tempo = load_script("tempo_end_to_end_fixture_test", "src/source_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            temp_root = Path(tmp)
            repo = temp_root / "fixture"
            repo.mkdir()
            subprocess.run(["git", "init", "-b", "main"], cwd=repo, check=True, capture_output=True)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "Test User"], cwd=repo, check=True)
            subprocess.run(["git", "config", "commit.gpgsign", "false"], cwd=repo, check=True)

            local_now = datetime.now().astimezone()
            first_day = local_now.date() - timedelta(days=1)
            first_moment = datetime.combine(first_day, datetime.min.time(), local_now.tzinfo).replace(hour=12)
            second_moment = datetime.combine(local_now.date(), datetime.min.time(), local_now.tzinfo).replace(hour=12)

            (repo / "src").mkdir()
            (repo / "tests").mkdir()
            (repo / "src" / "app.py").write_text("print('one')\n", encoding="utf-8")
            (repo / "tests" / "test_app.py").write_text(
                "def test_one():\n    assert True\n",
                encoding="utf-8",
            )
            (repo / "README.md").write_text("# Fixture\n", encoding="utf-8")
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            first_env = os.environ | {
                "GIT_AUTHOR_DATE": first_moment.isoformat(),
                "GIT_COMMITTER_DATE": first_moment.isoformat(),
            }
            subprocess.run(
                ["git", "commit", "-m", "initial source"],
                cwd=repo,
                env=first_env,
                check=True,
                capture_output=True,
            )

            (repo / "src" / "app.py").write_text(
                "print('one')\nprint('two')\n",
                encoding="utf-8",
            )
            (repo / "README.md").write_text("# Fixture\nDetails\n", encoding="utf-8")
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            second_env = os.environ | {
                "GIT_AUTHOR_DATE": second_moment.isoformat(),
                "GIT_COMMITTER_DATE": second_moment.isoformat(),
            }
            subprocess.run(
                ["git", "commit", "-m", "extend source"],
                cwd=repo,
                env=second_env,
                check=True,
                capture_output=True,
            )

            extra_repo = temp_root / "shared-sdk"
            extra_repo.mkdir()
            subprocess.run(
                ["git", "init", "-b", "main"],
                cwd=extra_repo,
                check=True,
                capture_output=True,
            )
            subprocess.run(
                ["git", "config", "user.email", "test@example.com"],
                cwd=extra_repo,
                check=True,
            )
            subprocess.run(
                ["git", "config", "user.name", "Test User"],
                cwd=extra_repo,
                check=True,
            )
            subprocess.run(
                ["git", "config", "commit.gpgsign", "false"],
                cwd=extra_repo,
                check=True,
            )
            (extra_repo / "client.py").write_text("CLIENT_VERSION = 1\n", encoding="utf-8")
            subprocess.run(["git", "add", "."], cwd=extra_repo, check=True)
            subprocess.run(
                ["git", "commit", "-m", "add client"],
                cwd=extra_repo,
                env=first_env,
                check=True,
                capture_output=True,
            )

            extra_repo_config = [
                {"label": "shared-sdk", "path": "../shared-sdk"},
            ]
            (repo / tempo.LOCAL_CONFIG_FILENAME).write_text(
                json.dumps({"extra_repos": extra_repo_config}),
                encoding="utf-8",
            )

            cache = temp_root / "cache.json"

            def run_report(name: str) -> dict:
                json_path = temp_root / f"{name}.json"
                html_path = temp_root / f"{name}.html"
                argv = [
                    "source-tempo",
                    "--root", str(repo),
                    "--period", "day",
                    "--days", "2",
                    "--workers", "1",
                    "--cache", str(cache),
                    "--html", str(html_path),
                    "--json", str(json_path),
                    "--no-languages",
                ]
                with mock.patch.object(sys, "argv", argv), redirect_stdout(io.StringIO()):
                    self.assertEqual(tempo.main(), 0)
                self.assertTrue(html_path.exists())
                return json.loads(json_path.read_text(encoding="utf-8"))

            cold = run_report("cold")
            warm = run_report("warm")

            self.assertEqual(cold["series"]["loc"], [4, 5])
            self.assertEqual(cold["series"]["docLoc"], [1, 2])
            self.assertEqual(cold["series"]["locByKind"], {"code": [2, 3], "test": [2, 2]})
            self.assertEqual(cold["series"]["churn"], [4, 1])
            self.assertEqual(cold["series"]["docChurn"], [1, 1])
            self.assertEqual(cold["series"]["docAdded"], [1, 1])
            self.assertEqual(cold["series"]["docDeleted"], [0, 0])
            self.assertEqual(cold["series"]["added"], [4, 1])
            self.assertEqual(
                [item["label"] for item in cold["latest"]["repositories"]],
                ["(parent)", "shared-sdk"],
            )
            self.assertEqual(cold["series"], warm["series"])
            self.assertEqual(cold["latest"], warm["latest"])

            (repo / tempo.LOCAL_CONFIG_FILENAME).write_text(
                json.dumps({
                    "exclude_exts": [".py", ".md", ".mdx"],
                    "extra_repos": extra_repo_config,
                }),
                encoding="utf-8",
            )
            policy_changed = run_report("policy-changed")
            self.assertEqual(policy_changed["series"]["loc"], [0, 0])
            self.assertEqual(policy_changed["series"]["churn"], [0, 0])

    def test_extra_repo_config_validation_rejects_bad_entries(self) -> None:
        tempo = load_script("tempo_config_test", "src/source_tempo/cli.py")

        for value in (
            {},
            ["companion"],
            [{"path": "../companion"}],
            [{"label": "companion"}],
        ):
            with self.subTest(value=value), self.assertRaises(ValueError):
                tempo._extra_repo_list(value, "extra_repos")


if __name__ == "__main__":
    unittest.main()
