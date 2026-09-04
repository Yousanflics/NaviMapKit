#!/bin/bash
# Negative compile-policy harness : fixtures named
# *-must-fail.swift must FAIL to typecheck against NaviMapCore; fixtures named
# *-must-compile.swift must PASS (positive control so a broken include path
# cannot produce vacuous green).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --target NaviMapCore >/dev/null

modules_dir=$(dirname "$(find .build -name 'NaviMapCore.swiftmodule' -not -path '*checkouts*' -path '*apple-macosx*' | head -1)")
if [ -z "$modules_dir" ]; then
    echo "compile-policy: cannot locate built Modules directory" >&2
    exit 2
fi

status=0
for fixture in Tests/CompilePolicyTests/Fixtures/*.swift; do
    name=$(basename "$fixture")
    if xcrun swiftc -typecheck -swift-version 6 -I "$modules_dir" "$fixture" 2>/tmp/compile-policy-diag.txt; then
        compiled=0
    else
        compiled=1
    fi
    case "$name" in
        *-must-fail.swift)
            if [ "$compiled" -eq 0 ]; then
                echo "compile-policy FAILED: $name compiled but must not" >&2
                status=1
            elif ! grep -q "cannot convert" /tmp/compile-policy-diag.txt; then
                echo "compile-policy FAILED: $name failed without the expected type-mismatch diagnostic:" >&2
                cat /tmp/compile-policy-diag.txt >&2
                status=1
            else
                echo "compile-policy OK: $name rejected with type mismatch"
            fi
            ;;
        *-must-compile.swift)
            if [ "$compiled" -ne 0 ]; then
                echo "compile-policy FAILED: $name must compile (positive control):" >&2
                cat /tmp/compile-policy-diag.txt >&2
                status=1
            else
                echo "compile-policy OK: $name compiles"
            fi
            ;;
    esac
done
exit $status
