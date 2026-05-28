# ============================================================
# fetch_denmark_data.R
#
# Builds final_json for the Danish Area Profile Builder.
# No API key or registration required — all sources are public.
#
# Primary sources:
#   DAWA (Danmarks Adressers Web API)       — sogne/kommune/region hierarchy
#   DST (Danmarks Statistik) API            — socioeconomic indicators
#     https://api.statbank.dk/v1/
#
# Geographic hierarchy:
#   Region (5)  ←  Kommune (98)  ←  Sogn (~2,100)
#
# Data availability:
#   Sogne level: population, age structure, foreign background (FOLK1A)
#   Kommune level: labour market, education, economy, households
#     (inherited by sogne within each kommune)
# ============================================================

DST_BASE <- "https://api.statbank.dk/v1/"
DAWA_BASE <- "https://api.dataforsyningen.dk/"

# ---- Variable map ----
VARIABLE_MAP <- list(
  AgeStructure = list(
    `Under 15 years (%)` = "BEV_UNDER15",
    `Over 65 years (%)`  = "BEV_OVER65"
  ),
  LabourMarket = list(
    `Employment rate (%)`     = "EMP_RATE",
    `Unemployment rate (%)`   = "UNEMP_RATE",
    `Out-commuter share (%)` = "COMMUTER_PCT"
  ),
  Economy = list(
    `Employees`   = "EMPLOYEES",
    `Enterprises` = "ENTERPRISES"
  ),
  Education = list(
    `Secondary education (%)` = "EDU_SEC",
    `Tertiary education (%)`  = "EDU_TER"
  ),
  Migration = list(
    `Foreign background (%)` = "FOREIGN_PCT"
  ),
  Households = list(
    `Avg household size` = "HH_SIZE",
    `Private households` = "HOUSEHOLDS",
    `Families`           = "FAMILIES"
  )
)

AGGREGATION_TYPE <- list(
  POPULATION    = "sum",
  BEV_UNDER15   = "pct",
  BEV_OVER65    = "pct",
  FOREIGN_PCT   = "pct",
  EMP_RATE      = "pct",
  UNEMP_RATE    = "pct",
  COMMUTER_PCT  = "pct",
  EMPLOYEES     = "sum",
  ENTERPRISES   = "sum",
  EDU_SEC       = "pct",
  EDU_TER       = "pct",
  HH_SIZE       = "pct",
  HOUSEHOLDS    = "sum",
  FAMILIES      = "sum"
)

INDICATOR_COLS <- names(AGGREGATION_TYPE)

# ============================================================
# Helper: POST request to DST API, returns a data frame
# ============================================================
fetch_dst <- function(table, variables, lang = "en") {
  body <- list(
    table     = table,
    format    = "CSV",
    delimiter = ";",
    lang      = lang,
    variables = variables
  )
  resp <- tryCatch(
    httr::POST(
      paste0(DST_BASE, "data"),
      httr::content_type_json(),
      body    = jsonlite::toJSON(body, auto_unbox = TRUE),
      httr::timeout(120)
    ),
    error = function(e) stop(sprintf("DST POST failed for %s: %s", table, conditionMessage(e)))
  )
  if (httr::http_error(resp))
    stop(sprintf("DST API HTTP %s for table %s", httr::status_code(resp), table))

  txt <- httr::content(resp, "text", encoding = "UTF-8")
  readr::read_delim(txt, delim = ";", show_col_types = FALSE,
                    locale = readr::locale(encoding = "UTF-8"))
}

# ============================================================
# Helper: GET request to DAWA, returns parsed JSON
# ============================================================
fetch_dawa <- function(endpoint, params = list()) {
  url  <- paste0(DAWA_BASE, endpoint)
  resp <- tryCatch(
    httr::GET(url, query = c(params, list(format = "json")), httr::timeout(120)),
    error = function(e) stop(sprintf("DAWA GET failed (%s): %s", endpoint, conditionMessage(e)))
  )
  if (httr::http_error(resp))
    stop(sprintf("DAWA HTTP %s for %s", httr::status_code(resp), endpoint))
  jsonlite::fromJSON(httr::content(resp, "text", encoding = "UTF-8"), simplifyDataFrame = TRUE)
}

# ============================================================
# 1. Geography: Region → Kommune → Sogn hierarchy from DAWA
# ============================================================
message("Fetching geography from DAWA...")

kommuner_raw <- tryCatch(
  fetch_dawa("kommuner"),
  error = function(e) { message("  DAWA kommuner failed: ", conditionMessage(e)); NULL }
)

sogne_raw <- tryCatch(
  fetch_dawa("sogne"),
  error = function(e) { message("  DAWA sogne failed: ", conditionMessage(e)); NULL }
)

if (is.null(kommuner_raw) || is.null(sogne_raw))
  stop("Could not fetch DAWA geography — check network and https://api.dataforsyningen.dk")

