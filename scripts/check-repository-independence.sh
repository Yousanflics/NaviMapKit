#!/usr/bin/env bash
# Repository independence gate: this SDK carries no trace of any consuming
# product, organisation, ticket system, or chat surface, and no CJK text.
# The rule covers every tracked file and every new commit message.
#
# Scope note: commit-message checking looks only at new commits. History was
# rewritten once for this purpose and is not rewritten again, so this gate
# prevents re-entry rather than proving the past clean.
#
# The forbidden terms cannot be written literally in this file's fixtures:
# a committed fixture containing them would itself violate the rule and be
# flagged by this very scan. The must-fail input is therefore assembled at
# self-test time from fragments; only the must-pass fixture is committed.
set -euo pipefail
cd "$(dirname "$0")/.."

# Assembled so this file contains no forbidden term literally.
brand="$(printf 'a%s-os|a%scent|geospa%sos|\\befb\\b' 'ir' 's' 'ti')"
refs="$(printf 'ENG-[0-9]+|PR #[0-9]+|Navi%sSDK' 'Map')"
# Host paths from whichever machine produced an artifact. A brand-term scan
# cannot see these, so absence of brand terms was never absence of exposure.
# Assembled from fragments for the same reason as the terms above.
paths="$(printf '/%ssers/[a-z]|/%some/[a-z]|\\.%sock/agents|/%sar/folders/' 'U' 'h' 'sl' 'v')"

pattern="${brand}|${refs}|${paths}"
# Built from byte escapes: this file must itself contain no CJK character.
cjk="[$(printf '\xe4\xb8\x80')-$(printf '\xe9\xbf\xbf')$(printf '\xe3\x81\x80')-$(printf '\xe3\x83\xbf')]"

scan_files() {  # $1 = ref or empty for the working tree
    local ref="${1:-}" files n hits
    if [ -n "$ref" ]; then
        files=$(git ls-tree -r --name-only "$ref")
    else
        files=$(git ls-files)
    fi
    files=$(printf '%s\n' "$files" | grep -v '^scripts/check-repository-independence.sh$' || true)
    n=$(printf '%s\n' "$files" | grep -c . || true)
    if [ "$n" -eq 0 ]; then
        echo "repository-independence ERROR: no tracked files found; check the scan root" >&2
        exit 2
    fi
    hits=$(printf '%s\n' "$files" | while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ -n "$ref" ]; then content=$(git show "$ref:$f" 2>/dev/null || true)
        else content=$(cat -- "$f" 2>/dev/null || true); fi
        printf '%s' "$content" | grep -IinE "$pattern|$cjk" | sed "s|^|${f}:|" || true
    done)
    if [ -n "$hits" ]; then
        echo "repository-independence FAILED: forbidden references in tracked files:" >&2
        echo "$hits" >&2
        return 1
    fi
    echo "repository-independence OK: ${n} tracked files scanned"
}

scan_messages() {  # $1 = explicit range; empty means the local default
    local range="${1:-}" msgs n hits explicit=1
    if [ -z "$range" ]; then
        explicit=0
        if git rev-parse --verify -q origin/main >/dev/null; then range="origin/main..HEAD"; else range="-30"; fi
    fi
    msgs=$(git log --format='%H%n%B' $range 2>/dev/null || git log --format='%H%n%B' -30)
    n=$(git log --format='%H' $range 2>/dev/null | grep -c . || true); n=${n:-0}
    if [ "$explicit" -eq 1 ] && [ "$n" -eq 0 ]; then
        echo "repository-independence ERROR: range ${range} selected no commits; the message scan would pass vacuously" >&2
        exit 2
    fi
    hits=$(printf '%s' "$msgs" | grep -inE "$pattern|$cjk" || true)
    if [ -n "$hits" ]; then
        echo "repository-independence FAILED: forbidden references in commit messages:" >&2
        echo "$hits" >&2
        return 1
    fi
    echo "repository-independence OK: ${n} commit messages scanned (${range})"
}

self_test() {
    local dir bad ok
    dir=$(mktemp -d); trap 'rm -rf "$dir"' RETURN
    # Assembled at run time: the forbidden words never exist in a tracked file.
    printf 'let host = "%s-os"\n' 'air' > "$dir/must-fail.txt"
    printf 'let note = "%s"\n' "$(printf '\xe4\xb8\xad\xe6\x96\x87')" >> "$dir/must-fail.txt"
    printf 'trace kept at ~/.%sock/agents/0000/evidence/x.tgz\n' 'sl' >> "$dir/must-fail.txt"
    cp scripts/fixtures/independence/must-pass.txt "$dir/must-pass.txt"
    bad=$(grep -inE "$pattern|$cjk" "$dir/must-fail.txt" | grep -c . || true)
    ok=$(grep -inE "$pattern|$cjk" "$dir/must-pass.txt" | grep -c . || true)
    local selfhits
    selfhits=$(grep -inE "$pattern|$cjk" scripts/check-repository-independence.sh | grep -c . || true)
    if [ "$bad" -lt 3 ] || [ "$ok" -ne 0 ] || [ "$selfhits" -ne 0 ]; then
        echo "repository-independence self-test FAILED: known-bad hits=${bad} (want >=3), known-good hits=${ok} (want 0), gate-self hits=${selfhits} (want 0)" >&2
        exit 1
    fi
    echo "repository-independence self-test: OK (constructed known-bad flagged, known-good passed, gate itself clean)"
}

case "${1:-}" in
    --self-test) self_test ;;
    --ref) shift; self_test; scan_files "$1" ;;
    --range) shift; self_test; scan_files ""; scan_messages "$1" ;;
    *) self_test; scan_files ""; scan_messages "${INDEPENDENCE_RANGE:-}" ;;
esac
