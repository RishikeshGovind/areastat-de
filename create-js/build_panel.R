# ============================================================
# build_panel.R
#
# Builds a clean Gemeinde-level panel dataset for ML modelling.
#
# Output: data/panel_dataset.csv
#   One row per Gemeinde per year (2010-2019)
#   Columns: fiscal totals, spending shares by category,
#            YoY changes, fiscal health score,
#            joined AEST socioeconomic indicators.
# ============================================================

source("create-js/config.R")

BUDGET_DIR  <- "create-js/inputs/"
OUTPUT_PATH <- "data/panel_dataset.csv"

# ============================================================
# 1. Stack all 10 budget files
# ============================================================
message("Loading budget files...")

budget_files <- list.files(BUDGET_DIR, pattern = "^OGD_gem_unterabschn_GHD_UA_\\d+\\.csv$", full.names = TRUE)

budget_raw <- lapply(budget_files, function(f) {
  df <- read.csv(f, sep = ";", stringsAsFactors = FALSE, check.names = FALSE)
  names(df) <- c("year_code", "gcd", "section_code", "expenditure", "revenue")
  df
}) |> bind_rows()

message(sprintf("  Raw rows: %s", format(nrow(budget_raw), big.mark = ",")))

# Parse year integer from "A10-2019" → 2019
budget_raw <- budget_raw |>
  mutate(
    year        = as.integer(sub("A10-", "", year_code)),
    gcd         = sprintf("%05d", as.integer(gcd)),
    expenditure = as.numeric(expenditure),
    revenue     = as.numeric(revenue),
    # Major section = first digit of the 3-digit VAUAB number
    section_num  = as.integer(sub("VAUAB-", "", section_code)),
    major_section = case_when(
      section_num >= 0   & section_num < 100 ~ "admin",
      section_num >= 100 & section_num < 200 ~ "public_order",
      section_num >= 200 & section_num < 400 ~ "education_culture",
      section_num >= 400 & section_num < 500 ~ "social_welfare",
      section_num >= 500 & section_num < 600 ~ "health",
      section_num >= 600 & section_num < 700 ~ "infrastructure",
      section_num >= 700 & section_num < 800 ~ "economy",
      section_num >= 800 & section_num < 900 ~ "utilities",
      section_num >= 900                     ~ "finance_debt",
      TRUE ~ "other"
    )
  ) |>
  filter(!is.na(year), !is.na(gcd), gcd != "00000")

message(sprintf("  After cleaning: %s rows | years: %s",
  format(nrow(budget_raw), big.mark = ","),
  paste(sort(unique(budget_raw$year)), collapse = ", ")))


# ============================================================
# 2. Aggregate to Gemeinde × Year level
# ============================================================
message("Aggregating to Gemeinde × Year...")

# 2a. Totals
fiscal_totals <- budget_raw |>
  group_by(gcd, year) |>
  summarise(
    total_expenditure = sum(expenditure, na.rm = TRUE),
    total_revenue     = sum(revenue,     na.rm = TRUE),
    .groups = "drop"
  ) |>
  mutate(
    fiscal_balance = total_revenue - total_expenditure,
    deficit_ratio  = (total_expenditure - total_revenue) / (total_revenue + 1),
    in_deficit     = as.integer(fiscal_balance < 0)
  )

# 2b. Expenditure shares by major section
section_exp <- budget_raw |>
  group_by(gcd, year, major_section) |>
  summarise(exp = sum(expenditure, na.rm = TRUE), .groups = "drop") |>
  pivot_wider(names_from = major_section, values_from = exp,
              names_prefix = "exp_", values_fill = 0)

# 2c. Revenue shares by major section
section_rev <- budget_raw |>
  group_by(gcd, year, major_section) |>
  summarise(rev = sum(revenue, na.rm = TRUE), .groups = "drop") |>
  pivot_wider(names_from = major_section, values_from = rev,
              names_prefix = "rev_", values_fill = 0)

# Merge totals + sections
fiscal_panel <- fiscal_totals |>
  left_join(section_exp, by = c("gcd", "year")) |>
  left_join(section_rev, by = c("gcd", "year"))

# Convert section totals to shares of total expenditure/revenue
exp_cols <- grep("^exp_", names(fiscal_panel), value = TRUE)
rev_cols <- grep("^rev_", names(fiscal_panel), value = TRUE)

fiscal_panel <- fiscal_panel |>
  mutate(across(all_of(exp_cols),
    ~ if_else(total_expenditure > 0, .x / total_expenditure, NA_real_),
    .names = "share_{.col}")) |>
  mutate(across(all_of(rev_cols),
    ~ if_else(total_revenue > 0, .x / total_revenue, NA_real_),
    .names = "share_{.col}"))

message(sprintf("  Panel: %s rows | %d Gemeinden",
  format(nrow(fiscal_panel), big.mark = ","),
  n_distinct(fiscal_panel$gcd)))


# ============================================================
# 3. Year-on-year changes (fiscal dynamics)
# ============================================================
message("Computing year-on-year changes...")

