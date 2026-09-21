#!/usr/bin/env python3
"""Period-bucketed LOC + churn history for a git workspace and submodules.

Metrics are aggregated across the parent repo, every usable submodule, and
configured extra repos (each repo uses its own history — no attempt is made to
reconcile submodule pointers against the parent):

  - LOC    : snapshot of tracked source lines at each period cutoff, computed by
             extracting `git archive` of the commit at that cutoff and counting
             newlines in files whose extension/name matches the language map.
  - Churn  : per-period total of (added + deleted) lines across non-merge commits
             authored in that period, taken from `git log --numstat --no-merges`
             and filtered through the same path/language rules as LOC.
  - Code/test split: counted paths are classified as code or test using
             conventional test directories and test/spec/e2e filename patterns.

By default, emits a self-contained HTML file under the workspace-specific user
cache directory with stacked LOC/churn charts, a language share chart, and
summary tables. Pass `--json PATH` to write the same report data as versioned
JSON. The latest-period per-language breakdown is printed by default.

By default, cached results are stored under a workspace-specific user cache directory.
Snapshot entries are keyed by repo, commit, and counting filters. Churn entries
are updated incrementally when the previously scanned HEAD is still an ancestor
of the current HEAD; rewritten history triggers a safe full rescan.
"""

from __future__ import annotations

import argparse
import calendar
import hashlib
import json
import os
import stat
import subprocess
import sys
import tempfile
from concurrent.futures import ProcessPoolExecutor, as_completed
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone, tzinfo
from html import escape
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

CACHE_SCHEMA_VERSION = 4
CONFIG_SCHEMA_VERSION = 1
REPORT_SCHEMA_VERSION = 1
CONFIG_FILENAME = ".source-tempo.json"
LOCAL_CONFIG_FILENAME = ".source-tempo.local.json"
REPORT_TITLE = "SourceTempo"
FORECAST_MONTHS = 3
FORECAST_SLOPE_WINDOW_MONTHS = 6

# Extension -> language label. Only extensions listed here count as "code".
# Markdown, JSON, YAML, TOML, and similar config/doc formats are intentionally
# excluded so the numbers reflect source code, not docs.
LANGUAGE_BY_EXT: dict[str, str] = {
    ".kt": "Kotlin", ".kts": "Kotlin",
    ".java": "Java",
    ".py": "Python", ".pyi": "Python",
    ".ts": "TypeScript", ".tsx": "TypeScript",
    ".js": "JavaScript", ".jsx": "JavaScript", ".mjs": "JavaScript", ".cjs": "JavaScript",
    ".vue": "Vue", ".svelte": "Svelte",
    ".go": "Go",
    ".rs": "Rust",
    ".rb": "Ruby",
    ".swift": "Swift",
    ".dart": "Dart",
    ".c": "C", ".h": "C",
    ".cpp": "C++", ".hpp": "C++", ".cc": "C++", ".hh": "C++",
    ".m": "Objective-C", ".mm": "Objective-C",
    ".sh": "Shell", ".bash": "Shell", ".zsh": "Shell",
    ".sql": "SQL",
    ".graphql": "GraphQL", ".gql": "GraphQL",
    ".proto": "Protocol Buffers",
    ".prisma": "Prisma",
    ".tf": "Terraform", ".tfvars": "Terraform",
    ".hcl": "HCL",
    ".gradle": "Gradle",
    ".css": "CSS", ".scss": "CSS", ".sass": "CSS", ".less": "CSS",
    ".html": "HTML",
}

EXCLUDE_EXTS = {".md", ".mdx"}

DOCUMENTATION_BY_EXT: dict[str, str] = {
    ".md": "Markdown",
    ".mdx": "MDX",
    ".rst": "reStructuredText",
    ".adoc": "AsciiDoc",
    ".asciidoc": "AsciiDoc",
}

# Repositories whose tracked source-like artifacts are documentation evidence
# rather than product source. Matching is by repository directory name, so a
# docs checkout is counted as source unless its name is configured here.
DOC_ONLY_REPO_NAMES: set[str] = set()

LANGUAGE_BY_NAME: dict[str, str] = {
    "dockerfile": "Docker",
    "containerfile": "Docker",
    "makefile": "Make",
}

SOURCE_KINDS = ("code", "test")

TEST_DIR_NAMES = {
    "__tests__",
    "androidtest",
    "commontest",
    "cypress",
    "e2e",
    "integration-test",
    "integration-tests",
    "iostest",
    "jstest",
    "jvmtest",
    "nativetest",
    "playwright",
    "spec",
    "specs",
    "test",
    "testfixtures",
    "tests",
    "ui-test",
    "ui-tests",
    "uitest",
    "unit-test",
    "unit-tests",
}

TEST_FILE_EXACT_STEMS = {"spec", "test", "tests", "e2e"}
TEST_FILE_LOWER_PREFIXES = ("test_", "test-")
TEST_FILE_LOWER_SUFFIXES = (
    ".e2e",
    ".spec",
    ".test",
    "-e2e",
    "-spec",
    "-test",
    "_e2e",
    "_spec",
    "_test",
)
TEST_FILE_CASE_SUFFIXES = ("E2E", "IT", "Spec", "Specs", "Test", "Tests")

EXCLUDE_DIRS = {
    "node_modules", ".git", "dist", "build", "out", "target",
    ".next", ".nuxt", ".gradle", ".idea", ".vscode", ".cache",
    "__pycache__", ".pytest_cache", "coverage", ".venv", "venv",
    "DerivedData", ".build", ".turbo", ".parcel-cache",
    "vendor", "_vendor", "third_party", "external", "deps",
    "Pods", "Carthage", "tmp", "temp",
    "generated", "__generated__", "gen",
}

VENDOR_DIRS = {"vendor", "_vendor", "third_party", "external", "deps"}

EXCLUDE_SUBMODULES: set[str] = set()
EXTRA_REPOS: list[dict[str, str]] | None = []

GENERATED_OR_MINIFIED_MARKERS = (
    ".generated.",
    ".gen.",
    ".pb.",
    ".min.",
    ".bundle.",
)

GENERATED_OR_MINIFIED_SUFFIXES = (
    ".g.dart",
    "_pb2.py",
    "_pb2_grpc.py",
    ".designer.cs",
)

GENERATED_OR_MINIFIED_NAMES = {
    "next-env.d.ts",
    "vite-env.d.ts",
    "auto-imports.d.ts",
    "components.d.ts",
    "buildconfig.java",
    "r.java",
}


def default_config_data(report_title: str | None = None) -> dict:
    return {
        "schema_version": CONFIG_SCHEMA_VERSION,
        "report_title": report_title or REPORT_TITLE,
        "language_by_ext": dict(sorted(LANGUAGE_BY_EXT.items())),
        "exclude_exts": sorted(EXCLUDE_EXTS),
        "documentation_by_ext": dict(sorted(DOCUMENTATION_BY_EXT.items())),
        "doc_only_repo_names": sorted(DOC_ONLY_REPO_NAMES),
        "language_by_name": dict(sorted(LANGUAGE_BY_NAME.items())),
        "exclude_dirs": sorted(EXCLUDE_DIRS),
        "vendor_dirs": sorted(VENDOR_DIRS),
        "exclude_submodules": sorted(EXCLUDE_SUBMODULES),
        "extra_repos": list(EXTRA_REPOS or []),
        "generated_or_minified_markers": list(GENERATED_OR_MINIFIED_MARKERS),
        "generated_or_minified_suffixes": list(GENERATED_OR_MINIFIED_SUFFIXES),
        "generated_or_minified_names": sorted(GENERATED_OR_MINIFIED_NAMES),
        "test_dir_names": sorted(TEST_DIR_NAMES),
        "test_file_exact_stems": sorted(TEST_FILE_EXACT_STEMS),
        "test_file_lower_prefixes": list(TEST_FILE_LOWER_PREFIXES),
        "test_file_lower_suffixes": list(TEST_FILE_LOWER_SUFFIXES),
        "test_file_case_suffixes": list(TEST_FILE_CASE_SUFFIXES),
    }


def _string_dict(value: object, name: str) -> dict[str, str]:
    if not isinstance(value, dict):
        raise ValueError(f"{name} must be an object")
    out: dict[str, str] = {}
    for key, item in value.items():
        if not isinstance(key, str) or not isinstance(item, str):
            raise ValueError(f"{name} must map strings to strings")
        out[key] = item
    return out


def _string_list(value: object, name: str) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ValueError(f"{name} must be a string array")
    return value


def _extra_repo_list(value: object, name: str) -> list[dict[str, str]]:
    if not isinstance(value, list):
        raise ValueError(f"{name} must be an array")
    out: list[dict[str, str]] = []
    for idx, item in enumerate(value):
        if not isinstance(item, dict):
            raise ValueError(f"{name}[{idx}] must be an object")
        label = item.get("label")
        path = item.get("path")
        if not isinstance(label, str) or not label:
            raise ValueError(f"{name}[{idx}].label must be a non-empty string")
        if not isinstance(path, str) or not path:
            raise ValueError(f"{name}[{idx}].path must be a non-empty string")
        out.append({"label": label, "path": path})
    return out


def load_workspace_config(path: Path | None) -> dict:
    if path is None or not path.exists():
        return {}
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"failed to read config {path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise ValueError(f"config {path} must be a JSON object")
    return raw


def load_workspace_config_layers(root: Path, explicit_path: Path | None = None) -> dict:
    merged: dict = {}
    paths = (
        root / CONFIG_FILENAME,
        explicit_path if explicit_path is not None else root / LOCAL_CONFIG_FILENAME,
    )
    for path in paths:
        merged.update(load_workspace_config(path))
    return merged


def apply_workspace_config(raw: dict) -> None:
    global REPORT_TITLE
    global LANGUAGE_BY_EXT, EXCLUDE_EXTS, DOCUMENTATION_BY_EXT, LANGUAGE_BY_NAME
    global DOC_ONLY_REPO_NAMES, EXCLUDE_DIRS, VENDOR_DIRS, EXCLUDE_SUBMODULES, EXTRA_REPOS
    global GENERATED_OR_MINIFIED_MARKERS, GENERATED_OR_MINIFIED_SUFFIXES, GENERATED_OR_MINIFIED_NAMES
    global TEST_DIR_NAMES, TEST_FILE_EXACT_STEMS
    global TEST_FILE_LOWER_PREFIXES, TEST_FILE_LOWER_SUFFIXES, TEST_FILE_CASE_SUFFIXES

    if not raw:
        return
    schema_version = raw.get("schema_version", CONFIG_SCHEMA_VERSION)
    if schema_version != CONFIG_SCHEMA_VERSION:
        raise ValueError(f"unsupported config schema_version {schema_version!r}")
    if "report_title" in raw:
        if not isinstance(raw["report_title"], str):
            raise ValueError("report_title must be a string")
        REPORT_TITLE = raw["report_title"]
    if "language_by_ext" in raw:
        LANGUAGE_BY_EXT = _string_dict(raw["language_by_ext"], "language_by_ext")
    if "exclude_exts" in raw:
        EXCLUDE_EXTS = set(_string_list(raw["exclude_exts"], "exclude_exts"))
    if "documentation_by_ext" in raw:
        DOCUMENTATION_BY_EXT = _string_dict(raw["documentation_by_ext"], "documentation_by_ext")
    if "doc_only_repo_names" in raw:
        DOC_ONLY_REPO_NAMES = set(_string_list(raw["doc_only_repo_names"], "doc_only_repo_names"))
    if "language_by_name" in raw:
        LANGUAGE_BY_NAME = _string_dict(raw["language_by_name"], "language_by_name")
    if "exclude_dirs" in raw:
        EXCLUDE_DIRS = set(_string_list(raw["exclude_dirs"], "exclude_dirs"))
    if "vendor_dirs" in raw:
        VENDOR_DIRS = set(_string_list(raw["vendor_dirs"], "vendor_dirs"))
    if "exclude_submodules" in raw:
        EXCLUDE_SUBMODULES = set(_string_list(raw["exclude_submodules"], "exclude_submodules"))
    if "extra_repos" in raw:
        EXTRA_REPOS = _extra_repo_list(raw["extra_repos"], "extra_repos")
    if "generated_or_minified_markers" in raw:
        GENERATED_OR_MINIFIED_MARKERS = tuple(_string_list(raw["generated_or_minified_markers"], "generated_or_minified_markers"))
    if "generated_or_minified_suffixes" in raw:
        GENERATED_OR_MINIFIED_SUFFIXES = tuple(_string_list(raw["generated_or_minified_suffixes"], "generated_or_minified_suffixes"))
    if "generated_or_minified_names" in raw:
        GENERATED_OR_MINIFIED_NAMES = set(_string_list(raw["generated_or_minified_names"], "generated_or_minified_names"))
    if "test_dir_names" in raw:
        TEST_DIR_NAMES = set(_string_list(raw["test_dir_names"], "test_dir_names"))
    if "test_file_exact_stems" in raw:
        TEST_FILE_EXACT_STEMS = set(_string_list(raw["test_file_exact_stems"], "test_file_exact_stems"))
    if "test_file_lower_prefixes" in raw:
        TEST_FILE_LOWER_PREFIXES = tuple(_string_list(raw["test_file_lower_prefixes"], "test_file_lower_prefixes"))
    if "test_file_lower_suffixes" in raw:
        TEST_FILE_LOWER_SUFFIXES = tuple(_string_list(raw["test_file_lower_suffixes"], "test_file_lower_suffixes"))
    if "test_file_case_suffixes" in raw:
        TEST_FILE_CASE_SUFFIXES = tuple(_string_list(raw["test_file_case_suffixes"], "test_file_case_suffixes"))


