# Schedule and materials-layout helpers -- the lower layer of the Canvas
# toolchain. Sourced by data_manifest.R (which needs the schedule to know
# what to build) and, through it, canvas_page.R. Keep this file free of any
# canvas/API/HTML concern so the source chain stays one-directional:
#
#   schedule.R <- data_manifest.R <- canvas_page.R <- canvas_cli.R

suppressWarnings(suppressPackageStartupMessages(library(yaml)))

if (!exists("REPO")) {
  REPO <- normalizePath(Sys.getenv("CANVAS_REPO", unset = getwd()), mustWork = TRUE)
}

# Config and schedule
# ---------------------------------------------------------------------------

read_schedule <- function(path = file.path(REPO, "schedule.yml")) {
  sched <- yaml::read_yaml(path)
  sched$lectures <- lapply(sched$lectures, merge_defaults, defaults = sched$defaults)
  sched
}

# A row inherits every default it does not set. Only `materials` is merged
# key-by-key; a row that names its own `data:` keeps the default `code:`.
merge_defaults <- function(row, defaults) {
  if (is.null(defaults)) return(row)
  for (key in names(defaults)) {
    if (key == "materials") {
      for (mk in names(defaults$materials)) {
        if (is.null(row$materials[[mk]])) row$materials[[mk]] <- defaults$materials[[mk]]
      }
    } else if (is.null(row[[key]])) {
      row[[key]] <- defaults[[key]]
    }
  }
  row
}


# Coding supplements publish straight to the site: companion_scripts/<stem>.qmd
# renders to {site}/code/<stem>.pdf with the runnable source staged alongside.
# One source of truth -- no supplemental_files glob, no Canvas Files fallback;
# a scheduled supplement whose PDF isn't built fails the checks instead.
norm_stem <- function(s) sub("\\.qmd$", "", s)

supp_source <- function(stem) {
  file.path(REPO, "companion_scripts", paste0(norm_stem(stem), ".qmd"))
}


# Every stem any row schedules -- what publish.sh --code builds.
scheduled_supplements <- function(sched) {
  sort(unique(norm_stem(unlist(lapply(sched$lectures,
    function(r) r$materials$supplements)))))
}



# Union across the whole schedule -- the contents of the cumulative zip.
all_schedule_datasets <- function(sched, manifest) {
  sort(unique(unlist(lapply(sched$lectures, row_datasets, manifest = manifest))),
       method = "radix")
}

# Which datasets belong to a row: an explicit list wins, otherwise the union of
# what this row's decks and supplements read, from the manifest.
row_datasets <- function(row, manifest) {
  spec <- row$materials$data
  if (is.null(spec)) return(character())
  if (!identical(spec, "auto")) return(unlist(spec, use.names = FALSE))

  keys <- c(
    if (length(row$materials$slides)) file.path("slides",
      paste0(unlist(row$materials$slides), ".qmd")),
    if (length(row$materials$supplements)) file.path("companion_scripts",
      paste0(norm_stem(unlist(row$materials$supplements)), ".qmd"))
  )
  ds <- unlist(lapply(keys, function(k) {
    unlist(manifest$sources[[k]]$datasets, use.names = FALSE)
  }), use.names = FALSE)
  # A deck absent from the manifest (typo, or a source that reads no data)
  # yields NULL, which sort() rejects outright rather than passing through.
  if (!length(ds)) return(character())
  sort(unique(as.character(ds)), method = "radix")  # locale-independent
}

