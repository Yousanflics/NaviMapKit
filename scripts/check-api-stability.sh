#!/bin/bash
# api-stability : swift-api-digester against the latest version
# tag's public surface. Additive changes pass; breaking changes fail (0.x
# escape valve: an intentional break lands with an allowlist entry in
# scripts/api-breakage-allowlist.txt, reviewed in the same PR).
#
# Driven directly (not via `swift package diagnose-api-breaking-changes`):
# the SwiftPM front end builds the whole graph — which drags in the
# iOS-only provider SDK on a macOS host — and its dump step breaks under a
# custom triple. Instead we build ONLY the public-face targets for the iOS
# simulator triple (they do not depend on the provider), dump each module's
# API JSON for HEAD and for a baseline worktree at the tag, and diagnose
# the pair. Covers the full public surface including the UIKit-gated view
# API — the digester compiles for iOS, unlike a host build.
set -euo pipefail
cd "$(dirname "$0")/.."

MODULES=(NaviMapCore NaviMapScene NaviMapKit NaviAviationMapKit NaviMapOffline)
TRIPLE=arm64-apple-ios18.0-simulator
SDKPATH=$(xcrun --sdk iphonesimulator --show-sdk-path)
ALLOWLIST=scripts/api-breakage-allowlist.txt

# The allowlist is a pattern file, so its comments and blank lines are
# patterns too — and an empty pattern matches every line, which would
# filter away every breakage and leave the gate reporting OK. Only
# meaningful lines are ever handed to grep, and when none remain the
# filter is skipped rather than run with an empty pattern set.
allowlist_patterns() {
    [ -f "$ALLOWLIST" ] || return 0
    grep -vE '^[[:space:]]*(#|$)' "$ALLOWLIST" || true
}

apply_allowlist() {
    local breakage="$1"
    [ -n "$breakage" ] || { printf '%s' "$breakage"; return 0; }
    local patterns
    patterns=$(allowlist_patterns)
    if [ -z "$patterns" ]; then
        printf '%s' "$breakage"
        return 0
    fi
    printf '%s\n' "$breakage" | grep -Fv -f <(printf '%s\n' "$patterns") || true
}

# Proves the filter reports a breakage the allowlist does not name — first
# with a plain allowlist, so a passing second case cannot come from a
# filter that never ran, and then with the comment-and-blank-line shape
# that as a raw pattern file would match every line and hide everything.
self_test() {
    local saved_allowlist="$ALLOWLIST"
    local input="Func Allowed.thing() has been removed
Func Guarded.thing() has been removed"
    local expected="Func Guarded.thing() has been removed"
    local stage result
    for stage in plain with-blank-lines; do
        ALLOWLIST=$(mktemp)
        if [ "$stage" = plain ]; then
            printf 'Func Allowed.thing() has been removed\n' >"$ALLOWLIST"
        else
            printf '# a comment\n\nFunc Allowed.thing() has been removed\n\n' >"$ALLOWLIST"
        fi
        result=$(apply_allowlist "$input")
        rm -f "$ALLOWLIST"
        if [ "$result" != "$expected" ]; then
            ALLOWLIST="$saved_allowlist"
            echo "api-stability self-test: FAILED ($stage: expected the unlisted breakage to survive)" >&2
            echo "  got: ${result:-<nothing>}" >&2
            exit 1
        fi
    done
    ALLOWLIST="$saved_allowlist"
    echo "api-stability self-test: OK (allowlist filters what it names, and comments and blank lines are not patterns)"
}

self_test

latest_tag=$(git tag -l 'v*' --sort=-v:refname | head -1)
if [ -z "$latest_tag" ]; then
    echo "api-stability: no version tag yet — baseline mode, OK"
    exit 0
fi
if [ -z "${MODULES[*]:-}" ]; then
    echo "api-stability FAILED: MODULES is empty; nothing would be compared" >&2
    exit 1
fi
echo "api-stability: comparing public API against ${latest_tag} (${MODULES[*]})"

