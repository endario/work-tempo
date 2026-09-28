#!/usr/bin/env python3
"""Focused contracts for WorkTempo collection and reporting."""

from __future__ import annotations

import dataclasses
import hashlib
import importlib.util
import io
import json
import os
import pickle
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from contextlib import redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock
from zoneinfo import ZoneInfo


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "src"))


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
                tempo.RepositoryLOC(label, label, lines, docs, code, test, f"{label}-commit")
                for label, lines, docs, code, test in repo_loc
            ],
            language_loc=language_loc,
            skipped_partition=skipped_partition,
            include_vendor=include_vendor,
            include_non_product=False,
            include_forecast=include_forecast,
        )
    )


def track_remote_main(repo: Path) -> None:
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
    subprocess.run(["git", "update-ref", "refs/remotes/origin/main", commit], cwd=repo, check=True)


def make_tracked_repo(repo: Path) -> None:
    subprocess.run(["git", "init", "-b", "main", str(repo)], check=True, capture_output=True)
    subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.name", "Test User"], cwd=repo, check=True)
    (repo / "main.py").write_text("VALUE = 1\n", encoding="utf-8")
    subprocess.run(["git", "add", "main.py"], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-m", "initial"], cwd=repo, check=True, capture_output=True)
    track_remote_main(repo)


class LocAnalysisScriptTest(unittest.TestCase):
    def test_generic_defaults_have_no_workspace_specific_scope(self) -> None:
        tempo = load_script(
            "tempo_generic_defaults_test",
            "src/work_tempo/cli.py",
        )

        with tempfile.TemporaryDirectory() as tmp:
            config = tempo.default_config()
            self.assertEqual(config.exclude_submodules, frozenset())
            self.assertEqual(config.extra_repos, ())
            self.assertEqual(tempo.CONFIG_FILENAME, ".work-tempo.json")
            self.assertEqual(tempo.LOCAL_CONFIG_FILENAME, ".work-tempo.local.json")

    def test_workspace_artifacts_use_isolated_user_cache_paths(self) -> None:
        tempo = load_script("tempo_artifact_paths_test", "src/work_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            cache_root = Path(tmp) / "cache"
            first = Path(tmp) / "first"
            second = Path(tmp) / "second"
            first.mkdir()
            second.mkdir()

            with mock.patch.dict(
                os.environ,
                {"WORK_TEMPO_CACHE_HOME": str(cache_root)},
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
            "src/work_tempo/cli.py",
        )

        self.assertEqual(
            tempo.default_report_title_for_root(Path("/tmp/example-workspace")),
            "example-workspace",
        )

    def test_active_timezone_uses_system_zone_name(self) -> None:
        tempo = load_script("tempo_timezone_test", "src/work_tempo/cli.py")
        with mock.patch.dict(os.environ, {"TZ": "Asia/Tokyo"}, clear=False):
            active_timezone = tempo.active_timezone()
            self.assertEqual(getattr(active_timezone, "key", None), "Asia/Tokyo")
            self.assertEqual(tempo.timezone_signature(active_timezone), "Asia/Tokyo")

    def test_workspace_config_layers_tracked_then_local(self) -> None:
        tempo = load_script(
            "tempo_layered_config_test",
            "src/work_tempo/cli.py",
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

            layers = tempo.load_workspace_config_layers(root)
            self.assertEqual([path.name for path, _layer in layers], [
                tempo.CONFIG_FILENAME, tempo.LOCAL_CONFIG_FILENAME,
            ])
            config = tempo.build_config(tempo.load_packaged_defaults(), layers, "Fallback")
            self.assertEqual(config.report_title, "Personal")
            self.assertEqual(config.extra_repos, ())

    def test_explicit_config_replaces_default_local_layer(self) -> None:
        tempo = load_script(
            "tempo_explicit_config_test",
            "src/work_tempo/cli.py",
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

            layers = tempo.load_workspace_config_layers(root, explicit)
            self.assertEqual([path.name for path, _layer in layers], [tempo.CONFIG_FILENAME, "personal.json"])
            config = tempo.build_config(tempo.load_packaged_defaults(), layers, "Fallback")
            self.assertEqual(config.report_title, "Explicit")

    def test_build_config_overlays_workspace_layers_onto_defaults(self) -> None:
        tempo = load_script("tempo_effective_config_test", "src/work_tempo/cli.py")
        config = tempo.build_config(
            tempo.load_packaged_defaults(),
            [(
                "test",
                {
                    "extra_repos": [
                        {"label": "companion", "path": "../companion"},
                        {"label": "embedded", "path": "embedded"},
                    ],
                },
            )],
            "Fixture",
        )

        self.assertEqual(
            config.extra_repos,
            (
                {"label": "companion", "path": "../companion"},
                {"label": "embedded", "path": "embedded"},
            ),
        )
        self.assertEqual(config.language_by_ext, tempo.default_config().language_by_ext)

    def test_list_repos_keeps_non_product_submodules_out_and_adds_extra_repo(self) -> None:
        tempo = load_script("tempo_repos_test", "src/work_tempo/cli.py")
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

            config = dataclasses.replace(
                tempo.default_config(),
                extra_repos=(
                    {"label": "companion", "path": "../companion"},
                    {"label": "embedded", "path": "embedded"},
                ),
                exclude_submodules=frozenset({
                    "modules/prototype",
                    "modules/demo",
                    "modules/status-site",
                }),
            )
            original_run = tempo.run
            try:
                tempo.run = fake_run
                repos, skipped, extra_count = tempo.list_repos(root, config)
            finally:
                tempo.run = original_run

            self.assertEqual(
                [label for label, _path in repos],
                ["(parent)", "modules/core", "companion", "embedded"],
            )
            self.assertEqual(extra_count, 2)
            self.assertIn("modules/prototype", skipped)
            self.assertIn("modules/demo", skipped)
            self.assertIn("modules/status-site", skipped)

    def test_list_repos_deduplicates_repeated_gitmodules_paths(self) -> None:
        tempo = load_script("tempo_duplicate_gitmodules_test", "src/work_tempo/cli.py")
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
            try:
                tempo.run = fake_run
                repos, skipped, _extra_count = tempo.list_repos(root, tempo.default_config())
            finally:
                tempo.run = original_run

        self.assertEqual([label for label, _path in repos], ["(parent)", "modules/core"])
        self.assertEqual(skipped, [])

    def test_list_repos_deduplicates_submodule_symlink_alias(self) -> None:
        tempo = load_script("tempo_submodule_symlink_test", "src/work_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "workspace"
            submodule = root / "modules" / "core"
            submodule.mkdir(parents=True)
            make_tracked_repo(submodule)
            (root / "alias").symlink_to(submodule, target_is_directory=True)
            with mock.patch.object(tempo, "gitmodule_paths", return_value=["modules/core", "alias"]):
                repos, skipped, _extra_count = tempo.list_repos(root, tempo.default_config())
            self.assertEqual(repos, [("(parent)", root), ("modules/core", submodule)])
            self.assertEqual(skipped, [])

    def test_list_repos_keeps_distinct_worktrees_with_shared_label(self) -> None:
        tempo = load_script("tempo_worktree_dedup_test", "src/work_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "workspace"
            make_tracked_repo(root)
            other = Path(tmp) / "branch"
            subprocess.run(["git", "worktree", "add", "-b", "branch", str(other)],
                           cwd=root, check=True, capture_output=True)
            config = dataclasses.replace(tempo.default_config(), extra_repos=(
                {"label": "shared", "path": "."},
                {"label": "shared", "path": "../branch"},
            ))
            repos, skipped, extra_count = tempo.list_repos(root, config)
            self.assertEqual(repos, [("(parent)", root), ("shared", other.resolve())])
            self.assertEqual(skipped, [])
            self.assertEqual(extra_count, 1)

    def test_list_repos_keeps_first_submodule_label_for_extra_alias(self) -> None:
        tempo = load_script("tempo_submodule_dedup_test", "src/work_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "workspace"
            submodule = root / "modules" / "core"
            submodule.mkdir(parents=True)
            make_tracked_repo(submodule)
            config = dataclasses.replace(tempo.default_config(), extra_repos=(
                {"label": "alias", "path": "modules/core"},
            ))
            with mock.patch.object(tempo, "gitmodule_paths", return_value=["modules/core"]):
                repos, skipped, extra_count = tempo.list_repos(root, config)
            self.assertEqual(repos, [("(parent)", root), ("modules/core", submodule)])
            self.assertEqual(skipped, [])
            self.assertEqual(extra_count, 0)

    def test_list_repos_skips_missing_gitmodules_path(self) -> None:
        tempo = load_script("tempo_missing_gitmodules_path_test", "src/work_tempo/cli.py")
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
            try:
                tempo.run = fake_run
                repos, skipped, _extra_count = tempo.list_repos(root, tempo.default_config())
            finally:
                tempo.run = original_run

        self.assertEqual([label for label, _path in repos], ["(parent)"])
        self.assertEqual(skipped, ["modules/core"])

    def test_extra_repo_must_be_repo_root_not_plain_subdirectory(self) -> None:
        tempo = load_script("tempo_extra_repo_root_test", "src/work_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "repo"
            nested = root / "nested" / "companion"
            nested.mkdir(parents=True)
            subprocess.run(["git", "init", str(root)], check=True, capture_output=True)

            config = dataclasses.replace(
                tempo.default_config(),
                extra_repos=({"label": "companion", "path": "nested/companion"},),
            )
            repos, skipped, _extra_count = tempo.list_repos(root, config)

        self.assertEqual([label for label, _path in repos], ["(parent)"])
        self.assertEqual(skipped, ["companion"])

    def test_partition_skipped_repos_separates_skip_reasons(self) -> None:
        tempo = load_script("tempo_partition_test", "src/work_tempo/cli.py")
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

            config = dataclasses.replace(
                tempo.default_config(),
                extra_repos=({"label": "companion", "path": "../companion"},),
                exclude_submodules=frozenset({"modules/status-site"}),
            )
            original_run = tempo.run
            try:
                tempo.run = fake_run
                partition = tempo.partition_skipped_repos(
                    root,
                    config,
                    ["_vendor/json-render", "modules/status-site", "modules/core", "companion"],
                )
            finally:
                tempo.run = original_run

        self.assertEqual(partition["vendor_like"], ["_vendor/json-render"])
        self.assertEqual(partition["non_product"], ["modules/status-site"])
        self.assertEqual(partition["unavailable_submodule"], ["modules/core"])
        self.assertEqual(partition["unavailable_extra"], ["companion"])

    def test_extra_repo_config_overrides_default_repo_discovery(self) -> None:
        tempo = load_script("tempo_config_roundtrip_test", "src/work_tempo/cli.py")
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

            defaults = tempo.load_packaged_defaults()
            original_run = tempo.run
            try:
                tempo.run = fake_run

                config = tempo.build_config(defaults, [("test", {"extra_repos": []})], "Fixture")
                repos, skipped, _extra_count = tempo.list_repos(root, config)
                self.assertEqual([label for label, _path in repos], ["(parent)"])
                self.assertEqual(skipped, [])

                config = tempo.build_config(
                    defaults,
                    [("test", {"extra_repos": [{"label": "custom-consult", "path": "../custom-consult"}]})],
                    "Fixture",
                )
                repos, skipped, _extra_count = tempo.list_repos(root, config)
                self.assertEqual([label for label, _path in repos], ["(parent)", "custom-consult"])
                self.assertEqual(skipped, [])
            finally:
                tempo.run = original_run

    def test_report_document_is_raw_complete_and_instance_driven(self) -> None:
        tempo = load_script("tempo_report_document_test", "src/work_tempo/cli.py")
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
            repo_loc=[tempo.RepositoryLOC('repo <& "', "/tmp/workspace", 30, 5, 20, 10, "abc123")],
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
        tempo = load_script("tempo_html_escape_test", "src/work_tempo/cli.py")
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
        tempo = load_script("tempo_json_write_test", "src/work_tempo/cli.py")
        document = {"schemaVersion": 1, "workspace": {"title": "Fixture"}}
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "reports" / "work-tempo.json"
            output.parent.mkdir()
            output.write_text('{"stale": true}\n', encoding="utf-8")
            output.chmod(0o640)

            tempo.write_json(output, document)

            self.assertEqual(json.loads(output.read_text(encoding="utf-8")), document)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o640)
            self.assertEqual(list(output.parent.iterdir()), [output])

    def test_write_json_uses_process_default_mode_for_new_file(self) -> None:
        tempo = load_script("tempo_json_mode_test", "src/work_tempo/cli.py")
        current_umask = os.umask(0)
        os.umask(current_umask)
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "work-tempo.json"

            tempo.write_json(output, {"schemaVersion": 1})

            self.assertEqual(
                stat.S_IMODE(output.stat().st_mode),
                0o666 & ~current_umask,
            )

    def test_report_outputs_reject_non_finite_values(self) -> None:
        tempo = load_script("tempo_strict_json_test", "src/work_tempo/cli.py")
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

    def test_fetch_source_tracks_remote_rewind(self) -> None:
        tempo = load_script("tempo_fetch_rewind_test", "src/work_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            remote = root / "remote.git"
            source = root / "source"
            checkout = root / "checkout"
            subprocess.run(["git", "init", "--bare", "-b", "main", str(remote)], check=True, capture_output=True)
            subprocess.run(["git", "clone", str(remote), str(source)], check=True, capture_output=True)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=source, check=True)
            subprocess.run(["git", "config", "user.name", "Test User"], cwd=source, check=True)
            for version in ("one", "two"):
                (source / "main.py").write_text(f"VERSION = '{version}'\n", encoding="utf-8")
                subprocess.run(["git", "add", "main.py"], cwd=source, check=True)
                subprocess.run(["git", "commit", "-m", version], cwd=source, check=True, capture_output=True)
            subprocess.run(["git", "push", "origin", "main"], cwd=source, check=True, capture_output=True)
            subprocess.run(["git", "clone", str(remote), str(checkout)], check=True, capture_output=True)
            old_tip = subprocess.check_output(["git", "rev-parse", "HEAD^"], cwd=source, text=True).strip()
            subprocess.run(["git", "reset", "--hard", old_tip], cwd=source, check=True, capture_output=True)
            subprocess.run(["git", "push", "--force", "origin", "main"], cwd=source, check=True, capture_output=True)

            self.assertEqual(tempo.fetch_source(checkout, 8), "fetched")
            self.assertEqual(tempo.source_oid(checkout), old_tip)

    def test_fetch_failure_preserves_last_fetched_source(self) -> None:
        tempo = load_script("tempo_fetch_fallback_test", "src/work_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            subprocess.run(["git", "init", "-b", "main", str(repo)], check=True, capture_output=True)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "Test User"], cwd=repo, check=True)
            (repo / "main.py").write_text("VALUE = 1\n", encoding="utf-8")
            subprocess.run(["git", "add", "main.py"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-m", "initial"], cwd=repo, check=True, capture_output=True)
            tip = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
            subprocess.run(["git", "update-ref", "refs/remotes/origin/main", tip], cwd=repo, check=True)

            self.assertEqual(tempo.fetch_source(repo, 8), "failed")
            self.assertEqual(tempo.source_oid(repo), tip)

    def test_missing_remote_main_never_falls_back_to_head(self) -> None:
        tempo = load_script("tempo_missing_source_test", "src/work_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            subprocess.run(["git", "init", "-b", "main", str(repo)], check=True, capture_output=True)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "Test User"], cwd=repo, check=True)
            (repo / "main.py").write_text("VALUE = 1\n", encoding="utf-8")
            subprocess.run(["git", "add", "main.py"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-m", "initial"], cwd=repo, check=True, capture_output=True)

            with self.assertRaisesRegex(RuntimeError, "origin/main is unavailable"):
                tempo.source_oid(repo)

    @unittest.skipUnless(os.name == "posix", "process groups require POSIX")
    def test_fetch_timeout_terminates_child_process(self) -> None:
        tempo = load_script("tempo_fetch_timeout_test", "src/work_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            pid_file = root / "child.pid"
            fake_git = bin_dir / "git"
            fake_git.write_text(
                '#!/bin/sh\n/bin/sh -c \'trap "" TERM; exec sleep 30\' &\nprintf "%s\\n" "$!" > "$PIDFILE"\nwait\n',
                encoding="utf-8",
            )
            fake_git.chmod(0o755)
            with mock.patch.dict(os.environ, {
                "PATH": f"{bin_dir}:{os.environ['PATH']}",
                "PIDFILE": str(pid_file),
            }):
                self.assertEqual(subprocess.check_output(["which", "git"], text=True).strip(), str(fake_git))
                self.assertEqual(tempo.fetch_source(root, 3), "timed_out")
            self.assertTrue(pid_file.exists())
            child_pid = pid_file.read_text(encoding="utf-8").strip()
            child = subprocess.run(
                ["ps", "-p", child_pid, "-o", "stat="],
                capture_output=True, text=True,
            )
            self.assertTrue(child.returncode != 0 or child.stdout.strip().startswith("Z"))

    def test_fetch_budget_rotates_skipped_repository_on_next_run(self) -> None:
        tempo = load_script("tempo_fetch_budget_test", "src/work_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            repos = []
            for index in range(6):
                repo = Path(tmp) / f"repo-{index}"
                make_tracked_repo(repo)
                repos.append((repo.name, repo))
            cache = tempo.empty_cache()
            attempted = []
            lock = threading.Lock()

            def stalled_fetch(repo, _timeout):
                with lock:
                    attempted.append(repo.name)
                time.sleep(0.1)
                return "timed_out"

            with mock.patch.object(tempo, "fetch_source", side_effect=stalled_fetch):
                first = tempo.fetch_sources(repos, cache, total_budget=0.04)
                second = tempo.fetch_sources(repos, cache, total_budget=0.04)

            self.assertEqual([item[3] for item in first],
                             ["timed_out"] * 4 + ["budget_skipped"] * 2)
            self.assertEqual([item[3] for item in second],
                             ["timed_out"] * 2 + ["budget_skipped"] * 2 + ["timed_out"] * 2)
            self.assertEqual(set(attempted[:4]), {f"repo-{index}" for index in range(4)})
            self.assertEqual(set(attempted[4:]), {"repo-4", "repo-5", "repo-0", "repo-1"})

    def test_churn_follows_pinned_remote_tip_not_local_head(self) -> None:
        tempo = load_script("tempo_remote_churn_test", "src/work_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            subprocess.run(["git", "init", "-b", "main", str(repo)], check=True, capture_output=True)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "Test User"], cwd=repo, check=True)
            commits = []
            for name in ("first", "second", "local_only"):
                (repo / f"{name}.py").write_text(f"{name} = 1\n", encoding="utf-8")
                subprocess.run(["git", "add", f"{name}.py"], cwd=repo, check=True)
                subprocess.run(["git", "commit", "-m", name], cwd=repo, check=True, capture_output=True)
                commits.append(subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip())
            config = tempo.default_config()
            cache = tempo.empty_cache()
            identity = tempo.repository_identity(repo)

            def collect(tip):
                buckets, status = tempo.collect_churn_cached(
                    repo, config, False, cache, timezone.utc, "month",
                    source_oid=tip, repo_identity=identity,
                )
                churn = sum(added + deleted for kinds in buckets.values() for added, deleted in kinds.values())
                return churn, status

            self.assertEqual(collect(commits[0]), (1, "miss"))
            self.assertEqual(collect(commits[1]), (2, "incremental"))
            self.assertEqual(collect(commits[0]), (1, "miss"))
            self.assertNotIn(commits[2], json.dumps(cache["churn_repos"]))

    def test_duplicate_display_labels_keep_repository_churn_separate(self) -> None:
        tempo = load_script("tempo_duplicate_labels_test", "src/work_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            parent = root / "parent"
            extras = []
            for name, lines in (("parent", 1), ("extra_a", 2), ("extra_b", 3)):
                repo = root / name
                subprocess.run(["git", "init", "-b", "main", str(repo)], check=True, capture_output=True)
                subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
                subprocess.run(["git", "config", "user.name", "Test User"], cwd=repo, check=True)
                (repo / "main.py").write_text("VALUE = 1\n" * lines, encoding="utf-8")
                subprocess.run(["git", "add", "main.py"], cwd=repo, check=True)
                subprocess.run(["git", "commit", "-m", "initial"], cwd=repo, check=True, capture_output=True)
                track_remote_main(repo)
                if name != "parent":
                    extras.append({"label": "shared", "path": f"../{name}"})
            (parent / tempo.LOCAL_CONFIG_FILENAME).write_text(
                json.dumps({"extra_repos": extras}), encoding="utf-8",
            )
            output = root / "report.json"
            argv = ["work-tempo", "--root", str(parent), "--period", "day", "--days", "1",
                    "--workers", "1", "--no-cache", "--no-html", "--json", str(output),
                    "--no-languages"]
            stdout = io.StringIO()
            with (mock.patch.object(sys, "argv", argv),
                  mock.patch.object(sys, "stderr", io.StringIO()),
                  redirect_stdout(stdout)):
                self.assertEqual(tempo.main(), 0)
            self.assertIn("Repos: 3 counted repositories (parent + 0 submodules + 2 extra repos)", stdout.getvalue())
            report = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(report["series"]["churn"], [6])
            self.assertEqual(report["series"]["loc"], [6])

    def test_snapshots_follow_remote_tip_when_head_has_local_commits(self) -> None:
        tempo = load_script("tempo_remote_snapshot_test", "src/work_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            subprocess.run(["git", "init", "-b", "main", str(repo)], check=True, capture_output=True)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "Test User"], cwd=repo, check=True)
            (repo / "main.py").write_text("ONE = 1\n", encoding="utf-8")
            subprocess.run(["git", "add", "main.py"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-m", "remote"], cwd=repo, check=True, capture_output=True)
            track_remote_main(repo)
            (repo / "main.py").write_text("ONE = 1\nLOCAL = 2\n", encoding="utf-8")
            subprocess.run(["git", "add", "main.py"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-m", "local only"], cwd=repo, check=True, capture_output=True)
            output = root / "report.json"
            argv = ["work-tempo", "--root", str(repo), "--period", "day", "--days", "1",
                    "--workers", "1", "--no-cache", "--no-html", "--json", str(output),
                    "--no-languages"]
            stdout = io.StringIO()
            stderr = io.StringIO()
            with (
                mock.patch.object(sys, "argv", argv),
                mock.patch.object(sys, "stderr", stderr),
                redirect_stdout(stdout),
            ):
                self.assertEqual(tempo.main(), 0)
            report = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(report["series"]["loc"], [1])
            self.assertEqual(report["series"]["churn"], [1])
            source = report["scope"]["repositories"][0]
            self.assertEqual(source["sourceRef"], "origin/main")
            self.assertEqual(source["fetchOutcome"], "failed")
            self.assertEqual(source["sourceOid"], tempo.source_oid(repo))
            self.assertIn(source["sourceOid"][:12], stdout.getvalue())
            self.assertIn("fetch failed", stderr.getvalue())

    def test_collection_git_errors_do_not_replace_reports(self) -> None:
        tempo = load_script("tempo_atomic_collection_test", "src/work_tempo/cli.py")
        for failing_operation in ("collect_churn_cached", "find_commit_at", "count_snapshot"):
            with self.subTest(operation=failing_operation), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                repo = root / "repo"
                make_tracked_repo(repo)
                html = root / "report.html"
                data = root / "report.json"
                html.write_text("previous HTML", encoding="utf-8")
                data.write_text("previous JSON", encoding="utf-8")
                argv = ["work-tempo", "--root", str(repo), "--months", "1", "--workers", "1",
                        "--no-cache", "--html", str(html), "--json", str(data), "--no-languages"]
                stderr = io.StringIO()
                with (
                    mock.patch.object(sys, "argv", argv),
                    mock.patch.object(sys, "stderr", stderr),
                    mock.patch.object(tempo, failing_operation, side_effect=RuntimeError("token=SECRET")),
                    redirect_stdout(io.StringIO()),
                ):
                    self.assertEqual(tempo.main(), 1)
                self.assertEqual(html.read_text(encoding="utf-8"), "previous HTML")
                self.assertEqual(data.read_text(encoding="utf-8"), "previous JSON")
                self.assertIn("collection failed", stderr.getvalue())
                self.assertNotIn("SECRET", stderr.getvalue())

    def test_cutoff_cache_reuses_null_and_invalidates_on_remote_tip_change(self) -> None:
        tempo = load_script("tempo_cutoff_cache_test", "src/work_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            make_tracked_repo(repo)
            cache = tempo.empty_cache()
            identity = tempo.repository_identity(repo)
            first_oid = tempo.source_oid(repo)
            cutoff = "2030-01-01T00:00:00+00:00"
            old_cutoff = "2000-01-01T00:00:00+00:00"
            self.assertEqual(tempo.cached_commit_at(repo, cutoff, first_oid, identity, cache), (first_oid, False))
            self.assertEqual(tempo.cached_commit_at(repo, old_cutoff, first_oid, identity, cache), (None, False))
            with mock.patch.object(tempo, "find_commit_at", side_effect=AssertionError("Git queried warm cutoff")):
                self.assertEqual(tempo.cached_commit_at(repo, cutoff, first_oid, identity, cache), (first_oid, True))
                self.assertEqual(tempo.cached_commit_at(repo, old_cutoff, first_oid, identity, cache), (None, True))

            (repo / "new.py").write_text("NEW = 1\n", encoding="utf-8")
            subprocess.run(["git", "add", "new.py"], cwd=repo, check=True)
            old_date = os.environ | {
                "GIT_AUTHOR_DATE": "2026-01-01T00:00:00+00:00",
                "GIT_COMMITTER_DATE": "2026-01-01T00:00:00+00:00",
            }
            subprocess.run(["git", "commit", "-m", "backdated"], cwd=repo,
                           env=old_date, check=True, capture_output=True)
            track_remote_main(repo)
            new_oid = tempo.source_oid(repo)
            self.assertEqual(tempo.cached_commit_at(repo, cutoff, new_oid, identity, cache), (new_oid, False))
            self.assertEqual(tempo.cached_commit_at(repo, cutoff, new_oid, identity, None), (new_oid, False))

    def test_warm_refresh_resolves_repository_identity_once_per_repo(self) -> None:
        tempo = load_script("tempo_warm_identity_test", "src/work_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            make_tracked_repo(repo)
            argv = ["work-tempo", "--root", str(repo), "--period", "day", "--days", "15",
                    "--workers", "1", "--cache", str(root / "cache.json"), "--no-html",
                    "--no-languages"]
            with (mock.patch.object(sys, "argv", argv),
                  mock.patch.object(sys, "stderr", io.StringIO()),
                  redirect_stdout(io.StringIO())):
                self.assertEqual(tempo.main(), 0)
            with (
                mock.patch.object(sys, "argv", argv),
                mock.patch.object(sys, "stderr", io.StringIO()),
                mock.patch.object(tempo, "git_dir", wraps=tempo.git_dir) as git_dir,
                redirect_stdout(io.StringIO()),
            ):
                self.assertEqual(tempo.main(), 0)
            self.assertEqual(git_dir.call_count, 1)

    def test_cache_schema_upgrade_discards_unverified_label_entries(self) -> None:
        tempo = load_script("tempo_cache_upgrade_test", "src/work_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            cache_path = Path(tmp) / "cache.json"
            cache_path.write_text(json.dumps({
                "schema_version": 4,
                "snapshots": {"shared-label": {"total": 99}},
                "churn_repos": {"shared-label": {"buckets": {}}},
            }), encoding="utf-8")
            self.assertEqual(tempo.load_cache(cache_path), tempo.empty_cache())

            cache_path.write_text(json.dumps({
                "schema_version": 5, "snapshots": {}, "churn_repos": {},
            }), encoding="utf-8")
            self.assertEqual(tempo.load_cache(cache_path)["commit_at"], {})

    def test_cutoff_lookup_stays_pinned_when_tracking_ref_moves_mid_query(self) -> None:
        tempo = load_script("tempo_cutoff_ref_move_test", "src/work_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            make_tracked_repo(repo)
            first_oid = tempo.source_oid(repo)
            (repo / "second.py").write_text("SECOND = 2\n", encoding="utf-8")
            subprocess.run(["git", "add", "second.py"], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-m", "second"], cwd=repo, check=True, capture_output=True)
            second_oid = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
            cutoff = "2030-01-01T00:00:00+00:00"
            cache = tempo.empty_cache()
            identity = tempo.repository_identity(repo)
            original_lookup = tempo.find_commit_at

            def move_ref_during_lookup(path, instant, source):
                track_remote_main(repo)
                return original_lookup(path, instant, source)

            with mock.patch.object(tempo, "find_commit_at", side_effect=move_ref_during_lookup):
                self.assertEqual(tempo.cached_commit_at(repo, cutoff, first_oid, identity, cache),
                                 (first_oid, False))
            self.assertEqual(tempo.source_oid(repo), second_oid)
            self.assertEqual(tempo.cached_commit_at(repo, cutoff, second_oid, identity, cache),
                             (second_oid, False))

    def test_cli_fetches_remote_main_then_falls_back_when_origin_is_unavailable(self) -> None:
        tempo = load_script("tempo_fetch_report_test", "src/work_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            remote = root / "remote.git"
            repo = root / "repo"
            contributor = root / "contributor"
            subprocess.run(["git", "init", "--bare", "-b", "main", str(remote)], check=True, capture_output=True)
            make_tracked_repo(repo)
            subprocess.run(["git", "remote", "add", "origin", str(remote)], cwd=repo, check=True)
            subprocess.run(["git", "push", "origin", "main"], cwd=repo, check=True, capture_output=True)
            subprocess.run(["git", "clone", str(remote), str(contributor)], check=True, capture_output=True)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=contributor, check=True)
            subprocess.run(["git", "config", "user.name", "Test User"], cwd=contributor, check=True)
            (contributor / "main.py").write_text("VALUE = 1\nREMOTE = 2\n", encoding="utf-8")
            subprocess.run(["git", "add", "main.py"], cwd=contributor, check=True)
            subprocess.run(["git", "commit", "-m", "remote advance"], cwd=contributor,
                           check=True, capture_output=True)
            subprocess.run(["git", "push", "origin", "main"], cwd=contributor,
                           check=True, capture_output=True)
            remote_tip = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=contributor, text=True).strip()
            output = root / "report.json"
            argv = ["work-tempo", "--root", str(repo), "--period", "day", "--days", "1",
                    "--workers", "1", "--cache", str(root / "cache.json"), "--no-html",
                    "--json", str(output), "--no-languages"]

            with mock.patch.object(sys, "argv", argv), redirect_stdout(io.StringIO()):
                self.assertEqual(tempo.main(), 0)
            fetched = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(fetched["series"]["loc"], [2])
            self.assertEqual(fetched["scope"]["repositories"][0]["sourceOid"], remote_tip)
            self.assertEqual(fetched["scope"]["repositories"][0]["fetchOutcome"], "fetched")

            subprocess.run(["git", "remote", "set-url", "origin", str(root / "missing.git")],
                           cwd=repo, check=True)
            stderr = io.StringIO()
            with (mock.patch.object(sys, "argv", argv), mock.patch.object(sys, "stderr", stderr),
                  redirect_stdout(io.StringIO())):
                self.assertEqual(tempo.main(), 0)
            fallback = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(fallback["series"]["loc"], [2])
            self.assertEqual(fallback["scope"]["repositories"][0]["sourceOid"], remote_tip)
            self.assertEqual(fallback["scope"]["repositories"][0]["fetchOutcome"], "failed")
            self.assertIn("using last-fetched origin/main", stderr.getvalue())

    def test_missing_remote_ref_keeps_last_report(self) -> None:
        tempo = load_script("tempo_missing_ref_report_test", "src/work_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            make_tracked_repo(repo)
            output = root / "report.json"
            argv = ["work-tempo", "--root", str(repo), "--period", "day", "--days", "1",
                    "--workers", "1", "--no-cache", "--no-html", "--json", str(output),
                    "--no-languages"]
            with (
                mock.patch.object(sys, "argv", argv),
                mock.patch.object(sys, "stderr", io.StringIO()),
                redirect_stdout(io.StringIO()),
            ):
                self.assertEqual(tempo.main(), 0)
            previous = output.read_bytes()
            subprocess.run(["git", "update-ref", "-d", "refs/remotes/origin/main"],
                           cwd=repo, check=True)
            stderr = io.StringIO()
            with (mock.patch.object(sys, "argv", argv), mock.patch.object(sys, "stderr", stderr),
                  redirect_stdout(io.StringIO())):
                self.assertEqual(tempo.main(), 1)
            self.assertEqual(output.read_bytes(), previous)
            self.assertIn("origin/main is unavailable", stderr.getvalue())
            self.assertIn("fetch main from origin", stderr.getvalue())
            self.assertNotIn("exclude this repository", stderr.getvalue())

    def test_parallel_archive_failure_does_not_publish_partial_report(self) -> None:
        tempo = importlib.import_module("work_tempo.cli")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            make_tracked_repo(repo)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            fake_git = bin_dir / "git"
            fake_git.write_text(
                '#!/bin/sh\nif [ "$1" = archive ]; then printf "token=SECRET\\n" >&2; exit 1; fi\nexec /usr/bin/git "$@"\n',
                encoding="utf-8",
            )
            fake_git.chmod(0o755)
            output = root / "report.json"
            output.write_text("previous", encoding="utf-8")
            argv = ["work-tempo", "--root", str(repo), "--months", "1", "--workers", "2",
                    "--no-cache", "--no-html", "--json", str(output), "--no-languages"]
            stderr = io.StringIO()
            stdout = io.StringIO()
            with (
                mock.patch.dict(os.environ, {"PATH": f"{bin_dir}:{os.environ['PATH']}"}),
                mock.patch.object(sys, "argv", argv),
                mock.patch.object(sys, "stderr", stderr),
                redirect_stdout(stdout),
            ):
                self.assertEqual(tempo.main(), 1, stdout.getvalue())
            self.assertEqual(output.read_text(encoding="utf-8"), "previous")
            self.assertNotIn("SECRET", stderr.getvalue())

    def test_shared_commit_in_distinct_repos_keeps_counting_policy_separate(self) -> None:
        tempo = load_script("tempo_repo_identity_snapshot_test", "src/work_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            parent = root / "parent"
            source = root / "source"
            documentation = root / "documentation"
            make_tracked_repo(parent)
            make_tracked_repo(source)
            subprocess.run(["git", "clone", str(source), str(documentation)], check=True, capture_output=True)
            (parent / tempo.LOCAL_CONFIG_FILENAME).write_text(json.dumps({
                "doc_only_repo_names": ["documentation"],
                "extra_repos": [
                    {"label": "shared", "path": "../source"},
                    {"label": "shared", "path": "../documentation"},
                ],
            }), encoding="utf-8")
            output = root / "report.json"
            argv = ["work-tempo", "--root", str(parent), "--period", "day", "--days", "1",
                    "--workers", "1", "--cache", str(root / "cache.json"), "--no-html",
                    "--json", str(output), "--no-languages"]
            with (mock.patch.object(sys, "argv", argv), mock.patch.object(sys, "stderr", io.StringIO()),
                  redirect_stdout(io.StringIO())):
                self.assertEqual(tempo.main(), 0)
            report = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(report["series"]["loc"], [2])
            self.assertEqual(report["series"]["docLoc"], [1])
            self.assertEqual(report["series"]["churn"], [2])
            self.assertEqual(report["series"]["docChurn"], [1])

    def test_missing_counted_extra_ref_suggests_exclusion(self) -> None:
        tempo = load_script("tempo_missing_extra_ref_test", "src/work_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            parent = root / "parent"
            extra = root / "extra"
            make_tracked_repo(parent)
            make_tracked_repo(extra)
            subprocess.run(["git", "update-ref", "-d", "refs/remotes/origin/main"],
                           cwd=extra, check=True)
            (parent / tempo.LOCAL_CONFIG_FILENAME).write_text(
                json.dumps({"extra_repos": [{"label": "extra", "path": "../extra"}]}),
                encoding="utf-8",
            )
            output = root / "report.json"
            argv = ["work-tempo", "--root", str(parent), "--months", "1", "--workers", "1",
                    "--no-cache", "--no-html", "--json", str(output)]
            stderr = io.StringIO()
            with (mock.patch.object(sys, "argv", argv), mock.patch.object(sys, "stderr", stderr),
                  redirect_stdout(io.StringIO())):
                self.assertEqual(tempo.main(), 1)
            self.assertFalse(output.exists())
            self.assertIn("exclude this repository", stderr.getvalue())

    @unittest.skipUnless(os.name == "posix", "process groups require POSIX")
    def test_app_cancellation_kills_fetch_child(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            pid_file = root / "child.pid"
            fake_git = bin_dir / "git"
            fake_git.write_text(
                '#!/bin/sh\n/bin/sh -c \'trap "" TERM; exec sleep 30\' &\nprintf "%s\\n" "$!" > "$PIDFILE"\nwait\n',
                encoding="utf-8",
            )
            fake_git.chmod(0o755)
            environment = os.environ | {
                "PATH": f"{bin_dir}:{os.environ['PATH']}",
                "PIDFILE": str(pid_file),
                "PYTHONPATH": str(REPO_ROOT / "src"),
            }
            collector = subprocess.Popen(
                [sys.executable, "-c", "from work_tempo.cli import fetch_source; "
                 "from pathlib import Path; fetch_source(Path('.'), 8)"],
                cwd=root, env=environment, start_new_session=True,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            child_pid = None
            try:
                deadline = time.monotonic() + 5
                while not pid_file.exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertTrue(pid_file.exists())
                child_pid = int(pid_file.read_text(encoding="utf-8").strip())
                os.killpg(collector.pid, signal.SIGTERM)
                time.sleep(0.1)
                if collector.poll() is None:
                    os.killpg(collector.pid, signal.SIGKILL)
                collector.wait(timeout=5)
                child = subprocess.run(["ps", "-p", str(child_pid), "-o", "stat="],
                                       capture_output=True, text=True)
                self.assertTrue(child.returncode != 0 or child.stdout.strip().startswith("Z"))
            finally:
                if collector.poll() is None:
                    os.killpg(collector.pid, signal.SIGKILL)
                    collector.wait()
                if child_pid is not None:
                    child = subprocess.run(["ps", "-p", str(child_pid), "-o", "stat="],
                                           capture_output=True, text=True)
                    if child.returncode == 0 and not child.stdout.strip().startswith("Z"):
                        os.kill(child_pid, signal.SIGKILL)

    def test_fetches_independent_repositories_concurrently(self) -> None:
        tempo = load_script("tempo_parallel_fetch_test", "src/work_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            repos = []
            for index in range(4):
                repo = Path(tmp) / f"repo-{index}"
                make_tracked_repo(repo)
                repos.append((f"repo-{index}", repo))
            barrier = threading.Barrier(4, timeout=1)

            def overlapping_fetch(_repo, _timeout):
                barrier.wait()
                return "failed"

            with mock.patch.object(tempo, "fetch_source", side_effect=overlapping_fetch):
                entries = tempo.fetch_sources(repos, tempo.empty_cache(), total_budget=5)
            self.assertEqual([status for _label, _path, _oid, status in entries], ["failed"] * 4)

    @unittest.skipUnless(os.name == "posix", "process groups require POSIX")
    def test_fetch_timeout_with_inaccessible_process_group_falls_back(self) -> None:
        tempo = load_script("tempo_fetch_permission_test", "src/work_tempo/cli.py")
        process = mock.Mock(pid=123456, returncode=-15)
        process.wait.side_effect = [subprocess.TimeoutExpired("git fetch", 8), None]
        with (
            mock.patch.object(tempo.subprocess, "Popen", return_value=process),
            mock.patch.object(tempo.os, "killpg", side_effect=[None, PermissionError("denied")]),
            mock.patch.object(tempo.time, "sleep"),
        ):
            self.assertEqual(tempo.fetch_source(Path("/tmp/repo"), 8), "timed_out")

    @unittest.skipUnless(os.name == "posix", "process groups require POSIX")
    def test_app_cancellation_kills_concurrent_fetches(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repos = []
            for index in range(4):
                repo = root / f"repo-{index}"
                make_tracked_repo(repo)
                repos.append((repo.name, repo))
            bin_dir = root / "bin"
            bin_dir.mkdir()
            fake_git = bin_dir / "git"
            fake_git.write_text(
                '#!/bin/sh\nif [ "$1" = fetch ]; then\n'
                '/bin/sh -c \'trap "" TERM; exec sleep 30\' &\n'
                'printf "%s\\n" "$!" > "$PID_DIR/$(basename "$PWD").pid"\n'
                'wait\nelse\nexec /usr/bin/git "$@"\nfi\n',
                encoding="utf-8",
            )
            fake_git.chmod(0o755)
            environment = os.environ | {
                "PATH": f"{bin_dir}:{os.environ['PATH']}",
                "PID_DIR": str(root),
                "PYTHONPATH": str(REPO_ROOT / "src"),
            }
            code = (
                "from pathlib import Path; from work_tempo.cli import fetch_sources; "
                f"fetch_sources([(name, Path(path)) for name, path in {[(name, str(path)) for name, path in repos]!r}], None)"
            )
            collector = subprocess.Popen(
                [sys.executable, "-c", code], cwd=root, env=environment,
                start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            child_pids = []
            try:
                deadline = time.monotonic() + 5
                while len(list(root.glob("repo-*.pid"))) < 4 and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertEqual(len(list(root.glob("repo-*.pid"))), 4)
                child_pids = [int(path.read_text(encoding="utf-8").strip()) for path in root.glob("repo-*.pid")]
                os.killpg(collector.pid, signal.SIGTERM)
                time.sleep(0.1)
                if collector.poll() is None:
                    os.killpg(collector.pid, signal.SIGKILL)
                collector.wait(timeout=5)
                for pid in child_pids:
                    child = subprocess.run(["ps", "-p", str(pid), "-o", "stat="],
                                           capture_output=True, text=True)
                    self.assertTrue(child.returncode != 0 or child.stdout.strip().startswith("Z"))
            finally:
                if collector.poll() is None:
                    os.killpg(collector.pid, signal.SIGKILL)
                    collector.wait()
                for pid in child_pids:
                    child = subprocess.run(["ps", "-p", str(pid), "-o", "stat="],
                                           capture_output=True, text=True)
                    if child.returncode == 0 and not child.stdout.strip().startswith("Z"):
                        os.kill(pid, signal.SIGKILL)

    @unittest.skipUnless(os.name == "posix", "process groups require POSIX")
    def test_fetch_process_error_uses_last_fetched_ref(self) -> None:
        tempo = load_script("tempo_fetch_wait_error_test", "src/work_tempo/cli.py")
        process = mock.Mock(pid=123456)
        process.wait.side_effect = [OSError("token=SECRET"), None]
        with (
            mock.patch.object(tempo.subprocess, "Popen", return_value=process),
            mock.patch.object(tempo.os, "killpg"),
        ):
            self.assertEqual(tempo.fetch_source(Path("/tmp/repo"), 8), "failed")

    @unittest.skipUnless(os.name == "posix", "process groups require POSIX")
    def test_denied_fetch_cleanup_cannot_wait_forever(self) -> None:
        tempo = load_script("tempo_fetch_bounded_cleanup_test", "src/work_tempo/cli.py")
        process = mock.Mock(pid=123456)
        process.wait.side_effect = [
            subprocess.TimeoutExpired("git fetch", 8),
            subprocess.TimeoutExpired("git fetch", 0.5),
            None,
        ]
        with (
            mock.patch.object(tempo.subprocess, "Popen", return_value=process),
            mock.patch.object(tempo.os, "killpg", side_effect=PermissionError("denied")),
            mock.patch.object(tempo.time, "sleep"),
        ):
            self.assertEqual(tempo.fetch_source(Path("/tmp/repo"), 8), "timed_out")
            self.assertLessEqual(len(process.wait.call_args_list), 3)

    @unittest.skipUnless(os.name == "posix", "signal masking requires POSIX")
    def test_signal_during_fetch_spawn_cleans_registered_process(self) -> None:
        tempo = load_script("tempo_fetch_spawn_signal_test", "src/work_tempo/cli.py")
        process = mock.Mock(pid=123456)
        process.wait.return_value = -15

        def interrupt_spawn(*_args, **_kwargs):
            signal.raise_signal(signal.SIGTERM)
            return process

        with (
            mock.patch.object(tempo.subprocess, "Popen", side_effect=interrupt_spawn),
            mock.patch.object(tempo.os, "killpg") as kill_group,
        ):
            with self.assertRaises(SystemExit):
                tempo.fetch_source(Path("/tmp/repo"), 8)
        self.assertTrue(kill_group.called)
        self.assertEqual(tempo._active_fetches, set())

    def test_duplicate_checkout_is_fetched_and_counted_once(self) -> None:
        tempo = load_script("tempo_duplicate_path_provenance_test", "src/work_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve() / "workspace"
            make_tracked_repo(root)
            oid = tempo.source_oid(root)
            (root / tempo.LOCAL_CONFIG_FILENAME).write_text(
                json.dumps({"extra_repos": [
                    {"label": "again", "path": "."},
                    {"label": "alias", "path": "../alias"},
                ]}), encoding="utf-8",
            )
            (root.parent / "alias").symlink_to(root, target_is_directory=True)
            output = root / "report.json"
            argv = ["work-tempo", "--root", str(root), "--period", "day", "--days", "1",
                    "--workers", "1", "--no-cache", "--no-html", "--no-languages",
                    "--json", str(output)]
            with (mock.patch.object(sys, "argv", argv),
                  mock.patch.object(sys, "stderr", io.StringIO()),
                  mock.patch.object(tempo, "fetch_source", return_value="failed") as fetch,
                  redirect_stdout(io.StringIO())):
                self.assertEqual(tempo.main(), 0)
            fetch.assert_called_once_with(root, mock.ANY)
            report = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual([item["label"] for item in report["scope"]["repositories"]], ["(parent)"])
            self.assertEqual(report["scope"]["repositories"][0]["sourceOid"], oid)
            self.assertEqual(report["series"]["loc"], [1])
            self.assertEqual(report["series"]["churn"], [1])

    def test_html_header_shows_last_fetched_source_warning(self) -> None:
        tempo = load_script("tempo_html_fetch_warning_test", "src/work_tempo/cli.py")
        document = make_report_document(
            tempo, ["2026-08"], [1], [0], [1], [0], [1], [0],
            {"code": [1], "test": [0]}, {"code": [1], "test": [0]},
            {"code": [1], "test": [0]}, {"code": [0], "test": [0]},
            {"Python": [1]}, [("repo", 1, 0, 1, 0)], [("Python", 1)],
            {"vendor_like": [], "non_product": [], "unavailable_submodule": [], "unavailable_extra": []},
            False, timezone.utc, "month",
        )
        document["scope"]["repositories"][0].update({
            "sourceRef": "origin/main", "sourceOid": "abc123", "fetchOutcome": "failed",
        })
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "report.html"
            tempo.write_html(output, document)
            html = output.read_text(encoding="utf-8")
        self.assertIn('role="status">1 repository using last-fetched origin/main</div>', html)

    def test_git_failures_are_not_returned_as_empty_metrics(self) -> None:
        tempo = load_script("tempo_git_failure_test", "src/work_tempo/cli.py")

        archive_failure = subprocess.CompletedProcess(
            args=["git", "archive"],
            returncode=1,
            stdout=b"",
            stderr=b"missing object",
        )
        with mock.patch.object(tempo.subprocess, "run", return_value=archive_failure):
            with self.assertRaisesRegex(RuntimeError, "missing object"):
                tempo.count_snapshot(Path("/tmp/repo"), "deadbeef", tempo.default_config())

        churn_failure = subprocess.CompletedProcess(
            args=["git", "log"],
            returncode=1,
            stdout="",
            stderr="repository unavailable",
        )
        with mock.patch.object(tempo.subprocess, "run", return_value=churn_failure):
            with self.assertRaisesRegex(RuntimeError, "repository unavailable"):
                tempo.collect_churn_by_period(Path("/tmp/repo"), tempo.default_config(), "deadbeef")

        cache = tempo.empty_cache()
        with mock.patch.object(
            tempo,
            "collect_churn_by_period",
            side_effect=RuntimeError("transient failure"),
        ):
            with self.assertRaisesRegex(RuntimeError, "transient failure"):
                tempo.collect_churn_cached(
                    Path("/tmp/repo"),
                    tempo.default_config(),
                    False,
                    cache,
                    timezone.utc,
                    "month",
                    source_oid="abc123",
                    repo_identity="repo",
                )
        self.assertEqual(cache["churn_repos"], {})

    def test_cli_rejects_non_positive_worker_count(self) -> None:
        tempo = load_script("tempo_worker_validation_test", "src/work_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            subprocess.run(["git", "init", "-b", "main"], cwd=repo, check=True, capture_output=True)
            argv = ["work-tempo", "--root", str(repo), "--workers", "0", "--no-html"]
            stderr = io.StringIO()
            with mock.patch.object(sys, "argv", argv), mock.patch.object(sys, "stderr", stderr):
                self.assertEqual(tempo.main(), 1)
            self.assertIn("workers must be >= 1", stderr.getvalue())

    def test_atomic_write_removes_temporary_file_when_flush_fails(self) -> None:
        tempo = load_script("tempo_json_failure_test", "src/work_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "work-tempo.json"

            with mock.patch.object(tempo.os, "fsync", side_effect=OSError("disk full")):
                with self.assertRaises(OSError):
                    tempo.write_json(output, {"schemaVersion": 1})

            self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_html_generated_badge_preserves_named_timezone(self) -> None:
        tempo = load_script("tempo_html_timezone_test", "src/work_tempo/cli.py")
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
            track_remote_main(root)
            tracked_config = root / ".work-tempo.json"
            local_config = root / ".work-tempo.local.json"
            tracked_config.write_text('{"report_title": "Shared"}\n', encoding="utf-8")
            local_config.write_text('{"report_title": "Personal"}\n', encoding="utf-8")

            json_output = Path(tmp) / "work-tempo.json"
            html_output = Path(tmp) / "work-tempo.html"
            result = subprocess.run(
                [
                    sys.executable,
                    str(REPO_ROOT / "src/work_tempo/cli.py"),
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
            # The churn the menu-bar rate consumes sums both source kinds and
            # leaves documentation to its own series.
            self.assertEqual(document["series"]["churnByKind"]["code"], [2])
            self.assertEqual(document["series"]["churnByKind"]["test"], [1])
            self.assertEqual(document["series"]["churn"], [3])
            self.assertEqual(document["series"]["docChurn"], [3])
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
                    str(REPO_ROOT / "src/work_tempo/cli.py"),
                    "--root", str(root),
                    "--init-config",
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            local_config = root / ".work-tempo.local.json"
            self.assertTrue(local_config.exists())
            self.assertFalse((root / ".work-tempo.json").exists())
            self.assertIn(str(local_config), result.stdout)

    def test_html_reports_missing_extra_repo_without_calling_it_excluded_submodule(self) -> None:
        tempo = load_script("tempo_html_test", "src/work_tempo/cli.py")
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
        tempo = load_script("tempo_timeline_test", "src/work_tempo/cli.py")
        timeline = tempo.chart_timeline_metadata(
            ["2026-06", "2026-07", "2026-08"],
            "month",
            timezone.utc,
            datetime(2026, 8, 4, 9, tzinfo=timezone.utc),
        )

        self.assertEqual(timeline["currentIndex"], 2)
        self.assertAlmostEqual(timeline["currentProgress"], 4 / 31)

    def test_daily_chart_timeline_interpolates_current_open_day(self) -> None:
        tempo = load_script("tempo_daily_timeline_test", "src/work_tempo/cli.py")
        timeline = tempo.chart_timeline_metadata(
            ["2026-08-30", "2026-08-31"],
            "day",
            timezone.utc,
            datetime(2026, 8, 31, 6, tzinfo=timezone.utc),
        )

        self.assertEqual(timeline["currentIndex"], 1)
        self.assertAlmostEqual(timeline["currentProgress"], 0.25)

    def test_chart_timeline_leaves_closed_months_at_full_tick(self) -> None:
        tempo = load_script("tempo_closed_timeline_test", "src/work_tempo/cli.py")
        timeline = tempo.chart_timeline_metadata(
            ["2026-05", "2026-06", "2026-07"],
            "month",
            timezone.utc,
            datetime(2026, 8, 4, 9, tzinfo=timezone.utc),
        )

        self.assertEqual(timeline["currentIndex"], None)
        self.assertEqual(timeline["currentProgress"], 1.0)

    def test_chart_timeline_keeps_last_day_visibly_open(self) -> None:
        tempo = load_script("tempo_last_day_timeline_test", "src/work_tempo/cli.py")
        timeline = tempo.chart_timeline_metadata(
            ["2026-06", "2026-07", "2026-08"],
            "month",
            timezone.utc,
            datetime(2026, 8, 31, 23, 59, tzinfo=timezone.utc),
        )

        self.assertEqual(timeline["currentIndex"], 2)
        self.assertLess(timeline["currentProgress"], 1.0)

    def test_html_embeds_current_month_timeline_metadata(self) -> None:
        tempo = load_script("tempo_timeline_html_test", "src/work_tempo/cli.py")
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
            document["period"] = {
                "kind": "day",
                "labels": ["2026-08-02", "2026-08-03", "2026-08-04"],
            }
            tempo.write_html(out, document)
            daily_html = out.read_text(encoding="utf-8")

        data_json = html.split("const DATA = ", 1)[1].split(";\n", 1)[0]
        data = json.loads(data_json)
        self.assertEqual(data["timeline"]["currentIndex"], 2)
        self.assertEqual(data["timeline"]["currentProgress"], 0.25)
        self.assertIn("chart.dataX(i)", html)
        self.assertIn("chart.dataX(startIdx)", html)
        self.assertIn('fill="#e5eaf1"', html)
        self.assertIn("Remaining month not counted yet", html)
        self.assertIn("Remaining day not counted yet", daily_html)
        self.assertIn("day-to-date", daily_html)

    def test_loc_forecast_projects_three_months(self) -> None:
        tempo = load_script("tempo_forecast_test", "src/work_tempo/cli.py")

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
        tempo = load_script("tempo_trailing_six_forecast_test", "src/work_tempo/cli.py")

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
        tempo = load_script("tempo_deletion_forecast_test", "src/work_tempo/cli.py")

        forecast = tempo.loc_forecast(
            ["2026-01", "2026-02", "2026-03", "2026-04", "2026-05", "2026-06", "2026-07"],
            [900_000, 930_000, 960_000, 990_000, 1_020_000, 1_050_000, 600_000],
            report_tz=timezone.utc,
            now=datetime(2026, 12, 31, tzinfo=timezone.utc),
        )

        self.assertEqual([point["value"] for point in forecast], [600_000] * 3)

    def test_loc_forecast_ignores_current_partial_month_for_slope(self) -> None:
        tempo = load_script("tempo_partial_month_forecast_test", "src/work_tempo/cli.py")

        forecast = tempo.loc_forecast(
            ["2026-05", "2026-06", "2026-07"],
            [100, 150, 151],
            report_tz=timezone.utc,
            now=datetime(2026, 7, 2, tzinfo=timezone.utc),
        )

        self.assertEqual([point["value"] for point in forecast], [201, 251, 301])

    def test_loc_forecast_requires_a_completed_delta(self) -> None:
        tempo = load_script("tempo_short_forecast_test", "src/work_tempo/cli.py")

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
        tempo = load_script("tempo_forecast_default_html_test", "src/work_tempo/cli.py")
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
        tempo = load_script("tempo_forecast_html_test", "src/work_tempo/cli.py")
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
        tempo = load_script("tempo_daily_forecast_html_test", "src/work_tempo/cli.py")
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
        tempo = load_script("tempo_worktree_repos_test", "src/work_tempo/cli.py")
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
        tempo = load_script("tempo_real_worktree_test", "src/work_tempo/cli.py")
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
        tempo = load_script("tempo_doc_only_signature_test", "src/work_tempo/cli.py")
        base = tempo.default_config()
        before = base.signature(include_vendor=False)
        after = dataclasses.replace(base, doc_only_repo_names=frozenset({"manuals"})).signature(
            include_vendor=False
        )

        self.assertNotEqual(before, after)

    def test_default_policy_signature_is_pinned(self) -> None:
        tempo = load_script("tempo_signature_pin_test", "src/work_tempo/cli.py")
        config = tempo.default_config()
        self.assertEqual(config.signature(include_vendor=False), "4a69ffb70c5e13ed")
        self.assertEqual(config.signature(include_vendor=True), "c2963656b6d8676b")

    def test_signature_payload_is_the_pre_v2_payload_plus_test_file_markers(self) -> None:
        tempo = load_script("tempo_signature_payload_test", "src/work_tempo/cli.py")
        payload = tempo.default_config().signature_payload(include_vendor=False)
        self.assertEqual(payload["test_file_markers"], (".test.", ".spec.", ".e2e.", ".cy."))
        del payload["test_file_markers"]
        encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        self.assertEqual(hashlib.sha256(encoded).hexdigest()[:16], "d1d7d3a40ab93799")

    def test_packaged_defaults_match_default_config_and_init_config(self) -> None:
        tempo = load_script("tempo_packaged_defaults_test", "src/work_tempo/cli.py")
        packaged = json.loads((REPO_ROOT / "src/work_tempo/defaults.json").read_text(encoding="utf-8"))
        self.assertEqual(tempo.default_config_data("x"), {**packaged, "report_title": "x"})
        self.assertNotIn("report_title", packaged)
        config = tempo.default_config()
        for key, value in packaged.items():
            if key == "schema_version":
                continue
            with self.subTest(key=key):
                actual = getattr(config, key)
                if isinstance(actual, dict):
                    self.assertEqual(actual, value)
                else:
                    self.assertEqual(sorted(actual, key=str), sorted(value, key=str))

    def test_missing_or_malformed_packaged_defaults_stop_the_run(self) -> None:
        source = REPO_ROOT / "src/work_tempo/cli.py"
        for label, content in (("missing", None), ("malformed", "{not json")):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as tmp:
                copy = Path(tmp) / "cli.py"
                copy.write_bytes(source.read_bytes())
                if content is not None:
                    (Path(tmp) / "defaults.json").write_text(content, encoding="utf-8")
                repo = Path(tmp) / "repo"
                repo.mkdir()
                subprocess.run(["git", "init", str(repo)], check=True, capture_output=True)
                result = subprocess.run(
                    [sys.executable, str(copy), "--root", str(repo), "--no-html"],
                    capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 1)
                self.assertIn("error: packaged defaults unreadable", result.stderr)
                self.assertIn("defaults.json", result.stderr)

    def test_config_classifies_from_its_own_data(self) -> None:
        tempo = load_script("tempo_config_object_test", "src/work_tempo/cli.py")
        base = tempo.default_config()
        custom = dataclasses.replace(
            base,
            language_by_ext={".zz": "Zed"},
            test_dir_names=frozenset({"checks"}),
        )
        self.assertEqual(custom.language_for_path("a/b.zz"), "Zed")
        self.assertIsNone(custom.language_for_path("a/b.py"))
        self.assertEqual(custom.source_kind_for_path("checks/x.zz"), "test")
        self.assertEqual(base.source_kind_for_path("checks/x.py"), "code")

    def test_config_round_trips_through_pickle(self) -> None:
        tempo = load_script("tempo_config_pickle_test", "src/work_tempo/cli.py")
        config = tempo.default_config()
        self.assertEqual(pickle.loads(pickle.dumps(config)), config)

    def test_workers_and_serial_runs_report_identically(self) -> None:
        # Worker processes must import the module by name, which a file-loaded copy cannot offer.
        tempo = importlib.import_module("work_tempo.cli")
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "fixture"
            repo.mkdir()

            def git(*args: str) -> None:
                subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True)

            git("init", "-b", "main")
            git("config", "user.email", "test@example.com")
            git("config", "user.name", "Test User")
            git("config", "commit.gpgsign", "false")
            (repo / "src").mkdir()
            (repo / "tests").mkdir()
            (repo / "src" / "app.py").write_text("print('one')\n", encoding="utf-8")
            (repo / "tests" / "test_app.py").write_text(
                "def test_one():\n    assert True\n", encoding="utf-8"
            )
            git("add", ".")
            git("commit", "-m", "initial")
            track_remote_main(repo)

            def run_report(workers: int) -> dict:
                json_path = Path(tmp) / f"workers-{workers}.json"
                argv = [
                    "work-tempo", "--root", str(repo), "--period", "day", "--days", "3",
                    "--workers", str(workers), "--no-cache", "--no-html", "--json", str(json_path),
                ]
                with (mock.patch.object(sys, "argv", argv),
                      mock.patch.object(sys, "stderr", io.StringIO()),
                      redirect_stdout(io.StringIO())):
                    self.assertEqual(tempo.main(), 0)
                document = json.loads(json_path.read_text(encoding="utf-8"))
                document.pop("generatedAt")
                document["timeline"].pop("currentProgress")
                return document

            serial = run_report(1)
            self.assertGreater(serial["series"]["loc"][-1], 0)
            self.assertEqual(serial, run_report(2))

            (repo / tempo.LOCAL_CONFIG_FILENAME).write_text(
                json.dumps({"language_by_ext": {".py": "Snake"}}), encoding="utf-8"
            )
            overlaid = run_report(1)
            self.assertIn("Snake", json.dumps(overlaid))
            self.assertEqual(overlaid, run_report(2))

    def test_config_version_matrix(self) -> None:
        tempo = load_script("tempo_version_matrix_test", "src/work_tempo/cli.py")
        cases = [
            ("missing version, v1 keys", {"test_dir_names": ["checks"]}, None),
            ("v1 with test_file_markers", {"schema_version": 1, "test_file_markers": [".t."]}, "test_file_markers"),
            ("missing version with test_file_markers", {"test_file_markers": [".t."]}, "test_file_markers"),
            ("v2 with test_file_markers", {"schema_version": 2, "test_file_markers": [".t."]}, None),
            ("unknown key", {"schema_version": 1, "test_dir_name": ["checks"]}, "test_dir_name"),
            ("unsupported version", {"schema_version": 3}, "schema_version"),
            ("boolean version", {"schema_version": True}, "schema_version"),
            ("bad type", {"schema_version": 1, "test_dir_names": "checks"}, "test_dir_names"),
        ]
        for label, layer, expected_error in cases:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                (root / tempo.CONFIG_FILENAME).write_text(json.dumps(layer), encoding="utf-8")
                layers = tempo.load_workspace_config_layers(root)
                if expected_error is None:
                    tempo.build_config(tempo.load_packaged_defaults(), layers, "Fixture")
                else:
                    with self.assertRaisesRegex(ValueError, expected_error):
                        tempo.build_config(tempo.load_packaged_defaults(), layers, "Fixture")

    def test_bad_tracked_layer_is_not_masked_by_a_good_local_layer(self) -> None:
        tempo = load_script("tempo_masking_test", "src/work_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / tempo.CONFIG_FILENAME).write_text(json.dumps({"schema_version": 3}), encoding="utf-8")
            (root / tempo.LOCAL_CONFIG_FILENAME).write_text(json.dumps({"schema_version": 1}), encoding="utf-8")
            layers = tempo.load_workspace_config_layers(root)
            with self.assertRaisesRegex(ValueError, "schema_version"):
                tempo.build_config(tempo.load_packaged_defaults(), layers, "Fixture")

    def test_invalid_value_in_a_tracked_layer_is_not_masked_by_a_local_layer(self) -> None:
        tempo = load_script("tempo_value_masking_test", "src/work_tempo/cli.py")
        bad_tracked = {
            "test_dir_names": "checks",
            "report_title": 7,
            "language_by_ext": ["py"],
            "extra_repos": [{"label": "x"}],
        }
        good_local = {
            "test_dir_names": ["checks"],
            "report_title": "Personal",
            "language_by_ext": {".py": "Python"},
            "extra_repos": [],
        }
        for key, value in bad_tracked.items():
            with self.subTest(key=key), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                (root / tempo.CONFIG_FILENAME).write_text(json.dumps({key: value}), encoding="utf-8")
                (root / tempo.LOCAL_CONFIG_FILENAME).write_text(
                    json.dumps({key: good_local[key]}), encoding="utf-8"
                )
                layers = tempo.load_workspace_config_layers(root)
                with self.assertRaisesRegex(ValueError, rf"{key}.*{tempo.CONFIG_FILENAME}"):
                    tempo.build_config(tempo.load_packaged_defaults(), layers, "Fixture")

    def test_v1_layer_may_overlay_v2_defaults(self) -> None:
        tempo = load_script("tempo_v1_over_v2_test", "src/work_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / tempo.CONFIG_FILENAME).write_text(
                json.dumps({"schema_version": 1, "test_dir_names": ["checks"]}), encoding="utf-8"
            )
            layers = tempo.load_workspace_config_layers(root)
            config = tempo.build_config(tempo.load_packaged_defaults(), layers, "Fixture")
            self.assertEqual(config.test_dir_names, frozenset({"checks"}))
            self.assertEqual(config.test_file_markers, tempo.default_config().test_file_markers)

    def test_packaged_defaults_missing_a_key_are_a_packaging_fault(self) -> None:
        tempo = load_script("tempo_defaults_missing_key_test", "src/work_tempo/cli.py")
        defaults = tempo.load_packaged_defaults()
        del defaults["test_dir_names"]
        with self.assertRaisesRegex(RuntimeError, "test_dir_names"):
            tempo.build_config(defaults, [], "Fixture")

    def test_init_config_output_is_accepted_by_the_strict_loader(self) -> None:
        tempo = load_script("tempo_init_roundtrip_test", "src/work_tempo/cli.py")
        written = json.loads(json.dumps(tempo.default_config_data("Fixture")))
        config = tempo.build_config(tempo.load_packaged_defaults(), [("init", written)], "Other")
        self.assertEqual(config, tempo.default_config("Fixture"))

    def test_packaged_defaults_declare_the_newest_supported_schema(self) -> None:
        tempo = load_script("tempo_defaults_version_test", "src/work_tempo/cli.py")
        self.assertEqual(
            tempo.load_packaged_defaults()["schema_version"], max(tempo.SUPPORTED_CONFIG_VERSIONS)
        )

    def test_test_file_markers_are_configurable(self) -> None:
        tempo = load_script("tempo_markers_test", "src/work_tempo/cli.py")
        base = tempo.default_config()
        self.assertEqual(base.source_kind_for_path("a/widget.cy.ts"), "test")
        custom = dataclasses.replace(base, test_file_markers=(".check.",))
        self.assertEqual(custom.source_kind_for_path("a/widget.cy.ts"), "code")
        self.assertEqual(custom.source_kind_for_path("a/widget.check.ts"), "test")

    def test_invalid_config_stops_the_run_before_any_repository_is_read(self) -> None:
        tempo = load_script("tempo_invalid_config_run_test", "src/work_tempo/cli.py")
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            subprocess.run(["git", "init", "-b", "main"], cwd=repo, check=True, capture_output=True)
            (repo / tempo.CONFIG_FILENAME).write_text(
                json.dumps({"test_dir_name": ["checks"]}), encoding="utf-8"
            )
            argv = ["work-tempo", "--root", str(repo), "--no-html", "--no-cache"]
            stderr = io.StringIO()
            with (
                mock.patch.object(sys, "argv", argv),
                mock.patch.object(sys, "stderr", stderr),
                mock.patch.object(tempo, "list_repos", side_effect=AssertionError("read a repository")),
            ):
                self.assertEqual(tempo.main(), 1)
            self.assertIn("unknown config key 'test_dir_name'", stderr.getvalue())

    def test_documentation_repo_source_like_artifacts_count_as_docs(self) -> None:
        tempo = load_script("tempo_doc_repo_artifacts_test", "src/work_tempo/cli.py")
        config = dataclasses.replace(
            tempo.default_config(), doc_only_repo_names=frozenset({"documentation"})
        )
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

                snap = tempo.count_snapshot(repo, commit, config)
                churn = tempo.collect_churn_by_period(repo, config, commit, period="month")
                source_only_churn = tempo.collect_churn_by_period(repo, config, commit, include_docs=False, period="month")

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
        tempo = load_script("tempo_end_to_end_fixture_test", "src/work_tempo/cli.py")
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
            track_remote_main(repo)

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
            track_remote_main(extra_repo)

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
                    "work-tempo",
                    "--root", str(repo),
                    "--period", "day",
                    "--days", "2",
                    "--workers", "1",
                    "--cache", str(cache),
                    "--html", str(html_path),
                    "--json", str(json_path),
                    "--no-languages",
                ]
                stdout = io.StringIO()
                with (mock.patch.object(sys, "argv", argv),
                      mock.patch.object(sys, "stderr", io.StringIO()),
                      redirect_stdout(stdout)):
                    self.assertEqual(tempo.main(), 0)
                if name == "warm":
                    self.assertIn("0 cutoff lookups", stdout.getvalue())
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
        tempo = load_script("tempo_config_test", "src/work_tempo/cli.py")

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