# Build kommune table: kode (4-char), navn, region_kode, region_navn
if (is.data.frame(kommuner_raw)) {
  kommune_df <- kommuner_raw
} else {
  kommune_df <- as.data.frame(kommuner_raw)
}

# Normalise: DAWA returns 4-char zero-padded kommunekode
kommune_df <- as_tibble(kommune_df) |>
  mutate(
    kommune_kode   = sprintf("%04d", as.integer(kode)),
    kommune_navn   = navn
  )

# Extract region from nested structure
if ("region" %in% names(kommune_df) && is.data.frame(kommune_df$region)) {
  kommune_df <- kommune_df |>
    mutate(
      region_kode = kommune_df$region$kode,
      region_navn = kommune_df$region$navn
    )
} else if ("regionkode" %in% names(kommune_df)) {
  kommune_df <- kommune_df |>
    rename(region_kode = regionkode) |>
    mutate(region_navn = dplyr::recode(region_kode,
      "1084" = "Region Nordjylland",
      "1085" = "Region Midtjylland",
      "1083" = "Region Syddanmark",
      "1082" = "Region Sjælland",
      "1081" = "Region Hovedstaden",
      .default = NA_character_
    ))
}

kommune_lookup <- kommune_df |>
  select(kommune_kode, kommune_navn, region_kode, region_navn) |>
  distinct()

message(sprintf("  %d kommuner | %d regions",
  nrow(kommune_lookup), n_distinct(kommune_lookup$region_kode)))

# Build sogne table: kode (4-char), navn, kommune_kode
if (is.data.frame(sogne_raw)) {
  sogne_df <- as_tibble(sogne_raw)
} else {
  sogne_df <- as_tibble(as.data.frame(sogne_raw))
}

sogne_df <- sogne_df |>
  mutate(sognekode = sprintf("%04d", as.integer(kode)), sognavn = navn)

# Extract kommune_kode from nested structure
if ("kommune" %in% names(sogne_df) && is.data.frame(sogne_df$kommune)) {
  sogne_df <- sogne_df |>
    mutate(kommune_kode = sprintf("%04d", as.integer(sogne_df$kommune$kode)))
} else if ("kommunekode" %in% names(sogne_df)) {
  sogne_df <- sogne_df |>
    mutate(kommune_kode = sprintf("%04d", as.integer(kommunekode)))
}

sogne_df <- sogne_df |>
  select(sognekode, sognavn, kommune_kode) |>
  left_join(kommune_lookup, by = "kommune_kode") |>
  distinct()

message(sprintf("  %d sogne fetched", nrow(sogne_df)))


# ============================================================
# 2. FOLK1A — Population, age structure, foreign background
#    Available at sognekode level from DST
# ============================================================
message("Fetching FOLK1A from DST (all areas, total + ancestry)...")

folk1a_raw <- tryCatch(
  fetch_dst("FOLK1A", list(
    list(code = "OMRÅDE",  values = list("*")),
    list(code = "ALDER",   values = list("IALT")),
    list(code = "HERKOMST",values = list("TOT", "2", "3")),
    list(code = "KØN",     values = list("TOT")),
    list(code = "Tid",     values = list(""))
  )),
  error = function(e) { message("  FOLK1A failed: ", conditionMessage(e)); NULL }
)

# FOLK1A age groups — fetch once at kommunal level (smaller dataset)
message("Fetching FOLK1A age groups at kommunal level...")
folk1a_ages <- tryCatch(
  fetch_dst("FOLK1A", list(
    list(code = "OMRÅDE",  values = list("*")),
    list(code = "ALDER",   values = as.list(c("IALT",
      as.character(0:14),                   # under-15
      as.character(65:99), "100PLUS"        # over-65
    ))),
    list(code = "HERKOMST",values = list("TOT")),
    list(code = "KØN",     values = list("TOT")),
    list(code = "Tid",     values = list(""))
  )),
  error = function(e) { message("  FOLK1A ages failed: ", conditionMessage(e)); NULL }
)

