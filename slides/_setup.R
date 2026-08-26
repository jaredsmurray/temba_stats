# Shared setup for the lecture slide decks. Each deck's setup chunk sources
# this file and calls only the loaders it needs, so no deck pays to load
# data it never plots. Data paths are relative to the slides/ directory.

# Locale guard: R in a C locale (cron, launchd, non-login shells) prints
# non-ASCII as literal <U+XXXX> into rendered text and figure labels, with a
# clean exit. Every deck sources this file, so pin UTF-8 here in case the
# machine-level fix (~/.Renviron LANG, see course-kit BOOTSTRAP.md) is absent.
if (!grepl("UTF-8", Sys.getlocale("LC_CTYPE"), fixed = TRUE)) {
  suppressWarnings(invisible(Sys.setlocale("LC_ALL", "en_US.UTF-8")))
}

library(tidyverse)
library(scales)
library(patchwork)

theme_set(theme_minimal(base_size = 16))

# math_usd() and the other inline formatters live in the shared render helpers.
source("R/inline_format.R")

# Table-cell sibling of math_usd(): escapes the "$" for pandoc but keeps a
# plain comma, since table cells are not set by MathJax.
cell_usd <- function(x, accuracy = 1) {
  paste0("\\$", comma(x, accuracy = accuracy))
}

load_austin_full <- function() {
  read_csv("../data/austin_houses/austin_houses.csv", show_col_types = FALSE)
}

load_austin_subset <- function() {
  read_csv("../data/austin_houses/austin_houses_subset.csv",
           show_col_types = FALSE)
}

read_ercot_raw <- function() {
  bind_rows(
    read_csv("../data/ercot/ercotproject/Data/load_1.csv", show_col_types = FALSE),
    read_csv("../data/ercot/ercotproject/Data/load_2.csv", show_col_types = FALSE),
    read_csv("../data/ercot/ercotproject/Data/load_3.csv", show_col_types = FALSE)
  ) |>
    filter(LOCATION == "North Central (DFW)")
}

# Hourly DFW load, 2016-2020 (matches the setup in singlevar_01/_02)
load_ercot <- function() {
  read_ercot_raw() |>
    mutate(datetime = as.POSIXct(DATEHOUR, format = "%Y-%m-%d %H:%M"),
           year = as.numeric(format(datetime, "%Y"))) |>
    filter(year >= 2016, year <= 2020)
}

# Daily mean DFW load, 2016-2020 (matches the setup in prob_04)
load_ercot_daily <- function() {
  read_ercot_raw() |>
    mutate(datetime = parse_date_time(DATEHOUR, orders = c("ymd HM", "ymd HMS")),
           year = year(datetime),
           date = as.Date(datetime)) |>
    filter(year >= 2016, year <= 2020) |>
    summarize(load = mean(LOAD, na.rm = TRUE), .by = date)
}

# Daily mean DFW load and temperature, 2016-2020 (matches the setup in twovar_02)
load_ercot_daily_temp <- function() {
  ercot <- read_ercot_raw() |>
    mutate(datetime = parse_date_time(DATEHOUR, orders = c("ymd HM", "ymd HMS")),
           year = year(datetime),
           date = as.Date(datetime)) |>
    filter(year >= 2016, year <= 2020)
  weather <- read_csv("../data/ercot/ercotproject/Data/weather_ncent.csv",
                      show_col_types = FALSE) |>
    mutate(datetime = parse_date_time(DATEHOUR, orders = c("ymd HM", "ymd HMS")),
           year = year(datetime)) |>
    filter(year >= 2016, year <= 2020)
  ercot |>
    inner_join(weather, by = c("datetime", "LOCATION"),
               relationship = "many-to-many") |>
    filter(!is.na(HourlyDryBulbTemperature), !is.na(LOAD)) |>
    distinct(datetime, .keep_all = TRUE) |>
    summarize(temp = mean(HourlyDryBulbTemperature, na.rm = TRUE),
              load = mean(LOAD, na.rm = TRUE),
              .by = date)
}

# The 81 publicly traded SAP customers from the 2006 Nucleus Research note
# (matches the setup in the archived prob_08 inference chapter)
load_sap <- function() {
  read_csv("../data/sap_roe/sap_roe.csv", show_col_types = FALSE)
}

