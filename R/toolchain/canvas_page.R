# Build the Canvas landing page from schedule.yml.
#
# The Canvas course page is a generated artifact: schedule.yml holds the course
# outline, this file turns it into HTML, and canvas.sh PUTs that HTML over the
# page body. Editing the page in Canvas's rich-content editor is pointless --
# the next push overwrites it -- which is why the generated body opens with a
# comment saying so.
#
# Two constraints shape the HTML. Canvas sanitizes server-side against a fixed
# allowlist: <table>, <a>, <p>, <ul>, and inline style= survive, while <script>
# and <style> TAGS are stripped no matter what is sent. And Canvas file links
# need an opaque numeric file id plus five data- attributes to render as real
# file links, so they are looked up by name through the API rather than typed.

suppressWarnings(suppressPackageStartupMessages({
  library(yaml)
  library(httr2)
  library(commonmark)
}))

# canvas.sh cds to the repo root before invoking R, so R/ resolves from here.
if (!exists("read_manifest")) source(file.path("R", "toolchain", "data_manifest.R"))

# Course identity: one slug, declared in schedule.yml, drives every generated
# name -- the provenance CSS class, the API user agent, the cumulative data
# zip, and the site-clone default. A new course sets course_slug and none of
# those strings need hunting down.
COURSE_SLUG <- {
  s <- tryCatch(yaml::read_yaml(file.path(REPO, "schedule.yml"))$course_slug,
                error = function(e) NULL)
  if (is.null(s) || !nzchar(s))
    stop("schedule.yml must set course_slug (e.g. 'sta380').", call. = FALSE)
  s
}

# Column widths from the page this replaces. Percentages, not the pixel heights
# the rich-content editor leaves behind -- those are drag-resize artifacts and
# make rows clip at other window sizes.
COL_WIDTHS <- c("31%", "29%", "40%")

# Provenance travels on a wrapper <div> around the whole pushed body -- NOT an
# HTML comment, which Canvas's sanitizer strips (verified empirically on the
# live course; class/id/title/data-* attributes all survive). It records where
# the page came from: the source commit, the schedule file's hash, and --
# critically -- the sha1 of the generated body itself. The delta gate compares
# hash(freshly generated) against that recorded hash, so "would a push change
# anything?" never has to diff against Canvas's own body, which Canvas
# rewrites on save and which would therefore always look different.
#
# The hash covers the body only (not the wrapper), so it is reproducible
# offline from schedule.yml + manifest alone.
page_with_marker <- function(body) {
  src <- tryCatch(
    system2("git", c("rev-parse", "--short", "HEAD"), stdout = TRUE, stderr = FALSE)[1],
    error = function(e) "unknown")
  sched <- digest::digest(file = file.path(REPO, "schedule.yml"), algo = "sha1")
  sprintf(paste0(
    '<div class="%s-generated" data-src="%s" data-schedule="%.12s" ',
    'data-content="%s" data-pushed="%s" ',
    'title="Generated from schedule.yml -- edits made in the Canvas editor ',
    'will be overwritten on the next push">\n%s\n</div>'),
    COURSE_SLUG, src, sched, digest::digest(body, algo = "sha1", serialize = FALSE),
    format(Sys.time(), "%Y-%m-%d %H:%M %Z"), body)
}

# Pull the provenance fields back out of a live page body, attribute by
# attribute so Canvas reordering them doesn't matter. Returns NULL when the
# wrapper is missing (hand-edited or pre-v3 page) -- callers treat that as
# "unknown provenance", which for the delta gate means push.
parse_marker <- function(body) {
  attr1 <- function(name) {
    m <- regmatches(body, regexr <- regexpr(sprintf('%s="([^"]*)"', name), body))
    if (!length(m)) return(NA_character_)
    sub(sprintf('%s="([^"]*)"', name), "\\1", m)
  }
  if (!grepl(sprintf('class="[^"]*%s-generated', COURSE_SLUG), body)) return(NULL)
  out <- list(src = attr1("data-src"), schedule = attr1("data-schedule"),
              content = attr1("data-content"), pushed = attr1("data-pushed"))
  if (is.na(out$content)) return(NULL)
  out
}

SNAPSHOT_PREFIX <- "Course Materials — snapshot "

# Schedule reading and materials-layout helpers (read_schedule, supp_source,
# scheduled_supplements, all_schedule_datasets, ...) live in schedule.R, the
# layer below data_manifest.R -- see the source-chain note there. They arrive
# through the data_manifest source above.