def default_report_title_for_root(root: Path) -> str:
    return root.name or REPORT_TITLE


def effective_extra_repos() -> list[dict[str, str]]:
    return EXTRA_REPOS or []


def resolve_repo_path(root: Path, repo_path: str) -> Path:
    path = Path(repo_path).expanduser()
    if not path.is_absolute():
        path = root / path
    return path.resolve()


def main_checkout_root(root: Path) -> Path | None:
    out = run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], cwd=root)
    if not out:
        return None
    common_dir = Path(out)
    if common_dir.name == ".git":
        return common_dir.parent.resolve()
    return None


def candidate_repo_paths(root: Path, repo: dict[str, str]) -> list[Path]:
    repo_path = Path(repo["path"]).expanduser()
    candidates: list[Path] = []
    main_root = main_checkout_root(root)
    if not repo_path.is_absolute() and main_root is not None and main_root != root.resolve():
        candidates.append(resolve_repo_path(main_root, repo["path"]))
    candidates.append(resolve_repo_path(root, repo["path"]))
    seen: set[Path] = set()
    out: list[Path] = []
    for path in candidates:
        if path not in seen:
            seen.add(path)
            out.append(path)
    return out


@dataclass
class Snapshot:
    total: int = 0
    by_language: dict[str, int] = field(default_factory=dict)
    by_kind: dict[str, int] = field(default_factory=dict)
    docs_total: int = 0
    docs_by_language: dict[str, int] = field(default_factory=dict)


@dataclass(frozen=True)
class ReportInput:
    root: Path
    report_title: str
    generated_at: datetime
    report_tz: tzinfo
    period: str
    labels: list[str]
    loc_series: list[int]
    doc_loc_series: list[int]
    churn_series: list[int]
    doc_churn_series: list[int]
    doc_added_series: list[int]
    doc_deleted_series: list[int]
    added_series: list[int]
    deleted_series: list[int]
    loc_kind_series: dict[str, list[int]]
    churn_kind_series: dict[str, list[int]]
    added_kind_series: dict[str, list[int]]
    deleted_kind_series: dict[str, list[int]]
    language_series: dict[str, list[int]]
    repo_loc: list[tuple[str, str, int, int, int, int, str | None]]
    language_loc: list[tuple[str, int]]
    skipped_partition: dict[str, list[str]]
    include_vendor: bool
    include_non_product: bool
    include_forecast: bool
    forecast_months: int = FORECAST_MONTHS
    forecast_slope_window_months: int = FORECAST_SLOPE_WINDOW_MONTHS


def run(cmd: list[str], cwd: Path | None = None) -> str | None:
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def git_dir(repo: Path) -> Path | None:
    out = run(["git", "rev-parse", "--git-dir"], cwd=repo)
    if out is None:
        return None
    path = Path(out)
    return (path if path.is_absolute() else repo / path).resolve()


def user_cache_root() -> Path:
    override = os.environ.get("SOURCE_TEMPO_CACHE_HOME")
    if override:
        return Path(override).expanduser().resolve()
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Caches" / "SourceTempo"
    if os.name == "nt":
        base = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local"))
        return base / "SourceTempo" / "Cache"
    return Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "source-tempo"


def workspace_artifact_dir(root: Path) -> Path:
    resolved_root = root.resolve()
    resolved_git_dir = git_dir(resolved_root)
    identity = f"{resolved_root}\n{resolved_git_dir or ''}".encode("utf-8")
    workspace_hash = hashlib.sha256(identity).hexdigest()[:12]
    slug = "".join(
        char.lower() if char.isalnum() else "-"
        for char in (resolved_root.name or "workspace")
    ).strip("-") or "workspace"
    return user_cache_root() / f"{slug}-{workspace_hash}"


def default_cache_path(root: Path) -> Path:
    return workspace_artifact_dir(root) / "cache.json"


def default_html_path(root: Path) -> Path:
    return workspace_artifact_dir(root) / "report.html"


def is_repo_root(repo: Path) -> bool:
    out = run(["git", "rev-parse", "--show-toplevel"], cwd=repo)
    return out is not None and Path(out).resolve() == repo.resolve()


def extra_repo_available(path: Path) -> bool:
    return path.is_dir() and is_repo_root(path)


def git_head(repo: Path) -> str | None:
    return run(["git", "rev-parse", "HEAD"], cwd=repo)


def is_ancestor(repo: Path, ancestor: str, descendant: str) -> bool:
    result = subprocess.run(
        ["git", "merge-base", "--is-ancestor", ancestor, descendant],
        cwd=repo,
        capture_output=True,
    )
    return result.returncode == 0


def active_timezone() -> tzinfo:
    candidates: list[str] = []
    env_timezone = os.environ.get("TZ", "").lstrip(":")
    if env_timezone:
        candidates.append(env_timezone)

    localtime = Path("/etc/localtime")
    try:
        resolved_localtime = localtime.resolve(strict=True).as_posix()
    except OSError:
        resolved_localtime = ""
    marker = "/zoneinfo/"
    if marker in resolved_localtime:
        candidates.append(resolved_localtime.split(marker, 1)[1])

    try:
        configured_timezone = Path("/etc/timezone").read_text(encoding="utf-8").strip()
    except OSError:
        configured_timezone = ""
    if configured_timezone:
        candidates.append(configured_timezone)

    for candidate in candidates:
        try:
            return ZoneInfo(candidate)
        except ZoneInfoNotFoundError:
            continue
    return timezone.utc


def timezone_label(tz: tzinfo) -> str:
    now = datetime.now(tz)
    name = now.tzname() or "UTC"
    offset = now.strftime("%z")
    if offset:
        offset = f"{offset[:3]}:{offset[3:]}"
        return f"{name} ({offset})"
    return name


def timezone_signature(tz: tzinfo) -> str:
    zone_key = getattr(tz, "key", None)
    return str(zone_key or timezone_label(tz)).replace(" ", "_")


def filter_signature(include_vendor: bool) -> str:
    payload = {
        "language_by_ext": LANGUAGE_BY_EXT,
        "language_by_name": LANGUAGE_BY_NAME,
        "documentation_by_ext": DOCUMENTATION_BY_EXT,
        "doc_only_repo_names": sorted(DOC_ONLY_REPO_NAMES),
        "exclude_exts": sorted(EXCLUDE_EXTS),
        "exclude_dirs": sorted(EXCLUDE_DIRS if not include_vendor else EXCLUDE_DIRS - VENDOR_DIRS),
        "generated_markers": GENERATED_OR_MINIFIED_MARKERS,
        "generated_suffixes": GENERATED_OR_MINIFIED_SUFFIXES,
        "generated_names": sorted(GENERATED_OR_MINIFIED_NAMES),
        "source_kinds": SOURCE_KINDS,
        "test_dir_names": sorted(TEST_DIR_NAMES),
        "test_file_exact_stems": sorted(TEST_FILE_EXACT_STEMS),
        "test_file_lower_prefixes": TEST_FILE_LOWER_PREFIXES,
        "test_file_lower_suffixes": TEST_FILE_LOWER_SUFFIXES,
        "test_file_case_suffixes": TEST_FILE_CASE_SUFFIXES,
        "include_vendor": include_vendor,
    }
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()[:16]


def empty_cache() -> dict:
    return {
        "schema_version": CACHE_SCHEMA_VERSION,
        "snapshots": {},
        "churn_repos": {},
    }


def load_cache(path: Path | None) -> dict:
    if path is None or not path.exists():
        return empty_cache()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return empty_cache()
    if not isinstance(data, dict) or data.get("schema_version") != CACHE_SCHEMA_VERSION:
        return empty_cache()
    data.setdefault("snapshots", {})
    data.setdefault("churn_repos", {})
    return data


def atomic_write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        output_mode = stat.S_IMODE(path.stat().st_mode)
    except FileNotFoundError:
        current_umask = os.umask(0)
        os.umask(current_umask)
        output_mode = 0o666 & ~current_umask
    temp_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as handle:
            temp_path = Path(handle.name)
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        temp_path.chmod(output_mode)
        temp_path.replace(path)
        temp_path = None
    finally:
        if temp_path is not None:
            temp_path.unlink(missing_ok=True)


def save_cache(path: Path | None, cache: dict | None) -> None:
    if path is None or cache is None:
        return
    atomic_write_text(path, json.dumps(cache, sort_keys=True))


def snapshot_cache_key(label: str, commit: str, include_vendor: bool) -> str:
    return f"{filter_signature(include_vendor)}|{label}|{commit}"


def churn_cache_key(label: str, include_vendor: bool, report_tz: tzinfo, period: str) -> str:
    return f"{filter_signature(include_vendor)}|{timezone_signature(report_tz)}|{period}|{label}"


def snapshot_to_cache(snap: Snapshot) -> dict:
    return {
        "total": snap.total,
        "by_language": snap.by_language,
        "by_kind": snap.by_kind,
        "docs_total": snap.docs_total,
        "docs_by_language": snap.docs_by_language,
    }


def snapshot_from_cache(data: object) -> Snapshot | None:
    if not isinstance(data, dict):
        return None
    total = data.get("total")
    by_language = data.get("by_language")
    by_kind = data.get("by_kind")
    docs_total = data.get("docs_total", 0)
    docs_by_language = data.get("docs_by_language", {})
    if not isinstance(total, int) or not isinstance(by_language, dict):
        return None
    if not isinstance(docs_total, int) or not isinstance(docs_by_language, dict):
        return None
    clean_by_language: dict[str, int] = {}
    for lang, lines in by_language.items():
        if isinstance(lang, str) and isinstance(lines, int):
            clean_by_language[lang] = lines
    clean_docs_by_language: dict[str, int] = {}
    for lang, lines in docs_by_language.items():
        if isinstance(lang, str) and isinstance(lines, int):
            clean_docs_by_language[lang] = lines
    clean_by_kind: dict[str, int] = {kind: 0 for kind in SOURCE_KINDS}
    if not isinstance(by_kind, dict):
        return None
    for kind, lines in by_kind.items():
        if kind in SOURCE_KINDS and isinstance(lines, int):
            clean_by_kind[kind] = lines
    return Snapshot(
        total=total,
        by_language=clean_by_language,
        by_kind=clean_by_kind,
        docs_total=docs_total,
        docs_by_language=clean_docs_by_language,
    )


def path_parts(path: str) -> tuple[str, ...]:
    return tuple(part for part in Path(path).parts if part not in ("", "."))


def language_for_path(path: str) -> str | None:
    p = Path(path)
    if p.suffix.lower() in EXCLUDE_EXTS:
        return None
    name = p.name.lower()
    lang = LANGUAGE_BY_NAME.get(name)
    if lang:
        return lang
    return LANGUAGE_BY_EXT.get(p.suffix.lower())


def documentation_language_for_path(path: str) -> str | None:
    return DOCUMENTATION_BY_EXT.get(Path(path).suffix.lower())


def is_doc_only_repo(repo: Path) -> bool:
    return repo.name in DOC_ONLY_REPO_NAMES


def doc_only_artifact_language_for_path(path: str) -> str | None:
    return documentation_language_for_path(path) or language_for_path(path)


def source_kind_for_path(path: str) -> str:
    parts = path_parts(path)
    lower_parts = tuple(part.lower() for part in parts)
    if any(part in TEST_DIR_NAMES for part in lower_parts[:-1]):
        return "test"

    p = Path(path)
    name = p.name
    lower_name = name.lower()
    suffix = p.suffix
    stem = name[:-len(suffix)] if suffix else name
    lower_stem = stem.lower()
    if lower_stem in TEST_FILE_EXACT_STEMS:
        return "test"
    if lower_stem.startswith(TEST_FILE_LOWER_PREFIXES):
        return "test"
    if lower_stem.endswith(TEST_FILE_LOWER_SUFFIXES):
        return "test"
    if stem.endswith(TEST_FILE_CASE_SUFFIXES):
        return "test"
    if any(marker in lower_name for marker in (".test.", ".spec.", ".e2e.", ".cy.")):
        return "test"
    return "code"


