# Which datasets does each lecture actually use?
#
# The Canvas landing page links a lecture's datasets directly instead of one
# course-wide data.zip. Rather than maintain that mapping by hand, derive it
# from the source: every deck, coding supplement, and chapter names the CSVs it
# reads, one way or another.
#
#   slides/*.qmd          call loaders -- load_austin_subset(), load_hamermesh()
#   slides/_setup.R       defines those loaders; their bodies hold the paths
#   companion_scripts/    read_csv("austin_houses/...") after setwd(data_dir)
#   *.qmd (chapters)      read_csv("data/austin_houses/...")
#
# Scanning is done over R's own parse tree, not with regex. A regex over source
# text breaks on a call split across lines -- which read_ercot_raw() and half of
# _setup.R are -- and would silently return a short list rather than fail. The
# parser sees the same calls the interpreter does regardless of formatting.
#
# Output is data_manifest.yml, which is tracked: a changed dependency shows up
# as a reviewable diff instead of quietly rewriting the student-facing page.

# suppressWarnings too, not just startup messages: a package built under a
# different R patch release warns on every load, which would bury the real
# warnings this script emits (an omitted dataset, an unresolvable path).
suppressWarnings(suppressPackageStartupMessages({
  library(yaml)
}))

`%||%` <- function(x, y) if (is.null(x)) y else x

# canvas.sh and publish.sh both cd to the repo root before invoking R, so the
# working directory is the root unless something explicitly says otherwise.
REPO <- normalizePath(Sys.getenv("CANVAS_REPO", unset = getwd()), mustWork = TRUE)

# Schedule helpers are the layer below this file; sourcing them here (rather
# than reaching up into canvas_page.R, which sources US) keeps the chain
# one-directional: schedule <- data_manifest <- canvas_page <- canvas_cli.
if (!exists("read_schedule"))
  source(file.path(REPO, "R", "toolchain", "schedule.R"))

# Functions that take a file path as their first string argument. Anything here
# contributes its literal path; a call with no literal path is reported (see
# scan_code) rather than dropped.
READ_FNS <- c("read_csv", "read_csv2", "read_tsv", "read_delim", "read.csv",
              "read.delim", "read.table", "read_excel", "readRDS", "load",
              "fromJSON", "read_json")

# ---------------------------------------------------------------------------
# Extracting R code
# ---------------------------------------------------------------------------

# Pull the R chunk bodies out of a .qmd; return a plain .R file whole. Only
# ```{r} chunks count -- a ```python or ```{=html} block has no R to parse, and
# feeding one to parse() would abort the scan.
qmd_r_code <- function(path) {
  lines <- readLines(path, warn = FALSE)
  if (!grepl("\\.qmd$|\\.Rmd$", path, ignore.case = TRUE)) return(lines)

  # The scan only parses R. A python chunk that reads data is invisible to it,
  # which would silently understate a lecture's datasets -- so at least say so.
  py_open <- grep("^\\s*```+\\s*\\{python", lines)
  if (length(py_open)) {
    fences <- grep("^\\s*```", lines)
    for (i in py_open) {
      end <- fences[fences > i][1]
      if (is.na(end)) end <- length(lines)
      chunk <- lines[(i + 1):(end - 1)]
      if (any(grepl("read_csv|read_parquet|read_excel|\\bopen\\(", chunk))) {
        warning(sprintf(
          "%s has a python chunk that reads data; the scan cannot resolve it -- list those datasets explicitly in schedule.yml",
          basename(path)), call. = FALSE)
        break
      }
    }
  }

  open <- grepl("^\\s*```+\\s*\\{r[,}]", lines) | grepl("^\\s*```+\\s*\\{r\\s*\\}", lines)
  fence <- grepl("^\\s*```", lines)

  out <- character()
  i <- 1
  while (i <= length(lines)) {
    if (open[i]) {
      j <- i + 1
      while (j <= length(lines) && !fence[j]) j <- j + 1
      if (j > i + 1) out <- c(out, lines[(i + 1):(j - 1)])
      i <- j + 1
    } else {
      i <- i + 1
    }
  }
  out
}

# ---------------------------------------------------------------------------
# Walking the parse tree
# ---------------------------------------------------------------------------

