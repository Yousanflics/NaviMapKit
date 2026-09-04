#!/usr/bin/env bash
# Comment independence gate: source comments describe API and module
# responsibilities only. References to internal design documents, decision
# numbers, phase or batch labels, and risk identifiers must not appear in
# shipped code. The API breakage allowlist is a tool data file and is exempt.
set -euo pipefail
cd "$(dirname "$0")/.."

pattern='§|ADR-00[0-9]|0[123]-(design|implementation|analysis)|docs/0[123]|\b0[123] §|design review|\bD[0-9]\b|\bP[0-9](-[0-9])?\b|\bR[0-9]\b'

hits=$(grep -rnE "$pattern" Sources Tests Examples scripts/*.sh scripts/*.py \
    --exclude-dir=.build --exclude-dir=DerivedData --exclude-dir='*.xcodeproj' \
    --exclude='check-comment-independence.sh' || true)

if [ -n "$hits" ]; then
    echo "comment-independence FAILED: design-document references in code:"
    echo "$hits"
    exit 1
fi
echo "comment-independence OK"
