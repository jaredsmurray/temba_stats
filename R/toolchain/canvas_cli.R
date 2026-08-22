# Action driver for canvas.sh -- run as: Rscript R/toolchain/canvas_cli.R <action> <keep> <restore_n>
# All argument parsing and locale setup happen in canvas.sh; this file assumes
# the working directory is the repo root.

  suppressWarnings(suppressPackageStartupMessages({
    source("R/toolchain/data_manifest.R"); source("R/toolchain/canvas_page.R")
  }))
  args <- commandArgs(trailingOnly = TRUE)
  action <- args[1]; keep <- as.integer(args[2]); restore_n <- args[3]

  fail <- function(...) { message(...); quit(status = 1) }

  if (action == "scan") {
    write_manifest()
    message(">> Wrote data_manifest.yml. Review the diff: git diff data_manifest.yml")
    quit(status = 0)
  }

  sched <- read_schedule()

  # CANVAS_PAGE overrides the target page slug -- the rehearsal path: push the
  # real generated page to a scratch page without touching schedule.yml or the
  # live front page. e.g.  CANVAS_PAGE=canvas-workflow-test ./canvas.sh --push
  page_override <- Sys.getenv("CANVAS_PAGE")
  if (nzchar(page_override)) {
    sched$canvas$page <- page_override
    message(">> Target page overridden: ", page_override, " (CANVAS_PAGE)")
  }

  networked <- !(action %in% c("preview"))

  # Token preflight: any networked action first proves the token works, so a
  # dead token fails in two seconds with the fix spelled out -- not mid-push
  # right before class. (Canvas returns 401 for expired and revoked alike.)
  if (networked) {
    whoami <- tryCatch(
      canvas_req(sched, "/users/self") |> req_perform() |> resp_body_json(),
      error = function(e) e)
    if (inherits(whoami, "error")) {
      if (action %in% c("check", "diff", "status")) {
        message("!! Canvas unreachable or token invalid; running offline checks only.")
        message("   (token lives in ~/.canvas_token; new ones: Canvas > Account >")
        message("   Settings > + New Access Token)")
        networked <- FALSE
      } else {
        fail("ERROR: Canvas API auth failed: ", conditionMessage(whoami), "\n",
             "  Token file: ~/.canvas_token (chmod 600). Create a new token at\n",
             "  Canvas > Account > Settings > + New Access Token.")
      }
    }
  }

  # --preview must work with no network; a cache miss degrades to a marker.
  files <- tryCatch(
    course_files(sched, refresh = action == "refresh-files"),
    error = function(e) {
      if (action == "preview" || !networked) {
        message("!! No Canvas file cache available; file links shown as missing.")
        list()
      } else stop(e)
    })

  if (action == "refresh-files") {
    # Surface duplicate display_names: file_link() matches by name, and a
    # duplicate means it could silently link the wrong file.
    raw <- canvas_get_all(sched, course_path(sched, "/files?per_page=100"))
    nms <- vapply(raw, function(f) f$display_name, character(1))
    dup <- unique(nms[duplicated(nms)])
    if (length(dup)) {
      message("!! Duplicate display names in Canvas Files (name lookup may pick")
      message("   the wrong one): ", paste(dup, collapse = ", "))
    }
    message(sprintf(">> Cached %d Canvas file name(s).", length(files)))
    quit(status = 0)
  }

  if (action == "status") { canvas_status(sched); quit(status = 0) }

  # The delta gate, for ship.sh: would a push change the page? Compares the
  # hash of the freshly generated body against the hash recorded in the live
  # page provenance marker at last push -- never against Canvas own body,
  # which Canvas rewrites on save. Exit 0 = unchanged, 10 = push needed,
  # 1 = cannot tell (network/token/no marker; ship treats as push-needed-
  # but-blocked and reports it).
  if (action == "gate") {
    if (!networked) fail("gate: Canvas unreachable")
    body <- build_html(sched, read_manifest(), files, strict = FALSE)
    h <- digest::digest(body, algo = "sha1", serialize = FALSE)
    live <- tryCatch(get_page(sched), error = function(e) NULL)
    if (is.null(live)) fail("gate: could not fetch the live page")
    mk <- parse_marker(live$body %||% "")
    if (is.null(mk)) {
      message("gate: live page has no provenance marker (never pushed, or hand-edited)")
      quit(status = 10)
    }
    if (identical(mk$content, h)) {
      message("gate: page unchanged since last push (", mk$pushed, ")")
      quit(status = 0)
    }
    message("gate: page would change (last push ", mk$pushed, ", src ", mk$src, ")")
    quit(status = 10)
  }

  manifest <- read_manifest()

  if (action == "preview") {
    html <- page_with_marker(build_html(sched, manifest, files, strict = FALSE))
    out <- file.path(CANVAS_WORK, "canvas_preview.html")
    writeLines(c("<!doctype html><meta charset=utf-8>",
                 "<title>Canvas page preview</title>",
                 "<body style=\"font-family: system-ui; max-width: 60em; margin: 2em auto\">",
                 html, "</body>"), out)
    message(sprintf(">> Wrote %s", out))
    system2("open", shQuote(out))
    quit(status = 0)
  }

  if (action == "diff") {
    # Diff against the body we generated at the last push (saved locally), not
    # against Canvas's live body -- Canvas rewrites HTML on save, so that diff
    # would drown real changes in attribute noise.
    now <- build_html(sched, manifest, files, strict = FALSE)
    ref <- file.path(CANVAS_WORK, "canvas_pushed_latest.html")
    if (!file.exists(ref)) {
      # No local reference (other machine pushed last?): fall back to a
      # provenance comparison so the answer is still meaningful.
      if (networked) {
        live <- tryCatch(get_page(sched), error = function(e) NULL)
        mk <- if (!is.null(live)) parse_marker(live$body %||% "") else NULL
        h <- digest::digest(now, algo = "sha1", serialize = FALSE)
        if (is.null(mk)) {
          message("No local reference and no provenance marker on the live page;")
          message("cannot diff. The next --push establishes both.")
        } else if (identical(mk$content, h)) {
          message(">> No changes: generated page matches what was last pushed.")
        } else {
          message(">> Page WOULD change (pushed ", mk$pushed, ", src ", mk$src, ");")
          message("   no local copy of that push to diff against on this machine.")
        }
      } else message("No local reference copy and Canvas unreachable; cannot diff.")
      quit(status = 0)
    }
    tmp <- tempfile(fileext = ".html"); writeLines(now, tmp)
    status <- system2("diff", c("-u", shQuote(ref), shQuote(tmp)),
                      stdout = "", stderr = "")
    if (status == 0) message(">> No changes: generated page matches the last push.")
    quit(status = 0)
  }

  if (action %in% c("check", "push")) {
    problems <- check_schedule(sched, manifest, files)

    # Online-only: verify each referenced Canvas file id still resolves. A
    # cached id can go stale when a file is replaced (new id, same name).
    if (networked) {
      used <- unique(unlist(lapply(sched$lectures, function(r)
        c(unlist(r$materials$files),
          unlist(r$materials$supplements)))))
      used <- used[used %in% names(files)]
      for (nm in used) {
        ok <- tryCatch({
          canvas_req(sched, sprintf("/courses/%s/files/%s",
                                    sched$canvas$course_id, files[[nm]])) |>
            req_perform(); TRUE
        }, error = function(e) FALSE)
        if (!ok) problems <- c(problems, sprintf(
          "cached id for Canvas file '%s' no longer resolves; run --refresh-files", nm))
      }
    }

    for (note in check_coverage(sched)) message("   note: ", note)

    if (length(problems)) {
      message(sprintf("!! %d problem(s):", length(problems)))
      for (p in problems) message("   - ", p)
      if (action == "check") quit(status = 1)
      fail("Refusing to push. Fix the above, or run --scan if the manifest is stale.")
    }
    message(">> Checks passed.")
    if (action == "check") quit(status = 0)
  }

  if (action == "push") {
    # Snapshot first: the PUT replaces the whole body, and Canvas keeps only a
    # buried revision history, so the copy is what makes a bad push undoable.
    stamp <- format(Sys.time(), "%Y-%m-%d %H%M")
    src <- tryCatch(system2("git", c("rev-parse", "--short", "HEAD"),
                            stdout = TRUE, stderr = FALSE)[1],
                    error = function(e) "unknown")
    live <- tryCatch(get_page(sched), error = function(e) NULL)
    gen <- build_html(sched, manifest, files, strict = TRUE)

    if (is.null(live)) {
      # Target page doesn't exist yet: create it UNPUBLISHED (invisible to
      # students until deliberately published in Canvas). This is the
      # rehearsal path -- and a guard against a typo'd slug silently going
      # student-visible.
      title <- gsub("-", " ", sched$canvas$page)
      created <- create_page(sched, title, page_with_marker(gen), published = FALSE)
      writeLines(gen, file.path(CANVAS_WORK, "canvas_pushed_latest.html"))
      message(sprintf(">> Created new UNPUBLISHED page \"%s\" (%s/courses/%s/pages/%s).",
                      created$title, sched$canvas$host, sched$canvas$course_id,
                      created$url))
      message(">> Review it in Canvas; publish it there when it looks right.")
      quit(status = 0)
    }

    body <- live$body %||% ""
    backup <- file.path(CANVAS_WORK, sprintf("canvas_backup_%s.html",
                                             gsub("[^0-9]", "", stamp)))
    writeLines(body, backup)
    # Rotate local snapshots (the Canvas-side ones have --prune; these would
    # otherwise accumulate forever). Newest 10 stay.
    snaps <- sort(list.files(CANVAS_WORK, "^canvas_backup_[0-9]+\\.html$",
                             full.names = TRUE), decreasing = TRUE)
    if (length(snaps) > 10) unlink(snaps[-(1:10)])
    snap <- create_page(sched, paste0(SNAPSHOT_PREFIX, stamp, " @", src), body,
                        published = FALSE)
    message(sprintf(">> Snapshot: \"%s\" (unpublished) + %s", snap$title, backup))

    put_page(sched, page_with_marker(gen))
    # The local reference --diff compares against next time.
    writeLines(gen, file.path(CANVAS_WORK, "canvas_pushed_latest.html"))
    message(sprintf(">> Pushed %d rows to %s/courses/%s/pages/%s",
                    length(sched$lectures), sched$canvas$host,
                    sched$canvas$course_id, sched$canvas$page))

    nsnap <- length(Filter(function(p) startsWith(p$title, SNAPSHOT_PREFIX),
                           list_pages(sched)))
    if (nsnap > 10) {
      message(sprintf(">> Note: %d snapshots accumulated; consider ./canvas.sh --prune", nsnap))
    }
    quit(status = 0)
  }

  if (action %in% c("snapshots", "prune", "restore")) {
    pages <- list_pages(sched)
    snaps <- Filter(function(p) startsWith(p$title, SNAPSHOT_PREFIX), pages)
    snaps <- snaps[order(vapply(snaps, function(p) p$created_at, character(1)),
                         decreasing = TRUE)]
    if (!length(snaps)) { message(">> No snapshots."); quit(status = 0) }

    if (action == "snapshots") {
      for (i in seq_along(snaps)) {
        message(sprintf("  %2d. %s   (%s)", i, snaps[[i]]$title, snaps[[i]]$url))
      }
      message(sprintf(">> %d snapshot(s). Restore one with --restore <number>.",
                      length(snaps)))
      quit(status = 0)
    }

    if (action == "restore") {
      i <- suppressWarnings(as.integer(restore_n))
      if (is.na(i) || i < 1 || i > length(snaps)) {
        fail("ERROR: --restore wants a snapshot number 1..", length(snaps),
             " (see --snapshots).")
      }
      chosen <- snaps[[i]]
      message(sprintf(">> Restoring \"%s\" to the live page.", chosen$title))
      # Snapshot the current state first, so a restore is itself undoable.
      stamp <- format(Sys.time(), "%Y-%m-%d %H%M")
      live <- get_page(sched)
      create_page(sched, paste0(SNAPSHOT_PREFIX, stamp, " @pre-restore"),
                  live$body %||% "", published = FALSE)
      snap_full <- get_page(sched, chosen$url)
      put_page(sched, snap_full$body %||% "")
      message(">> Restored. (The replaced state was snapshotted first.)")
      quit(status = 0)
    }

    doomed <- if (keep > 0) utils::tail(snaps, -keep) else snaps
    if (!length(doomed)) {
      message(sprintf(">> %d snapshot(s), keeping %d. Nothing to delete.",
                      length(snaps), keep))
      quit(status = 0)
    }
    message(sprintf(">> Will DELETE %d of %d snapshot(s):", length(doomed), length(snaps)))
    for (p in doomed) message("   - ", p$title)
    cat("Proceed? [y/N] ")
    ans <- tolower(trimws(readLines("stdin", n = 1)))
    if (!identical(ans, "y")) { message(">> Aborted."); quit(status = 0) }
    for (p in doomed) { delete_page(sched, p$url); message("   deleted ", p$title) }
    quit(status = 0)
  }

  if (action == "sync-data") {
    host <- manifest$host
    targets <- names(host)[vapply(host, function(v) identical(v, "canvas"), logical(1))]
    if (!length(targets)) {
      message(">> No datasets marked `host: canvas` in data_manifest.yml. Nothing to do.")
      quit(status = 0)
    }
    for (rel in targets) {
      message("   uploading ", rel)
      upload_file(sched, rel)
    }
    course_files(sched, refresh = TRUE)
    message(sprintf(">> Uploaded %d dataset(s) and refreshed the file cache.", length(targets)))
    quit(status = 0)
  }