# Process FOLK1A total + ancestry
pop_df <- NULL
if (!is.null(folk1a_raw)) {
  # Normalise column names (DST returns English labels when lang="en")
  names(folk1a_raw) <- janitor::make_clean_names(names(folk1a_raw))

  # Identify area and value columns (column names vary by DST version)
  area_col  <- grep("omr|area|region|municipality|parish", names(folk1a_raw), value=TRUE, ignore.case=TRUE)[1]
  val_col   <- grep("indhold|value|antal|count", names(folk1a_raw), value=TRUE, ignore.case=TRUE)[1]
  anc_col   <- grep("herkomst|ancestry|origin", names(folk1a_raw), value=TRUE, ignore.case=TRUE)[1]
  age_col   <- grep("alder|age", names(folk1a_raw), value=TRUE, ignore.case=TRUE)[1]

  if (!is.na(area_col) && !is.na(val_col)) {
    folk1a_clean <- folk1a_raw |>
      rename(area = !!area_col, value = !!val_col) |>
      mutate(
        area_code = sprintf("%04d", suppressWarnings(as.integer(area))),
        value     = suppressWarnings(as.numeric(gsub(",",".",value)))
      ) |>
      filter(!is.na(value))

    if (!is.na(anc_col)) folk1a_clean <- folk1a_clean |> rename(ancestry = !!anc_col)
    if (!is.na(age_col))  folk1a_clean <- folk1a_clean |> rename(age = !!age_col)

    # Filter to sognekode only (match against known sogne)
    sogne_codes <- sogne_df$sognekode

    folk1a_sogne <- folk1a_clean |>
      filter(area_code %in% sogne_codes)

    # Total population per sogne
    pop_total <- folk1a_sogne |>
      filter(if ("age" %in% names(folk1a_sogne)) age == "IALT" | grepl("ialt|total", age, ignore.case=TRUE) else TRUE,
             if ("ancestry" %in% names(folk1a_sogne)) grepl("TOT|total|alle", ancestry, ignore.case=TRUE) else TRUE) |>
      group_by(area_code) |>
      summarise(POPULATION = sum(value, na.rm=TRUE), .groups="drop")

    # Foreign background (immigrants + descendants) per sogne
    foreign_counts <- folk1a_sogne |>
      filter(if ("age" %in% names(folk1a_sogne)) age == "IALT" | grepl("ialt|total", age, ignore.case=TRUE) else TRUE,
             if ("ancestry" %in% names(folk1a_sogne)) grepl("^2$|^3$|immigrant|descendant", ancestry, ignore.case=TRUE) else FALSE) |>
      group_by(area_code) |>
      summarise(foreign_count = sum(value, na.rm=TRUE), .groups="drop")

    pop_df <- pop_total |>
      left_join(foreign_counts, by="area_code") |>
      mutate(
        FOREIGN_PCT = if_else(POPULATION > 0,
                              round((foreign_count / POPULATION) * 100, 1), NA_real_)
      ) |>
      select(sognekode = area_code, POPULATION, FOREIGN_PCT)

    message(sprintf("  FOLK1A: %d sogne with population data", nrow(pop_df)))
  }
}

# Age structure from kommunal level FOLK1A
age_df <- NULL
if (!is.null(folk1a_ages)) {
  names(folk1a_ages) <- janitor::make_clean_names(names(folk1a_ages))
  area_col2  <- grep("omr|area|region|municipality", names(folk1a_ages), value=TRUE, ignore.case=TRUE)[1]
  val_col2   <- grep("indhold|value|antal|count", names(folk1a_ages), value=TRUE, ignore.case=TRUE)[1]
  age_col2   <- grep("alder|age", names(folk1a_ages), value=TRUE, ignore.case=TRUE)[1]

  if (!is.na(area_col2) && !is.na(val_col2) && !is.na(age_col2)) {
    ages_clean <- folk1a_ages |>
      rename(area = !!area_col2, value = !!val_col2, age = !!age_col2) |>
      mutate(
        area_code = sprintf("%04d", suppressWarnings(as.integer(area))),
        value     = suppressWarnings(as.numeric(gsub(",",".",value))),
        age_num   = suppressWarnings(as.integer(age))
      ) |>
      filter(!is.na(value))

    # Kommunal level only (numeric area code 101-860, zero-padded = 0101-0860)
    komm_codes_int <- sprintf("%04d", as.integer(kommune_lookup$kommune_kode))
    ages_kommunal  <- ages_clean |>
      filter(area_code %in% komm_codes_int)

    total_per_komm <- ages_kommunal |>
      filter(grepl("ialt|total", age, ignore.case=TRUE)) |>
      group_by(area_code) |>
      summarise(total = sum(value, na.rm=TRUE), .groups="drop")

    under15_per_komm <- ages_kommunal |>
      filter(!is.na(age_num), age_num >= 0, age_num <= 14) |>
      group_by(area_code) |>
      summarise(under15 = sum(value, na.rm=TRUE), .groups="drop")

    over65_per_komm <- ages_kommunal |>
      filter(!is.na(age_num), age_num >= 65) |>
      group_by(area_code) |>
      summarise(over65 = sum(value, na.rm=TRUE), .groups="drop")

    age_df <- total_per_komm |>
      left_join(under15_per_komm, by="area_code") |>
      left_join(over65_per_komm,  by="area_code") |>
      mutate(
        BEV_UNDER15 = if_else(total > 0, round((under15 / total) * 100, 1), NA_real_),
        BEV_OVER65  = if_else(total > 0, round((over65  / total) * 100, 1), NA_real_)
      ) |>
      select(kommune_kode = area_code, BEV_UNDER15, BEV_OVER65)

    message(sprintf("  Age structure: %d kommuner", nrow(age_df)))
  }
}


