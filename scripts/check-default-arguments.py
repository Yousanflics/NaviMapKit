#!/usr/bin/env python3
"""Default-argument evaluation gate for main-actor-constructed types.

A type constructed on the main actor must not evaluate anything in its
initializer's default arguments: a default may only be a literal, `nil`,
an enum case, or a static member whose definition body is itself a bare
memberwise construction of a constant marker. Every path lookup, file
manager call, URL formation, and home-directory lookup performs file
system work on the caller's thread, invisible to the runtime hook.

Usage: check-default-arguments.py [--ref <git-ref>] [paths...]
       check-default-arguments.py --self-test
Scans Swift sources under Sources/NaviMapKit by default; with --ref the
same paths are read from that git tree instead of the working tree. A scan
path that does not exist is an error, a scan that finds no main-actor type
fails, and the default scan must find every registered type, so a renamed
directory or a mistyped path cannot turn into an empty green.
--self-test runs the gate on its registered known-bad and known-good
fixtures. Each fixture declares the exact set of initializer parameters
the gate must report in an `// expect:` line; the self-test fails on any
parameter missing from or added to that set, so a scanner that silently
loses one detection path cannot report a hollow green.
"""
import re, subprocess, sys, os, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
args = sys.argv[1:]
ref = None
if args == ["--self-test"]:
    me = pathlib.Path(__file__).resolve()
    fixtures = ROOT / "scripts" / "fixtures" / "default-arguments"
    problems = []
    missing = subprocess.run([sys.executable, str(me), "Sources/DoesNotExist"], cwd=ROOT, capture_output=True, text=True)
    if missing.returncode != 2:
        problems.append(f"nonexistent scan path: exit {missing.returncode}, expected 2")
    empty = subprocess.run([sys.executable, str(me), str(fixtures.relative_to(ROOT) / "no-main-actor-types.swift")], cwd=ROOT, capture_output=True, text=True)
    if empty.returncode != 1 or "no main-actor type" not in empty.stdout:
        problems.append(f"scan without main-actor types: exit {empty.returncode}, expected 1 with a denominator failure")
    for name in ("must-fail.swift", "must-pass.swift"):
        rel = fixtures.relative_to(ROOT) / name
        text = (ROOT / rel).read_text()
        em = re.search(r"^// expect:(.*)$", text, re.M)
        if not em:
            problems.append(f"{rel}: no `// expect:` line"); continue
        expected = set(re.findall(r"\w+", em.group(1))) - {"none"}
        run = subprocess.run([sys.executable, str(me), str(rel)], cwd=ROOT, capture_output=True, text=True)
        reported = set(re.findall(r"\.init (\w+):", run.stdout))
        if run.returncode != (1 if expected else 0):
            problems.append(f"{rel}: exit {run.returncode}, expected {1 if expected else 0}")
        if reported != expected:
            problems.append(f"{rel}: reported {sorted(reported)}, expected {sorted(expected)}")
    if problems:
        print("default-arguments self-test: FAILED")
        for pr in problems: print("  " + pr)
        sys.exit(1)
    print("default-arguments self-test: OK (known-bad hits match its expect line exactly, known-good reports none, empty and missing scans fail)")
    sys.exit(0)
if args[:1] == ["--ref"]:
    ref = args[1]; args = args[2:]
default_scan = not args
paths = args or ["Sources/NaviMapKit"]

# Types the default scan must find. A type missing from this list because it
# was renamed or moved is reported so the registration is kept current; the
# point is that the scan can never quietly cover nothing.
REGISTERED = {
    "NaviMapHandle", "NaviMapContentAccess", "NaviMapSceneStore",
    "ContentPipeline", "NaviMapCoordinator", "BackgroundTaskLease",
}

def swift_files():
    files = []
    for p in paths:
        if ref:
            out = subprocess.run(["git", "ls-tree", "-r", "--name-only", ref, p], cwd=ROOT, capture_output=True, text=True).stdout
            found = [f for f in out.split("\n") if f.endswith(".swift")]
        elif (ROOT / p).is_file():
            found = [p]
        elif (ROOT / p).is_dir():
            found = []
            for dirpath, _, names in os.walk(ROOT / p):
                found += [os.path.relpath(os.path.join(dirpath, n), ROOT) for n in names if n.endswith(".swift")]
        else:
            found = []
        if not found:
            print(f"default-arguments ERROR: scan path `{p}` does not exist or has no Swift sources" + (f" at {ref}" if ref else ""))
            sys.exit(2)
        files += found
    return files