# ---------------------------------------------------------------------------
# Token and API
# ---------------------------------------------------------------------------

# Env var first so a one-off run can override; otherwise ~/.canvas_token. The
# token stays outside the repo -- it grants everything the account can do.
canvas_token <- function() {
  tok <- Sys.getenv("CANVAS_TOKEN")
  if (nzchar(tok)) return(tok)
  path <- path.expand("~/.canvas_token")
  if (file.exists(path)) return(trimws(readLines(path, warn = FALSE)[1]))
  stop("No Canvas token. Set CANVAS_TOKEN, or put one in ~/.canvas_token ",
       "(chmod 600). Create it at Account > Settings > + New Access Token.",
       call. = FALSE)
}

canvas_req <- function(cfg, path) {
  request(paste0(cfg$canvas$host, "/api/v1", path)) |>
    req_auth_bearer_token(canvas_token()) |>
    req_user_agent(paste0(COURSE_SLUG, "-canvas-page"))
}

# Canvas paginates with a Link header; follow rel="next" until it stops. Written
# out rather than using req_perform_iterative so the stopping condition is
# visible -- a truncated file list silently breaks file-name lookups.
canvas_get_all <- function(cfg, path) {
  url <- paste0(cfg$canvas$host, "/api/v1", path)
  out <- list()
  while (!is.null(url)) {
    resp <- request(url) |>
      req_auth_bearer_token(canvas_token()) |>
      req_user_agent(paste0(COURSE_SLUG, "-canvas-page")) |>
      req_perform()
    out <- c(out, resp_body_json(resp))
    link <- resp_header(resp, "Link")
    url <- if (is.null(link)) NULL else link_next(link)
  }
  out
}

link_next <- function(link) {
  parts <- trimws(strsplit(link, ",", fixed = TRUE)[[1]])
  hit <- grep('rel="next"', parts, fixed = TRUE, value = TRUE)
  if (!length(hit)) return(NULL)
  sub("^<(.*)>.*$", "\\1", hit[1])
}

course_path <- function(cfg, suffix) {
  paste0("/courses/", cfg$canvas$course_id, suffix)
}

get_page <- function(cfg, page = cfg$canvas$page) {
  canvas_req(cfg, course_path(cfg, paste0("/pages/", page))) |>
    req_perform() |> resp_body_json()
}

put_page <- function(cfg, html, page = cfg$canvas$page) {
  canvas_req(cfg, course_path(cfg, paste0("/pages/", page))) |>
    req_method("PUT") |>
    req_body_form(`wiki_page[body]` = html) |>
    req_perform() |> resp_body_json()
}

create_page <- function(cfg, title, html, published = FALSE) {
  canvas_req(cfg, course_path(cfg, "/pages")) |>
    req_method("POST") |>
    req_body_form(`wiki_page[title]` = title,
                  `wiki_page[body]` = html,
                  `wiki_page[published]` = if (published) "true" else "false") |>
    req_perform() |> resp_body_json()
}

delete_page <- function(cfg, page) {
  canvas_req(cfg, course_path(cfg, paste0("/pages/", page))) |>
    req_method("DELETE") |> req_perform() |> resp_body_json()
}

list_pages <- function(cfg) canvas_get_all(cfg, course_path(cfg, "/pages?per_page=100"))

# ---------------------------------------------------------------------------
# Canvas files
# ---------------------------------------------------------------------------

# Tool I/O corner inside the scratch space: preview, local snapshots, the
# file cache, and the last-pushed reference all live here rather than loose
# in working/ (see working/README.md). Local snapshots rotate on push.
CANVAS_WORK <- file.path("working", "canvas")
dir.create(file.path(REPO, CANVAS_WORK), recursive = TRUE, showWarnings = FALSE)

FILE_CACHE <- file.path(CANVAS_WORK, "canvas_files.json")

# display_name -> id for every file in the course. Cached because --preview must
# work offline, and because the list changes far less often than the schedule.
course_files <- function(cfg, refresh = FALSE) {
  path <- file.path(REPO, FILE_CACHE)
  if (!refresh && file.exists(path)) {
    return(jsonlite::fromJSON(path, simplifyVector = FALSE))
  }
  files <- canvas_get_all(cfg, course_path(cfg, "/files?per_page=100"))
  out <- list()
  for (f in files) out[[f$display_name]] <- f$id
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  jsonlite::write_json(out, path, auto_unbox = TRUE, pretty = TRUE)
  out
}