# ============================================================
# 3. Unemployment — AUL01
# ============================================================
message("Fetching AUL01 (unemployment) from DST...")

unemp_df <- tryCatch({
  raw <- fetch_dst("AUL01", list(
    list(code = "OMRÅDE",  values = list("*")),
    list(code = "ALDER",   values = list("16-64")),
    list(code = "KØN",     values = list("TOT")),
    list(code = "Tid",     values = list(""))
  ))
  names(raw) <- janitor::make_clean_names(names(raw))
  area_c <- grep("omr|area|municipality", names(raw), value=TRUE, ignore.case=TRUE)[1]
  val_c  <- grep("indhold|value|antal|count|pct", names(raw), value=TRUE, ignore.case=TRUE)[1]

  if (!is.na(area_c) && !is.na(val_c)) {
    komm_int <- sprintf("%04d", as.integer(kommune_lookup$kommune_kode))
    raw |>
      rename(area = !!area_c, value = !!val_c) |>
      mutate(
        kommune_kode = sprintf("%04d", suppressWarnings(as.integer(area))),
        UNEMP_RATE   = suppressWarnings(as.numeric(gsub(",",".",value)))
      ) |>
      filter(kommune_kode %in% komm_int) |>
      select(kommune_kode, UNEMP_RATE)
  } else NULL
}, error = function(e) { message("  AUL01 failed: ", conditionMessage(e)); NULL })

if (!is.null(unemp_df)) message(sprintf("  Unemployment: %d kommuner", nrow(unemp_df)))


# ============================================================
# 4. Employment rate — RAS1
# ============================================================
message("Fetching RAS1 (employment status) from DST...")

emp_df <- tryCatch({
  raw <- fetch_dst("RAS1", list(
    list(code = "OMRÅDE",  values = list("*")),
    list(code = "SOCIO13", values = list("1110")),   # employed
    list(code = "KØN",     values = list("TOT")),
    list(code = "ALDER",   values = list("15-64")),
    list(code = "Tid",     values = list(""))
  ))
  names(raw) <- janitor::make_clean_names(names(raw))
  area_c  <- grep("omr|area|municipality", names(raw), value=TRUE, ignore.case=TRUE)[1]
  val_c   <- grep("indhold|value|antal|count", names(raw), value=TRUE, ignore.case=TRUE)[1]
  komm_int <- sprintf("%04d", as.integer(kommune_lookup$kommune_kode))

  if (!is.na(area_c) && !is.na(val_c)) {
    emp_counts <- raw |>
      rename(area = !!area_c, emp_count = !!val_c) |>
      mutate(
        kommune_kode = sprintf("%04d", suppressWarnings(as.integer(area))),
        emp_count    = suppressWarnings(as.numeric(gsub(",",".",emp_count)))
      ) |>
      filter(kommune_kode %in% komm_int) |>
      select(kommune_kode, emp_count)

    # Population 15-64 from FOLK1A ages (if available)
    if (!is.null(age_df)) {
      pop_1564 <- if (!is.null(folk1a_ages)) {
        names(folk1a_ages) <- janitor::make_clean_names(names(folk1a_ages))
        a2 <- grep("alder|age", names(folk1a_ages), value=TRUE, ignore.case=TRUE)[1]
        v2 <- grep("indhold|value|antal", names(folk1a_ages), value=TRUE, ignore.case=TRUE)[1]
        ar2 <- grep("omr|area", names(folk1a_ages), value=TRUE, ignore.case=TRUE)[1]
        if (!is.na(a2) && !is.na(v2) && !is.na(ar2)) {
          folk1a_ages |>
            rename(area=!!ar2, age=!!a2, value=!!v2) |>
            mutate(
              kommune_kode = sprintf("%04d", suppressWarnings(as.integer(area))),
              age_num = suppressWarnings(as.integer(age)),
              value   = suppressWarnings(as.numeric(gsub(",",".",value)))
            ) |>
            filter(kommune_kode %in% komm_int, !is.na(age_num), age_num >= 15, age_num <= 64) |>
            group_by(kommune_kode) |>
            summarise(pop_1564 = sum(value, na.rm=TRUE), .groups="drop")
        } else NULL
      } else NULL

      if (!is.null(pop_1564)) {
        emp_counts |>
          left_join(pop_1564, by="kommune_kode") |>
          mutate(EMP_RATE = if_else(pop_1564 > 0, round(emp_count/pop_1564*100, 1), NA_real_)) |>
          select(kommune_kode, EMP_RATE)
      } else emp_counts |> rename(EMP_RATE = emp_count) # fallback
    } else emp_counts |> rename(EMP_RATE = emp_count)
  } else NULL
}, error = function(e) { message("  RAS1 failed: ", conditionMessage(e)); NULL })

