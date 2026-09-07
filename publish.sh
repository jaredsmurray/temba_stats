#!/usr/bin/env bash
# All release preparation and deployment belongs to the private course workflow.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ ! -f "$ROOT/tools/release_workflow.py" ]; then
  echo 'Use publish.sh from the private TEMBA course checkout; see its WORKFLOWS.md.' >&2
  exit 1
fi
exec "$ROOT/publish.sh" "$@"
