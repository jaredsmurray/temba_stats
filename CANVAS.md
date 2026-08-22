<!-- TEMBA 2026 -->
## TEMBA 2026 notes

This site publishes with `./publish.sh` (a thin wrapper around
`quarto publish gh-pages`). There is no `ship.sh` here, and this repo's
`publish.sh` is not course-kit's. Wherever the text below refers to `ship.sh`
or to `publish.sh` subcommands (`--data`, `--code`, `--site`, deploy logs,
`SITE_CLONE`), those instructions do not apply: run `./canvas.sh` directly
(`--scan`, `--preview`, `--check`, `--diff`, `--status`, `--push`) after
publishing the site the normal way. Everything else about `schedule.yml` and
the Canvas page generator applies as written.

# The Canvas landing page

*(Scenario-by-scenario cookbook for the whole publishing workflow:
[`WORKFLOW.md`](WORKFLOW.md). This file is the Canvas-side reference.)*

The course page on Canvas is **generated**, not hand-edited. `schedule.yml` (started
from [`schedule.yml.template`](schedule.yml.template), which documents every key)
holds the outline; `./canvas.sh --push` renders it to HTML and overwrites the page body.

Editing the page in Canvas's rich-content editor is pointless — the next push discards
whatever you typed. That's why the generated body opens with a comment saying so.

Daily loop — one command:

```bash
./ship.sh
```

`ship.sh` builds what changed, deploys the site, byte-verifies it live, and then
runs the **Canvas delta gate**: it regenerates the page and compares its hash to
the hash recorded in the live page's provenance marker at the last push. A math
typo on a deck changes nothing here (the link URL is stable) → "canvas: unchanged
— skipped". A new dataset, schedule edit, or deck title change → push, with its
snapshot and checks. Canvas trouble (token, network) never blocks the site
stages; the closing ledger says exactly what to re-run.

---

## First-time setup

1. **Get a token.** In Canvas: Account → Settings → scroll to *Approved Integrations* →
   **+ New Access Token**. Give it a purpose and an expiry.

2. **Check it works.**

   ```bash
   curl -s -H "Authorization: Bearer <token>" \
     https://utexas.instructure.com/api/v1/users/self | head -c 300
   ```

   A JSON user object means you're set. A 401/403 — or no *+ New Access Token* button at
   all — means UT has disabled personal tokens for non-admins, and none of this works;
   fall back to publishing a schedule page on the site and embedding it in Canvas with a
   single `<iframe>`.

3. **Store it outside the repo.**

   ```bash
   printf '%s' '<token>' > ~/.canvas_token && chmod 600 ~/.canvas_token
   ```

   The token can do anything your Canvas account can do, including reading student data.
   It never goes in the repo, and `CANVAS_TOKEN` in the environment overrides the file
   for a one-off run.

4. **Cache the course file list.**

   ```bash
   ./canvas.sh --refresh-files
   ```

5. **Rehearse on a throwaway page.** Make a scratch page in Canvas, point
   `canvas.page` in `schedule.yml` at its slug, and `--push`. Confirm the table renders,
   file links actually download, and it reads correctly in the Canvas mobile app. Then
   repoint at the real page.

---

## Commands

| Command | What it does |
|---|---|
| `./ship.sh` | The daily command: build what changed → deploy → verify → Canvas if changed. |
| `./canvas.sh --preview` | Render to `working/canvas/canvas_preview.html` and open it. No network. |
| `./canvas.sh --check` | Validate links, manifest, bundles, file ids. Read-only; exits non-zero on problems. |
| `./canvas.sh --diff` | Show what a push would change (vs. the body generated at the last push). |
| `./canvas.sh --status` | Drift matrix: source sha vs. deployed site vs. live Canvas page. |
| `./canvas.sh --push` | Snapshot the live page, run the checks, then overwrite. |
| `./canvas.sh --scan` | Rescan dataset dependencies into `data_manifest.yml`. |
| `./canvas.sh --snapshots` | List snapshot pages, newest first, numbered. |
| `./canvas.sh --restore N` | Put snapshot N's body back on the live page (snapshotting first, so restores are undoable). |
| `./canvas.sh --prune [--keep N \| --all]` | Delete old snapshots. Lists them and prompts first; keeps 3 by default. |
| `./canvas.sh --refresh-files` | Re-fetch the Canvas file-id cache; warns on duplicate file names. |
| `./canvas.sh --sync-data` | Upload datasets marked `host: canvas` in the manifest. |
| `./tools/check_links.sh` | HEAD every absolute link in the last `--preview`; fails on dead ones. Wired into `ship.sh`. |

Every networked action starts with a token preflight, so a dead token fails in
seconds with the fix spelled out rather than mid-push before class.

---

## Two machines

The published artifacts themselves carry the state, so laptop and desktop need no
coordination:

- The **site**: deploys compose onto a pulled clone of `gh-pages` at
  `~/builds/<course_slug>_site` (created automatically per machine), so each deploy
  starts from whatever either machine last published. No full build is ever
  required — see the deploy-architecture section of [`WORKFLOW.md`](WORKFLOW.md).
- The **Canvas page**: the delta gate compares against the live page's marker, not
  local files, so it answers correctly no matter which machine pushed last.
- Each machine needs its own `~/.canvas_token` and its own untracked `site.conf`
  (one-time each; the full list is in [`BOOTSTRAP.md`](BOOTSTRAP.md)).
- Uncommitted work no longer syncs between machines — this repo lives outside
  Dropbox, so `git push` is the only sync.
- If both machines somehow deploy at the same moment, the later push fails
  non-fast-forward; just re-run it.