if (!is.null(emp_df)) message(sprintf("  Employment: %d kommuner", nrow(emp_df)))


# ============================================================
# 5. Education — HFUDD11
# ============================================================
message("Fetching HFUDD11 (education) from DST...")

edu_df <- tryCatch({
  raw <- fetch_dst("HFUDD11", list(
    list(code = "UDDNIV",  values = list("*")),
    list(code = "BOPKODE", values = list("*")),
    list(code = "KØN",     values = list("TOT")),
    list(code = "Tid",     values = list(""))
  ))
  names(raw) <- janitor::make_clean_names(names(raw))
  area_c  <- grep("bop|area|municipality|omr", names(raw), value=TRUE, ignore.case=TRUE)[1]
  val_c   <- grep("indhold|value|antal|count", names(raw), value=TRUE, ignore.case=TRUE)[1]
  edu_c   <- grep("uddniv|educ|niveau", names(raw), value=TRUE, ignore.case=TRUE)[1]
  komm_int <- sprintf("%04d", as.integer(kommune_lookup$kommune_kode))

  if (!is.na(area_c) && !is.na(val_c) && !is.na(edu_c)) {
    edu_clean <- raw |>
      rename(area=!!area_c, value=!!val_c, edu_level=!!edu_c) |>
      mutate(
        kommune_kode = sprintf("%04d", suppressWarnings(as.integer(area))),
        value        = suppressWarnings(as.numeric(gsub(",",".",value)))
      ) |>
      filter(kommune_kode %in% komm_int, !is.na(value))

    # DST education levels: H10=primary, H20=secondary/vocational, H30=short higher,
    # H35=medium higher, H40=long higher, H50=PhD, H90=unknown
    total_edu <- edu_clean |>
      group_by(kommune_kode) |>
      summarise(total = sum(value, na.rm=TRUE), .groups="drop")

    secondary <- edu_clean |>
      filter(grepl("H20|H30|sekund|erhvervs|almen", edu_level, ignore.case=TRUE)) |>
      group_by(kommune_kode) |>
      summarise(sec_count = sum(value, na.rm=TRUE), .groups="drop")

    tertiary <- edu_clean |>
      filter(grepl("H35|H40|H50|kortere|bachelor|lang|ph|universitets", edu_level, ignore.case=TRUE)) |>
      group_by(kommune_kode) |>
      summarise(ter_count = sum(value, na.rm=TRUE), .groups="drop")

    total_edu |>
      left_join(secondary, by="kommune_kode") |>
      left_join(tertiary,  by="kommune_kode") |>
      mutate(
        EDU_SEC = if_else(total>0, round((sec_count/total)*100, 1), NA_real_),
        EDU_TER = if_else(total>0, round((ter_count/total)*100, 1), NA_real_)
      ) |>
      select(kommune_kode, EDU_SEC, EDU_TER)
  } else NULL
}, error = function(e) { message("  HFUDD11 failed: ", conditionMessage(e)); NULL })

if (!is.null(edu_df)) message(sprintf("  Education: %d kommuner", nrow(edu_df)))


# ============================================================
# 6. Households — FAM44B
# ============================================================
message("Fetching FAM44B (households) from DST...")

hh_df <- tryCatch({
  raw <- fetch_dst("FAM44B", list(
    list(code = "STRKODE", values = list("*")),
    list(code = "KOMKODE", values = list("*")),
    list(code = "Tid",     values = list(""))
  ))
  names(raw) <- janitor::make_clean_names(names(raw))
  area_c <- grep("komkode|area|municipality|omr|kom", names(raw), value=TRUE, ignore.case=TRUE)[1]
  val_c  <- grep("indhold|value|antal|count", names(raw), value=TRUE, ignore.case=TRUE)[1]
  str_c  <- grep("strkode|size|str", names(raw), value=TRUE, ignore.case=TRUE)[1]
  komm_int <- sprintf("%04d", as.integer(kommune_lookup$kommune_kode))

  if (!is.na(area_c) && !is.na(val_c)) {
    hh_clean <- raw |>
      rename(area=!!area_c, value=!!val_c) |>
      mutate(
        kommune_kode = sprintf("%04d", suppressWarnings(as.integer(area))),
        value        = suppressWarnings(as.numeric(gsub(",",".",value)))
      ) |>
      filter(kommune_kode %in% komm_int, !is.na(value))

    hh_total <- hh_clean |>
      filter(if (!is.na(str_c)) grepl("ialt|total|alle", .data[[str_c]], ignore.case=TRUE) else TRUE) |>
      group_by(kommune_kode) |>
      summarise(HOUSEHOLDS = sum(value, na.rm=TRUE), .groups="drop")

    # Avg household size: total persons / total households
    # Use FAMILIES as proxy for family count
    hh_total |>
      mutate(
        FAMILIES = HOUSEHOLDS,    # approximate; replace if FAM55 available
        HH_SIZE  = NA_real_       # computed in a later join if population known
      )
  } else NULL
}, error = function(e) { message("  FAM44B failed: ", conditionMessage(e)); NULL })

