#!/usr/bin/env bash
#
# Manage the Canvas landing page generated from schedule.yml.
#
#     ./canvas.sh --preview     render to working/ and open it (no network)
#     ./canvas.sh --check       validate links, manifest, bundles (read-only)
#     ./canvas.sh --diff        show what a push would change on the page
#     ./canvas.sh --push        snapshot the live page, check, then overwrite it
#     ./canvas.sh --status      drift matrix: source vs site vs Canvas
#
#     ./canvas.sh --scan        rescan dataset dependencies -> data_manifest.yml
#     ./canvas.sh --snapshots   list snapshot pages, newest first
#     ./canvas.sh --prune       delete old snapshots (keeps 3; --keep N, --all)
#     ./canvas.sh --restore N   restore the Nth snapshot (1 = newest) to the page
#     ./canvas.sh --refresh-files   re-fetch the Canvas file-id cache
#     ./canvas.sh --sync-data   upload datasets marked `host: canvas`
#
# Normally driven by ./ship.sh, which builds and deploys the site first and
# pushes here only when the generated page actually changed.
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v Rscript >/dev/null 2>&1; then
  echo "ERROR: Rscript not found on PATH." >&2
  exit 1
fi

# Shared preamble: SITE_CLONE definition + UTF-8 locale pinning (the page
# carries em dashes, and snapshot titles do too).
. tools/lib/preamble.sh

action=""
keep=3
restore_n=""

if [ "$#" -eq 0 ]; then
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --preview|--check|--diff|--push|--status|--scan|--snapshots|--prune|--refresh-files|--sync-data)
      if [ -n "$action" ] && [ "$action" != "${1#--}" ]; then
        echo "ERROR: pick one action at a time (got --$action and $1)." >&2
        exit 1
      fi
      action="${1#--}" ;;
    --restore) action="restore"; shift; restore_n="$1" ;;
    --keep) shift; keep="$1" ;;
    --all)  keep=0 ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "ERROR: unknown option '$1'." >&2
      exit 1 ;;
  esac
  shift
done

mkdir -p working

exec Rscript --vanilla R/toolchain/canvas_cli.R "$action" "$keep" "${restore_n:-0}"
