#!/usr/bin/env bash
#
# check_links.sh [preview.html]
#
# Link-liveness gate for the generated Canvas page. Extracts every absolute
# http(s) URL from the preview HTML (default: working/canvas/canvas_preview.html,
# written by ./canvas.sh --preview) and HEADs each unique one. Exits 1 if any
# is dead -- the offering->book links that {{notes}} expands to otherwise break
# mid-semester with no signal when a chapter renames.
set -uo pipefail

html="${1:-working/canvas/canvas_preview.html}"
[ -f "$html" ] || { echo "error: no preview at ${html}; run ./canvas.sh --preview first" >&2; exit 1; }

urls=$(grep -oE 'https?://[^"'"'"'<>) ]+' "$html" | sed 's/[.,;:]*$//' | sort -u)
[ -n "$urls" ] || { echo "no absolute links in ${html}"; exit 0; }

dead=0
while IFS= read -r u; do
  if curl -sfL --max-time 20 -o /dev/null -I "$u"; then
    printf '  ok   %s\n' "$u"
  else
    printf '  DEAD %s\n' "$u"; dead=$((dead + 1))
  fi
done <<< "$urls"

total=$(printf '%s\n' "$urls" | wc -l | tr -d ' ')
if [ "$dead" -gt 0 ]; then
  echo "link check: ${dead} of ${total} dead" >&2; exit 1
fi
echo "link check: ${total} links live"
