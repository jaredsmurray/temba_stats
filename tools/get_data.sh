#!/usr/bin/env bash
#
# get_data.sh [--pin <tag>] [dest]
#
# Materializes the pinned course datasets under <dest> (default: the repo
# root). The pin is the one line in ./data_pin; pass --pin to override for a
# one-off check without editing the tracked file.
#
# <dest> is the PARENT of data/, not data/ itself: every path in the
# teaching-data manifest already starts with "data/", and the fetcher also
# drops cards/ and manifest.yml beside it. All three are gitignored here.
#
# Decks read "../data/..." from slides/, supplements setwd() into data/, and
# the Canvas dataset scan reads data/manifest.yml for its `label:` fields --
# all three work exactly when this has run at the repo root.
#
# The heavy lifting is tools/fetch_data.sh, a vendored copy of the same script
# in the teaching-data repo (canonical there; see RECONCILE.md). It needs curl,
# unzip, and -- while teaching-data is private -- an authenticated `gh`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN_FILE="${ROOT}/data_pin"
FETCH="${ROOT}/tools/fetch_data.sh"

pin=""
dest=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pin)    [ $# -ge 2 ] || { echo "--pin needs a tag" >&2; exit 64; }
              pin="$2"; shift 2 ;;
    --pin=*)  pin="${1#--pin=}"; shift ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 64 ;;
    -*)       echo "unknown option: $1" >&2; exit 64 ;;
    *)        [ -z "$dest" ] || { echo "one dest, please" >&2; exit 64; }
              dest="$1"; shift ;;
  esac
done

if [ -z "$pin" ]; then
  [ -f "$PIN_FILE" ] || { echo "error: no data_pin at ${PIN_FILE}" >&2; exit 1; }
  pin="$(tr -d '[:space:]' < "$PIN_FILE")"
fi
[ -n "$pin" ] || { echo "error: data_pin is empty" >&2; exit 1; }
[ -x "$FETCH" ] || { echo "error: ${FETCH} is missing or not executable" >&2; exit 1; }

dest="${dest:-${ROOT}}"
echo ">> data pin: ${pin}"
"$FETCH" "$pin" "$dest"
ln -sfn ../cards "$dest/data/cards"

# Book chapters include data cards as data/cards/<card>.qmd; fetch_data.sh
# delivers them at <dest>/cards/, so expose them under data/ as well.