def is_generated_or_minified(path: str) -> bool:
    lower = path.lower()
    name = Path(path).name.lower()
    if name in GENERATED_OR_MINIFIED_NAMES:
        return True
    if any(marker in lower for marker in GENERATED_OR_MINIFIED_MARKERS):
        return True
    return any(lower.endswith(suffix) for suffix in GENERATED_OR_MINIFIED_SUFFIXES)


def should_count_path(path: str, include_vendor: bool = False) -> bool:
    parts = path_parts(path)
    excluded = EXCLUDE_DIRS if not include_vendor else EXCLUDE_DIRS - VENDOR_DIRS
    if any(part in excluded for part in parts[:-1]):
        return False
    if is_generated_or_minified(path):
        return False
    return language_for_path(path) is not None


def should_count_documentation_path(path: str, include_vendor: bool = False) -> bool:
    parts = path_parts(path)
    excluded = EXCLUDE_DIRS if not include_vendor else EXCLUDE_DIRS - VENDOR_DIRS
    if any(part in excluded for part in parts[:-1]):
        return False
    if is_generated_or_minified(path):
        return False
    return documentation_language_for_path(path) is not None


def gitmodule_paths(root: Path) -> list[str]:
    out = run(
        ["git", "config", "--file", ".gitmodules", "--get-regexp", r"^submodule\..*\.path$"],
        cwd=root,
    ) or ""
    paths: list[str] = []
    seen: set[str] = set()
    for line in out.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1] not in seen:
            seen.add(parts[1])
            paths.append(parts[1])
    return paths


def list_repos(
    root: Path,
    include_vendor: bool = False,
    include_non_product: bool = False,
) -> tuple[list[tuple[str, Path]], list[str]]:
    """Return (label, path) for the parent repo, usable submodules, and configured extra repos."""
    repos: list[tuple[str, Path]] = [("(parent)", root)]
    skipped: list[str] = []
    for sub_path in gitmodule_paths(root):
        if not include_vendor and any(part in EXCLUDE_DIRS for part in path_parts(sub_path)):
            skipped.append(sub_path)
            continue
        if not include_non_product and sub_path in EXCLUDE_SUBMODULES:
            skipped.append(sub_path)
            continue
        full = root / sub_path
        if not full.is_dir() or not is_repo_root(full):
            skipped.append(sub_path)
            continue
        repos.append((sub_path, full))
    for repo in effective_extra_repos():
        label = repo["label"]
        full = next((
            path for path in candidate_repo_paths(root, repo)
            if extra_repo_available(path)
        ), None)
        if full is None:
            skipped.append(label)
        else:
            repos.append((label, full))
    return repos, skipped


def partition_skipped_repos(root: Path, skipped_repos: list[str]) -> dict[str, list[str]]:
    extra_labels = {repo["label"] for repo in effective_extra_repos()}
    declared_submodules = set(gitmodule_paths(root))
    non_product = [r for r in skipped_repos if r in EXCLUDE_SUBMODULES]
    unavailable_extra = [r for r in skipped_repos if r in extra_labels]
    unavailable_submodule = [
        r for r in skipped_repos
        if (
            r in declared_submodules
            and r not in EXCLUDE_SUBMODULES
            and r not in extra_labels
            and not any(part in EXCLUDE_DIRS for part in path_parts(r))
        )
    ]
    vendor_like = [
        r for r in skipped_repos
        if (
            r not in EXCLUDE_SUBMODULES
            and r not in extra_labels
            and r not in unavailable_submodule
        )
    ]
    return {
        "vendor_like": vendor_like,
        "non_product": non_product,
        "unavailable_submodule": unavailable_submodule,
        "unavailable_extra": unavailable_extra,
    }


def find_commit_at(repo: Path, cutoff_iso: str) -> str | None:
    result = subprocess.run(
        ["git", "log", "-1", "--format=%H", f"--before={cutoff_iso}", "HEAD"],
        cwd=repo,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"git log cutoff lookup failed for {repo}: "
            f"{result.stderr.strip() or 'unknown error'}"
        )
    return result.stdout.strip() or None


def count_snapshot(repo: Path, commit: str, include_vendor: bool = False) -> Snapshot:
    """Extract `commit` from `repo` into a temporary directory and count lines."""
    snap = Snapshot()
    archive = subprocess.run(
        ["git", "archive", "--format=tar", commit],
        cwd=repo, capture_output=True,
    )
    if archive.returncode != 0 or not archive.stdout:
        error = archive.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"git archive failed for {repo}: {error or 'empty archive'}")

    with tempfile.TemporaryDirectory(prefix="loc-snap-") as tmp:
        extract = subprocess.run(
            ["tar", "-x", "-C", tmp],
            input=archive.stdout, capture_output=True,
        )
        if extract.returncode != 0:
            error = extract.stderr.decode("utf-8", errors="replace").strip()
            raise RuntimeError(f"tar extraction failed for {repo}: {error or 'unknown error'}")

        excluded = EXCLUDE_DIRS if not include_vendor else EXCLUDE_DIRS - VENDOR_DIRS
        for dirpath, dirnames, filenames in os.walk(tmp):
            dirnames[:] = [d for d in dirnames if d not in excluded]
            for name in filenames:
                fpath = Path(dirpath) / name
                rel = fpath.relative_to(tmp).as_posix()
                lang = language_for_path(rel)
                doc_lang = (
                    doc_only_artifact_language_for_path(rel)
                    if is_doc_only_repo(repo)
                    else documentation_language_for_path(rel)
                )
                if lang is None and doc_lang is None:
                    continue
                if lang is not None and not should_count_path(rel, include_vendor=include_vendor):
                    continue
                if doc_lang is not None and not should_count_documentation_path(rel, include_vendor=include_vendor):
                    if not (is_doc_only_repo(repo) and should_count_path(rel, include_vendor=include_vendor)):
                        continue
                try:
                    with open(fpath, "rb") as fh:
                        lines = sum(1 for _ in fh)
                except OSError:
                    continue
                if doc_lang is not None:
                    snap.docs_total += lines
                    snap.docs_by_language[doc_lang] = snap.docs_by_language.get(doc_lang, 0) + lines
                    continue
                kind = source_kind_for_path(rel)
                snap.total += lines
                snap.by_language[lang] = snap.by_language.get(lang, 0) + lines
                snap.by_kind[kind] = snap.by_kind.get(kind, 0) + lines
    return snap


def _snapshot_task(args: tuple[str, str, bool, dict]) -> Snapshot:
    """Worker entry for ProcessPoolExecutor — must be top-level for pickling."""
    repo_str, commit, include_vendor, workspace_config = args
    apply_workspace_config(workspace_config)
    return count_snapshot(Path(repo_str), commit, include_vendor=include_vendor)


def collect_churn_by_period(
    repo: Path,
    include_vendor: bool = False,
    rev_range: str | None = None,
    report_tz: tzinfo | None = None,
    include_docs: bool = True,
    period: str = "month",
) -> dict[str, dict[str, tuple[int, int]]]:
    """Return {period_label: {source_kind: (added, deleted)}} across repo history.

    Binary files (numstat '-') and files outside LANGUAGE_BY_EXT are skipped.
    """
    cmd = ["git", "log", "--no-merges", "--numstat", "--format=__C__ %aI"]
    if rev_range:
        cmd.append(rev_range)
    result = subprocess.run(
        cmd,
        cwd=repo, capture_output=True, text=True, errors="replace",
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"git log failed for {repo}: {result.stderr.strip() or 'unknown error'}"
        )

    bucket_tz = report_tz or timezone.utc
    buckets: dict[str, dict[str, tuple[int, int]]] = {}
    current_bucket: str | None = None
    for line in result.stdout.splitlines():
        if line.startswith("__C__ "):
            ts = line[6:].strip()
            current_bucket = bucket_for_timestamp(ts, bucket_tz, period)
            continue
        if current_bucket is None or not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        added_s, deleted_s, path = parts[0], parts[1], parts[2]
        if added_s == "-" or deleted_s == "-":
            continue  # binary
        if is_doc_only_repo(repo) and should_count_path(path, include_vendor=include_vendor):
            if not include_docs:
                continue
            kind = "doc"
        elif should_count_path(path, include_vendor=include_vendor):
            kind = source_kind_for_path(path)
        elif include_docs and should_count_documentation_path(path, include_vendor=include_vendor):
            kind = "doc"
        else:
            continue
        try:
            added, deleted = int(added_s), int(deleted_s)
        except ValueError:
            continue
        period_bucket = buckets.setdefault(current_bucket, {})
        prev_added, prev_deleted = period_bucket.get(kind, (0, 0))
        period_bucket[kind] = (prev_added + added, prev_deleted + deleted)
    return buckets


def merge_buckets(
    base: dict[str, dict[str, tuple[int, int]]],
    delta: dict[str, dict[str, tuple[int, int]]],
) -> dict[str, dict[str, tuple[int, int]]]:
    out = {month: dict(by_kind) for month, by_kind in base.items()}
    for month, by_kind in delta.items():
        month_bucket = out.setdefault(month, {})
        for kind, (added, deleted) in by_kind.items():
            prev_added, prev_deleted = month_bucket.get(kind, (0, 0))
            month_bucket[kind] = (prev_added + added, prev_deleted + deleted)
    return out


def _churn_buckets_to_cache(
    buckets: dict[str, dict[str, tuple[int, int]]],
) -> dict[str, dict[str, list[int]]]:
    return {
        month: {kind: [added, deleted] for kind, (added, deleted) in by_kind.items()}
        for month, by_kind in buckets.items()
    }


def _churn_buckets_from_cache(raw: object) -> dict[str, dict[str, tuple[int, int]]] | None:
    if not isinstance(raw, dict):
        return None
    out: dict[str, dict[str, tuple[int, int]]] = {}
    for month, value in raw.items():
        if not isinstance(month, str):
            continue
        if not isinstance(value, dict):
            continue
        month_bucket: dict[str, tuple[int, int]] = {}
        for kind, counts in value.items():
            if (
                kind in SOURCE_KINDS + ("doc",)
                and isinstance(counts, list)
                and len(counts) == 2
                and all(isinstance(v, int) for v in counts)
            ):
                month_bucket[kind] = (counts[0], counts[1])
        out[month] = month_bucket
    return out


def collect_churn_cached(
    label: str,
    repo: Path,
    include_vendor: bool,
    cache: dict | None,
    report_tz: tzinfo,
    period: str,
) -> tuple[dict[str, dict[str, tuple[int, int]]], str]:
    """Return churn buckets and a cache status: hit, incremental, miss, disabled."""
    if cache is None:
        return collect_churn_by_period(
            repo,
            include_vendor=include_vendor,
            report_tz=report_tz,
            include_docs=True,
            period=period,
        ), "disabled"

    head = git_head(repo)
    if head is None:
        return {}, "miss"

    key = churn_cache_key(label, include_vendor, report_tz, period)
    repos_cache = cache.setdefault("churn_repos", {})
    entry = repos_cache.get(key)
    if isinstance(entry, dict):
        cached_head = entry.get("head")
        cached = _churn_buckets_from_cache(entry.get("buckets"))
        if isinstance(cached_head, str) and cached is not None:
            if cached_head == head:
                return cached, "hit"
            if is_ancestor(repo, cached_head, head):
                delta = collect_churn_by_period(
                    repo,
                    include_vendor=include_vendor,
                    rev_range=f"{cached_head}..HEAD",
                    report_tz=report_tz,
                    include_docs=True,
                    period=period,
                )
                merged = merge_buckets(cached, delta)
                repos_cache[key] = {"head": head, "buckets": _churn_buckets_to_cache(merged)}
                return merged, "incremental"

    buckets = collect_churn_by_period(
        repo,
        include_vendor=include_vendor,
        report_tz=report_tz,
        include_docs=True,
        period=period,
    )
    repos_cache[key] = {"head": head, "buckets": _churn_buckets_to_cache(buckets)}
    return buckets, "miss"


def bucket_for_timestamp(timestamp: str, report_tz: tzinfo, period: str) -> str | None:
    try:
        dt = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    except ValueError:
        fallback_len = 10 if period == "day" else 7
        return timestamp[:fallback_len] if len(timestamp) >= fallback_len else None
    fmt = "%Y-%m-%d" if period == "day" else "%Y-%m"
    return dt.astimezone(report_tz).strftime(fmt)