# Collect, from one blob of R code: literal paths passed to a READ_FN, and the
# names of any load_*/read_*_raw helpers called. The helper names are resolved
# against _setup.R later; that indirection is why a one-pass scan isn't enough.
scan_code <- function(lines, label = "<code>") {
  exprs <- tryCatch(parse(text = lines, keep.source = FALSE),
                    error = function(e) {
                      warning(sprintf("could not parse R code in %s: %s",
                                      label, conditionMessage(e)),
                              call. = FALSE)
                      NULL
                    })
  if (is.null(exprs)) return(list(paths = character(), helpers = character(), opaque = character()))

  paths <- character(); helpers <- character(); opaque <- character()

  walk <- function(e) {
    if (is.call(e)) {
      fn <- e[[1]]
      if (is.name(fn)) {
        nm <- as.character(fn)
        if (nm %in% READ_FNS) {
          args <- as.list(e)[-1]
          lit <- Filter(function(a) is.character(a) && length(a) == 1, args)
          if (length(lit)) {
            paths <<- c(paths, lit[[1]])
          } else {
            # A computed path (paste0, file.path, a variable). Can't resolve it
            # statically, so surface it -- a missing dataset link is a silent
            # wrong answer otherwise.
            opaque <<- c(opaque, paste0(nm, "(", deparse(e[[2]])[1], ")"))
          }
        } else if (grepl("^(load|read)_", nm)) {
          helpers <<- c(helpers, nm)
        }
      }
    }
    if (is.call(e) || is.pairlist(e) || is.expression(e) || is.list(e)) {
      for (part in as.list(e)) if (!missing(part)) walk(part)
    }
  }

  for (e in exprs) walk(e)
  list(paths = unique(paths), helpers = unique(helpers), opaque = unique(opaque))
}

# Map each helper defined in _setup.R to what it reads and what it calls, so a
# helper that delegates (load_ercot_daily -> read_ercot_raw) resolves fully.
helper_defs <- function(setup_path) {
  exprs <- parse(setup_path, keep.source = FALSE)
  defs <- list()
  for (e in exprs) {
    if (is.call(e) && length(e) == 3 &&
        as.character(e[[1]])[1] %in% c("<-", "=") &&
        is.name(e[[2]]) && is.call(e[[3]]) &&
        as.character(e[[3]][[1]])[1] == "function") {
      nm <- as.character(e[[2]])
      body_txt <- paste(deparse(e[[3]]), collapse = "\n")
      defs[[nm]] <- scan_code(body_txt, label = paste0("_setup.R:", nm))
    }
  }
  defs
}

# Follow helper -> helper until only paths remain. The `seen` set makes a cyclic
# or self-referential definition terminate instead of recursing forever.
resolve_helper <- function(nm, defs, seen = character()) {
  if (nm %in% seen || is.null(defs[[nm]])) return(character())
  d <- defs[[nm]]
  c(d$paths,
    unlist(lapply(d$helpers, resolve_helper, defs = defs, seen = c(seen, nm))))
}

# ---------------------------------------------------------------------------
# Path normalization
# ---------------------------------------------------------------------------

# Resolve "a/../b/./c" without touching the filesystem, then make it relative to
# the repo root. `base` is where the source's paths are interpreted from:
# slides/ for the decks, data/ for the supplements (they setwd(data_dir) first),
# the repo root for chapters.
normalize_rel <- function(path, base) {
  parts <- c(strsplit(base, "/", fixed = TRUE)[[1]],
             strsplit(path, "/", fixed = TRUE)[[1]])
  parts <- parts[nzchar(parts) & parts != "."]
  out <- character()
  for (p in parts) {
    if (p == "..") out <- utils::head(out, -1) else out <- c(out, p)
  }
  paste(out, collapse = "/")
}

# Where each source root interprets its relative paths from.
source_base <- function(path) {
  if (startsWith(path, "slides/")) return("slides")
  if (startsWith(path, "companion_scripts/")) return("data")
  "."
}

# ---------------------------------------------------------------------------
# Scanning a source file
# ---------------------------------------------------------------------------

scan_source <- function(path, defs) {
  found <- scan_code(qmd_r_code(file.path(REPO, path)), label = path)

  raw <- c(found$paths,
           unlist(lapply(found$helpers, resolve_helper, defs = defs)))
  if (!length(raw)) return(list(datasets = character(), opaque = found$opaque))

  base <- source_base(path)
  rel <- vapply(raw, normalize_rel, character(1), base = base, USE.NAMES = FALSE)

  # Keep only real files under data/. This drops library() side effects, helper
  # paths that point elsewhere, and typos -- but a path under data/ that does
  # NOT exist is a genuine problem, so report it rather than filtering silently.
  under <- rel[startsWith(rel, "data/")]
  missing <- under[!file.exists(file.path(REPO, under))]
  if (length(missing)) {
    warning(sprintf("%s reads data files that do not exist: %s",
                    path, paste(missing, collapse = ", ")), call. = FALSE)
  }

  # Radix sort, not the default: the locale-aware collation orders
  # "austin_houses_subset.csv" before "austin_houses.csv" on some machines and
  # after it on others, which would churn this tracked file between builds.
  list(datasets = sort(unique(under[file.exists(file.path(REPO, under))]),
                       method = "radix"),
       opaque = found$opaque)
}

