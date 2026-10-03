#!/usr/bin/env python3
"""Hermetic positive/negative coverage for the local producer guard."""

from __future__ import annotations

import importlib.util
import pathlib
import sys
import tempfile
import textwrap
import unittest


REPO = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "ci_producer_policy", REPO / "scripts" / "ci-producer-policy.py"
)
assert SPEC and SPEC.loader
POLICY = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = POLICY
SPEC.loader.exec_module(POLICY)


SAFE = """
name: safe
on:
  pull_request:
  push:
    branches: [main]
  release:
    types: [published]
concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: true
"""

CONCURRENCY = """concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
"""


class ProducerPolicyTest(unittest.TestCase):
    def audit(self, *documents: str):
        with tempfile.TemporaryDirectory(prefix="ci-producer-policy.") as temporary:
            root = pathlib.Path(temporary)
            workflows = root / ".github" / "workflows"
            workflows.mkdir(parents=True)
            for index, document in enumerate(documents):
                (workflows / f"fixture-{index}.yml").write_text(
                    textwrap.dedent(document), encoding="utf-8"
                )
            return POLICY.audit_repository(root, "main")

    def test_unsafe_forms_fail_with_typed_findings(self) -> None:
        cases = {
            "missing": (
                SAFE.replace(CONCURRENCY, ""),
                {"missing_workflow_concurrency"},
            ),
            "job-only": (
                SAFE.replace(CONCURRENCY, "").replace(
                    "  test:\n",
                    "  test:\n"
                    "    concurrency:\n"
                    "      group: job-${{ github.ref }}\n"
                    "      cancel-in-progress: true\n",
                    1,
                ),
                {"job_only_concurrency", "non_pr_job_cancellation"},
            ),
            "unconditional": (
                SAFE.replace("${{ github.event_name == 'pull_request' }}", "true", 1),
                {"non_pr_cancellation"},
            ),
            "feature-push": (
                SAFE.replace("branches: [main]", "branches: ['**']", 1),
                {"feature_branch_push"},
            ),
            "malformed": (
                SAFE.replace(CONCURRENCY, "concurrency: unsafe\n", 1),
                {"malformed_concurrency"},
            ),
        }
        for label, (document, expected) in cases.items():
            with self.subTest(label=label):
                self.assertEqual({item.code for item in self.audit(document)}, expected)

    def test_safe_mixed_default_release_form_passes(self) -> None:
        self.assertEqual(self.audit(SAFE), ())

    def test_cross_workflow_name_collision_is_rejected(self) -> None:
        findings = self.audit(SAFE, SAFE)
        self.assertEqual(
            [item.code for item in findings],
            ["cross_workflow_group_collision", "cross_workflow_group_collision"],
        )

    def test_repository_workflows_pass(self) -> None:
        self.assertEqual(POLICY.audit_repository(REPO, "main"), ())


if __name__ == "__main__":
    unittest.main()
