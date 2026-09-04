#!/bin/bash
# Audit report : list every call site of the named
# cross-semantic time conversions (e.g. assumingObservation). Informational —
# reviewers compare the count against the PR description's justification.
set -euo pipefail
cd "$(dirname "$0")/.."
echo "Named time-conversion call sites:"
grep -rn --include='*.swift' 'assumingObservation' Sources Tests Examples 2>/dev/null || echo "  (none)"