# ---------------------------------------------------------------------------
# Human names for the data directories
# ---------------------------------------------------------------------------

# data.qmd already groups the downloads under headings Jared wrote ("ERCOT load
# & weather"). Reuse that curation rather than inventing a second vocabulary or
# falling back to directory names.
dataset_names <- function() {
  # Primary source: the delivered data/manifest.yml from teaching-data --
  # each entry's `label:` was seeded verbatim from the book's data.qmd
  # headings, so labels match the pre-split page exactly. An offering always
  # has this file after tools/get_data.sh.
  mpath <- file.path(REPO, "manifest.yml")
  if (file.exists(mpath)) {
    m <- tryCatch(yaml::read_yaml(mpath), error = function(e) NULL)
    if (!is.null(m$datasets)) {
      out <- lapply(m$datasets, function(d) d$label)
      out <- out[!vapply(out, is.null, logical(1))]
      if (length(out)) return(out)
    }
  }
  # Legacy fallback: scrape the book's data.qmd headings (pre-split layout).
  path <- file.path(REPO, "data.qmd")
  if (!file.exists(path)) return(list())
  lines <- readLines(path, warn = FALSE)

  names_out <- list()
  current <- NA_character_
  for (ln in lines) {
    h <- regmatches(ln, regexec("^##\\s+(.+?)\\s*$", ln))[[1]]
    if (length(h) == 2) { current <- h[2]; next }
    if (is.na(current)) next
    for (hit in regmatches(ln, gregexpr("data/[A-Za-z0-9_.-]+/", ln))[[1]]) {
      dir <- sub("/$", "", sub("^data/", "", hit))
      if (is.null(names_out[[dir]])) names_out[[dir]] <- current
    }
  }
  names_out
}

# ---------------------------------------------------------------------------
# Building and writing the manifest
# ---------------------------------------------------------------------------

source_files <- function() {
  decks <- list.files(file.path(REPO, "slides"), "\\.qmd$", full.names = FALSE)
  supps <- list.files(file.path(REPO, "companion_scripts"), "\\.qmd$", full.names = FALSE)
  chaps <- list.files(REPO, "\\.qmd$", full.names = FALSE)
  chaps <- setdiff(chaps, c("supplements.qmd", "data.qmd"))
  c(file.path("slides", decks),
    file.path("companion_scripts", supps),
    chaps)
}

build_manifest <- function() {
  defs <- helper_defs(file.path(REPO, "slides", "_setup.R"))

  sources <- list()
  opaque <- character()
  for (path in source_files()) {
    res <- scan_source(path, defs)
    if (length(res$opaque)) {
      opaque <- c(opaque, paste0(path, ": ", res$opaque))
    }
    if (length(res$datasets)) {
      sources[[path]] <- list(datasets = as.list(res$datasets))
    }
  }

  if (length(opaque)) {
    warning(sprintf("computed data paths the scan could not resolve:\n  %s",
                    paste(opaque, collapse = "\n  ")), call. = FALSE)
  }

  list(sources = sources, names = dataset_names(), host = list())
}

MANIFEST <- "data_manifest.yml"

write_manifest <- function(path = file.path(REPO, MANIFEST)) {
  m <- build_manifest()
  # Preserve any hand-set `host:` entries; the scan owns `sources` and `names`,
  # Jared owns which datasets are served from Canvas.
  if (file.exists(path)) {
    old <- yaml::read_yaml(path)
    if (length(old$host)) m$host <- old$host
  }
  header <- c(
    "# Which datasets each deck, supplement, and chapter reads.",
    "#",
    "# GENERATED by R/toolchain/data_manifest.R -- run ./canvas.sh --scan to refresh, and",
    "# review the diff. Do not hand-edit `sources`; it is overwritten. The",
    "# `host:` block IS yours to edit: list a dataset there to serve it from",
    "# Canvas Files instead of the published site.",
    ""
  )
  writeLines(c(header, yaml::as.yaml(m, indent = 2)), path)
  invisible(m)
}