def months_back(n: int, report_tz: tzinfo) -> list[tuple[int, int]]:
    today = datetime.now(report_tz)
    y, m = today.year, today.month
    out: list[tuple[int, int]] = []
    for _ in range(n):
        out.append((y, m))
        m -= 1
        if m == 0:
            m = 12
            y -= 1
    out.reverse()
    return out


def days_back(n: int, report_tz: tzinfo) -> list[str]:
    today = datetime.now(report_tz).date()
    return [
        (today - timedelta(days=offset)).strftime("%Y-%m-%d")
        for offset in range(n - 1, -1, -1)
    ]


def period_labels(period: str, count: int, report_tz: tzinfo) -> list[str]:
    if period == "day":
        return days_back(count, report_tz)
    return [f"{y:04d}-{m:02d}" for y, m in months_back(count, report_tz)]


def add_months(label: str, offset: int) -> str:
    year, month = (int(part) for part in label.split("-", 1))
    month_index = (year * 12 + (month - 1)) + offset
    return f"{month_index // 12:04d}-{month_index % 12 + 1:02d}"


def loc_forecast(
    months_labels: list[str],
    loc_series: list[int],
    report_tz: tzinfo,
    forecast_months: int = FORECAST_MONTHS,
    slope_window_months: int = FORECAST_SLOPE_WINDOW_MONTHS,
    now: datetime | None = None,
) -> list[dict[str, int | str]]:
    if not months_labels or not loc_series or forecast_months <= 0:
        return []
    if len(months_labels) != len(loc_series):
        raise ValueError("months_labels and loc_series must have the same length")

    trend_series = loc_series
    if months_labels:
        current_month = (now or datetime.now(report_tz)).astimezone(report_tz).strftime("%Y-%m")
        if months_labels[-1] == current_month:
            trend_series = loc_series[:-1]

    deltas = [
        trend_series[i] - trend_series[i - 1]
        for i in range(1, len(trend_series))
    ]
    if not deltas:
        return []

    recent_deltas = deltas[-slope_window_months:]
    monthly_delta = max(0.0, sum(recent_deltas) / len(recent_deltas))

    start = loc_series[-1]
    return [
        {
            "month": add_months(months_labels[-1], offset),
            "value": int(round(start + monthly_delta * offset)),
        }
        for offset in range(1, forecast_months + 1)
    ]


def chart_timeline_metadata(
    labels: list[str],
    period: str,
    report_tz: tzinfo,
    now: datetime | None = None,
) -> dict[str, int | float | None]:
    """Describe where the latest open monthly bucket should render."""
    if len(labels) < 2:
        return {
            "currentIndex": None,
            "currentProgress": 1.0,
        }

    local_now = (now or datetime.now(report_tz)).astimezone(report_tz)
    if period == "day":
        current_label = local_now.strftime("%Y-%m-%d")
        if labels[-1] != current_label:
            return {"currentIndex": None, "currentProgress": 1.0}
        elapsed = (
            local_now.hour * 3600
            + local_now.minute * 60
            + local_now.second
            + local_now.microsecond / 1_000_000
        )
        return {
            "currentIndex": len(labels) - 1,
            "currentProgress": min(0.999, max(0.0, elapsed / 86_400)),
        }
    if period != "month":
        return {"currentIndex": None, "currentProgress": 1.0}

    current_label = local_now.strftime("%Y-%m")
    if labels[-1] != current_label:
        return {
            "currentIndex": None,
            "currentProgress": 1.0,
        }

    days_in_month = calendar.monthrange(local_now.year, local_now.month)[1]
    progress = min(0.999, max(0.0, local_now.day / days_in_month))
    return {
        "currentIndex": len(labels) - 1,
        "currentProgress": progress,
    }


def end_of_month_iso(year: int, month: int, report_tz: tzinfo) -> str:
    if month == 12:
        cutoff = datetime(year + 1, 1, 1, tzinfo=report_tz)
    else:
        cutoff = datetime(year, month + 1, 1, tzinfo=report_tz)
    return cutoff.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def end_of_period_iso(label: str, period: str, report_tz: tzinfo) -> str:
    if period == "day":
        cutoff = datetime.fromisoformat(label).replace(tzinfo=report_tz) + timedelta(days=1)
        return cutoff.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    year, month = (int(part) for part in label.split("-", 1))
    return end_of_month_iso(year, month, report_tz)


def format_int(n: int) -> str:
    return f"{n:,}" if n else "-"


def format_signed_int(n: int) -> str:
    if n > 0:
        return f"+{n:,}"
    if n < 0:
        return f"-{abs(n):,}"
    return "-"


def format_with_docs(source_lines: int, doc_lines: int) -> str:
    if doc_lines <= 0:
        return format_int(source_lines)
    source = f"{source_lines:,}" if source_lines else "0"
    return f"{source} ({format_int(doc_lines)})"


def format_compact(n: int) -> str:
    sign = "-" if n < 0 else ""
    n_abs = abs(n)
    if n_abs >= 1_000_000:
        value = n_abs / 1_000_000
        suffix = "M"
    elif n_abs >= 1_000:
        value = n_abs / 1_000
        suffix = "K"
    else:
        return f"{n:,}" if n else "-"
    formatted = f"{value:.1f}".rstrip("0").rstrip(".")
    return f"{sign}{formatted}{suffix}"


def format_signed_compact(n: int) -> str:
    if n > 0:
        return f"+{format_compact(n)}"
    if n < 0:
        return format_compact(n)
    return "-"


def format_with_docs_compact(source_lines: int, doc_lines: int) -> str:
    if doc_lines <= 0:
        return format_compact(source_lines)
    source = format_compact(source_lines) if source_lines else "0"
    return f"{source} ({format_compact(doc_lines)})"


def format_pct(n: float) -> str:
    return f"{n * 100:.1f}%"


def print_table(header: list[str], rows: list[list[str]]) -> None:
    widths = [len(h) for h in header]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(cell))
    sep = "  "

    def fmt(cells: list[str]) -> str:
        return sep.join(
            cell.rjust(widths[i]) if i > 0 else cell.ljust(widths[i])
            for i, cell in enumerate(cells)
        )

    print(fmt(header))
    print(sep.join("-" * w for w in widths))
    for row in rows:
        print(fmt(row))