if (!is.null(hh_df)) message(sprintf("  Households: %d kommuner", nrow(hh_df)))


# ============================================================
# 7. Enterprises — FIRM1
# ============================================================
message("Fetching FIRM1 (enterprises) from DST...")

firm_df <- tryCatch({
  raw <- fetch_dst("FIRM1", list(
    list(code = "BRANCHE07", values = list("TOT")),
    list(code = "KOMKODE",   values = list("*")),
    list(code = "Tid",       values = list(""))
  ))
  names(raw) <- janitor::make_clean_names(names(raw))
  area_c <- grep("komkode|area|municipality|omr|kom", names(raw), value=TRUE, ignore.case=TRUE)[1]
  val_c  <- grep("indhold|value|antal|count", names(raw), value=TRUE, ignore.case=TRUE)[1]
  komm_int <- sprintf("%04d", as.integer(kommune_lookup$kommune_kode))

  if (!is.na(area_c) && !is.na(val_c)) {
    raw |>
      rename(area=!!area_c, value=!!val_c) |>
      mutate(
        kommune_kode = sprintf("%04d", suppressWarnings(as.integer(area))),
        ENTERPRISES  = suppressWarnings(as.numeric(gsub(",",".",value)))
      ) |>
      filter(kommune_kode %in% komm_int, !is.na(ENTERPRISES)) |>
      select(kommune_kode, ENTERPRISES)
  } else NULL
}, error = function(e) { message("  FIRM1 failed: ", conditionMessage(e)); NULL })

if (!is.null(firm_df)) message(sprintf("  Enterprises: %d kommuner", nrow(firm_df)))


# ============================================================
# 8. Employees — LBESK10
# ============================================================
message("Fetching LBESK10 (employees at local units) from DST...")

emp_local_df <- tryCatch({
  raw <- fetch_dst("LBESK10", list(
    list(code = "BRANCHE07", values = list("TOT")),
    list(code = "KOMKODE",   values = list("*")),
    list(code = "Tid",       values = list(""))
  ))
  names(raw) <- janitor::make_clean_names(names(raw))
  area_c <- grep("komkode|area|municipality|omr|kom", names(raw), value=TRUE, ignore.case=TRUE)[1]
  val_c  <- grep("indhold|value|antal|count", names(raw), value=TRUE, ignore.case=TRUE)[1]
  komm_int <- sprintf("%04d", as.integer(kommune_lookup$kommune_kode))

  if (!is.na(area_c) && !is.na(val_c)) {
    raw |>
      rename(area=!!area_c, value=!!val_c) |>
      mutate(
        kommune_kode = sprintf("%04d", suppressWarnings(as.integer(area))),
        EMPLOYEES    = suppressWarnings(as.numeric(gsub(",",".",value)))
      ) |>
      filter(kommune_kode %in% komm_int, !is.na(EMPLOYEES)) |>
      select(kommune_kode, EMPLOYEES)
  } else NULL
}, error = function(e) { message("  LBESK10 failed: ", conditionMessage(e)); NULL })

if (!is.null(emp_local_df)) message(sprintf("  Employees: %d kommuner", nrow(emp_local_df)))


# ============================================================
# 9. Commuting — PENDLING01
# ============================================================
message("Fetching PENDLING01 (out-commuters) from DST...")

commute_df <- tryCatch({
  raw <- fetch_dst("PENDLING01", list(
    list(code = "BOPKOM",  values = list("*")),
    list(code = "KØN",     values = list("TOT")),
    list(code = "Tid",     values = list(""))
  ))
  names(raw) <- janitor::make_clean_names(names(raw))
  area_c <- grep("bopkom|area|municipality|omr", names(raw), value=TRUE, ignore.case=TRUE)[1]
  val_c  <- grep("indhold|value|antal|count|pct", names(raw), value=TRUE, ignore.case=TRUE)[1]
  komm_int <- sprintf("%04d", as.integer(kommune_lookup$kommune_kode))

  if (!is.na(area_c) && !is.na(val_c)) {
    raw |>
      rename(area=!!area_c, value=!!val_c) |>
      mutate(
        kommune_kode  = sprintf("%04d", suppressWarnings(as.integer(area))),
        COMMUTER_PCT = suppressWarnings(as.numeric(gsub(",",".",value)))
      ) |>
      filter(kommune_kode %in% komm_int, !is.na(COMMUTER_PCT)) |>
      select(kommune_kode, COMMUTER_PCT)
  } else NULL
}, error = function(e) { message("  PENDLING01 failed: ", conditionMessage(e)); NULL })

if (!is.null(commute_df)) message(sprintf("  Commuting: %d kommuner", nrow(commute_df)))