def read(path):
    if ref:
        return subprocess.run(["git", "show", f"{ref}:{path}"], cwd=ROOT, capture_output=True, text=True).stdout
    return (ROOT / path).read_text()

sources = {f: read(f) for f in swift_files()}

# 1. Types constructed on the main actor: @MainActor classes/structs.
main_actor_types = set()
for text in sources.values():
    for m in re.finditer(r"@MainActor\s+(?:package|public|internal|private|fileprivate)?\s*(?:final\s+)?(?:class|struct)\s+(\w+)", text):
        main_actor_types.add(m.group(1))

# 2. Default arguments in their initializers.
failures = []
param_default = re.compile(r"(\w+):\s*([^=\n]+?)\s*=\s*((?:[^,()\n]|\([^()]*\))+)")

ENUM_CASE = object()

def find_member_body(ptype, member):
    tname = ptype.split(".")[-1].rstrip("?")
    # An enum case is a constant marker by definition.
    for text in sources.values():
        em = re.search(r"enum\s+" + re.escape(tname) + r"\b[^{]*\{", text)
        if em:
            depth = 1; i = em.end()
            while i < len(text) and depth:
                if text[i] == "{": depth += 1
                elif text[i] == "}": depth -= 1
                i += 1
            body = text[em.end():i-1]
            if re.search(r"\bcase\b[^\n]*\b" + re.escape(member) + r"\b", body):
                return ENUM_CASE
    for text in sources.values():
        tm = re.search(r"(?:struct|class|enum)\s+" + re.escape(tname) + r"\b[\s\S]*", text)
        if not tm:
            continue
        block = tm.group(0)
        mm = re.search(r"static\s+(?:var|let|func)\s+`?" + re.escape(member) + r"`?\b[^{=\n]*(?:\{|=)", block)
        if not mm:
            continue
        start = mm.end()
        if block[mm.end()-1] == "=":
            return block[start:block.find("\n", start)]
        depth = 1; i = start
        while i < len(block) and depth:
            if block[i] == "{": depth += 1
            elif block[i] == "}": depth -= 1
            i += 1
        return block[start:i-1]
    return None

for path, text in sources.items():
    for im in re.finditer(r"\n(\s*)(?:package|public|internal|private|fileprivate)?\s*init\(", text):
        # Balanced-parenthesis scan: defaults such as `.seconds(8)` and
        # types such as `(any P)?` contain parentheses of their own.
        depth = 1; i = im.end()
        while i < len(text) and depth:
            if text[i] == "(": depth += 1
            elif text[i] == ")": depth -= 1
            i += 1
        params = text[im.end():i-1]
        owner = None
        for tm in re.finditer(r"(?:class|struct)\s+(\w+)", text[:im.start()]):
            owner = tm.group(1)
        if owner not in main_actor_types:
            continue
        for pm in param_default.finditer(params):
            name, ptype, default = pm.group(1), pm.group(2).strip(), pm.group(3).strip()
            if default in ("nil", "true", "false") or re.fullmatch(r"-?\d+(\.\d+)?", default) or re.fullmatch(r"\"[^\"]*\"", default):
                continue
            if re.fullmatch(r"\.\w+", default):
                member = default[1:]
                body = find_member_body(ptype, member)
                if body is ENUM_CASE:
                    continue
                if body is None:
                    failures.append(f"{path}: {owner}.init {name}: default `{default}` on `{ptype}` — definition not found for review")
                    continue
                bad = [c for c in re.findall(r"\b([A-Za-z_]\w*)\s*\(", body) if c not in (ptype.split(".")[-1].rstrip("?"), "init")]
                if bad:
                    failures.append(f"{path}: {owner}.init {name}: `{ptype}.{member}` evaluates {sorted(set(bad))}")
                continue
            failures.append(f"{path}: {owner}.init {name}: default `{default}` is an expression evaluated on the main actor")

label = ref or "working tree"
if not main_actor_types:
    print(f"default-arguments FAILED ({label}): no main-actor type found under {paths}; the scan covered nothing")
    sys.exit(1)
if default_scan:
    missing_types = sorted(REGISTERED - main_actor_types)
    if missing_types:
        print(f"default-arguments FAILED ({label}): registered main-actor types not found: {missing_types}; update the registration if they were renamed or moved")
        sys.exit(1)
if failures:
    print(f"default-arguments FAILED ({label}): main-actor initializer defaults that evaluate:")
    for f in failures: print("  " + f)
    sys.exit(1)
print(f"default-arguments OK ({label}): {len(main_actor_types)} main-actor types checked")