HTML_TEMPLATE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="icon" href="data:,">
<title>__REPORT_TITLE__ — Source LOC &amp; Churn</title>
<style>
  :root {
    color-scheme: light;
    --bg: #f5f7fb;
    --panel: #ffffff;
    --ink: #172033;
    --muted: #667085;
    --line: #d9e0ea;
    --soft: #eef2f7;
    --blue: #2563eb;
    --green: #059669;
    --orange: #d97706;
  }
  * { box-sizing: border-box; }
  html, body {
    margin: 0;
    padding: 0;
    background: var(--bg);
    color: var(--ink);
    font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont,
      "Segoe UI", sans-serif;
  }
  body { line-height: 1.45; }
  .wrap { max-width: 1240px; margin: 0 auto; padding: 32px 24px 48px; }
  header { margin-bottom: 22px; }
  .title-row {
    display: flex;
    justify-content: space-between;
    gap: 24px;
    align-items: center;
  }
  h1 { font-size: 28px; font-weight: 720; letter-spacing: 0; margin: 0; }
  h2 { font-size: 16px; margin: 0 0 16px; font-weight: 700; }
  .sub { color: var(--muted); font-size: 14px; margin-top: 6px; }
  .pill {
    display: inline-flex;
    align-items: center;
    border: 1px solid var(--line);
    border-radius: 999px;
    background: var(--panel);
    color: var(--muted);
    font-size: 12px;
    padding: 6px 10px;
    white-space: nowrap;
    flex: 0 0 auto;
  }
  .stats {
    display: grid;
    grid-template-columns: repeat(4, minmax(0, 1fr));
    gap: 12px;
    margin-bottom: 16px;
  }
  .stat, .card {
    background: var(--panel);
    border: 1px solid var(--line);
    border-radius: 8px;
    box-shadow: 0 1px 2px rgba(16, 24, 40, 0.04);
  }
  .stat { padding: 14px 16px; min-width: 0; }
  .stat .label {
    color: var(--muted);
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
  }
  .stat .value {
    font-size: 22px;
    font-weight: 720;
    margin-top: 4px;
    white-space: nowrap;
  }
  .stat .hint { color: var(--muted); font-size: 12px; margin-top: 2px; }
  .grid {
    display: grid;
    grid-template-columns: minmax(0, 1.7fr) minmax(320px, 0.9fr);
    gap: 16px;
    align-items: stretch;
  }
  .card { padding: 20px; overflow: hidden; }
  .chart-wrap {
    min-height: 0;
    display: flex;
    flex-direction: column;
  }
  .chart-stack {
    display: grid;
    grid-template-rows: minmax(0, 1fr) minmax(0, 1fr);
    gap: 18px;
    flex: 1;
    min-height: 0;
  }
  .chart-panel {
    display: flex;
    flex-direction: column;
    min-width: 0;
    min-height: 0;
  }
  .chart-title {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    color: var(--muted);
    font-size: 12px;
    font-weight: 650;
    margin-bottom: 6px;
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }
  .chart-title strong {
    color: var(--ink);
    font-size: 13px;
    font-weight: 700;
    text-transform: none;
    letter-spacing: 0;
  }
  .metric-chart {
    display: block;
    width: 100%;
    min-height: 210px;
    flex: 1;
  }
  .legend { display: flex; flex-wrap: wrap; gap: 12px 18px; color: var(--muted); font-size: 13px; margin-top: 4px; }
  .chart-note { color: var(--muted); font-size: 12px; margin: 4px 0 0; }
  .key { display: inline-flex; align-items: center; gap: 7px; }
  .dot { width: 10px; height: 10px; border-radius: 999px; display: inline-block; }
  .language-card { display: grid; grid-template-rows: auto auto minmax(0, 1fr); }
  .donut-wrap { display: flex; justify-content: center; padding: 6px 0 16px; }
  .donut {
    width: 210px;
    height: 210px;
    border-radius: 50%;
    position: relative;
    background: var(--soft);
  }
  .donut::after {
    content: "";
    position: absolute;
    inset: 38px;
    border-radius: 50%;
    background: var(--panel);
    box-shadow: inset 0 0 0 1px var(--line);
  }
  .donut-center {
    position: absolute;
    inset: 0;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    z-index: 1;
    pointer-events: none;
  }
  .donut-center strong { font-size: 24px; line-height: 1.1; }
  .donut-center span { color: var(--muted); font-size: 12px; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th {
    color: var(--muted);
    text-align: left;
    font-weight: 650;
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    border-bottom: 1px solid var(--line);
    padding: 9px 8px;
  }
  td { border-bottom: 1px solid #edf1f6; padding: 9px 8px; vertical-align: middle; }
  td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
  .bar-cell { min-width: 92px; }
  .bar { height: 7px; border-radius: 999px; background: var(--soft); overflow: hidden; }
  .bar > span { display: block; height: 100%; border-radius: inherit; }
  .section { margin-top: 16px; }
  .notes {
    color: var(--muted);
    font-size: 12px;
    margin-top: 14px;
  }
  @media (max-width: 980px) {
    .stats { grid-template-columns: repeat(2, minmax(0, 1fr)); }
    .grid { grid-template-columns: 1fr; }
  }
  @media (max-width: 640px) {
    .title-row {
      flex-direction: column;
      align-items: flex-start;
      gap: 10px;
    }
  }
  @media (max-width: 560px) {
    .wrap { padding: 24px 14px 36px; }
    .stats { grid-template-columns: 1fr; }
    .card { padding: 16px; }
    .metric-chart { min-height: 220px; }
  }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <div class="title-row">
      <h1>__REPORT_TITLE__ Source LOC &amp; Churn</h1>
      <div class="pill">Generated __GENERATED_AT__</div>
    </div>
    <div class="sub">__SUBTITLE__</div>
  </header>

  <div class="stats" id="stats"></div>

  <div class="grid">
    <section class="card chart-wrap">
      <h2>Codebase Growth</h2>
      <div class="chart-stack">
        <div class="chart-panel">
          <div class="chart-title"><strong>LOC Snapshot</strong><span>__LOC_CHART_SUBTITLE__</span></div>
          <svg id="locChart" class="metric-chart" role="img" aria-label="Source LOC chart"></svg>
          <div class="chart-note"><em>LOC colors match the language breakdown on the right.</em></div>
        </div>
        <div class="chart-panel">
          <div class="chart-title"><strong>__CHURN_CHART_TITLE__</strong><span>__CHURN_CHART_SUBTITLE__</span></div>
          <svg id="churnChart" class="metric-chart" role="img" aria-label="Source churn chart"></svg>
        </div>
      </div>
      <div class="legend">
        <span class="key"><span class="dot" style="background:#059669"></span>Code added</span>
        <span class="key"><span class="dot" style="background:#0891b2"></span>Test added</span>
        <span class="key"><span class="dot" style="background:#dc2626"></span>Code deleted</span>
        <span class="key"><span class="dot" style="background:#f97316"></span>Test deleted</span>
        <span class="key"><span class="dot" style="background:#9333ea"></span>Docs changed</span>
        __FORECAST_LEGEND__
      </div>
    </section>

    <section class="card language-card">
      <h2>Current Language Share</h2>
      <div class="donut-wrap">
        <div class="donut" id="languageDonut">
          <div class="donut-center"><strong id="topLanguage"></strong><span id="topLanguageShare"></span></div>
        </div>
      </div>
      <table>
        <thead><tr><th>Language</th><th class="num">Lines</th><th class="num">Share</th></tr></thead>
        <tbody id="languageRows"></tbody>
      </table>
    </section>
  </div>

  <section class="card section">
    <h2>Current LOC by Repo</h2>
    <table>
      <thead><tr><th>Repo</th><th class="num">Lines (Docs)</th><th class="num">Code</th><th class="num">Test</th><th class="num">Share</th><th class="bar-cell"></th></tr></thead>
      <tbody id="repoRows"></tbody>
    </table>
    <div class="notes">__COUNTING_NOTES__</div>
  </section>

  <section class="card section">
    <h2>__DETAIL_TITLE__</h2>
    <table>
      <thead><tr><th>__PERIOD_HEADER__</th><th class="num">LOC (Docs)</th><th class="num">Code LOC</th><th class="num">Test LOC</th><th class="num">__CHANGE_HEADER__</th><th class="num">Churn (Doc)</th><th class="num">Code Churn</th><th class="num">Test Churn</th></tr></thead>
      <tbody id="monthRows"></tbody>
    </table>
  </section>
  </div>

<script>
const DATA = __DATA__;
const COLORS = ["#2563eb", "#059669", "#d97706", "#dc2626", "#7c3aed", "#0891b2", "#be123c", "#65a30d", "#4f46e5", "#475569"];
const KIND_COLORS = {
  codeLoc: "#2563eb",
  testLoc: "#d97706",
  codeAdded: "#059669",
  testAdded: "#0891b2",
  codeDeleted: "#dc2626",
  testDeleted: "#f97316",
  docs: "#9333ea",
};

const fmt = (n) => n == null || Number.isNaN(n) ? "-" : Math.round(n).toLocaleString();
const pct = (n) => `${(n * 100).toFixed(n >= 0.1 ? 1 : 2)}%`;
const signed = (n) => n > 0 ? `+${fmt(n)}` : fmt(n);
const withDocs = (source, docs) => docs > 0 ? `${fmt(source)} (${fmt(docs)})` : fmt(source);

function isInterpolatedCurrentIndex(i) {
  const timeline = DATA.timeline || {};
  return Number.isInteger(timeline.currentIndex) &&
    i === timeline.currentIndex &&
    timeline.currentProgress > 0 &&
    timeline.currentProgress < 1;
}

function scaledX(i, count, pad, innerW) {
  return pad.left + (count === 1 ? innerW / 2 : (i / (count - 1)) * innerW);
}

function actualX(i, count, pad, innerW) {
  if (!isInterpolatedCurrentIndex(i) || i <= 0) {
    return scaledX(i, count, pad, innerW);
  }
  const timeline = DATA.timeline || {};
  const previous = scaledX(i - 1, count, pad, innerW);
  const current = scaledX(i, count, pad, innerW);
  return previous + (current - previous) * timeline.currentProgress;
}

function churnFillRatio(i) {
  if (!isInterpolatedCurrentIndex(i)) return 1;
  return Math.max(0, Math.min(1, (DATA.timeline || {}).currentProgress || 0));
}

function pushChurnRect(els, i, x, y, width, height, color, opacity, title) {
  const ratio = churnFillRatio(i);
  const fillWidth = ratio > 0 ? Math.min(width, Math.max(2, width * ratio)) : 0;
  if (ratio < 1) {
    const restWidth = width - fillWidth;
    if (restWidth > 0) {
      els.push(
        `<rect x="${x + fillWidth}" y="${y}" width="${restWidth}" height="${height}" fill="#e5eaf1" opacity="0.82">` +
        `<title>Remaining __CURRENT_PERIOD_NOUN__ not counted yet</title></rect>`
      );
    }
  }
  if (fillWidth > 0) {
    els.push(
      `<rect x="${x}" y="${y}" width="${fillWidth}" height="${height}" fill="${color}" opacity="${opacity}">` +
      `<title>${title}${ratio < 1 ? " __CURRENT_PERIOD_NOUN__-to-date" : ""}</title></rect>`
    );
  }
}

function renderStats() {
  const root = document.getElementById("stats");
  root.innerHTML = DATA.stats.map((s) => `
    <div class="stat">
      <div class="label">${s.label}</div>
      <div class="value">${s.value}</div>
      <div class="hint">${s.hint || ""}</div>
    </div>
  `).join("");
}

function chartFrame(svgId, values) {
  const svg = document.getElementById(svgId);
  const cssWidth = svg.clientWidth || 1000;
  const cssHeight = svg.clientHeight || 255;
  const width = 1000;
  const height = Math.max(220, Math.round(width * cssHeight / cssWidth));
  const pad = { left: 64, right: 28, top: 16, bottom: 42 };
  const innerW = width - pad.left - pad.right;
  const innerH = height - pad.top - pad.bottom;
  const maxValue = Math.max(...values, 1);
  const x = (i) => pad.left + (DATA.months.length === 1 ? innerW / 2 : (i / (DATA.months.length - 1)) * innerW);
  const y = (v) => pad.top + innerH - (v / maxValue) * innerH;
  const labelEvery = Math.max(1, Math.ceil(DATA.months.length / 6));
  const els = [];

  svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
  svg.setAttribute("xmlns", "http://www.w3.org/2000/svg");

  for (let i = 0; i <= 3; i++) {
    const gy = pad.top + (i / 3) * innerH;
    const value = maxValue - (i / 3) * maxValue;
    els.push(`<line x1="${pad.left}" y1="${gy}" x2="${width - pad.right}" y2="${gy}" stroke="#e5eaf1" stroke-width="1"/>`);
    els.push(`<text x="${pad.left - 10}" y="${gy + 4}" text-anchor="end" font-size="12" fill="#667085">${fmt(value)}</text>`);
  }

  DATA.months.forEach((month, i) => {
    if (i % labelEvery === 0 || i === DATA.months.length - 1) {
      els.push(`<text x="${x(i)}" y="${height - 14}" text-anchor="middle" font-size="12" fill="#667085">${month}</text>`);
    }
  });

  return { svg, width, height, pad, innerW, innerH, maxValue, x, y, els };
}

function timelineLabels() {
  return DATA.months.concat((DATA.locForecast || []).map((point) => point.month));
}

function signedChartFrame(svgId, positiveValues, negativeValues, labels = DATA.months, forceLabelIndexes = []) {
  const svg = document.getElementById(svgId);
  const cssWidth = svg.clientWidth || 1000;
  const cssHeight = svg.clientHeight || 255;
  const width = 1000;
  const height = Math.max(220, Math.round(width * cssHeight / cssWidth));
  const pad = { left: 72, right: 28, top: 16, bottom: 42 };
  const innerW = width - pad.left - pad.right;
  const innerH = height - pad.top - pad.bottom;
  const positiveMax = Math.max(...positiveValues, 1);
  const negativeMax = Math.max(...negativeValues, 0);
  const range = positiveMax + negativeMax || 1;
  const x = (i) => scaledX(i, labels.length, pad, innerW);
  const dataX = (i) => actualX(i, labels.length, pad, innerW);
  const y = (v) => pad.top + ((positiveMax - v) / range) * innerH;
  const zeroY = y(0);
  const labelEvery = Math.max(1, Math.ceil(labels.length / 6));
  const els = [];

  svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
  svg.setAttribute("xmlns", "http://www.w3.org/2000/svg");

  for (let i = 0; i <= 3; i++) {
    const value = (i / 3) * positiveMax;
    const gy = y(value);
    els.push(`<line x1="${pad.left}" y1="${gy}" x2="${width - pad.right}" y2="${gy}" stroke="#e5eaf1" stroke-width="1"/>`);
    els.push(`<text x="${pad.left - 10}" y="${gy + 4}" text-anchor="end" font-size="12" fill="#667085">${fmt(value)}</text>`);
  }
  if (negativeMax > 0) {
    for (let i = 1; i <= 2; i++) {
      const value = -(i / 2) * negativeMax;
      const gy = y(value);
      els.push(`<line x1="${pad.left}" y1="${gy}" x2="${width - pad.right}" y2="${gy}" stroke="#ede7f6" stroke-width="1"/>`);
      els.push(`<text x="${pad.left - 10}" y="${gy + 4}" text-anchor="end" font-size="12" fill="#7e6a9d">-${fmt(Math.abs(value))}</text>`);
    }
  }
  els.push(`<line x1="${pad.left}" y1="${zeroY}" x2="${width - pad.right}" y2="${zeroY}" stroke="#98a2b3" stroke-width="1.5"/>`);

  labels.forEach((month, i) => {
    if (i % labelEvery === 0 || i === labels.length - 1 || forceLabelIndexes.includes(i)) {
      els.push(`<text x="${x(i)}" y="${height - 14}" text-anchor="middle" font-size="12" fill="#667085">${month}</text>`);
    }
  });

  return { svg, width, height, pad, innerW, innerH, positiveMax, negativeMax, range, labels, x, dataX, y, zeroY, els };
}

function renderLocChart() {
  const series = DATA.languageSeries || [];
  const forecast = DATA.locForecast || [];
  const forecastValues = forecast.map((point) => point.value);
  const boundaryIndexes = forecast.length ? [DATA.months.length - 1] : [];
  const chart = signedChartFrame(
    "locChart",
    DATA.loc.concat(forecastValues),
    DATA.docLoc || [],
    timelineLabels(),
    boundaryIndexes,
  );
  const months = DATA.months.length;
  const cumulative = new Array(months).fill(0);
  series.forEach((s, idx) => {
    const color = COLORS[idx % COLORS.length];
    const top = s.values.map((v, i) => cumulative[i] + v);
    const topPts = top.map((v, i) => `${chart.dataX(i)},${chart.y(v)}`).join(" ");
    const botPts = cumulative.map((v, i) => `${chart.dataX(i)},${chart.y(v)}`)
      .reverse().join(" ");
    chart.els.push(
      `<polygon points="${topPts} ${botPts}" fill="${color}" opacity="0.92" stroke="#ffffff" stroke-width="0.5">` +
      `<title>${s.language}: ${fmt(s.values[months - 1])} (latest)</title></polygon>`
    );
    for (let i = 0; i < months; i++) cumulative[i] = top[i];
  });
  const docValues = DATA.docLoc || [];
  if (docValues.some((v) => v > 0)) {
    const topPts = docValues.map((_, i) => `${chart.dataX(i)},${chart.zeroY}`).join(" ");
    const bottomPts = docValues.map((v, i) => `${chart.dataX(i)},${chart.y(-v)}`).reverse().join(" ");
    const pts = docValues.map((v, i) => `${chart.dataX(i)},${chart.y(-v)}`).join(" ");
    chart.els.push(
      `<polygon points="${topPts} ${bottomPts}" fill="${KIND_COLORS.docs}" opacity="0.16">` +
      `<title>Documentation LOC area: informational only, excluded from true LOC</title></polygon>`
    );
    chart.els.push(
      `<polyline points="${pts}" fill="none" stroke="${KIND_COLORS.docs}" stroke-width="3" ` +
      `stroke-dasharray="10 8" stroke-linecap="round" stroke-linejoin="round">` +
      `<title>Documentation LOC: -${fmt(docValues[months - 1])} latest, informational only</title></polyline>`
    );
  }
  if (forecast.length && months > 0) {
    const startIdx = months - 1;
    const forecastPoints = [{ month: DATA.months[startIdx], value: DATA.loc[startIdx] }].concat(forecast);
    const topPts = forecastPoints.map((point, i) => {
      const index = startIdx + i;
      const px = i === 0 ? chart.dataX(index) : chart.x(index);
      return `${px},${chart.y(point.value)}`;
    }).join(" ");
    const bottomPts = forecastPoints.map((_, i) => {
      const index = startIdx + i;
      const px = i === 0 ? chart.dataX(index) : chart.x(index);
      return `${px},${chart.zeroY}`;
    }).reverse().join(" ");
    chart.els.push(
      `<polygon points="${topPts} ${bottomPts}" fill="#475467" opacity="0.10">` +
      `<title>${DATA.forecast.label}: ${fmt(forecast[forecast.length - 1].value)} by ${forecast[forecast.length - 1].month}</title></polygon>`
    );
    chart.els.push(
      `<line x1="${chart.dataX(startIdx)}" y1="${chart.pad.top}" x2="${chart.dataX(startIdx)}" y2="${chart.zeroY}" ` +
      `stroke="#98a2b3" stroke-width="1.25" stroke-dasharray="5 7"/>`
    );
    chart.els.push(
      `<polyline points="${topPts}" fill="none" stroke="#475467" stroke-width="3" ` +
      `stroke-dasharray="9 7" stroke-linecap="round" stroke-linejoin="round">` +
      `<title>${DATA.forecast.label}: ${fmt(forecast[forecast.length - 1].value)} by ${forecast[forecast.length - 1].month}</title></polyline>`
    );
  }
  chart.svg.innerHTML = chart.els.join("");
}

function renderChurnChart() {
  const forecast = DATA.locForecast || [];
  const boundaryIndexes = forecast.length ? [DATA.months.length - 1] : [];
  const chart = signedChartFrame(
    "churnChart",
    DATA.churn,
    DATA.docChurn || [],
    timelineLabels(),
    boundaryIndexes,
  );
  const months = DATA.months.length;
  const barW = Math.max(12, chart.innerW / chart.labels.length * 0.52);
  const baseY = chart.zeroY;
  if (forecast.length && months > 0) {
    chart.els.push(
      `<line x1="${chart.x(months - 1)}" y1="${chart.pad.top}" x2="${chart.x(months - 1)}" y2="${chart.height - chart.pad.bottom}" ` +
      `stroke="#98a2b3" stroke-width="1.25" stroke-dasharray="5 7">` +
      `<title>No churn projected beyond this point</title></line>`
    );
  }
  for (let i = 0; i < months; i++) {
    const bx = chart.x(i) - barW / 2;
    let yCursor = baseY;
    const segments = [
      { label: "code added", value: DATA.addedByKind.code[i] || 0, color: KIND_COLORS.codeAdded },
      { label: "test added", value: DATA.addedByKind.test[i] || 0, color: KIND_COLORS.testAdded },
      { label: "code deleted", value: DATA.deletedByKind.code[i] || 0, color: KIND_COLORS.codeDeleted },
      { label: "test deleted", value: DATA.deletedByKind.test[i] || 0, color: KIND_COLORS.testDeleted },
    ];
    segments.forEach((segment) => {
      if (segment.value <= 0) return;
      const h = (segment.value / chart.range) * chart.innerH;
      yCursor -= h;
      pushChurnRect(
        chart.els,
        i,
        bx,
        yCursor,
        barW,
        h,
        segment.color,
        0.78,
        `${DATA.months[i]} ${segment.label}: ${fmt(segment.value)}`
      );
    });
  }
  const docValues = DATA.docChurn || [];
  if (docValues.some((v) => v > 0)) {
    docValues.forEach((v, i) => {
      if (v <= 0) return;
      const h = (v / chart.range) * chart.innerH;
      const bx = chart.x(i) - barW / 2;
      pushChurnRect(
        chart.els,
        i,
        bx,
        chart.zeroY,
        barW,
        h,
        KIND_COLORS.docs,
        0.42,
        `${DATA.months[i]} doc churn: -${fmt(v)} informational only`
      );
    });
  }
  chart.svg.innerHTML = chart.els.join("");
}

function renderLanguages() {
  const total = DATA.languages.reduce((sum, row) => sum + row.lines, 0) || 1;
  let cursor = 0;
  const segments = DATA.languages.map((row, i) => {
    const start = cursor;
    cursor += row.lines / total * 100;
    return `${COLORS[i % COLORS.length]} ${start.toFixed(4)}% ${cursor.toFixed(4)}%`;
  }).join(", ");
  const top = DATA.languages[0] || { language: "-", lines: 0 };
  document.getElementById("languageDonut").style.background = `conic-gradient(${segments})`;
  document.getElementById("topLanguage").textContent = top.language;
  document.getElementById("topLanguageShare").textContent = `${pct(top.lines / total)} of current LOC`;
  document.getElementById("languageRows").innerHTML = DATA.languages.map((row, i) => `
    <tr>
      <td><span class="dot" style="background:${COLORS[i % COLORS.length]}"></span> ${row.language}</td>
      <td class="num">${fmt(row.lines)}</td>
      <td class="num">${pct(row.lines / total)}</td>
    </tr>
  `).join("");
}

function renderRepos() {
  const total = DATA.repoLoc.reduce((sum, row) => sum + row.lines, 0) || 1;
  document.getElementById("repoRows").innerHTML = DATA.repoLoc.map((row, i) => {
    const share = row.lines / total;
    return `
      <tr>
        <td>${row.repo}</td>
        <td class="num">${withDocs(row.lines, row.docs || 0)}</td>
        <td class="num">${fmt(row.code)}</td>
        <td class="num">${fmt(row.test)}</td>
        <td class="num">${pct(share)}</td>
        <td class="bar-cell"><div class="bar"><span style="width:${Math.max(1, share * 100)}%;background:${COLORS[i % COLORS.length]}"></span></div></td>
      </tr>
    `;
  }).join("");
}

function renderMonths() {
  document.getElementById("monthRows").innerHTML = DATA.months.map((month, i) => {
    const prev = i === 0 ? null : DATA.loc[i - 1];
    const delta = prev == null ? null : DATA.loc[i] - prev;
    return `
      <tr>
        <td>${month}</td>
        <td class="num">${withDocs(DATA.loc[i], (DATA.docLoc || [])[i] || 0)}</td>
        <td class="num">${fmt(DATA.locByKind.code[i])}</td>
        <td class="num">${fmt(DATA.locByKind.test[i])}</td>
        <td class="num">${delta == null ? "-" : signed(delta)}</td>
        <td class="num">${withDocs(DATA.churn[i], (DATA.docChurn || [])[i] || 0)}</td>
        <td class="num">${fmt(DATA.churnByKind.code[i])}</td>
        <td class="num">${fmt(DATA.churnByKind.test[i])}</td>
      </tr>
    `;
  }).join("");
}

renderStats();
renderLocChart();
renderChurnChart();
renderLanguages();
renderRepos();
renderMonths();
</script>
</body>
</html>
"""


def build_report_data(report: ReportInput) -> dict[str, object]:
    sorted_languages = sorted(
        report.language_series.items(),
        key=lambda item: item[1][-1] if item[1] else 0,
        reverse=True,
    )
    forecast_points = (
        loc_forecast(
            report.labels,
            report.loc_series,
            report.report_tz,
            forecast_months=report.forecast_months,
            slope_window_months=report.forecast_slope_window_months,
            now=report.generated_at,
        )
        if report.include_forecast and report.period == "month"
        else []
    )
    repositories = [
        {
            "label": label,
            "path": path,
            "lines": lines,
            "docs": docs,
            "code": code,
            "test": test,
            "commit": commit,
        }
        for label, path, lines, docs, code, test, commit in report.repo_loc
    ]
    document: dict[str, object] = {
        "schemaVersion": REPORT_SCHEMA_VERSION,
        "generatedAt": report.generated_at.isoformat(),
        "workspace": {
            "root": str(report.root),
            "title": report.report_title,
            "timezone": timezone_label(report.report_tz),
            "timezoneAbbreviation": report.generated_at.tzname() or "",
        },
        "scope": {
            "includeVendor": report.include_vendor,
            "includeNonProduct": report.include_non_product,
            "repositories": [
                {"label": repo["label"], "path": repo["path"], "commit": repo["commit"]}
                for repo in repositories
            ],
            "skipped": report.skipped_partition,
        },
        "period": {"kind": report.period, "labels": report.labels},
        "series": {
            "loc": report.loc_series,
            "docLoc": report.doc_loc_series,
            "churn": report.churn_series,
            "docChurn": report.doc_churn_series,
            "docAdded": report.doc_added_series,
            "docDeleted": report.doc_deleted_series,
            "added": report.added_series,
            "deleted": report.deleted_series,
            "locByKind": report.loc_kind_series,
            "churnByKind": report.churn_kind_series,
            "addedByKind": report.added_kind_series,
            "deletedByKind": report.deleted_kind_series,
            "language": [
                {"language": language, "values": values}
                for language, values in sorted_languages
                if any(values)
            ],
        },
        "latest": {
            "repositories": repositories,
            "languages": [
                {"language": language, "lines": lines}
                for language, lines in report.language_loc
                if lines > 0
            ],
        },
        "timeline": chart_timeline_metadata(
            report.labels,
            report.period,
            report.report_tz,
            now=report.generated_at,
        ),
        "forecast": forecast_points,
    }
    if forecast_points:
        document["forecastModel"] = {
            "horizonMonths": report.forecast_months,
            "slopeWindowMonths": report.forecast_slope_window_months,
        }
    return document


def write_json(path: Path, document: dict[str, object]) -> None:
    content = json.dumps(
        document,
        ensure_ascii=False,
        indent=2,
        allow_nan=False,
    )
    atomic_write_text(
        path,
        content + "\n",
    )


def _render_html(
    path: Path,
    months_labels: list[str],
    loc_series: list[int],
    doc_loc_series: list[int],
    churn_series: list[int],
    doc_churn_series: list[int],
    added_series: list[int],
    deleted_series: list[int],
    loc_kind_series: dict[str, list[int]],
    churn_kind_series: dict[str, list[int]],
    added_kind_series: dict[str, list[int]],
    deleted_kind_series: dict[str, list[int]],
    language_series: dict[str, list[int]],
    repo_loc: list[tuple[str, int, int, int, int]],
    language_loc: list[tuple[str, int]],
    skipped_partition: dict[str, list[str]],
    include_vendor: bool,
    report_tz: tzinfo,
    period: str,
    include_forecast: bool = False,
    now: datetime | None = None,
    *,
    report_title: str = REPORT_TITLE,
    timezone_text: str | None = None,
    timezone_abbreviation: str | None = None,
    generated_at: datetime | None = None,
    timeline_override: dict[str, int | float | None] | None = None,
    forecast_points_override: list[dict[str, int | str]] | None = None,
    forecast_months: int = FORECAST_MONTHS,
    forecast_slope_window_months: int = FORECAST_SLOPE_WINDOW_MONTHS,
) -> None:
    period_title = "Daily" if period == "day" else "Monthly"
    period_header = "Day" if period == "day" else "Month"
    period_end = "Day-end" if period == "day" else "Month-end"
    start_loc = loc_series[0] if loc_series else 0
    end_loc = loc_series[-1] if loc_series else 0
    end_doc_loc = doc_loc_series[-1] if doc_loc_series else 0
    net_loc = end_loc - start_loc
    total_churn = sum(churn_series)
    total_doc_churn = sum(doc_churn_series)
    peak_churn = max(churn_series) if churn_series else 0
    peak_idx = churn_series.index(peak_churn) if churn_series else 0
    latest_delta = end_loc - (loc_series[-2] if len(loc_series) > 1 else start_loc)
    growth_pct = (net_loc / start_loc) if start_loc else 0
    churn_ratio = (total_churn / end_loc) if end_loc else 0
    current_code_loc = loc_kind_series.get("code", [0])[-1] if loc_kind_series.get("code") else 0
    current_test_loc = loc_kind_series.get("test", [0])[-1] if loc_kind_series.get("test") else 0
    test_share = (current_test_loc / end_loc) if end_loc else 0
    total_test_churn = sum(churn_kind_series.get("test", []))
    forecast_points = forecast_points_override
    if forecast_points is None:
        forecast_points = (
            loc_forecast(
                months_labels,
                loc_series,
                report_tz=report_tz,
                forecast_months=forecast_months,
                slope_window_months=forecast_slope_window_months,
                now=now,
            )
            if include_forecast and period == "month"
            else []
        )

    stats = [
        {"label": "Current LOC", "value": format_with_docs_compact(end_loc, end_doc_loc), "hint": f"{months_labels[-1]} snapshot; docs in parentheses"},
        {"label": "Code LOC", "value": format_compact(current_code_loc), "hint": "non-test source"},
        {"label": "Test LOC", "value": format_compact(current_test_loc), "hint": format_pct(test_share)},
        {"label": "Net Growth", "value": format_signed_compact(net_loc), "hint": format_pct(growth_pct)},
        {"label": f"Latest {period_header}", "value": format_signed_compact(latest_delta), "hint": f"{months_labels[-1]} LOC change"},
        {"label": "Total Churn", "value": format_with_docs_compact(total_churn, total_doc_churn), "hint": "source churn; doc churn in parentheses"},
        {"label": "Test Churn", "value": format_compact(total_test_churn), "hint": "period total"},
        {"label": "Churn / LOC", "value": f"{churn_ratio:.1f}x", "hint": "period total vs current"},
    ]

    sorted_languages = sorted(
        language_series.items(),
        key=lambda kv: kv[1][-1] if kv[1] else 0,
        reverse=True,
    )
    data = {
        "months": months_labels,
        "loc": loc_series,
        "locForecast": forecast_points,
        "timeline": timeline_override or chart_timeline_metadata(
            months_labels,
            period,
            report_tz,
            now=now,
        ),
        "docLoc": doc_loc_series,
        "churn": churn_series,
        "docChurn": doc_churn_series,
        "added": added_series,
        "deleted": deleted_series,
        "locByKind": loc_kind_series,
        "churnByKind": churn_kind_series,
        "addedByKind": added_kind_series,
        "deletedByKind": deleted_kind_series,
        "languageSeries": [
            {"language": escape(lang), "values": values}
            for lang, values in sorted_languages
            if any(values)
        ],
        "stats": stats,
        "repoLoc": [
            {"repo": escape(repo), "lines": lines, "docs": doc_lines, "code": code_lines, "test": test_lines}
            for repo, lines, doc_lines, code_lines, test_lines in repo_loc
            if lines > 0 or doc_lines > 0
        ],
        "languages": [
            {"language": escape(language), "lines": lines}
            for language, lines in language_loc
            if lines > 0
        ],
    }
    if forecast_points:
        data["forecast"] = {"label": f"{forecast_months}-month LOC forecast"}
    counted_repos = len(repo_loc)
    skipped_note_parts: list[str] = []
    excluded_submodules = skipped_partition.get("vendor_like", []) + skipped_partition.get("non_product", [])
    unavailable_submodules = skipped_partition.get("unavailable_submodule", [])
    unavailable_extra = skipped_partition.get("unavailable_extra", [])
    if excluded_submodules:
        skipped_note_parts.append(
            "Excluded submodules by default (vendor-like or non-product): "
            f"{', '.join(escape(r) for r in excluded_submodules)}."
        )
    if unavailable_submodules:
        skipped_note_parts.append(
            "Declared submodules with no usable checkout: "
            f"{', '.join(escape(r) for r in unavailable_submodules)} (not counted)."
        )
    if unavailable_extra:
        skipped_note_parts.append(
            "Configured extra repos not found on disk: "
            f"{', '.join(escape(r) for r in unavailable_extra)} (not counted)."
        )
    skipped_note = f" {' '.join(skipped_note_parts)}" if skipped_note_parts else ""
    filter_note = (
        "excluding generated, minified, dependency, build, cache, and scratch paths"
        if not include_vendor else
        "excluding generated, minified, build, cache, and scratch paths; vendor-like paths included"
    )
    subtitle = (
        f"{counted_repos} repos · {months_labels[0]} to {months_labels[-1]} · "
        f"tracked source files only, {filter_note} · documentation counted separately · timezone {timezone_text or timezone_label(report_tz)}."
    )
    forecast_note = (
        f" LOC Snapshot forecast is informational only: it uses the average net source LOC delta over the last {forecast_slope_window_months} completed months, or all available completed months when fewer, floored at zero so a net-deletion history projects flat, then projects {forecast_months} future months from the current LOC."
        if forecast_points
        else ""
    )
    notes = (
        f"LOC is physical source lines from tracked files at the {period.lower()}-end commit. "
        "Churn is non-merge author-date added + deleted lines through the same file filter. "
        "Code/test classification is path-based: conventional test directories and test/spec/e2e filename patterns are marked as test. "
        "It is not semantic SLOC: blanks and comments are counted when they are in counted source files. "
        "Documentation is shown in parentheses and chart guide-lines for context only; it is excluded from true LOC, growth, and churn metrics."
        f"{forecast_note}"
        f"{skipped_note}"
        f"{' Pass --include-vendor to include vendor-like paths.' if not include_vendor else ''}"
    )
    loc_chart_subtitle = f"{period_end} source lines, stacked by language; docs shown as guide"
    if forecast_points:
        loc_chart_subtitle += f"; {forecast_months}-month forecast"
    churn_chart_subtitle = "Source churn above axis; doc churn below axis"
    if forecast_points:
        churn_chart_subtitle += "; axis extends to LOC forecast horizon"
    forecast_legend = (
        '<span class="key"><span class="dot" style="background:#475467"></span>Forecast</span>'
        if forecast_points
        else ""
    )
    generated_moment = generated_at or datetime.now(report_tz)
    generated_label = generated_moment.strftime("%Y-%m-%d %H:%M")
    generated_timezone = timezone_abbreviation or generated_moment.tzname()
    if generated_timezone:
        generated_label += f" {generated_timezone}"
    html = (
        HTML_TEMPLATE
        .replace("__DATA__", json.dumps(data, ensure_ascii=False, allow_nan=False))
        .replace("__REPORT_TITLE__", escape(report_title))
        .replace("__LOC_CHART_SUBTITLE__", loc_chart_subtitle)
        .replace("__FORECAST_LEGEND__", forecast_legend)
        .replace("__CHURN_CHART_TITLE__", f"{period_title} Churn")
        .replace("__CHURN_CHART_SUBTITLE__", churn_chart_subtitle)
        .replace("__DETAIL_TITLE__", f"{period_title} Detail")
        .replace("__PERIOD_HEADER__", period_header)
        .replace("__CHANGE_HEADER__", f"{period_title} Change")
        .replace("__CURRENT_PERIOD_NOUN__", period.lower())
        .replace("__SUBTITLE__", escape(subtitle))
        .replace("__GENERATED_AT__", escape(generated_label))
        .replace("__COUNTING_NOTES__", notes)
    )
    atomic_write_text(path, html)


def write_html(path: Path, document: dict[str, object]) -> None:
    document = json.loads(json.dumps(document, ensure_ascii=False, allow_nan=False))
    generated_at = datetime.fromisoformat(str(document["generatedAt"]))
    report_tz = generated_at.tzinfo or timezone.utc
    workspace = document["workspace"]
    scope = document["scope"]
    period = document["period"]
    series = document["series"]
    latest = document["latest"]
    forecast_points = document["forecast"]
    forecast_model = document.get("forecastModel", {})
    _render_html(
        path,
        period["labels"],
        series["loc"],
        series["docLoc"],
        series["churn"],
        series["docChurn"],
        series["added"],
        series["deleted"],
        series["locByKind"],
        series["churnByKind"],
        series["addedByKind"],
        series["deletedByKind"],
        {
            item["language"]: item["values"]
            for item in series["language"]
        },
        [
            (repo["label"], repo["lines"], repo["docs"], repo["code"], repo["test"])
            for repo in latest["repositories"]
        ],
        [
            (language["language"], language["lines"])
            for language in latest["languages"]
        ],
        scope["skipped"],
        scope["includeVendor"],
        report_tz,
        period["kind"],
        include_forecast=bool(forecast_points),
        now=generated_at,
        report_title=workspace["title"],
        timezone_text=workspace["timezone"],
        timezone_abbreviation=workspace.get("timezoneAbbreviation"),
        generated_at=generated_at,
        timeline_override=document["timeline"],
        forecast_points_override=forecast_points,
        forecast_months=forecast_model.get("horizonMonths", len(forecast_points)),
        forecast_slope_window_months=forecast_model.get(
            "slopeWindowMonths",
            FORECAST_SLOPE_WINDOW_MONTHS,
        ),
    )


def main() -> int:
    global REPORT_TITLE

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--months", type=int, default=18)
    parser.add_argument("--period", choices=("month", "day"), default="month",
                        help="Bucket history by month or day (default: month)")
    parser.add_argument("--days", type=int, default=30,
                        help="Number of days when --period day is used (default: 30)")
    parser.add_argument("--root", type=Path, default=None,
                        help="Git workspace to analyze (default: current directory)")
    parser.add_argument("--config", type=Path, default=None,
                        help=("Personal config override path (default: "
                              f"<root>/{LOCAL_CONFIG_FILENAME}, if it exists; tracked defaults "
                              f"load from <root>/{CONFIG_FILENAME})"))
    parser.add_argument("--no-config", action="store_true",
                        help="Ignore tracked and personal workspace config")
    parser.add_argument("--init-config", action="store_true",
                        help=(f"Write built-in defaults to <root>/{LOCAL_CONFIG_FILENAME}, or to "
                              "--config when supplied, then exit"))
    parser.add_argument("--force-config", action="store_true",
                        help="Overwrite an existing config when used with --init-config")
    parser.add_argument("--languages", action=argparse.BooleanOptionalAction, default=True,
                        help=("Print per-language breakdown for the most recent period "
                              "(default: enabled; use --no-languages to suppress)"))
    parser.add_argument("--html", type=Path, default=None,
                        help=("Write a self-contained HTML report to this path "
                              "(default: workspace-specific user cache path)"))
    parser.add_argument("--no-html", action="store_true",
                        help="Do not write the default HTML report")
    parser.add_argument("--json", type=Path, default=None,
                        help="Write the versioned report data as JSON")
    parser.add_argument("--forecast", action=argparse.BooleanOptionalAction, default=False,
                        help=("Include the informational LOC Snapshot forecast in reports "
                              "(default: disabled)"))
    parser.add_argument("--workers", type=int, default=max(1, (os.cpu_count() or 4) - 1),
                        help="Parallel workers for LOC snapshot computation")
    parser.add_argument("--include-vendor", action="store_true",
                        help="Include vendor-like paths and submodules that are excluded by default")
    parser.add_argument("--include-non-product", action="store_true",
                        help="Include workspace paths configured as non-product (default: excluded)")
    parser.add_argument("--cache", type=Path, default=None,
                        help="Cache file path (default: workspace-specific user cache path)")
    parser.add_argument("--no-cache", action="store_true",
                        help="Disable persistent caching")
    parser.add_argument("--clear-cache", action="store_true",
                        help="Delete the cache before running")
    args = parser.parse_args()

    root: Path = (args.root or Path.cwd()).resolve()
    if not (root / ".git").exists():
        print(f"error: {root} is not a git repo", file=sys.stderr)
        return 1

    explicit_config_path = args.config.resolve() if args.config else None
    config_path = None if args.no_config else (explicit_config_path or root / LOCAL_CONFIG_FILENAME)
    if args.init_config:
        if config_path is None:
            print("error: --init-config cannot be used with --no-config", file=sys.stderr)
            return 1
        if config_path.exists() and not args.force_config:
            print(f"error: config already exists: {config_path} (pass --force-config to overwrite)", file=sys.stderr)
            return 1
        config_path.parent.mkdir(parents=True, exist_ok=True)
        config_data = default_config_data(default_report_title_for_root(root))
        config_path.write_text(json.dumps(config_data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"Wrote config: {config_path}")
        return 0

    try:
        workspace_config = (
            {} if args.no_config else load_workspace_config_layers(root, explicit_config_path)
        )
        if "report_title" not in workspace_config:
            REPORT_TITLE = default_report_title_for_root(root)
        apply_workspace_config(workspace_config)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    cache_path = None if args.no_cache else (
        args.cache.resolve() if args.cache else default_cache_path(root)
    )
    html_path = None if args.no_html else (
        args.html.resolve() if args.html else default_html_path(root)
    )
    if args.clear_cache and cache_path and cache_path.exists():
        cache_path.unlink()
    cache = None if args.no_cache else load_cache(cache_path)

    repos, skipped_repos = list_repos(
        root,
        include_vendor=args.include_vendor,
        include_non_product=args.include_non_product,
    )
    report_tz = active_timezone()
    period_count = args.days if args.period == "day" else args.months
    if period_count < 1:
        print("error: period count must be >= 1", file=sys.stderr)
        return 1
    if args.workers < 1:
        print("error: workers must be >= 1", file=sys.stderr)
        return 1
    month_labels = period_labels(args.period, period_count, report_tz)
    period_header = "Days" if args.period == "day" else "Months"

    print(f"Workspace: {root}")
    if workspace_config:
        config_sources = [root / CONFIG_FILENAME]
        config_sources.append(explicit_config_path or root / LOCAL_CONFIG_FILENAME)
        active_config_sources = [str(path) for path in config_sources if path.exists()]
        print(f"Config: {', '.join(active_config_sources)}")
    else:
        print("Config: built-in defaults")
    counted_labels = {label for label, _path in repos}
    extra_labels = {repo["label"] for repo in effective_extra_repos()}
    extra_count = len(counted_labels & extra_labels)
    submodule_count = max(0, len(repos) - 1 - extra_count)
    repo_parts = ["parent", f"{submodule_count} submodules"]
    if extra_count:
        repo_parts.append(f"{extra_count} extra {'repo' if extra_count == 1 else 'repos'}")
    print(f"Repos: {len(repos)} counted repositories ({' + '.join(repo_parts)})")
    skipped_partition = partition_skipped_repos(root, skipped_repos)
    if skipped_repos:
        vendor_like = skipped_partition["vendor_like"]
        non_product = skipped_partition["non_product"]
        unavailable_submodule = skipped_partition["unavailable_submodule"]
        unavailable_extra = skipped_partition["unavailable_extra"]
        if vendor_like:
            print(f"Skipped vendor-like submodules: {', '.join(vendor_like)}")
        if non_product:
            print(f"Skipped non-product submodules: {', '.join(non_product)} (pass --include-non-product to count them)")
        if unavailable_submodule:
            print(f"Skipped declared submodules with no usable checkout: {', '.join(unavailable_submodule)}")
        if unavailable_extra:
            print(f"Skipped unavailable extra repos: {', '.join(unavailable_extra)}")
    print(f"{period_header}: {month_labels[0]} .. {month_labels[-1]}")
    print(f"Timezone: {timezone_label(report_tz)}")
    print(f"Workers: {args.workers}")
    if args.include_vendor:
        print("Counting: tracked source lines; documentation counted separately in parentheses; generated/minified/build/cache/scratch paths excluded; vendor-like paths included")
    else:
        print("Counting: tracked source lines; documentation counted separately in parentheses; generated/minified/dependency/build/cache/scratch paths excluded")
    print(f"Cache: {cache_path if cache_path else 'disabled'}")
    print()

    # ------------------------------------------------------------------ churn
    print("Collecting churn from git log ...")
    churn_all: dict[str, dict[str, dict[str, tuple[int, int]]]] = {}
    churn_cache_counts = {
        "hit": 0,
        "incremental": 0,
        "miss": 0,
        "disabled": 0,
        "error": 0,
    }
    for label, path in repos:
        try:
            churn_all[label], status = collect_churn_cached(
                label,
                path,
                args.include_vendor,
                cache,
                report_tz,
                args.period,
            )
        except RuntimeError as exc:
            churn_all[label] = {}
            status = "error"
            print(f"  warn: churn failed for {label}: {exc}", file=sys.stderr)
        churn_cache_counts[status] = churn_cache_counts.get(status, 0) + 1
    print(
        "  churn cache: "
        f"{churn_cache_counts.get('hit', 0)} hit, "
        f"{churn_cache_counts.get('incremental', 0)} incremental, "
        f"{churn_cache_counts.get('miss', 0)} miss"
        + (f", {churn_cache_counts.get('disabled', 0)} disabled" if args.no_cache else "")
        + (f", {churn_cache_counts['error']} error" if churn_cache_counts["error"] else "")
    )
    save_cache(cache_path, cache)

    # ------------------------------------------------------------------- LOC
    print("Computing LOC snapshots (parallel) ...")
    # Build all (repo, commit) tasks first
    tasks: list[tuple[int, int, Path, str, str]] = []  # month_idx, repo_idx, path, commit, cache_key
    snapshots: list[list[Snapshot | None]] = [[None] * len(repos) for _ in month_labels]
    snapshot_commits: list[list[str | None]] = [[None] * len(repos) for _ in month_labels]
    snapshot_cache_hits = 0
    for mi, period_label in enumerate(month_labels):
        cutoff = end_of_period_iso(period_label, args.period, report_tz)
        for ri, (label, path) in enumerate(repos):
            try:
                commit = find_commit_at(path, cutoff)
            except RuntimeError as exc:
                print(f"  warn: snapshot lookup failed for {label}: {exc}", file=sys.stderr)
                continue
            if commit is None:
                continue
            snapshot_commits[mi][ri] = commit
            key = snapshot_cache_key(label, commit, args.include_vendor)
            cached = (
                snapshot_from_cache(cache.get("snapshots", {}).get(key))
                if cache is not None else None
            )
            if cached is not None:
                snapshots[mi][ri] = cached
                snapshot_cache_hits += 1
            else:
                tasks.append((mi, ri, path, commit, key))

    print(f"  {snapshot_cache_hits} snapshot cache hits")
    print(f"  {len(tasks)} snapshots to compute")

    if tasks and args.workers == 1:
        done_count = 0
        for mi, ri, path, commit, key in tasks:
            try:
                snap = count_snapshot(path, commit, args.include_vendor)
                snapshots[mi][ri] = snap
                if cache is not None:
                    cache.setdefault("snapshots", {})[key] = snapshot_to_cache(snap)
            except Exception as e:
                print(f"  warn: snapshot failed for {repos[ri][0]}: {e}", file=sys.stderr)
            done_count += 1
            if done_count % 20 == 0 or done_count == len(tasks):
                print(f"  {done_count}/{len(tasks)}", flush=True)
                save_cache(cache_path, cache)
    elif tasks:
        with ProcessPoolExecutor(max_workers=args.workers) as pool:
            futures = {
                pool.submit(
                    _snapshot_task,
                    (str(path), commit, args.include_vendor, workspace_config),
                ): (mi, ri, key)
                for mi, ri, path, commit, key in tasks
            }
            done_count = 0
            for fut in as_completed(futures):
                mi, ri, key = futures[fut]
                try:
                    snap = fut.result()
                    snapshots[mi][ri] = snap
                    if cache is not None:
                        cache.setdefault("snapshots", {})[key] = snapshot_to_cache(snap)
                except Exception as e:
                    print(f"  warn: snapshot failed for {repos[ri][0]}: {e}", file=sys.stderr)
                done_count += 1
                if done_count % 20 == 0 or done_count == len(tasks):
                    print(f"  {done_count}/{len(tasks)}", flush=True)
                    save_cache(cache_path, cache)

    # ------------------------------------------------------- aggregation
    period_column = "Day" if args.period == "day" else "Month"
    header = (
        [period_column]
        + [label for label, _ in repos]
        + ["Code LOC", "Test LOC", "Total LOC (Docs)", "Code Churn", "Test Churn", "Churn (Doc)"]
    )
    rows: list[list[str]] = []
    loc_series: list[int] = []
    doc_loc_series: list[int] = []
    churn_series: list[int] = []
    doc_churn_series: list[int] = []
    doc_added_series: list[int] = []
    doc_deleted_series: list[int] = []
    added_series: list[int] = []
    deleted_series: list[int] = []
    loc_kind_series: dict[str, list[int]] = {kind: [] for kind in SOURCE_KINDS}
    churn_kind_series: dict[str, list[int]] = {kind: [] for kind in SOURCE_KINDS}
    added_kind_series: dict[str, list[int]] = {kind: [] for kind in SOURCE_KINDS}
    deleted_kind_series: dict[str, list[int]] = {kind: [] for kind in SOURCE_KINDS}
    language_series: dict[str, list[int]] = {}

    for mi, ym in enumerate(month_labels):
        row = [ym]
        total_loc = 0
        total_doc_loc = 0
        month_by_kind = {kind: 0 for kind in SOURCE_KINDS}
        month_by_lang: dict[str, int] = {}
        for ri in range(len(repos)):
            snap = snapshots[mi][ri]
            if snap is None:
                row.append("-")
            else:
                row.append(format_with_docs(snap.total, snap.docs_total))
                total_loc += snap.total
                total_doc_loc += snap.docs_total
                for kind in SOURCE_KINDS:
                    month_by_kind[kind] += snap.by_kind.get(kind, 0)
                for lang, n in snap.by_language.items():
                    month_by_lang[lang] = month_by_lang.get(lang, 0) + n
        for lang, n in month_by_lang.items():
            series = language_series.setdefault(lang, [0] * len(month_labels))
            series[mi] = n
        total_added = 0
        total_deleted = 0
        total_doc_added = 0
        total_doc_deleted = 0
        month_added_by_kind = {kind: 0 for kind in SOURCE_KINDS}
        month_deleted_by_kind = {kind: 0 for kind in SOURCE_KINDS}
        for label, _ in repos:
            by_kind = churn_all[label].get(ym, {})
            for kind in SOURCE_KINDS:
                added, deleted = by_kind.get(kind, (0, 0))
                month_added_by_kind[kind] += added
                month_deleted_by_kind[kind] += deleted
                total_added += added
                total_deleted += deleted
            doc_added, doc_deleted = by_kind.get("doc", (0, 0))
            total_doc_added += doc_added
            total_doc_deleted += doc_deleted
        total_churn = total_added + total_deleted
        total_doc_churn = total_doc_added + total_doc_deleted
        code_churn = month_added_by_kind["code"] + month_deleted_by_kind["code"]
        test_churn = month_added_by_kind["test"] + month_deleted_by_kind["test"]
        row.append(format_int(month_by_kind["code"]))
        row.append(format_int(month_by_kind["test"]))
        row.append(format_with_docs(total_loc, total_doc_loc))
        row.append(format_int(code_churn))
        row.append(format_int(test_churn))
        row.append(format_with_docs(total_churn, total_doc_churn))
        rows.append(row)
        loc_series.append(total_loc)
        doc_loc_series.append(total_doc_loc)
        churn_series.append(total_churn)
        doc_churn_series.append(total_doc_churn)
        doc_added_series.append(total_doc_added)
        doc_deleted_series.append(total_doc_deleted)
        added_series.append(total_added)
        deleted_series.append(total_deleted)
        for kind in SOURCE_KINDS:
            loc_kind_series[kind].append(month_by_kind[kind])
            added_kind_series[kind].append(month_added_by_kind[kind])
            deleted_kind_series[kind].append(month_deleted_by_kind[kind])
            churn_kind_series[kind].append(month_added_by_kind[kind] + month_deleted_by_kind[kind])

    print()
    print_table(header, rows)

    if args.languages:
        print()
        latest_idx = len(month_labels) - 1
        print(f"Per-language breakdown for {month_labels[latest_idx]}:")
        by_lang: dict[str, int] = {}
        for snap in snapshots[latest_idx]:
            if snap is None:
                continue
            for lang, n in snap.by_language.items():
                by_lang[lang] = by_lang.get(lang, 0) + n
        lang_rows = sorted(by_lang.items(), key=lambda kv: kv[1], reverse=True)
        latest_total = sum(n for _, n in lang_rows)
        print_table(
            ["Language", "Lines", "Share"],
            [[lang, format_int(n), format_pct(n / latest_total if latest_total else 0)] for lang, n in lang_rows],
        )

    if html_path or args.json:
        latest_idx = len(month_labels) - 1
        by_lang: dict[str, int] = {}
        repo_loc: list[tuple[str, str, int, int, int, int, str | None]] = []
        for ri, (label, repo_path) in enumerate(repos):
            snap = snapshots[latest_idx][ri]
            if snap is None:
                repo_loc.append((label, str(repo_path), 0, 0, 0, 0, None))
                continue
            code_lines = snap.by_kind.get("code", 0)
            test_lines = snap.by_kind.get("test", 0)
            repo_loc.append((
                label,
                str(repo_path),
                snap.total,
                snap.docs_total,
                code_lines,
                test_lines,
                snapshot_commits[latest_idx][ri],
            ))
            for lang, n in snap.by_language.items():
                by_lang[lang] = by_lang.get(lang, 0) + n
        repo_loc.sort(key=lambda item: item[2], reverse=True)
        language_loc = sorted(by_lang.items(), key=lambda kv: kv[1], reverse=True)

        document = build_report_data(ReportInput(
            root=root,
            report_title=REPORT_TITLE,
            generated_at=datetime.now(report_tz),
            report_tz=report_tz,
            period=args.period,
            labels=month_labels,
            loc_series=loc_series,
            doc_loc_series=doc_loc_series,
            churn_series=churn_series,
            doc_churn_series=doc_churn_series,
            doc_added_series=doc_added_series,
            doc_deleted_series=doc_deleted_series,
            added_series=added_series,
            deleted_series=deleted_series,
            loc_kind_series=loc_kind_series,
            churn_kind_series=churn_kind_series,
            added_kind_series=added_kind_series,
            deleted_kind_series=deleted_kind_series,
            language_series=language_series,
            repo_loc=repo_loc,
            language_loc=language_loc,
            skipped_partition=skipped_partition,
            include_vendor=args.include_vendor,
            include_non_product=args.include_non_product,
            include_forecast=args.forecast,
        ))
        if html_path:
            html_path.parent.mkdir(parents=True, exist_ok=True)
            write_html(html_path, document)
            print()
            print(f"HTML chart written to: {html_path}")
        if args.json:
            write_json(args.json, document)
            print()
            print(f"JSON report written to: {args.json}")

    save_cache(cache_path, cache)

    return 0


if __name__ == "__main__":
    sys.exit(main())