# The anchor form Canvas actually renders as a file link, copied from a working
# link on the live page. Drop any of the data- attributes and Canvas shows a
# plain link that misbehaves in the editor and loses its preview.
file_link <- function(cfg, name, files, strict = TRUE) {
  id <- files[[name]]
  if (is.null(id)) {
    msg <- sprintf("no Canvas file named '%s' in course %s", name, cfg$canvas$course_id)
    if (strict) stop(msg, call. = FALSE)
    warning(msg, call. = FALSE)
    return(sprintf('<span style="color: #a00">[missing Canvas file: %s]</span>',
                   esc(name)))
  }
  base <- cfg$canvas$host
  cid <- cfg$canvas$course_id
  sprintf(paste0('<a class="instructure_file_link inline_disabled" title="%s" ',
                 'href="%s/courses/%s/files/%s?wrap=1" target="_blank" ',
                 'data-canvas-previewable="false" ',
                 'data-api-endpoint="%s/api/v1/courses/%s/files/%s" ',
                 'data-api-returntype="File" rel="noopener">%s</a>'),
          esc(name), base, cid, id, base, cid, id, esc(name))
}

# Canvas's three-step upload: ask for a target, POST the file to it, then follow
# the confirmation redirect. Only used for datasets marked `host: canvas`.
upload_file <- function(cfg, path, folder = "course files/data") {
  info <- canvas_req(cfg, course_path(cfg, "/files")) |>
    req_method("POST") |>
    req_body_form(name = basename(path),
                  size = as.character(file.size(path)),
                  parent_folder_path = folder,
                  on_duplicate = "overwrite") |>
    req_perform() |> resp_body_json()

  params <- info$upload_params
  fields <- lapply(params, function(v) if (is.null(v)) "" else as.character(v))
  fields$file <- curl::form_file(path)

  resp <- request(info$upload_url) |>
    req_body_multipart(!!!fields) |>
    req_perform()

  # A 201 carries the file JSON directly; a 3xx points at a confirmation URL.
  if (resp_status(resp) %in% c(200L, 201L)) return(resp_body_json(resp))
  loc <- resp_header(resp, "Location")
  request(loc) |> req_auth_bearer_token(canvas_token()) |>
    req_perform() |> resp_body_json()
}

# ---------------------------------------------------------------------------
# Link builders
# ---------------------------------------------------------------------------

esc <- function(x) {
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;", x, fixed = TRUE)
  gsub(">", "&gt;", x, fixed = TRUE)
}

anchor <- function(href, text) {
  sprintf('<a href="%s" target="_blank" rel="noopener">%s</a>', esc(href), esc(text))
}

site <- function(cfg, rel) paste0(sub("/$", "", cfg$site_url), "/", rel)

# Deck titles are already good link text ("Linear regression"), so read them
# from the source rather than showing a URL or a filename.
deck_title <- function(deck) {
  path <- file.path(REPO, "slides", paste0(deck, ".qmd"))
  if (!file.exists(path)) return(deck)
  ln <- grep("^title:", readLines(path, n = 20, warn = FALSE), value = TRUE)
  if (!length(ln)) return(deck)
  trimws(gsub('"', "", sub("^title:\\s*", "", ln[1])))
}

slide_link <- function(cfg, deck) {
  anchor(site(cfg, paste0("slides/", deck, ".html#/title-slide")), deck_title(deck))
}

# Link text from the supplement's own title:, like deck_title() for slides.
# qmd titles write en dashes as "--", which pandoc converts but Canvas shows
# literally -- swap them here.
supp_title <- function(stem) {
  path <- supp_source(stem)
  if (!file.exists(path)) return(norm_stem(stem))
  ln <- grep("^title:", readLines(path, n = 20, warn = FALSE), value = TRUE)
  if (!length(ln)) return(norm_stem(stem))
  gsub("--", "–", trimws(gsub('"', "", sub("^title:\\s*", "", ln[1]))))
}

supplement_link <- function(cfg, stem) {
  stem <- norm_stem(stem)
  paste0(anchor(site(cfg, paste0("code/", stem, ".pdf")), supp_title(stem)),
         " (", anchor(site(cfg, paste0("code/", stem, ".qmd")), "source"), ")")
}