read_manifest <- function(path = file.path(REPO, MANIFEST)) {
  if (!file.exists(path)) {
    stop("data_manifest.yml not found; run ./canvas.sh --scan", call. = FALSE)
  }
  yaml::read_yaml(path)
}

# Is the checked-in manifest still what a fresh scan produces? Called by
# --check so a changed loader fails the push instead of silently altering the
# links students see.
manifest_is_stale <- function(path = file.path(REPO, MANIFEST)) {
  if (!file.exists(path)) return(TRUE)
  # Compare the dataset lists as plain character vectors, not the parsed
  # structures. A source with exactly one dataset is written as a YAML list but
  # read back as a bare scalar, so identical() on the raw objects reports every
  # single-dataset source as changed on every run.
  flatten <- function(sources) {
    lapply(sources, function(s) sort(as.character(unlist(s$datasets))))
  }
  !identical(flatten(build_manifest()$sources), flatten(read_manifest(path)$sources))
}

# ---------------------------------------------------------------------------
# Per-lecture bundles
# ---------------------------------------------------------------------------

# One zip per lecture holding exactly the datasets that lecture's sources read.
# Replaces the course-wide data.zip: a student pulls the 24 KB portfolios.csv
# for that day instead of 282 MB of everything.
#
# Files are stored relative to data/ so a bundle unzips into the same layout the
# supplements expect after setwd(data_dir).
build_bundle <- function(datasets, out_path, limit_mb = 90) {
  if (!length(datasets)) return(invisible(NULL))

  dir.create(dirname(out_path), recursive = TRUE, showWarnings = FALSE)

  zip_it <- function(paths) {
    if (file.exists(out_path)) unlink(out_path)
    old <- setwd(file.path(REPO, "data"))
    on.exit(setwd(old), add = TRUE)
    utils::zip(out_path, sub("^data/", "", paths), flags = "-qr9X")
    file.size(out_path) / 1024^2
  }

  # The 90 MB ceiling is GitHub's per-file limit, so it applies to the finished
  # zip -- not to the sum of the inputs. These CSVs compress about 5x, so
  # budgeting on uncompressed size drops datasets that would have fit easily.
  # Zip everything, then shed the largest file only if the artifact is actually
  # too big.
  keep <- datasets
  size <- zip_it(keep)
  while (size > limit_mb && length(keep) > 1) {
    raw <- file.size(file.path(REPO, keep))
    drop <- keep[which.max(raw)]
    # Never ship a quietly-thin bundle: name what was left out, so the omission
    # shows up in the build log instead of being found by a student.
    warning(sprintf("%s: omitting %s -- bundle is %.0f MB, over the %d MB limit",
                    basename(out_path), drop, size, limit_mb), call. = FALSE)
    keep <- setdiff(keep, drop)
    size <- zip_it(keep)
  }
  invisible(out_path)
}

# Entry point for publish.sh: ONE cumulative zip of every dataset any
# scheduled lecture uses, at a stable URL every row links. Adding a lecture
# that introduces a dataset grows the zip; rows never carry their own zip, so
# a student who grabs it once has everything through the latest lecture.
build_all_bundles <- function(schedule_path = file.path(REPO, "schedule.yml"),
                              out_dir = file.path(REPO, "_book", "data")) {
  if (!file.exists(schedule_path)) {
    message("no schedule.yml; skipping the data zip")
    return(invisible(NULL))
  }
  sched <- read_schedule(schedule_path)
  ds <- all_schedule_datasets(sched, read_manifest())
  if (!length(ds)) {
    message("no scheduled datasets; skipping the data zip")
    return(invisible(NULL))
  }

  # Drop the retired per-lecture bundles so they can't linger half-stale.
  unlink(file.path(REPO, "_book", "data", "bundles"), recursive = TRUE)

  out <- file.path(out_dir, basename(CUMULATIVE_ZIP))
  build_bundle(ds, out)
  # Record the zip's intended contents, so the Canvas checks can tell when the
  # schedule/manifest and the built zip have drifted apart.
  writeLines(ds, file.path(out_dir, ".zip_contents"))
  message(sprintf(">> Built %s: %d dataset(s), %.0f MB.",
                  basename(out), length(ds), file.size(out) / 1024^2))
  invisible(out)
}

