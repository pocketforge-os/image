#!/usr/bin/env python3
"""Reject the Build 33 self-flash/cloud-init ordering cycle.

The image overlay owns the grow unit, while cloud-init supplies the stock
units that are not present in this repository.  The small graph below models
the systemd ordering rules relevant to those units, including the default
sysinit dependency for an ordinary service.  It is deliberately hermetic:
it does not start systemd or inspect the host manager.
"""

from __future__ import annotations

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
GROW = ROOT / "rootfs-overlay/etc/systemd/system/pocketforge-self-flash-v3-grow.service"

# These are the Build 33 cloud-init and systemd target contracts extracted
# from the published rootfs.  cloud-init-local is a DefaultDependencies=no
# unit and is explicitly Before=sysinit.target.
CLOUD_INIT_LOCAL = """\
[Unit]
DefaultDependencies=no
Before=network-pre.target shutdown.target sysinit.target
"""
SYSINIT = """\
[Unit]
Wants=local-fs.target swap.target
After=local-fs.target swap.target
"""


def unit_directives(text: str) -> dict[str, list[str]]:
    values: dict[str, list[str]] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith(("#", ";")) or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values.setdefault(key, []).extend(value.split())
    return values


def ordering_edges(units: dict[str, str]) -> dict[str, set[str]]:
    """Return prerequisite -> dependent edges for the relevant unit set."""
    edges = {name: set() for name in units}
    for name, text in units.items():
        directives = unit_directives(text)
        for target in directives.get("After", ()):
            if target in edges:
                edges[target].add(name)
        for target in directives.get("Before", ()):
            if target in edges:
                edges[name].add(target)

        # systemd's DefaultDependencies=yes for services adds
        # Requires=sysinit.target and After=sysinit.target.  Only this
        # ordering edge is needed for the cycle under test.
        if directives.get("DefaultDependencies") != ["no"] and name.endswith(".service"):
            if "sysinit.target" in edges:
                edges["sysinit.target"].add(name)
    return edges


def find_cycle(edges: dict[str, set[str]]) -> tuple[str, ...] | None:
    visiting: list[str] = []
    active: set[str] = set()
    complete: set[str] = set()

    def visit(node: str) -> tuple[str, ...] | None:
        if node in active:
            return tuple(visiting[visiting.index(node) :] + [node])
        if node in complete:
            return None
        active.add(node)
        visiting.append(node)
        for child in sorted(edges[node]):
            cycle = visit(child)
            if cycle is not None:
                return cycle
        visiting.pop()
        active.remove(node)
        complete.add(node)
        return None

    for node in sorted(edges):
        cycle = visit(node)
        if cycle is not None:
            return cycle
    return None


class SelfFlashOrderingTests(unittest.TestCase):
    def graph(self, grow: str) -> dict[str, set[str]]:
        return ordering_edges(
            {
                "pocketforge-self-flash-v3-grow.service": grow,
                "cloud-init-local.service": CLOUD_INIT_LOCAL,
                "sysinit.target": SYSINIT,
            }
        )

    def test_current_overlay_does_not_order_cloud_init_behind_growth(self):
        grow = GROW.read_text(encoding="utf-8")
        self.assertNotRegex(grow, r"(?m)^Before=.*\bcloud-init-local\.service\b")
        self.assertIsNone(find_cycle(self.graph(grow)))

    def test_old_before_edge_is_a_negative_control(self):
        old = GROW.read_text(encoding="utf-8").replace(
            "[Unit]\n",
            "[Unit]\nBefore=cloud-init-local.service cloud-init.service ssh.service\n",
            1,
        )
        cycle = find_cycle(self.graph(old))
        self.assertIsNotNone(cycle)
        self.assertEqual(
            set(cycle or ()),
            {
                "cloud-init-local.service",
                "pocketforge-self-flash-v3-grow.service",
                "sysinit.target",
            },
        )


if __name__ == "__main__":
    unittest.main()