build_faces() {
    # NaviAviationMapKit pulls the provider via _RuntimeAssembly, so build
    # stops at the Kit layer there; Aviation's own public face (profile +
    # re-exports) is compiled separately below via its sources' owning
    # targets. Build what we can without the provider.
    (cd "$1" && swift build --triple "$TRIPLE" --sdk "$SDKPATH" \
        --target NaviAviationMapKit --scratch-path "$2" >/dev/null)
}

dump_module() { # $1 scratch dir, $2 module, $3 out json
    # Provider binary frameworks (needed to load modules that transitively
    # import them, e.g. the aviation profile via the assembly target).
    local fw_args=""
    for fw in "$1"/artifacts/*/*/*.xcframework/ios-arm64_x86_64-simulator; do
        [ -d "$fw" ] && fw_args="$fw_args -F $fw"
    done
    # shellcheck disable=SC2086
    xcrun swift-api-digester -dump-sdk -module "$2" -o "$3" \
        -sdk "$SDKPATH" -target "$TRIPLE" \
        -I "$1/debug/Modules" $fw_args \
        -avoid-tool-args -abort-on-module-fail
}

baseline_dir=.build/api-baseline
if [ ! -d "$baseline_dir" ]; then
    git worktree add --detach "$baseline_dir" "$latest_tag" >/dev/null
else
    (cd "$baseline_dir" && git checkout --detach "$latest_tag" >/dev/null 2>&1)
fi

build_faces . "$PWD/.build/api-current"
build_faces "$baseline_dir" "$PWD/.build/api-baseline-scratch"

status=0
compared=0
report_dir=.build/api-reports
mkdir -p "$report_dir"
for module in "${MODULES[@]}"; do
    current_json="$report_dir/${module}-current.json"
    baseline_json="$report_dir/${module}-baseline.json"
    if [ ! -d "Sources/$module" ]; then
        echo "api-stability FAILED: listed module ${module} has no sources in the current tree" >&2
        exit 1
    fi
    # Modules absent at the baseline tag are new — additive by definition.
    # Absence is decided from the tag's tree, not from a failed dump: a dump
    # that fails for any other reason is a gate failure, never a skip.
    if [ -z "$(git ls-tree -d "$latest_tag" "Sources/$module")" ]; then
        echo "  ${module}: not present at ${latest_tag} (new module) — OK"
        continue
    fi
    if ! dump_module "$PWD/.build/api-baseline-scratch" "$module" "$baseline_json"; then
        echo "api-stability FAILED: could not dump ${module} at ${latest_tag}" >&2
        exit 1
    fi
    if ! dump_module "$PWD/.build/api-current" "$module" "$current_json"; then
        echo "api-stability FAILED: could not dump ${module} from the current tree" >&2
        exit 1
    fi
    compared=$((compared + 1))
    report="$report_dir/${module}.txt"
    xcrun swift-api-digester -diagnose-sdk \
        -input-paths "$baseline_json" -input-paths "$current_json" \
        >"$report" 2>&1 || true
    breakage=$(grep -E '^[^/]*(has been removed|has been renamed|has been changed|type change|now with|is now|no longer)' "$report" | grep -v '^\s*$' || true)
    breakage=$(apply_allowlist "$breakage")
    if [ -n "$breakage" ]; then
        echo "  ${module}: BREAKING CHANGES vs ${latest_tag}:"
        echo "$breakage" | sed 's/^/    /'
        status=1
    else
        echo "  ${module}: OK"
    fi
done

if [ "$status" -ne 0 ]; then
    echo "api-stability FAILED: unapproved breaking changes vs ${latest_tag}" >&2
    exit 1
fi
# A run that compared nothing proves nothing: an empty or mis-filtered
# module list must not turn into a green result.
if [ "$compared" -eq 0 ]; then
    echo "api-stability FAILED: no module was compared against ${latest_tag} (MODULES: ${MODULES[*]:-none})" >&2
    exit 1
fi
echo "api-stability OK: no unapproved breaking changes vs ${latest_tag}"