---

## Editing the schedule

Everything lives in `schedule.yml` (see [`schedule.yml.template`](schedule.yml.template)
for the annotated version). A row:

```yaml
  - lecture: 6
    date: 2026-07-21          # ISO; rendered "Tue 7/21"
    topic: "Multiple regression"
    readings: |
      Lecture notes: [Sections 19-22]({{notes}})
    materials:
      slides: [08_regression, 09_categorical_predictors]
      supplements: [regression, categorical]
```

**Prose fields** (`preamble`, `topic`, `readings`, `note`) are markdown, so a cell can
carry the asides the table has always had — "Sections 1–5", the Devore reference, the
hit-**E**-for-print tip. Inside prose you can use:

| Ref | Expands to |
|---|---|
| `{{site}}` | this offering's published course site (`site_url`) |
| `{{notes}}` | the book site (`notes_url`, falling back to `site_url`) |
| `{{slides:DECK}}` | a link to that deck, titled from its `.qmd` |
| `{{file:NAME}}` | a Canvas file, looked up by name — no file ids to copy |

**Structured fields** build the labelled link groups:

| Key | Meaning |
|---|---|
| `slides:` | deck stems from `slides/`; link text comes from each deck's `title:` |
| `supplements:` | stems from `companion_scripts/`; publish to `{site}/code/<stem>.pdf` + source, titled from the qmd |
| `data:` | `auto` (the default) derives datasets from the manifest; a list overrides |
| `bundle:` | also link the cumulative `<course_slug>_data.zip` (same link every row) |
| `files:` | Canvas files by name |

Anything in `defaults:` applies to every row that doesn't set it — that's where the
per-row boilerplate lives.

> **The lecture number key is `lecture:`, not `n:`.** YAML 1.1 reads a bare `n` as the
> boolean *no*, so `n: 1` parses as a key named `FALSE` and the bundle links silently
> vanish. Same trap as `y`, `on`, and `off`.

---

## Where datasets come from

You don't list a lecture's datasets by hand. [`R/toolchain/data_manifest.R`](R/toolchain/data_manifest.R)
reads what each source *actually* reads:

- **Decks** call `load_austin_subset()`, `load_hamermesh()`, …; `slides/_setup.R` defines
  those loaders and their bodies hold the paths. Resolution is transitive, so
  `load_ercot_daily_temp()` reaches `read_ercot_raw()`'s three files too.
- **Supplements** read relative paths after `setwd(data_dir)`.
- **Problem sets and other tracked sources** read `data/...` directly. (In the
  book repo the same scanner reads chapters this way; an offering has none.)

The scan walks R's parse tree rather than grepping the text — a regex misses a call split
across lines and returns a short list without failing.

Results go to `data_manifest.yml`, which is **tracked on purpose**:
a changed dependency shows up as a reviewable git diff instead of quietly changing what
students see. `--check` fails if the manifest is stale, so after editing a loader in
`slides/_setup.R`, run `./canvas.sh --scan` and read the diff.

Datasets are served from the published site, which `publish.sh` already stages — no
Canvas upload needed. Each row lists only the datasets that lecture *introduces*
(first use wins; later lectures reusing a dataset don't repeat it), plus one
cumulative `data/<course_slug>_data.zip` that `publish.sh --data` rebuilds as the union of
every scheduled lecture's datasets — the same link in every row, growing as rows
are added.

To serve a particular dataset from Canvas instead (licensed material, say), add it to the
`host:` block in the manifest and run `--sync-data`. That block is yours to edit; the scan
overwrites everything else.

---

## Safety

**Every push snapshots first.** The Canvas API replaces the entire page body — there is no
append — so before overwriting, `--push` copies the live body to an **unpublished** page
titled `Course Materials — snapshot <date time>` and writes it to
`working/canvas/canvas_backup_<stamp>.html (rotated, newest 10 kept)`. Unpublished means students can't see it but you can,
in the Pages index. Clean up in batches with `--prune`, which always lists what it will
delete and waits for confirmation. Canvas's own page revision history sits underneath as a
second net, and deleted pages stay recoverable from the course's deleted items.

**Checks run inside every push.** A typo'd deck stem, a dataset that isn't staged, an
unknown Canvas file name, or a stale manifest fails the push rather than shipping a dead
link to the class.

**Solutions and exam guard.** Any link whose text or href mentions "solution", or points
into `exams/`, is refused unless it points into Canvas — solutions live in Canvas and
exam material never leaves the private repo. Same posture as
the guard in `publish.sh`, and deliberately no override flag: the fix is to remove the
link, never to force past it.

**Bundle freshness.** The zips record which manifest built them; `--check` fails when the
page's dataset lists and the bundles have drifted apart ("run `./publish.sh --data`").

**Coverage notices.** `--check` also lists decks and supplements that appear in no
schedule row — the "published it, forgot the row" failure — as notes, not errors.

---

## Semester rollover (next course copy)

1. **Prune snapshots BEFORE copying the course** (`--prune --all`) — unpublished
   snapshot pages ride along on a Canvas course copy otherwise.
2. After the copy, update the `canvas:` block in `schedule.yml`: new `course_id`
   (from the new course's URL) and, if the page was recreated, its slug.
3. `./canvas.sh --refresh-files` — every file id changes in a copied course.
4. New semester, new token? Each machine: `~/.canvas_token`.
5. If the site moves (new repo/URL for the new year), update `site_url` in
   `schedule.yml`; the site clone recreates itself from the new origin. If the book
   site moved, update `notes_url` too.
6. Clear out `lectures:` and start the new outline; `defaults:` and the preamble
   mostly carry over.
