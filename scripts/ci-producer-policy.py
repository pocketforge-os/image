#!/usr/bin/env python3
"""Fail closed when public-repository workflow producers can accumulate stale PR CI.

This local guard is intentionally self-contained: this public repository cannot
resolve the canonical private pocketforge-automation action. Keep its contract
aligned with pocketforge-automation's ci-producer-policy/v1 interface.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
from dataclasses import dataclass
from typing import Any

try:
    import yaml
except ImportError as exc:  # pragma: no cover - fail-closed runtime admission
    raise SystemExit(f"policy_status=error reason=pyyaml_missing detail={exc}")


STANDARD_GROUP_PARTS = (
    "${{github.workflow}}",
    "${{github.event.pull_request.number||github.ref}}",
)
PR_ONLY_CANCELLATION = "${{github.event_name=='pull_request'}}"


class UniqueKeyLoader(yaml.BaseLoader):
    """Keep expressions verbatim and reject duplicate YAML mapping keys."""

    def construct_mapping(self, node: yaml.MappingNode, deep: bool = False) -> dict[Any, Any]:
        mapping: dict[Any, Any] = {}
        for key_node, value_node in node.value:
            key = self.construct_object(key_node, deep=deep)
            if key in mapping:
                raise yaml.constructor.ConstructorError(
                    "while constructing a mapping",
                    node.start_mark,
                    f"found duplicate key {key!r}",
                    key_node.start_mark,
                )
            mapping[key] = self.construct_object(value_node, deep=deep)
        return mapping


@dataclass(frozen=True, order=True)
class Finding:
    code: str
    workflow: str
    location: str
    detail: str


def compact(value: object) -> str:
    return re.sub(r"\s+", "", value) if isinstance(value, str) else ""


def event_mapping(raw: object) -> tuple[dict[str, object], str | None]:
    if isinstance(raw, str):
        return {raw: None}, None
    if isinstance(raw, list) and all(isinstance(item, str) for item in raw):
        return {item: None for item in raw}, None
    if isinstance(raw, dict) and all(isinstance(key, str) for key in raw):
        return raw, None
    return {}, "on must be a string, sequence, or mapping"


def string_list(value: object) -> list[str] | None:
    if isinstance(value, str):
        return [value]
    if isinstance(value, list) and all(isinstance(item, str) for item in value):
        return value
    return None


def push_findings(file: str, push: object, default_branch: str) -> list[Finding]:
    if push is None:
        return [Finding("feature_branch_push", file, "on.push", "unfiltered push trigger")]
    if not isinstance(push, dict):
        return [Finding("malformed_push", file, "on.push", "push trigger must be a mapping")]
    if "branches-ignore" in push:
        return [
            Finding(
                "feature_branch_push",
                file,
                "on.push",
                "branches-ignore admits an open-ended feature-branch set",
            )
        ]
    branches = push.get("branches")
    tags = push.get("tags")
    if branches is None:
        if tags is None:
            return [Finding("feature_branch_push", file, "on.push", "push has no branch filter")]
        if string_list(tags) is None:
            return [Finding("malformed_push", file, "on.push", "tags must be strings")]
        return []
    parsed = string_list(branches)
    if parsed != [default_branch]:
        return [
            Finding(
                "feature_branch_push",
                file,
                "on.push",
                f"branches={parsed!r}; expected only default branch {default_branch!r}",
            )
        ]
    if tags is not None and string_list(tags) is None:
        return [Finding("malformed_push", file, "on.push", "tags must be strings")]
    return []


def concurrency_findings(file: str, document: dict[str, object]) -> list[Finding]:
    findings: list[Finding] = []
    concurrency = document.get("concurrency")
    jobs = document.get("jobs")
    job_blocks: list[tuple[str, dict[str, object]]] = []
    if isinstance(jobs, dict):
        for job_name, job in jobs.items():
            if isinstance(job_name, str) and isinstance(job, dict):
                block = job.get("concurrency")
                if isinstance(block, dict):
                    job_blocks.append((job_name, block))

    if concurrency is None:
        code = "job_only_concurrency" if job_blocks else "missing_workflow_concurrency"
        findings.append(
            Finding(code, file, "concurrency", "pull_request workflow lacks workflow concurrency")
        )
        workflow_group = ""
    elif not isinstance(concurrency, dict):
        findings.append(Finding("malformed_concurrency", file, "concurrency", "must be a mapping"))
        workflow_group = ""
    else:
        workflow_group = compact(concurrency.get("group"))
        if not all(part in workflow_group for part in STANDARD_GROUP_PARTS):
            findings.append(
                Finding(
                    "malformed_group",
                    file,
                    "concurrency.group",
                    "must identify workflow plus pull request number/ref",
                )
            )
        if compact(concurrency.get("cancel-in-progress")) != PR_ONLY_CANCELLATION:
            findings.append(
                Finding(
                    "non_pr_cancellation",
                    file,
                    "concurrency.cancel-in-progress",
                    "must equal github.event_name == 'pull_request'",
                )
            )

    for job_name, block in job_blocks:
        location = f"jobs.{job_name}.concurrency"
        if workflow_group and compact(block.get("group")) == workflow_group:
            findings.append(
                Finding(
                    "workflow_job_group_collision",
                    file,
                    f"{location}.group",
                    "job and workflow groups are identical and can deadlock",
                )
            )
        cancellation = compact(block.get("cancel-in-progress"))
        if "cancel-in-progress" in block and cancellation not in ("false", PR_ONLY_CANCELLATION):
            findings.append(
                Finding(
                    "non_pr_job_cancellation",
                    file,
                    f"{location}.cancel-in-progress",
                    "must be false or conditional on pull_request",
                )
            )
    return findings


def audit_repository(root: pathlib.Path, default_branch: str) -> tuple[Finding, ...]:
    workflow_dir = root / ".github" / "workflows"
    if not workflow_dir.is_dir():
        return (Finding("workflow_directory_missing", "-", str(workflow_dir), "directory is absent"),)
    files = sorted((*workflow_dir.glob("*.yml"), *workflow_dir.glob("*.yaml")))
    if not files:
        return (Finding("workflow_inventory_empty", "-", str(workflow_dir), "zero workflows"),)

    findings: list[Finding] = []
    names: dict[str, list[str]] = {}
    for path in files:
        relative = path.relative_to(root).as_posix()
        try:
            document = yaml.load(path.read_text(encoding="utf-8"), Loader=UniqueKeyLoader)
        except (OSError, UnicodeError, yaml.YAMLError) as exc:
            findings.append(Finding("workflow_unparseable", relative, "-", str(exc).splitlines()[0]))
            continue
        if not isinstance(document, dict):
            findings.append(Finding("workflow_not_mapping", relative, "-", "root must be a mapping"))
            continue
        events, event_error = event_mapping(document.get("on"))
        if event_error:
            findings.append(Finding("malformed_triggers", relative, "on", event_error))
        name = document.get("name")
        if not isinstance(name, str) or not name.strip():
            findings.append(Finding("workflow_name_missing", relative, "name", "non-empty name required"))
            name = relative
        if "pull_request" in events:
            names.setdefault(name, []).append(relative)
            findings.extend(concurrency_findings(relative, document))
        if "push" in events:
            findings.extend(push_findings(relative, events["push"], default_branch))

    for name, paths in sorted(names.items()):
        if len(paths) > 1:
            for path in paths:
                findings.append(
                    Finding(
                        "cross_workflow_group_collision",
                        path,
                        "name",
                        f"workflow name {name!r} is shared by {paths!r}",
                    )
                )
    return tuple(sorted(findings))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path.cwd())
    parser.add_argument("--default-branch", required=True)
    args = parser.parse_args(argv)
    findings = audit_repository(args.root.resolve(), args.default_branch)
    print(f"policy_status={'fail' if findings else 'pass'} findings={len(findings)}")
    for item in findings:
        print(
            f"policy_finding code={item.code} workflow={item.workflow} "
            f"location={item.location} detail={item.detail}"
        )
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
