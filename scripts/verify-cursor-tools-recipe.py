#!/usr/bin/env python3
"""Bind cursor provenance to the immutable tools image that produced it."""

from __future__ import annotations

import sys


TOOLS_RECIPES = {
    "10.0.32.86:5555/pocketforge/ci-tools@sha256:2ff536627228c90e5c32b7d6345b21600a38a17481c075b41683db47ead3e862":
        "ec5b2621f636261978d3bb4fd9843ae22a59c320",
}


def main() -> int:
    if len(sys.argv) != 3 or TOOLS_RECIPES.get(sys.argv[1]) != sys.argv[2]:
        print(
            "cursor_tools_recipe_binding=refused "
            "reason=tools_recipe_binding_mismatch",
            file=sys.stderr,
        )
        return 2
    print("cursor_tools_recipe_binding=pass")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