# publish.sh gzips anything over 90 MB on the way into _book, which renames it.
# Link whatever actually landed there so the big datasets don't 404.
data_href <- function(cfg, rel) {
  staged <- file.path(REPO, "_book", rel)
  if (!file.exists(staged) && file.exists(paste0(staged, ".gz"))) {
    rel <- paste0(rel, ".gz")
  }
  site(cfg, rel)
}

data_link <- function(cfg, rel, names, files, strict = TRUE, host = list()) {
  dir <- sub("^data/([^/]+)/.*$", "\\1", rel)
  label <- names[[dir]] %||% dir
  text <- paste0(label, " — ", basename(rel))
  if (identical(host[[rel]], "canvas")) {
    return(file_link(cfg, basename(rel), files, strict = strict))
  }
  anchor(data_href(cfg, rel), text)
}

# Per-row dataset lists for DISPLAY: only what each lecture introduces. A
# dataset used in lectures 1 and 4 is linked from lecture 1 alone -- rows walk
# the schedule in order and subtract everything already seen. Rows with an
# explicit `data:` list show it verbatim (the override is the author speaking),
# but their datasets still count as seen for later rows.
new_datasets_by_row <- function(sched, manifest) {
  seen <- character()
  lapply(sched$lectures, function(row) {
    ds <- row_datasets(row, manifest)
    shown <- if (is.null(row$materials$data) || identical(row$materials$data, "auto")) {
      setdiff(ds, seen)
    } else ds
    seen <<- union(seen, ds)
    shown
  })
}

# (all_schedule_datasets and row_datasets live in schedule.R.)

# ---------------------------------------------------------------------------
# Markdown with {{...}} refs
# ---------------------------------------------------------------------------

# Prose cells are markdown so they can hold the notes and asides the table
# already carries. {{...}} refs let a sentence link to course material without a
# pasted URL: {{site}}, {{notes}}, {{slides:DECK}}, {{file:NAME}}.
expand_refs <- function(txt, cfg, files, strict = TRUE) {
  if (is.null(txt) || !nzchar(txt)) return("")

  # {{site}} is the offering's own site; {{notes}} is the book (lecture-notes)
  # site, declared as notes_url in schedule.yml. A schedule without notes_url
  # keeps the pre-split behavior: both refs point at site_url.
  txt <- gsub("{{site}}", sub("/$", "", cfg$site_url), txt, fixed = TRUE)
  notes <- if (!is.null(cfg$notes_url) && nzchar(cfg$notes_url)) cfg$notes_url else cfg$site_url
  txt <- gsub("{{notes}}", sub("/$", "", notes), txt, fixed = TRUE)

  # Splice by match position rather than sub(): the replacements are HTML
  # anchors, and sub() would read any backslash sequence in them as a
  # backreference. Position splicing treats the replacement as literal text.
  repl <- function(pattern, fn) {
    repeat {
      m <- regexpr(pattern, txt, perl = TRUE)
      if (m == -1) break
      whole <- regmatches(txt, m)
      arg <- sub(pattern, "\\1", whole, perl = TRUE)
      txt <<- paste0(substr(txt, 1, m - 1), fn(arg),
                     substring(txt, m + attr(m, "match.length")))
    }
  }
  repl("\\{\\{file:([^}]+)\\}\\}", function(a) file_link(cfg, a, files, strict = strict))
  repl("\\{\\{slides:([^}]+)\\}\\}", function(a) slide_link(cfg, a))
  txt
}

render_markdown <- function(txt, cfg, files, strict = TRUE) {
  if (is.null(txt) || !nzchar(trimws(paste(txt, collapse = "")))) return("")
  commonmark::markdown_html(expand_refs(paste(txt, collapse = "\n"), cfg, files, strict))
}

# ---------------------------------------------------------------------------
# Building the page
# ---------------------------------------------------------------------------

# One labelled group of links as a collapsible section. <details>/<summary>
# survive Canvas's sanitizer (verified on the live course) and give the native
# disclosure arrow; the `open` attribute does NOT survive, so every group is
# collapsed by default -- that's the sanitizer's choice, not ours.
link_group <- function(label, links, extra = "") {
  if (!length(links) && !nzchar(extra)) return("")
  paste0("<details><summary>", label, "</summary>\n",
         if (length(links)) paste0("<ul>\n",
           paste0("<li>", links, "</li>", collapse = "\n"), "\n</ul>\n") else "",
         extra,
         "</details>\n")
}

