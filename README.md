# TEMBA Statistics — public course site

The public Quarto website for TEMBA Statistics (Jared Murray, McCombs School of
Business). It carries the landing page, the course notes (a Quarto book rendered as a
sub-site), the lecture decks, and any handed-off PDFs. It is published to GitHub Pages.

This repository is nested inside a **private** course repository, which holds drafts,
solutions, exams, and the syllabus. The private parent gitignores this directory, so
nothing private can reach the public site by accident.

## Layout

```
_quarto.yml        website project: output-dir _book, renders root pages + slides only
index.qmd          landing page
data.qmd           datasets placeholder (datasets are distributed via Canvas)
publish.sh         the only publish path (see below)
slides/            lecture decks (revealjs)
  _metadata.yml    revealjs options for every deck in this directory
  _setup.R         data loaders + constants, imported from intro-stats-decks
  R/               inline_format.R helpers
  UPSTREAM         upstream repo + SHA the decks were imported from
notes/             course notes, a separate Quarto *book* project
  _quarto.yml      output-dir ../_book/notes
  data -> ../data  tracked symlink so chapters can read data/...
  _extensions/ styles/ images/ references.bib
  UPSTREAM         upstream repo + SHA the chapters were imported from
files/             handed-off PDFs, listed as site resources
data/ cards/ manifest.yml   gitignored; materialized by tools/get_data.sh
_book/ _freeze/ .quarto/    gitignored build output
```

## Publishing

```
./publish.sh                  # render site + notes, then quarto publish gh-pages
./publish.sh --no-publish     # render only (use this to check work locally)
./publish.sh --site           # render the root site only (incremental, --no-clean)
./publish.sh --notes          # render the notes book only
./publish.sh --refresh        # drop _freeze and notes/_freeze first, then render
```

Order matters: a full root `quarto render` cleans `_book`, so the root site renders
before the notes. `publish.sh` refuses to publish if either `_book/index.html` or
`_book/notes/index.html` is missing, so a partial site is never force-pushed. It also
sets `LC_ALL=en_US.UTF-8`, because R in a C locale prints `<U+XXXX>` escapes into
rendered text.

The root of the private parent repository has a one-line `publish.sh` that execs this
one, so `./publish.sh` works from either directory.

## Importing content

Notes chapters and decks are **imported** from their upstream repositories
(`~/repos/intro-stats`, `~/repos/intro-stats-decks`) using `tools/import.sh` in the
private parent:

```
../tools/import.sh notes singlevar_02_describing-distributions.qmd
../tools/import.sh deck  02_summarizing_distributions
```

It refuses to copy a file that is untracked or has uncommitted changes upstream, rewrites
each deck's `subtitle:` to "TEMBA Statistics 2026", and records the upstream repo and SHA
in `notes/UPSTREAM` / `slides/UPSTREAM`. Fixes made here should be backported upstream by
hand (branch, copy, PR) so the next import does not clobber them.

New chapters must also be added to `notes/_quarto.yml`'s `chapters:` list; new decks are
picked up automatically but should be linked from `index.qmd`.

## Data

```
tools/get_data.sh             # fetch the datasets pinned in ./data_pin
```

`data_pin` holds a teaching-data release tag (currently `v2026.09`). `get_data.sh`
delegates to `tools/fetch_data.sh` (a copy of the canonical script in the teaching-data
repository) and needs `curl`, `unzip`, and an authenticated `gh`, because teaching-data is
private. It writes `data/`, `cards/`, and `manifest.yml` here — all gitignored, and all
excluded from rendering, so no dataset or data card is published to the site.

To publish a dataset deliberately, add a glob to `resources:` in `_quarto.yml` — only
after checking its license in `teaching-data/LICENSING.md`. Restricted datasets go to
Canvas Files instead.

## Freeze blind spot

`execute: freeze: auto` re-runs a chunk when its `.qmd` changes — but **not** when
`_setup.R`, a file under `R/`, or the data behind `data_pin` changes. After editing any of
those, publish with `./publish.sh --refresh`.

## License

**TODO (for the instructor to decide):** the content license for these notes and slides
(e.g. CC BY-NC-SA 4.0) has not been chosen. Add a `LICENSE` file and a footer note once
it has. Datasets are not covered by whatever is chosen here — see the teaching-data
repository's licensing terms.