# ============================================================
# 10. Assemble kommunal indicator table
# ============================================================
message("Assembling kommunal indicator table...")

komm_data <- kommune_lookup |>
  select(kommune_kode)

for (df_obj in list(age_df, unemp_df, emp_df, edu_df, hh_df, firm_df, emp_local_df, commute_df)) {
  if (!is.null(df_obj) && nrow(df_obj) > 0) {
    key <- intersect(names(df_obj), "kommune_kode")
    if (length(key) == 1) {
      komm_data <- left_join(komm_data, df_obj, by = "kommune_kode")
    }
  }
}

# Compute avg household size = population / households (if both available)
if ("HOUSEHOLDS" %in% names(komm_data)) {
  # Get kommunal population from age totals
  if (!is.null(age_df)) {
    komm_pop <- age_df |>
      left_join(
        if (!is.null(folk1a_ages)) {
          folk1a_ages |>
            { n <- janitor::make_clean_names(names(.)); `names<-`(., n) }() |>
            { ar <- grep("omr|area",names(.), value=TRUE, ignore.case=TRUE)[1];
              vl <- grep("indhold|value|antal",names(.), value=TRUE, ignore.case=TRUE)[1];
              ag <- grep("alder|age",names(.), value=TRUE, ignore.case=TRUE)[1];
              if (!is.na(ar)&&!is.na(vl)&&!is.na(ag))
                rename(., area=!!ar, value=!!vl, age=!!ag) |>
                filter(grepl("ialt|total",age,ignore.case=TRUE)) |>
                mutate(kommune_kode=sprintf("%04d",suppressWarnings(as.integer(area))),
                       value=suppressWarnings(as.numeric(gsub(",",".",value)))) |>
                group_by(kommune_kode) |> summarise(komm_pop=sum(value,na.rm=TRUE),.groups="drop")
              else tibble(kommune_kode=character(),komm_pop=numeric()) }()
        } else tibble(kommune_kode=character(),komm_pop=numeric()),
        by = "kommune_kode"
      )
    if ("komm_pop" %in% names(komm_pop)) {
      hh_size_df <- komm_pop |>
        inner_join(komm_data |> select(kommune_kode, HOUSEHOLDS), by = "kommune_kode") |>
        mutate(HH_SIZE = if_else(HOUSEHOLDS > 0, round(komm_pop / HOUSEHOLDS, 2), NA_real_)) |>
        select(kommune_kode, HH_SIZE)
      komm_data <- left_join(komm_data, hh_size_df, by = "kommune_kode", suffix = c("", ".new")) |>
        mutate(HH_SIZE = coalesce(HH_SIZE.new, if ("HH_SIZE" %in% names(.)) HH_SIZE else NA_real_)) |>
        select(-any_of("HH_SIZE.new"))
    }
  }
}

message(sprintf("  Kommunal table: %d rows × %d columns", nrow(komm_data), ncol(komm_data)))


# ============================================================
# 11. Urban-rural classification (Eurostat DEGURBA thresholds)
# ============================================================
classify_urban_rural <- function(pop) {
  dplyr::case_when(
    pop >= 20000 ~ "Urban",
    pop >=  5000 ~ "Intermediate",
    TRUE         ~ "Rural"
  )
}

classify_settlement <- function(pop) {
  dplyr::case_when(
    pop >= 50000 ~ "Large City",
    pop >= 10000 ~ "Small City",
    pop >=  2000 ~ "Town",
    TRUE         ~ "Village"
  )
}

classify_density <- function(dens) {
  dplyr::case_when(
    is.na(dens)  ~ "Unknown",
    dens >= 1000 ~ "Very Dense",
    dens >= 300  ~ "Dense",
    dens >= 100  ~ "Medium",
    TRUE         ~ "Sparse"
  )
}


# ============================================================
# 12. Build Sogn-level dataset
#     Demographics from FOLK1A; other indicators from parent kommune
# ============================================================
message("Building Sogn-level dataset...")

sogne_full <- sogne_df |>
  left_join(
    if (!is.null(pop_df)) pop_df else tibble(sognekode=character(), POPULATION=numeric(), FOREIGN_PCT=numeric()),
    by = "sognekode"
  ) |>
  left_join(kommune_lookup, by = "kommune_kode", suffix = c("", ".k")) |>
  left_join(komm_data |> select(-any_of(c("kommune_navn","region_kode","region_navn"))),
            by = "kommune_kode") |>
  mutate(
    POPULATION = as.integer(coalesce(POPULATION, 0L)),
    urban_rural_status = classify_urban_rural(POPULATION),
    settlement_class   = classify_settlement(POPULATION),
    density_class      = "Unknown"    # area data not available at sogne level
  )

message(sprintf("  %d sogne assembled", nrow(sogne_full)))


