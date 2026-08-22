#!/usr/bin/env bash
# ./publish.sh [--site|--notes] [--refresh] [--no-publish]
set -euo pipefail; cd "$(dirname "$0")"
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8   # R in a C locale prints <U+XXXX> into rendered text
site=true; notes=true; publish=true; full=true
for a in "$@"; do case "$a" in
  --site) notes=false; full=false ;; --notes) site=false; full=false ;;
  --refresh) rm -rf _freeze notes/_freeze ;; --no-publish) publish=false ;;
  *) echo "unknown flag $a" >&2; exit 1 ;; esac; done
if ! $site && ! $notes; then echo "--site and --notes together render nothing; pick one or neither" >&2; exit 1; fi
[ -d data ] || { echo "data/ missing: run tools/get_data.sh" >&2; exit 1; }
if $site;  then if $full; then quarto render; else quarto render --no-clean; fi; fi
if $notes; then (cd notes && quarto render); fi
for f in _book/index.html _book/notes/index.html; do [ -f "$f" ] || { echo "ERROR: $f missing; run full ./publish.sh" >&2; exit 1; }; done
# NB: `$publish && quarto publish ...` would leave the script exiting 1 under --no-publish.
if $publish; then quarto publish gh-pages --no-render --no-prompt --no-browser; fi
