#!/usr/bin/env python3
"""Symbol-graph audits.

Two rules over the public products' symbol graphs:
  1. provider-isolation: no public symbol references MapboxMaps/MapboxCoreMaps/
     MapboxCommon/Turf modules.
  2. api-optionals: no public declaration signature contains a banned Optional
     (currently Optional<VerticalCoordinate> / VerticalCoordinate?).

Usage: check-symbol-graph.py <symbolgraph-dir>
Before any public symbols exist an empty or missing directory passes with a
notice, so the job stays wired and turns meaningful once symbols appear.
"""
import json
import pathlib
import sys

BANNED_MODULES = {"MapboxMaps", "MapboxCoreMaps", "MapboxCommon", "Turf"}
BANNED_OPTIONAL_FRAGMENTS = ["Optional<VerticalCoordinate>", "VerticalCoordinate?"]


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check-symbol-graph.py <symbolgraph-dir>", file=sys.stderr)
        return 2
    root = pathlib.Path(sys.argv[1])
    graphs = sorted(root.glob("*.symbols.json")) if root.exists() else []
    if not graphs:
        print("symbol-graph: no graphs found (no public symbols yet) — OK")
        return 0

    failures = []
    for path in graphs:
        data = json.loads(path.read_text())
        for rel in data.get("relationships", []):
            target = rel.get("targetFallback", "")
            if target.split(".")[0] in BANNED_MODULES:
                failures.append(f"{path.name}: references {target}")
        for symbol in data.get("symbols", []):
            fragments = "".join(
                f.get("spelling", "")
                for f in symbol.get("declarationFragments", [])
            )
            for banned in BANNED_OPTIONAL_FRAGMENTS:
                if banned in fragments:
                    name = symbol.get("names", {}).get("title", "?")
                    failures.append(f"{path.name}: {name} exposes {banned}")

    if failures:
        print("symbol-graph audit FAILED:", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1
    print(f"symbol-graph audit OK ({len(graphs)} graphs)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
