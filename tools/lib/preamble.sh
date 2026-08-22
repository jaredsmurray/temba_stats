# Shared preamble for the publishing scripts (ship.sh, publish.sh, canvas.sh).
# Source from the repo root:  . tools/lib/preamble.sh
#
# Defines SITE_CLONE — the single-branch gh-pages clone deploys compose onto —
# in one place (exported, so R sees the same value via Sys.getenv), and pins a
# UTF-8 locale before anything renders.

# Read one section of targets.conf: the lines between [name] and the next
# [section], minus blanks and comments. Consumers: ship.sh ([classify]),
# clean.sh and publish.sh ([render-dirs], [render-globs]).
targets_section() {
  awk -v s="[$1]" '$0 == s {f = 1; next} /^\[/ {f = 0} f && NF && $0 !~ /^#/' \
    targets.conf
}

# The clone path derives from the course_slug declared in schedule.yml, so a
# new course gets its own clone without touching any script. SITE_CLONE in the
# environment overrides for a one-off run.
if [ -z "${SITE_CLONE:-}" ]; then
  course_slug=$(grep -m1 '^course_slug:' schedule.yml 2>/dev/null | awk '{print $2}')
  if [ -z "$course_slug" ]; then
    echo "ERROR: schedule.yml has no course_slug and SITE_CLONE is unset." >&2
    exit 1
  fi
  SITE_CLONE="$HOME/builds/${course_slug}_site"
fi
export SITE_CLONE

# R renders non-ASCII characters as literal "<U+XXXX>" text when it runs in the
# C locale, which is what an unset LANG gives you -- cron, launchd, or a shell
# started from Finder. The regression tables built by R/pkg/model_table.R emit a
# true minus sign (U+2212) and a superscript two (U+00B2), so a C-locale build
# publishes "R<U+00B2>" and "<U+2212>$435,551" into the tables; the Canvas page
# and its snapshot titles carry em dashes that mangle the same way. Nothing
# fails: the render is clean, quarto exits 0, and the wrong thing ships. Pin a
# UTF-8 locale before anything renders.
if [ "$(locale charmap 2>/dev/null)" != "UTF-8" ]; then
  # Read the list once, then match against the string. Piping `locale -a`
  # straight into `grep -q` looks tidier but is wrong here: grep exits at the
  # first match, `locale -a` takes SIGPIPE, and `set -o pipefail` turns that
  # dead producer into a failed pipeline -- so the check reports "missing" for
  # a locale that exists. Codesets are spelled UTF-8 on macOS and utf8 on many
  # Linux builds, so accept either.
  available=$(locale -a 2>/dev/null || true)
  utf8_locale=$(printf '%s\n' "$available" | grep -ixm1 'en_US\.utf-\?8' || true)
  if [ -z "$utf8_locale" ]; then
    utf8_locale=$(printf '%s\n' "$available" | grep -ixm1 'C\.utf-\?8' || true)
  fi
  if [ -z "$utf8_locale" ]; then
    echo "ERROR: no UTF-8 locale available; rendered text would be mangled." >&2
    echo "Install/enable en_US.UTF-8, or run with LC_ALL set to a UTF-8 locale." >&2
    exit 1
  fi
  export LC_ALL="$utf8_locale" LANG="$utf8_locale"
fi
