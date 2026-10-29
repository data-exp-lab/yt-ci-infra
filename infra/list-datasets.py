#!/usr/bin/env python3
"""List the test datasets a yt checkout references, one top-level name per line.

usage: python3 infra/list-datasets.py /path/to/yt [--verbose] > infra/datasets.txt

Walks every test module under yt/, finds calls to the answer-testing helpers (requires_ds,
requires_file, data_dir_load, can_run_ds, load) and resolves their first argument through
module-level string constants, since the tests mostly write

    g30 = "IsolatedGalaxy/galaxy0030/galaxy0030"
    @requires_ds(g30)

Output is the first path component of each resolved name, which is what the seeding script
fetches as <name>.tar.gz. Unresolvable arguments (computed paths, function parameters) go to
stderr with --verbose so they can be chased by hand.
"""

from __future__ import annotations

import argparse
import ast
import sys
from pathlib import Path

CALLS = {"requires_ds", "requires_file", "data_dir_load", "can_run_ds", "load"}


def const_assignments(tree: ast.Module) -> dict[str, str]:
    """Module-level NAME = "string" (and NAME = other_NAME) bindings."""
    names: dict[str, str] = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1:
            target = node.targets[0]
            if not isinstance(target, ast.Name):
                continue
            value = resolve(node.value, names)
            if value is not None:
                names[target.id] = value
    return names


def resolve(node: ast.expr, names: dict[str, str]) -> str | None:
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.Name):
        return names.get(node.id)
    if isinstance(node, ast.JoinedStr):  # f-string: keep literal parts, drop placeholders
        parts = [resolve(v, names) for v in node.values if isinstance(v, ast.Constant)]
        return "".join(p for p in parts if p) or None
    if isinstance(node, ast.Call):  # os.path.join(a, b, ...): first arg is the dataset dir
        fn = node.func
        if isinstance(fn, ast.Attribute) and fn.attr == "join" and node.args:
            return resolve(node.args[0], names)
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        left = resolve(node.left, names)
        return left
    return None


def call_name(node: ast.Call) -> str | None:
    fn = node.func
    if isinstance(fn, ast.Name):
        return fn.id
    if isinstance(fn, ast.Attribute):
        return fn.attr
    return None


def scan(path: Path, verbose: bool) -> set[str]:
    try:
        tree = ast.parse(path.read_text(), filename=str(path))
    except SyntaxError as e:
        print(f"skip {path}: {e}", file=sys.stderr)
        return set()
    names = const_assignments(tree)
    found: set[str] = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call) or call_name(node) not in CALLS or not node.args:
            continue
        value = resolve(node.args[0], names)
        if value is None:
            if verbose:
                src = ast.get_source_segment(path.read_text(), node) or "?"
                print(f"unresolved {path}:{node.lineno}: {src.splitlines()[0]}", file=sys.stderr)
            continue
        if value.startswith(("/", "~", ".", "http")):
            if verbose:
                print(f"skipped-path {path}:{node.lineno}: {value}", file=sys.stderr)
            continue
        found.add(value.split("/")[0])
    return found


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("yt_repo", type=Path, help="path to a yt checkout")
    ap.add_argument("--verbose", action="store_true", help="report unresolved arguments on stderr")
    args = ap.parse_args()

    root = args.yt_repo / "yt"
    if not root.is_dir():
        print(f"{args.yt_repo} does not look like a yt checkout (no yt/ package)", file=sys.stderr)
        return 2

    datasets: set[str] = set()
    files = sorted(
        p for p in root.rglob("*.py") if "tests" in p.parts or p.name.startswith("test_")
    )
    for path in files:
        datasets |= scan(path, args.verbose)

    for name in sorted(datasets, key=str.lower):
        print(name)
    print(f"{len(datasets)} datasets from {len(files)} test modules", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