CUMULATIVE_ZIP <- sprintf("data/%s_data.zip", COURSE_SLUG)

materials_cell <- function(row, cfg, manifest, files, strict = TRUE,
                           shown_ds = NULL) {
  m <- row$materials
  parts <- character()

  if (length(m$slides)) {
    parts <- c(parts, link_group("Slides",
      vapply(unlist(m$slides), function(d) slide_link(cfg, d), character(1))))
  }

  code <- character()
  if (length(m$supplements)) {
    code <- c(code, vapply(unlist(m$supplements),
                           function(s) supplement_link(cfg, s),
                           character(1)))
  }
  # `code:` remains as an arbitrary-URL escape hatch (unused by default now
  # that supplements link individually).
  if (!is.null(m$code)) {
    href <- expand_refs(m$code, cfg, files, strict)
    code <- c(code, anchor(href, "Additional code"))
  }
  parts <- c(parts, link_group("Code", code))

  # Data: what this lecture introduces (precomputed schedule-wide; "(none)"
  # when a lecture only reuses earlier data), then always the cumulative zip
  # -- the same link in every row, growing as lectures are added.
  ds <- shown_ds %||% row_datasets(row, manifest)
  show_data <- isTRUE(m$bundle) || length(ds) ||
    !is.null(m$data)   # rows that opted out of everything get no Data group
  if (show_data) {
    new_part <- if (length(ds)) {
      paste0("<p>New datasets:</p>\n<ul>\n",
             paste0("<li>", vapply(ds, function(d)
               data_link(cfg, d, manifest$names, files, strict,
                         manifest$host %||% list()), character(1)),
               "</li>", collapse = "\n"),
             "\n</ul>\n")
    } else {
      "<p>New datasets: (none)</p>\n"
    }
    zip_part <- if (isTRUE(m$bundle)) {
      paste0("<p>", anchor(site(cfg, CUMULATIVE_ZIP),
                           "Complete data archive (zip)"), "</p>\n")
    } else ""
    parts <- c(parts, link_group("Data", character(),
                                 extra = paste0(new_part, zip_part)))
  }

  if (length(m$files)) {
    parts <- c(parts, link_group("Files:",
      vapply(unlist(m$files), function(f) file_link(cfg, f, files, strict), character(1))))
  }

  if (!is.null(m$note)) parts <- c(parts, render_markdown(m$note, cfg, files, strict))

  paste(parts[nzchar(parts)], collapse = "\n")
}

# Dates live in schedule.yml as ISO (date: 2026-07-13) and render uniformly
# here -- "Mon 7/13" -- so the page never mixes "Tues", "Th", and "M" the way
# hand-typed cells did. A value that doesn't parse as a date (e.g. "TBD",
# "Finals week") passes through as typed.
fmt_date <- function(d) {
  dt <- tryCatch(as.Date(as.character(d)), error = function(e) NA,
                 warning = function(w) NA)
  if (is.na(dt)) return(as.character(d))
  sprintf("%s %d/%d", format(dt, "%a"),
          as.integer(format(dt, "%m")), as.integer(format(dt, "%d")))
}

# First column, headed "Date": the date leads, its recording link sits right
# under it (a row's own `recording:` beats the schedule-wide Panopto folder --
# per-session Panopto URLs are behind UT SSO, so resolving them automatically
# isn't possible; paste one into a row if it's ever wanted), then the topic.
topic_cell <- function(row, cfg, files, strict = TRUE) {
  parts <- character()
  if (!is.null(row$date)) parts <- c(parts, paste0("<p>", esc(fmt_date(row$date)), "</p>"))
  rec <- row$recording %||% cfg$recordings
  if (!is.null(rec)) parts <- c(parts, paste0("<p>", anchor(rec, "Recording (Panopto)"), "</p>"))
  if (!is.null(row$topic)) parts <- c(parts, render_markdown(row$topic, cfg, files, strict))
  paste(parts, collapse = "\n")
}