# ============================================================
# Helper: build domain-grouped indicator list for one row
# ============================================================
build_indicator_list <- function(row_data) {
  lapply(VARIABLE_MAP, function(domain) {
    lapply(names(domain), function(label) {
      col <- domain[[label]]
      val <- row_data[[col]]
      if (is.null(val) || length(val) == 0 || is.na(val)) return(NULL)
      as.numeric(val)
    }) |> setNames(names(domain))
  })
}


# ============================================================
# 13. Build Sogn entries
# ============================================================
message("Building Sogn entries...")

sogne_entries <- lapply(seq_len(nrow(sogne_full)), function(i) {
  row <- sogne_full[i, ]
  indicators <- build_indicator_list(row)
  c(
    list(
      Urban_rural_status = row$urban_rural_status,
      Settlement_class   = row$settlement_class,
      Density_class      = row$density_class,
      Kommune            = row$kommune_kode,
      Sognavn            = row$sognavn,
      Region             = row$region_navn,
      Population         = as.integer(row$POPULATION)
    ),
    indicators
  )
}) |> setNames(sogne_full$sognekode)


# ============================================================
# 14. Build Kommune entries (aggregate from sogne)
# ============================================================
message("Building Kommune entries...")

build_kommune_entry <- function(kom_code, sogne_rows, kom_meta) {
  total_pop <- sum(sogne_rows$POPULATION, na.rm = TRUE)

  agg_row <- list(kommune_kode = kom_code)
  for (col in INDICATOR_COLS) {
    if (!col %in% names(sogne_rows)) { agg_row[[col]] <- NA_real_; next }
    vals <- sogne_rows[[col]]
    pops <- sogne_rows$POPULATION
    ok   <- !is.na(vals) & !is.na(pops) & pops > 0

    if (!any(ok)) {
      # Fall back to kommunal table if available
      agg_row[[col]] <- if (col %in% names(komm_data)) {
        km <- komm_data |> filter(kommune_kode == kom_code)
        if (nrow(km) > 0 && !is.na(km[[col]][1])) km[[col]][1] else NA_real_
      } else NA_real_
    } else if (AGGREGATION_TYPE[[col]] == "sum") {
      agg_row[[col]] <- sum(vals[ok], na.rm = TRUE)
    } else {
      agg_row[[col]] <- sum(vals[ok] * pops[ok]) / sum(pops[ok])
    }
  }
  agg_row <- as_tibble(agg_row)

  majority_class <- function(x) {
    t <- table(x[!is.na(x)])
    if (length(t) == 0) return(NA_character_)
    names(sort(t, decreasing=TRUE))[1]
  }

  indicators <- build_indicator_list(agg_row)
  c(
    list(
      Urban_rural_status = majority_class(sogne_rows$urban_rural_status),
      Settlement_class   = majority_class(sogne_rows$settlement_class),
      Density_class      = majority_class(sogne_rows$density_class),
      Region             = kom_meta$region_navn,
      Population         = as.integer(total_pop)
    ),
    indicators
  )
}

kommune_codes <- unique(sogne_full$kommune_kode)
kommune_entries <- lapply(kommune_codes, function(kc) {
  rows <- filter(sogne_full, kommune_kode == kc)
  meta <- filter(kommune_lookup, kommune_kode == kc)
  if (nrow(meta) == 0) meta <- tibble(region_navn = NA_character_)
  build_kommune_entry(kc, rows, meta[1, ])
}) |> setNames(kommune_codes)


# ============================================================
# 15. Build Denmark Total
# ============================================================
message("Building Denmark Total...")

total_pop <- sum(sogne_full$POPULATION, na.rm = TRUE)

denmark_total_row <- list()
for (col in INDICATOR_COLS) {
  if (!col %in% names(sogne_full)) { denmark_total_row[[col]] <- NA_real_; next }
  vals <- sogne_full[[col]]
  pops <- sogne_full$POPULATION
  ok   <- !is.na(vals) & !is.na(pops) & pops > 0

  if (!any(ok)) {
    denmark_total_row[[col]] <- NA_real_
  } else if (AGGREGATION_TYPE[[col]] == "sum") {
    denmark_total_row[[col]] <- sum(vals[ok])
  } else {
    denmark_total_row[[col]] <- round(sum(vals[ok] * pops[ok]) / sum(pops[ok]), 1)
  }
}
denmark_total_row <- as_tibble(denmark_total_row)
denmark_total     <- build_indicator_list(denmark_total_row)


# ============================================================
# 16. Assemble final_json
# ============================================================
final_json <- list(
  "Denmark Total" = denmark_total,
  "Kommune"       = lapply(kommune_entries, convert_to_named_list),
  "Sogn"          = lapply(sogne_entries,   convert_to_named_list)
)

message(sprintf(
  "Done. Denmark Total + %d Kommuner + %d Sogne ready.",
  length(kommune_entries), length(sogne_entries)
))