load_lending <- function() {
  read_csv("../data/lending_club/data/df_all.csv", show_col_types = FALSE) |>
    mutate(default = as.integer(loan_status == "Charged Off"))
}

load_lending_subs <- function() {
  read_csv("../data/lending_club/data/df_subs.csv", show_col_types = FALSE) |>
    mutate(default = as.integer(loan_status == "Charged Off"))
}

load_shed <- function() {
  read_csv("../data/shed/shed_2025.csv", show_col_types = FALSE)
}

load_returns <- function() {
  read_csv("../data/returns/returns.csv", show_col_types = FALSE) |>
    mutate(date = as.Date(date))
}

# Weekly returns on SPY, EFA, and TLT plus the T-bill rate, Sept 2023 -- Sept
# 2025 (matches the setup in prob_07)
load_portfolios <- function() {
  read_csv("../data/portfolios/portfolios.csv", show_col_types = FALSE) |>
    mutate(date = as.Date(date))
}

# Hamermesh & Parker (2005) UT Austin course evaluations (matches the setup
# in regression_01)
load_hamermesh <- function() {
  read_csv("../data/hamermesh_evals/hamermesh_evals.csv", show_col_types = FALSE)
}

load_mincer <- function() {
  read_csv("../data/mincer/cps_asec_2023.csv", show_col_types = FALSE)
}

# GMAT Focus Edition total-score percentile concordance, published by GMAC in
# July 2025 (percentiles cover test takers from July 1, 2020 to June 30, 2025).
gmat <- tribble(
  ~score, ~pct,
  805, 100.0, 795, 100.0, 785, 100.0, 775, 100.0, 765, 99.9, 755, 99.9,
  745, 99.7, 735, 99.5, 725, 99.1, 715, 98.8, 705, 98.0, 695, 97.4,
  685, 95.8, 675, 94.8, 665, 92.1, 655, 90.5, 645, 86.7, 635, 81.9,
  625, 79.2, 615, 76.4, 605, 70.3, 595, 67.1, 585, 60.6, 575, 57.4,
  565, 50.9, 555, 47.8, 545, 41.9, 535, 39.2, 525, 34.0, 515, 31.5,
  505, 27.1, 495, 25.1, 485, 21.3, 475, 19.7, 465, 16.6, 455, 15.2,
  445, 12.7, 435, 11.6, 425,  9.6, 415,  8.7, 405,  7.1, 395,  6.4,
  385,  5.2, 375,  4.7, 365,  3.8, 355,  3.4, 345,  2.7, 335,  2.4,
  325,  1.9, 315,  1.7, 305,  1.3, 295,  1.1, 285,  0.8, 275,  0.7,
  265,  0.5, 255,  0.4, 245,  0.3, 235,  0.3, 225,  0.2, 215,  0.2,
  205,  0.1
) |>
  arrange(score) |>
  mutate(quantile = pct / 100)

# CME FedWatch market-implied probabilities, retrieved 2026-07-09.
# Buckets are FOMC target ranges; midpoints used for numeric work.
cme_july <- tribble(
  ~bucket,       ~midpoint, ~prob,
  "3.50--3.75%", 3.625,     0.759,
  "3.75--4.00%", 3.875,     0.241
)

cme_sept <- tribble(
  ~bucket,       ~midpoint, ~prob,
  "3.50--3.75%", 3.625,     0.366,
  "3.75--4.00%", 3.875,     0.509,
  "4.00--4.25%", 4.125,     0.125
)

# CME FedWatch joint distribution for the July 29 / September 16, 2026
# meetings (retrieved 2026-07-09; matches the setup in prob_05). Midpoints
# stand in for ranges.
cme_joint <- tribble(
  ~july,          ~sept,          ~july_mid, ~sept_mid, ~prob,
  "3.50--3.75%",  "3.50--3.75%",  3.625,     3.625,     0.366,
  "3.50--3.75%",  "3.75--4.00%",  3.625,     3.875,     0.393,
  "3.75--4.00%",  "3.75--4.00%",  3.875,     3.875,     0.116,
  "3.75--4.00%",  "4.00--4.25%",  3.875,     4.125,     0.125
)
