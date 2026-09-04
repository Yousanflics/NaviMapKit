#!/bin/bash
# provider-isolation : `import MapboxMaps` may appear ONLY inside
# Sources/_PrimaryVectorRuntime/. Examples are separate Xcode projects and are
# covered by the symbol-graph half, not this grep.
set -euo pipefail
cd "$(dirname "$0")/.."

violations=$(grep -rln --include='*.swift' -E '^[[:space:]]*(@preconcurrency[[:space:]]+)?(internal[[:space:]]+|public[[:space:]]+|package[[:space:]]+)?import[[:space:]]+(MapboxMaps|MapboxCoreMaps|MapboxCommon|Turf)\b' Sources Tests 2>/dev/null \
    | grep -v '^Sources/_PrimaryVectorRuntime/' || true)

if [ -n "$violations" ]; then
    echo "provider-isolation FAILED — Mapbox imports outside _PrimaryVectorRuntime:" >&2
    echo "$violations" >&2
    exit 1
fi
echo "provider-isolation OK"