# Is the built cumulative zip out of step with what the schedule + manifest
# now imply? Compared as the resolved dataset list, so the error can name
# exactly what would change.
bundles_stale <- function(sched, manifest,
                          out_dir = file.path(REPO, "_book", "data")) {
  sidecar <- file.path(out_dir, ".zip_contents")
  if (!file.exists(sidecar) ||
      !file.exists(file.path(out_dir, basename(CUMULATIVE_ZIP)))) return(TRUE)
  !identical(readLines(sidecar, warn = FALSE),
             all_schedule_datasets(sched, manifest))
}

# ---------------------------------------------------------------------------
# Coding supplements -> _book/code/
# ---------------------------------------------------------------------------

# Locate quarto the same way publish.sh does: PATH first, then the copy
# bundled with Positron (the project's IDE), then RStudio's. Needed because
# this file is also invoked as a bare Rscript, without publish.sh's PATH setup.
quarto_bin <- function() {
  hit <- Sys.which("quarto")
  if (nzchar(hit)) return(hit)
  for (p in c("/Applications/Positron.app/Contents/Resources/app/quarto/bin/quarto",
              path.expand("~/Applications/Positron.app/Contents/Resources/app/quarto/bin/quarto"),
              "/Applications/RStudio.app/Contents/Resources/app/quarto/bin/quarto")) {
    if (file.exists(p)) return(p)
  }
  stop("quarto not found on PATH or in Positron/RStudio bundles", call. = FALSE)
}

# Render every scheduled supplement to PDF and stage PDF + source at
# _book/code/<stem>.{pdf,qmd}. A supplement rebuilds only when STALE: PDF
# missing, older than its source, or older than any dataset it reads (from the
# manifest -- refreshed data invalidates the rendered output even when the qmd
# didn't change). This rule applies on every build including --full, so an
# up-to-date supplement never pays the render tax twice; `touch` the qmd to
# force one.
build_code_supplements <- function(schedule_path = file.path(REPO, "schedule.yml"),
                                   out_dir = file.path(REPO, "_book", "code")) {
  if (!file.exists(schedule_path)) {
    message("no schedule.yml; skipping coding supplements")
    return(invisible(NULL))
  }
  sched <- read_schedule(schedule_path)
  stems <- scheduled_supplements(sched)
  if (!length(stems)) {
    message("no scheduled supplements; nothing to build")
    return(invisible(NULL))
  }
  manifest <- read_manifest()
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  # Drop staged files that no longer belong to any scheduled stem -- a renamed
  # or unscheduled supplement would otherwise linger in _book/code and ride
  # the deploy forever.
  want <- c(paste0(stems, ".pdf"), paste0(stems, ".qmd"))
  orphans <- setdiff(list.files(out_dir), want)
  if (length(orphans)) {
    unlink(file.path(out_dir, orphans))
    message(">> Removed staged orphan(s): ", paste(orphans, collapse = ", "))
  }

  built <- 0; fresh <- 0
  for (stem in stems) {
    qmd <- supp_source(stem)
    if (!file.exists(qmd)) {
      stop(sprintf("scheduled supplement has no source: companion_scripts/%s.qmd",
                   stem), call. = FALSE)
    }
    pdf <- file.path(REPO, "companion_scripts", paste0(stem, ".pdf"))
    key <- file.path("companion_scripts", paste0(stem, ".qmd"))
    deps <- file.path(REPO,
                      unlist(manifest$sources[[key]]$datasets, use.names = FALSE))
    newest_input <- max(c(file.mtime(qmd), file.mtime(deps[file.exists(deps)])))

    if (!file.exists(pdf) || file.mtime(pdf) < newest_input) {
      message(">> Rendering supplement ", stem, "...")
      status <- system2(quarto_bin(), c("render", shQuote(qmd), "--to", "pdf"))
      if (status != 0 || !file.exists(pdf)) {
        stop(sprintf("rendering %s failed", key), call. = FALSE)
      }
      built <- built + 1
    } else {
      fresh <- fresh + 1
    }
    file.copy(pdf, file.path(out_dir, basename(pdf)), overwrite = TRUE)
    file.copy(qmd, file.path(out_dir, basename(qmd)), overwrite = TRUE)
  }
  message(sprintf(">> Coding supplements: %d rendered, %d already current, %d staged.",
                  built, fresh, length(stems)))
  invisible(stems)
}

# CLI: Rscript R/toolchain/data_manifest.R [--scan|--bundles|--code]
if (!interactive() && sys.nframe() == 0) {
  args <- commandArgs(trailingOnly = TRUE)
  if ("--bundles" %in% args) {
    build_all_bundles()
  } else if ("--code" %in% args) {
    build_code_supplements()
  } else {
    write_manifest()
  }
}