fiscal_panel <- fiscal_panel |>
  arrange(gcd, year) |>
  group_by(gcd) |>
  mutate(
    exp_growth      = (total_expenditure - lag(total_expenditure)) / (lag(total_expenditure) + 1),
    rev_growth      = (total_revenue     - lag(total_revenue))     / (lag(total_revenue)     + 1),
    balance_change  = fiscal_balance - lag(fiscal_balance),
    # Consecutive deficit years (fiscal stress accumulation)
    deficit_streak  = cumsum(in_deficit) - cummax(cumsum(in_deficit) * (1 - in_deficit))
  ) |>
  ungroup()


# ============================================================
# 4. Join AEST socioeconomic data (all years)
# ============================================================
message("Loading AEST data (all years)...")

OGD_BASE_URL <- "https://data.statistik.gv.at/data"

aest_all <- tryCatch({
  raw <- read.csv(paste0(OGD_BASE_URL, "/OGDEXT_AEST_GEMTAB_1.csv"),
                  sep = ";", fileEncoding = "latin1",
                  stringsAsFactors = FALSE, check.names = TRUE)
  raw |>
    as_tibble() |>
    mutate(
      gcd  = sprintf("%05d", as.integer(GCD)),
      year = as.integer(JAHR)
    ) |>
    mutate(across(c(BEV_ABSOLUT, BEV_UNTER15, BEV_UEBER65, AUSL_STAATSB,
                    EWTQ_15BIS64, ALQ_15PLUS, EDU_15_SEK, EDU_15_TER,
                    AUSPENDLER, PHH, HH_SIZE, FAMILIEN, BESCH_AST, UNT, AST),
                  ~ as.numeric(gsub(",", ".", .x)))) |>
    select(gcd, year,
           population    = BEV_ABSOLUT,
           pct_under15   = BEV_UNTER15,
           pct_over65    = BEV_UEBER65,
           pct_foreign   = AUSL_STAATSB,
           emp_rate      = EWTQ_15BIS64,
           unemp_rate    = ALQ_15PLUS,
           pct_secondary = EDU_15_SEK,
           pct_tertiary  = EDU_15_TER,
           pct_commuters = AUSPENDLER,
           households    = PHH,
           avg_hh_size   = HH_SIZE,
           families      = FAMILIEN,
           employees     = BESCH_AST,
           enterprises   = UNT,
           local_units   = AST)
}, error = function(e) {
  message("  AEST fetch failed: ", conditionMessage(e))
  NULL
})

if (!is.null(aest_all)) {
  message(sprintf("  AEST years available: %s",
    paste(sort(unique(aest_all$year)), collapse = ", ")))
  fiscal_panel <- fiscal_panel |>
    left_join(aest_all, by = c("gcd", "year"))
  message("  AEST joined successfully")
} else {
  message("  Continuing without AEST data")
}


# ============================================================
# 5. Derive Bundesland + settlement type
# ============================================================
bundesland_names <- c("1"="Burgenland","2"="Kärnten","3"="Niederösterreich",
                      "4"="Oberösterreich","5"="Salzburg","6"="Steiermark",
                      "7"="Tirol","8"="Vorarlberg","9"="Wien")

fiscal_panel <- fiscal_panel |>
  mutate(
    bundesland       = bundesland_names[substr(gcd, 1, 1)],
    bezirk_code      = substr(gcd, 1, 3),
    settlement_class = case_when(
      population >= 50000 ~ "Großstadt",
      population >= 10000 ~ "Kleinstadt",
      population >=  2000 ~ "Marktgemeinde",
      !is.na(population)  ~ "Dorfgemeinde",
      TRUE                ~ NA_character_
    ),
    urban_rural = case_when(
      population >= 20000 ~ "Urban",
      population >=  5000 ~ "Intermediate",
      !is.na(population)  ~ "Rural",
      TRUE                ~ NA_character_
    ),
    # Per-capita fiscal indicators (€ per person)
    exp_per_capita = if_else(population > 0, total_expenditure / population, NA_real_),
    rev_per_capita = if_else(population > 0, total_revenue     / population, NA_real_),
    balance_per_capita = if_else(population > 0, fiscal_balance / population, NA_real_)
  )


# ============================================================
# 6. Save
# ============================================================
message("Saving panel dataset...")

dir.create("data", showWarnings = FALSE)
write.csv(fiscal_panel, OUTPUT_PATH, row.names = FALSE, fileEncoding = "UTF-8")

message(sprintf("Done. Panel saved to %s", OUTPUT_PATH))
message(sprintf("  Rows: %s | Columns: %d | Gemeinden: %d | Years: %s",
  format(nrow(fiscal_panel), big.mark = ","),
  ncol(fiscal_panel),
  n_distinct(fiscal_panel$gcd),
  paste(sort(unique(fiscal_panel$year)), collapse = ", ")))

# Quick summary
message("\nFiscal balance summary:")
fiscal_panel |>
  group_by(year) |>
  summarise(
    n_gemeinden   = n(),
    pct_deficit   = round(mean(in_deficit, na.rm = TRUE) * 100, 1),
    median_ratio  = round(median(deficit_ratio, na.rm = TRUE), 3),
    .groups = "drop"
  ) |>
  print()