build_html <- function(sched, manifest, files = list(), strict = TRUE) {
  cfg <- sched

  head_cells <- paste0(
    sprintf('<td style="width: %s;"><strong>%s</strong></td>',
            COL_WIDTHS[seq_along(sched$columns)], esc(unlist(sched$columns))),
    collapse = "\n")

  shown <- new_datasets_by_row(sched, manifest)
  rows <- vapply(seq_along(sched$lectures), function(i) {
    row <- sched$lectures[[i]]
    cells <- c(topic_cell(row, cfg, files, strict),
               render_markdown(row$readings, cfg, files, strict),
               materials_cell(row, cfg, manifest, files, strict,
                              shown_ds = shown[[i]]))
    paste0("<tr>\n",
           paste0(sprintf('<td style="width: %s;">\n%s\n</td>', COL_WIDTHS, cells),
                  collapse = "\n"),
           "\n</tr>")
  }, character(1))

  # No marker here: build_html returns the reproducible body; page_with_marker
  # wraps it for pushing, so the recorded content hash covers exactly this.
  paste0(
    render_markdown(sched$preamble, cfg, files, strict), "\n",
    '<table style="border-collapse: collapse; width: 100%;" border="1">\n<tbody>\n',
    "<tr>\n", head_cells, "\n</tr>\n",
    paste(rows, collapse = "\n"),
    "\n</tbody>\n</table>\n"
  )
}

# ---------------------------------------------------------------------------
# Checking
# ---------------------------------------------------------------------------

# Everything that can be wrong offline, collected rather than thrown one at a
# time -- a push should report all of its problems in one go.
check_schedule <- function(sched, manifest, files) {
  problems <- character()

  if (manifest_is_stale()) {
    problems <- c(problems,
      "data_manifest.yml is stale: a source's datasets changed. Run ./canvas.sh --scan and review the diff.")
  }

  # The page lists datasets from the manifest; the cumulative zip was built
  # from the schedule + manifest as of the last --data run. If those differ,
  # the "All course data" link lies about its contents.
  any_bundles <- any(vapply(sched$lectures,
                            function(r) isTRUE(r$materials$bundle), logical(1)))
  if (any_bundles && bundles_stale(sched, manifest)) {
    problems <- c(problems,
      "the cumulative data zip is out of date: run ./publish.sh --data")
  }

  book <- file.path(REPO, "_book")
  have_book <- dir.exists(book)
  if (!have_book) {
    problems <- c(problems,
      "_book/ does not exist, so site links cannot be validated. Run ./publish.sh first.")
  }

  for (row in sched$lectures) {
    tag <- row$date %||% paste("lecture", row$lecture %||% "?")

    for (deck in unlist(row$materials$slides)) {
      if (!file.exists(file.path(REPO, "slides", paste0(deck, ".qmd")))) {
        problems <- c(problems, sprintf("%s: no such deck slides/%s.qmd", tag, deck))
      } else if (have_book && !file.exists(file.path(book, "slides", paste0(deck, ".html")))) {
        problems <- c(problems, sprintf("%s: deck %s is not published yet", tag, deck))
      }
    }

    for (s in norm_stem(unlist(row$materials$supplements))) {
      if (!file.exists(supp_source(s))) {
        problems <- c(problems, sprintf(
          "%s: no such supplement companion_scripts/%s.qmd", tag, s))
      } else if (have_book &&
                 !file.exists(file.path(book, "code", paste0(s, ".pdf")))) {
        problems <- c(problems, sprintf(
          "%s: supplement %s is not built -- run ./publish.sh --code", tag, s))
      }
    }

    for (d in row_datasets(row, manifest)) {
      if (!file.exists(file.path(REPO, d))) {
        problems <- c(problems, sprintf("%s: dataset %s does not exist", tag, d))
      } else if (have_book &&
                 !file.exists(file.path(book, d)) &&
                 !file.exists(file.path(book, paste0(d, ".gz")))) {
        problems <- c(problems, sprintf("%s: dataset %s is not staged in _book", tag, d))
      }
    }

    for (f in unlist(row$materials$files)) {
      if (is.null(files[[f]])) {
        problems <- c(problems, sprintf("%s: no Canvas file named '%s'", tag, f))
      }
    }
  }

  c(problems, check_solutions(sched, manifest, files))
}

# Sources that exist in the repo but appear in no schedule row -- the
# forgetting failure one level up from datasets: rendered and published a deck,
# never added the row. Informational (new material legitimately predates its
# row), so callers print these as notices, not failures.
check_coverage <- function(sched) {
  used_decks <- unlist(lapply(sched$lectures, function(r) r$materials$slides))
  used_supps <- scheduled_supplements(sched)

  decks <- sub("\\.qmd$", "", list.files(file.path(REPO, "slides"), "^[0-9]+_.*\\.qmd$"))
  supps <- norm_stem(list.files(file.path(REPO, "companion_scripts"), "\\.qmd$"))

  c(
    if (length(setdiff(decks, used_decks)))
      sprintf("deck not in any schedule row: %s",
              paste(setdiff(decks, used_decks), collapse = ", ")),
    if (length(setdiff(supps, used_supps)))
      sprintf("supplement not in any schedule row: %s",
              paste(setdiff(supps, used_supps), collapse = ", "))
  )
}

# The three-surface drift matrix: where is source, what does the site have,
# what does the Canvas page have. Site state comes from the deploy log on
# origin/gh-pages; Canvas state from the live page's provenance marker. Both
# travel with their artifact, so this works identically on either machine.
canvas_status <- function(cfg, site_clone = Sys.getenv("SITE_CLONE",
                                                       sprintf("~/builds/%s_site", COURSE_SLUG))) {
  git1 <- function(...) tryCatch(
    system2("git", c(...), stdout = TRUE, stderr = FALSE)[1],
    error = function(e) NA_character_)

  src_sha <- git1("rev-parse", "--short", "HEAD")
  dirty <- length(system2("git", c("status", "--porcelain"), stdout = TRUE)) > 0

  clone <- path.expand(site_clone)
  site_line <- if (dir.exists(file.path(clone, ".git"))) {
    system2("git", c("-C", clone, "fetch", "origin", "gh-pages"),
            stdout = FALSE, stderr = FALSE)
    git1("-C", clone, "log", "-1", "--format=%s", "origin/gh-pages")
  } else NA_character_

  live <- tryCatch(get_page(cfg), error = function(e) NULL)
  marker <- if (!is.null(live)) parse_marker(live$body %||% "") else NULL

  cat(sprintf("source   %s%s\n", src_sha, if (dirty) "  (working tree dirty)" else ""))

  if (is.na(site_line)) {
    cat(sprintf("site     no clone at %s yet (first deploy creates it)\n", clone))
  } else if (startsWith(site_line %||% "", "publish: ")) {
    site_sha <- sub("^publish: ([0-9a-f]+).*", "\\1", site_line)
    ok <- identical(sub("\\+dirty$", "", site_sha), src_sha) && !dirty
    cat(sprintf("site     %s   %s\n", site_line, if (ok) "= source" else "BEHIND source"))
  } else {
    cat(sprintf("site     last deploy predates v3 tooling (%s)\n", site_line))
  }

  if (is.null(live)) {
    cat("canvas   unreachable (network or token)\n")
  } else if (is.null(marker)) {
    cat("canvas   live page has no provenance marker (hand-edited or never pushed)\n")
  } else {
    body <- build_html(read_schedule(), read_manifest(),
                       tryCatch(course_files(cfg), error = function(e) list()),
                       strict = FALSE)
    now_hash <- digest::digest(body, algo = "sha1", serialize = FALSE)
    same <- identical(now_hash, marker$content)
    cat(sprintf("canvas   src=%s pushed %s   %s\n", marker$src, marker$pushed,
                if (same) "= current schedule" else "BEHIND (schedule/manifest changed)"))
  }
  invisible(NULL)
}

# Nothing derived from problem-set solutions may be linked from a public URL.
# publish.sh guards the site the same way; this guards the page that points at
# it. Canvas-internal links are exempt: solutions legitimately live in Canvas.
check_solutions <- function(sched, manifest, files) {
  html <- tryCatch(build_html(sched, manifest, files, strict = FALSE),
                   error = function(e) "")
  hits <- regmatches(html, gregexpr('<a [^>]*href="([^"]+)"[^>]*>([^<]*)</a>', html))[[1]]
  bad <- Filter(function(a) {
    grepl("solution", a, ignore.case = TRUE) &&
      # fixed: the host is a URL, and its dots and slashes would otherwise be
      # read as regex metacharacters.
      !grepl(sprintf('href="%s', sched$canvas$host), a, fixed = TRUE) &&
      !grepl('href="/courses/', a, fixed = TRUE)
  }, hits)
  if (length(bad)) {
    return(sprintf("solutions guard: public link mentions solutions: %s",
                   substr(bad, 1, 120)))
  }
  character()
}
