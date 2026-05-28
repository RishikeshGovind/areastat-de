# ============================================================
# fetch_denmark_data.R
#
# Builds final_json for the Danish Area Profile Builder.
# No API key required — all sources are public.
#
# Sources:
#   DAWA (api.dataforsyningen.dk) — kommuner/regioner geography
#   DST  (api.statbank.dk)        — statistics
#
# Geographic hierarchy:
#   Region (5)  ←  Kommune (98)
#
# DST notes:
#   - kommunekode in DST = 3-digit string, e.g. "101" for Copenhagen
#   - kommunekode in DAWA = 4-digit zero-padded, e.g. "0101"
#   - We normalise everything to 4-digit in data.json
# ============================================================

DST_BASE  <- "https://api.statbank.dk/v1/"
DAWA_BASE <- "https://api.dataforsyningen.dk/"

# ---- Domain → indicator → internal column mapping ----
VARIABLE_MAP <- list(
  AgeStructure = list(
    `Under 15 years (%)` = "BEV_UNDER15",
    `Over 65 years (%)`  = "BEV_OVER65"
  ),
  LabourMarket = list(
    `Employment rate (%)`    = "EMP_RATE",
    `Unemployment rate (%)`  = "UNEMP_RATE"
  ),
  Economy = list(
    `Employees`   = "EMPLOYEES"
  ),
  Education = list(
    `Secondary education (%)` = "EDU_SEC",
    `Tertiary education (%)`  = "EDU_TER"
  ),
  Migration = list(
    `Foreign citizens (%)` = "FOREIGN_PCT"
  )
)

AGGREGATION_TYPE <- list(
  POPULATION  = "sum",
  BEV_UNDER15 = "pct",
  BEV_OVER65  = "pct",
  FOREIGN_PCT = "pct",
  EMP_RATE    = "pct",
  UNEMP_RATE  = "pct",
  EMPLOYEES   = "sum",
  EDU_SEC     = "pct",
  EDU_TER     = "pct"
)
INDICATOR_COLS <- names(AGGREGATION_TYPE)

# ============================================================
# Helpers
# ============================================================
# Caches — populated on first use per table
.tid_cache   <- list()
.label_cache <- list()  # table -> list of variable id -> data.frame(id, text)

get_table_meta <- function(table) {
  if (!is.null(.label_cache[[table]])) return(.label_cache[[table]])
  r <- tryCatch(
    httr::GET(paste0(DST_BASE, "tableinfo/", table), httr::accept_json(), httr::timeout(30)),
    error = function(e) NULL
  )
  if (is.null(r) || httr::http_error(r)) return(NULL)
  info <- jsonlite::fromJSON(httr::content(r, "text", encoding="UTF-8"))
  meta <- list()
  for (i in seq_len(nrow(info$variables))) {
    var_id <- info$variables$id[i]
    vals   <- info$variables$values[[i]]
    if (is.data.frame(vals) && "id" %in% names(vals) && "text" %in% names(vals))
      meta[[var_id]] <- vals[, c("id","text")]
  }
  .label_cache[[table]] <<- meta
  meta
}

latest_tid <- function(table) {
  if (!is.null(.tid_cache[[table]])) return(.tid_cache[[table]])
  meta <- get_table_meta(table)
  if (is.null(meta) || !"Tid" %in% names(meta)) return(NULL)
  val <- tail(meta$Tid$id, 1)
  .tid_cache[[table]] <<- val
  val
}

dst_post <- function(table, variables) {
  # Replace any empty Tid value with the actual latest period for this table
  variables <- lapply(variables, function(v) {
    if (identical(v$code, "Tid") && identical(v$values, list(""))) {
      latest <- latest_tid(table)
      if (!is.null(latest)) v$values <- list(latest)
    }
    v
  })

  body <- list(table=table, format="CSV", delimiter=";", lang="da",
               variables=variables)
  resp <- tryCatch(
    httr::POST(paste0(DST_BASE,"data"),
               httr::content_type_json(),
               body=jsonlite::toJSON(body, auto_unbox=TRUE),
               httr::timeout(120)),
    error = function(e) { message("  POST failed: ", conditionMessage(e)); NULL }
  )
  if (is.null(resp) || httr::http_error(resp)) {
    errtxt <- if (!is.null(resp))
      httr::content(resp, "text", encoding="UTF-8") else "no response"
    message(sprintf("  %s HTTP %s: %s", table,
      if(is.null(resp)) "?" else httr::status_code(resp),
      substr(errtxt, 1, 120)))
    return(NULL)
  }
  txt <- httr::content(resp, "text", encoding="UTF-8")
  df  <- tryCatch(
    readr::read_delim(txt, delim=";", show_col_types=FALSE,
                      locale=readr::locale(encoding="UTF-8")),
    error = function(e) { message("  Parse failed: ", conditionMessage(e)); NULL }
  )
  if (is.null(df)) return(NULL)
  names(df) <- janitor::make_clean_names(names(df))

  # DST returns English labels in the area column; join back to numeric codes.
  # We attach a column `area_code` containing the padded-4-digit kommunekode.
  meta <- get_table_meta(table)
  area_var <- Filter(function(v) grepl("omr|area|bop|arbejdssted", v$code, ignore.case=TRUE),
                     variables)
  if (length(area_var) > 0 && !is.null(meta)) {
    var_id   <- area_var[[1]]$code
    lkp_key  <- tolower(janitor::make_clean_names(var_id))
    area_col <- grep(lkp_key, names(df), value=TRUE, ignore.case=TRUE)[1]
    df$area_code <- NA_character_  # always add column; fill if matching succeeds
    if (!is.na(area_col) && var_id %in% names(meta)) {
      lkp <- meta[[var_id]] |>
        dplyr::mutate(label_clean = tolower(trimws(text)),
                      area_code  = pad4(id)) |>
        dplyr::select(label_clean, area_code)
      df_label <- df[[area_col]] |> tolower() |> trimws()
      df$area_code <- lkp$area_code[match(df_label, lkp$label_clean)]
    }
  } else {
    df$area_code <- NA_character_
  }
  df
}

# 3-digit DST code → 4-digit DAWA-style code
pad4 <- function(x) sprintf("%04d", suppressWarnings(as.integer(x)))

# Extract kommune_kode from a DST data frame.
# Prefers the area_code column injected by dst_post (via label→code join);
# falls back to pad4() of the raw area label if needed.
extract_kommune_kode <- function(df, area_col) {
  if ("area_code" %in% names(df)) return(df$area_code)
  pad4(df[[area_col]])
}

# Identify kommunal-level codes: 3-digit numeric in range 100-860
is_kommunal <- function(x) {
  n <- suppressWarnings(as.integer(x))
  !is.na(n) & nchar(trimws(x)) == 3 & n >= 100 & n <= 860
}

build_indicator_list <- function(row_data) {
  lapply(VARIABLE_MAP, function(domain) {
    lapply(names(domain), function(label) {
      col <- domain[[label]]
      val <- row_data[[col]]
      if (is.null(val) || length(val)==0 || is.na(val)) return(NULL)
      round(as.numeric(val), 2)
    }) |> setNames(names(domain))
  })
}


# ============================================================
# 1. Geography from DAWA
# ============================================================
message("Fetching geography from DAWA...")

# Kommuner (98)
komm_raw <- jsonlite::fromJSON(
  httr::content(httr::GET(paste0(DAWA_BASE,"kommuner?format=json"), httr::timeout(60)),
                "text", encoding="UTF-8"),
  simplifyDataFrame=TRUE
)
kommune_df <- as_tibble(as.data.frame(komm_raw)) |>
  mutate(kommune_kode = pad4(kode), kommune_navn = as.character(navn))

if ("region" %in% names(kommune_df) && is.data.frame(kommune_df$region)) {
  kommune_df$region_kode <- as.character(kommune_df$region$kode)
  kommune_df$region_navn <- as.character(kommune_df$region$navn)
} else {
  reg_map <- c("1081"="Region Hovedstaden","1082"="Region Sjælland",
               "1083"="Region Syddanmark", "1084"="Region Midtjylland",
               "1085"="Region Nordjylland")
  kommune_df$region_kode <- as.character(kommune_df[["regionskode"]])
  kommune_df$region_navn <- reg_map[kommune_df$region_kode]
}

kommune_lookup <- kommune_df |>
  select(kommune_kode, kommune_navn, region_kode, region_navn) |>
  distinct()

message(sprintf("  %d kommuner across %d regions", nrow(kommune_lookup),
                n_distinct(kommune_lookup$region_kode)))

# Regioner (5) — for the Region level data
region_lookup <- kommune_lookup |>
  select(region_kode, region_navn) |>
  distinct()

# DST uses 3-digit codes (e.g. "101") — map to our 4-digit DAWA codes
dst_to_kode <- setNames(kommune_lookup$kommune_kode,
                        as.character(suppressWarnings(as.integer(kommune_lookup$kommune_kode))))


# ============================================================
# 2. FOLK1A — Population + age structure
# ============================================================
message("Fetching FOLK1A (population + age) from DST...")

# Request total + ages 0-14 + ages 65-99 in one call
age_codes <- c("IALT", as.character(0:14), as.character(65:99))

folk1a <- dst_post("FOLK1A", list(
  list(code="OMRÅDE", values=list("*")),
  list(code="ALDER",  values=as.list(age_codes)),
  list(code="KØN",    values=list("TOT")),
  list(code="Tid",    values=list(""))
))

pop_age_df <- NULL
if (!is.null(folk1a)) {
  names(folk1a) <- janitor::make_clean_names(names(folk1a))
  area_c <- grep("omr|area", names(folk1a), value=TRUE, ignore.case=TRUE)[1]
  age_c  <- grep("alder|age", names(folk1a), value=TRUE, ignore.case=TRUE)[1]
  val_c  <- grep("indhold|value|antal|count", names(folk1a), value=TRUE, ignore.case=TRUE)[1]

  if (!is.na(area_c) && !is.na(age_c) && !is.na(val_c)) {
    f <- folk1a |>
      rename(area=!!area_c, age=!!age_c, value=!!val_c) |>
      mutate(value = suppressWarnings(as.numeric(gsub(",",".",value))),
             kommune_kode = coalesce(area_code, pad4(area))) |>
      filter(kommune_kode %in% kommune_lookup$kommune_kode, !is.na(value))

    # Danish labels: "Alder i alt" for total, "X år" for individual years
    totals <- f |>
      filter(grepl("i alt", age, ignore.case=TRUE)) |>
      group_by(kommune_kode) |> summarise(POPULATION = sum(value,na.rm=TRUE),.groups="drop")

    # Extract year number from "X år" pattern
    u15 <- f |>
      filter(!grepl("i alt", age, ignore.case=TRUE)) |>
      mutate(age_n = suppressWarnings(as.integer(gsub("[^0-9]", "", age)))) |>
      filter(!is.na(age_n), age_n <= 14) |>
      group_by(kommune_kode) |> summarise(n_under15=sum(value,na.rm=TRUE),.groups="drop")

    o65 <- f |>
      filter(!grepl("i alt", age, ignore.case=TRUE)) |>
      mutate(age_n = suppressWarnings(as.integer(gsub("[^0-9]", "", age)))) |>
      filter(!is.na(age_n), age_n >= 65) |>
      group_by(kommune_kode) |> summarise(n_over65=sum(value,na.rm=TRUE),.groups="drop")

    pop_age_df <- totals |>
      left_join(u15, by="kommune_kode") |>
      left_join(o65, by="kommune_kode") |>
      mutate(
        BEV_UNDER15 = if_else(POPULATION>0, round(n_under15/POPULATION*100,1), NA_real_),
        BEV_OVER65  = if_else(POPULATION>0, round(n_over65/POPULATION*100,1),  NA_real_)
      ) |>
      select(kommune_kode, POPULATION, BEV_UNDER15, BEV_OVER65)
    message(sprintf("  Population data: %d kommuner", nrow(pop_age_df)))
  }
}


# ============================================================
# 3. FOLK1B — Foreign citizens (STATSB = citizenship)
# ============================================================
message("Fetching FOLK1B (citizenship) from DST...")

folk1b <- dst_post("FOLK1B", list(
  list(code="OMRÅDE", values=list("*")),
  list(code="ALDER",  values=list("IALT")),
  list(code="KØN",    values=list("TOT")),
  list(code="STATSB", values=list("*")),
  list(code="Tid",    values=list(""))
))

foreign_df <- NULL
if (!is.null(folk1b)) {
  names(folk1b) <- janitor::make_clean_names(names(folk1b))
  area_c  <- grep("omr|area", names(folk1b), value=TRUE, ignore.case=TRUE)[1]
  val_c   <- grep("indhold|value|antal|count", names(folk1b), value=TRUE, ignore.case=TRUE)[1]
  stat_c  <- grep("statsb|citizenship|state", names(folk1b), value=TRUE, ignore.case=TRUE)[1]

  if (!is.na(area_c) && !is.na(val_c) && !is.na(stat_c)) {
    fb <- folk1b |>
      rename(area=!!area_c, value=!!val_c, citizenship=!!stat_c) |>
      mutate(value = suppressWarnings(as.numeric(gsub(",",".",value))),
             kommune_kode = coalesce(area_code, pad4(area))) |>
      filter(kommune_kode %in% kommune_lookup$kommune_kode, !is.na(value))

    # Danish labels: "I alt" = total, "Danmark" = Danish citizens
    total_cit <- fb |>
      filter(grepl("^i alt$|^in all$", citizenship, ignore.case=TRUE)) |>
      group_by(kommune_kode) |> summarise(cit_total=sum(value,na.rm=TRUE),.groups="drop")

    danish_cit <- fb |>
      filter(grepl("^Danmark$|^Denmark$", citizenship, ignore.case=TRUE)) |>
      group_by(kommune_kode) |> summarise(cit_danish=sum(value,na.rm=TRUE),.groups="drop")

    foreign_df <- total_cit |>
      left_join(danish_cit, by="kommune_kode") |>
      mutate(FOREIGN_PCT = if_else(cit_total>0,
               round((cit_total-coalesce(cit_danish,0))/cit_total*100, 1), NA_real_)) |>
      select(kommune_kode, FOREIGN_PCT)
    message(sprintf("  Foreign citizens: %d kommuner", nrow(foreign_df)))
  }
}


# ============================================================
# 4. AUL01 — Unemployment
# ============================================================
message("Fetching AUL01 (unemployment) from DST...")

aul01 <- dst_post("AUL01", list(
  list(code="OMRÅDE",      values=list("*")),
  list(code="YDELSESTYPE", values=list("TOT")),
  list(code="ALDER",       values=list("TOT")),
  list(code="KØN",         values=list("TOT")),
  list(code="AKASSE",      values=list("TOT")),
  list(code="Tid",         values=list(""))
))

unemp_df <- NULL
if (!is.null(aul01)) {
  names(aul01) <- janitor::make_clean_names(names(aul01))
  area_c <- grep("omr|area", names(aul01), value=TRUE, ignore.case=TRUE)[1]
  val_c  <- grep("indhold|value|antal|count", names(aul01), value=TRUE, ignore.case=TRUE)[1]

  if (!is.na(area_c) && !is.na(val_c)) {
    unemp_raw <- aul01 |>
      rename(area=!!area_c, value=!!val_c) |>
      mutate(value = suppressWarnings(as.numeric(gsub(",",".",value))),
             kommune_kode = coalesce(area_code, pad4(area))) |>
      filter(kommune_kode %in% kommune_lookup$kommune_kode, !is.na(value))

    # AUL01 gives count of unemployed — compute rate against population
    if (!is.null(pop_age_df)) {
      unemp_df <- unemp_raw |>
        group_by(kommune_kode) |> summarise(unemp_count=sum(value,na.rm=TRUE),.groups="drop") |>
        left_join(pop_age_df |> select(kommune_kode, POPULATION), by="kommune_kode") |>
        mutate(UNEMP_RATE = if_else(POPULATION>0,
                             round(unemp_count/POPULATION*100, 1), NA_real_)) |>
        select(kommune_kode, UNEMP_RATE)
    } else {
      unemp_df <- unemp_raw |>
        group_by(kommune_kode) |>
        summarise(UNEMP_RATE = round(sum(value,na.rm=TRUE), 1), .groups="drop")
    }
    message(sprintf("  Unemployment: %d kommuner", nrow(unemp_df)))
  }
}


# ============================================================
# 5. RAS1 — Employment rate
# ============================================================
message("Fetching RAS1 (employment) from DST...")

ras1 <- dst_post("RAS1", list(
  list(code="OMRÅDE", values=list("*")),
  list(code="SOCIO",  values=list("499","500","505")),
  list(code="IETYPE", values=list("999")),
  list(code="ALDER",  values=list("16-19","20-24","25-29","30-34","35-39",
                                   "40-44","45-49","50-54","55-59","60-64","65-66")),
  list(code="KØN",    values=list("M","K")),  # RAS1 has no TOT — sum M+K
  list(code="Tid",    values=list(""))
))

emp_df <- NULL
if (!is.null(ras1)) {
  names(ras1) <- janitor::make_clean_names(names(ras1))
  area_c  <- grep("omr|area", names(ras1), value=TRUE, ignore.case=TRUE)[1]
  val_c   <- grep("indhold|value|antal|count", names(ras1), value=TRUE, ignore.case=TRUE)[1]
  socio_c <- grep("socio", names(ras1), value=TRUE, ignore.case=TRUE)[1]

  if (!is.na(area_c) && !is.na(val_c) && !is.na(socio_c)) {
    ras <- ras1 |>
      rename(area=!!area_c, value=!!val_c, socio=!!socio_c) |>
      mutate(value = suppressWarnings(as.numeric(gsub(",",".",value))),
             kommune_kode = coalesce(area_code, pad4(area))) |>
      filter(kommune_kode %in% kommune_lookup$kommune_kode, !is.na(value))

    emp_df <- ras |>
      group_by(kommune_kode) |>
      summarise(
        employed = sum(value[grepl("Besk", socio, ignore.case=TRUE)], na.rm=TRUE),
        total    = sum(value, na.rm=TRUE),
        .groups  = "drop"
      ) |>
      mutate(EMP_RATE = if_else(total>0, round(employed/total*100, 1), NA_real_)) |>
      select(kommune_kode, EMP_RATE)
    message(sprintf("  Employment: %d kommuner", nrow(emp_df)))
  }
}


# ============================================================
# 6. ERHV6 — Employees at local workplaces
# ============================================================
message("Fetching ERHV6 (employees) from DST...")

erhv6 <- dst_post("ERHV6", list(
  list(code="OMRÅDE",      values=list("*")),
  list(code="BRANCHE0710", values=list("TOT")),
  list(code="ARBSTRDK",    values=list("*")),
  list(code="Tid",         values=list(""))
))

emp_local_df <- NULL
if (!is.null(erhv6)) {
  names(erhv6) <- janitor::make_clean_names(names(erhv6))
  area_c <- grep("omr|area|omrade", names(erhv6), value=TRUE, ignore.case=TRUE)[1]
  val_c  <- grep("indhold|value|antal|count", names(erhv6), value=TRUE, ignore.case=TRUE)[1]

  if (!is.na(area_c) && !is.na(val_c)) {
    emp_local_df <- erhv6 |>
      rename(area=!!area_c, value=!!val_c) |>
      mutate(value = suppressWarnings(as.numeric(gsub(",",".",value))),
             kommune_kode = coalesce(area_code, pad4(area))) |>
      filter(kommune_kode %in% kommune_lookup$kommune_kode, !is.na(value)) |>
      group_by(kommune_kode) |>
      summarise(EMPLOYEES=sum(value,na.rm=TRUE), .groups="drop")
    message(sprintf("  Employees: %d kommuner", nrow(emp_local_df)))
  }
}


# ============================================================
# 7. HFUDD11 — Education level
# ============================================================
message("Fetching HFUDD11 (education) from DST...")

hfudd <- dst_post("HFUDD11", list(
  list(code="BOPOMR",  values=list("*")),
  list(code="HFUDD",   values=list("TOT","H20","H30","H35","H40","H50")),
  list(code="ALDER",   values=list("TOT")),
  list(code="KØN",     values=list("TOT")),
  list(code="HERKOMST",values=list("TOT")),
  list(code="Tid",     values=list(""))
))

edu_df <- NULL
if (!is.null(hfudd)) {
  names(hfudd) <- janitor::make_clean_names(names(hfudd))
  area_c <- grep("bopomr|omr|area|bop", names(hfudd), value=TRUE, ignore.case=TRUE)[1]
  val_c  <- grep("indhold|value|antal|count", names(hfudd), value=TRUE, ignore.case=TRUE)[1]
  edu_c  <- grep("hfudd|educ|udd", names(hfudd), value=TRUE, ignore.case=TRUE)[1]

  if (!is.na(area_c) && !is.na(val_c) && !is.na(edu_c)) {
    edu <- hfudd |>
      rename(area=!!area_c, value=!!val_c, edu=!!edu_c) |>
      mutate(value = suppressWarnings(as.numeric(gsub(",",".",value))),
             kommune_kode = coalesce(area_code, pad4(area))) |>
      filter(kommune_kode %in% kommune_lookup$kommune_kode, !is.na(value))

    # Danish HFUDD labels: "I alt", "H10 Grundskole", "H20 Gymnasiale uddannelser",
    # "H30 Korte videregående", "H35 Mellemlange videregående", "H40 Bachelor", "H50 Lang videregående"
    edu_total <- edu |>
      filter(grepl("^i alt$|^in all$", edu, ignore.case=TRUE)) |>
      group_by(kommune_kode) |> summarise(edu_total=sum(value,na.rm=TRUE),.groups="drop")

    edu_sec <- edu |>
      filter(grepl("^H20", edu, ignore.case=TRUE)) |>
      group_by(kommune_kode) |> summarise(sec=sum(value,na.rm=TRUE),.groups="drop")

    edu_ter <- edu |>
      filter(grepl("^H3|^H4|^H5", edu, ignore.case=TRUE)) |>
      group_by(kommune_kode) |> summarise(ter=sum(value,na.rm=TRUE),.groups="drop")

    edu_df <- edu_total |>
      left_join(edu_sec, by="kommune_kode") |>
      left_join(edu_ter, by="kommune_kode") |>
      mutate(
        EDU_SEC = if_else(edu_total>0, round(coalesce(sec,0)/edu_total*100,1), NA_real_),
        EDU_TER = if_else(edu_total>0, round(coalesce(ter,0)/edu_total*100,1), NA_real_)
      ) |>
      select(kommune_kode, EDU_SEC, EDU_TER)
    message(sprintf("  Education: %d kommuner", nrow(edu_df)))
  }
}


# ============================================================
# 8. Assemble kommunal indicator table
# ============================================================
message("Assembling kommunal indicator table...")

komm_stats <- kommune_lookup |> select(kommune_kode)

for (df in list(pop_age_df, foreign_df, unemp_df, emp_df, emp_local_df, edu_df)) {
  if (!is.null(df) && "kommune_kode" %in% names(df))
    komm_stats <- left_join(komm_stats, df, by="kommune_kode")
}
message(sprintf("  %d kommuner × %d indicator columns",
  nrow(komm_stats), ncol(komm_stats)-1))


# ============================================================
# 9. Urban-rural classification from population
# ============================================================
classify_urban_rural <- function(pop) {
  dplyr::case_when(pop >= 20000 ~ "Urban",
                   pop >=  5000 ~ "Intermediate",
                   TRUE         ~ "Rural")
}
classify_settlement <- function(pop) {
  dplyr::case_when(pop >= 50000 ~ "Large City",
                   pop >= 10000 ~ "Small City",
                   pop >=  2000 ~ "Town",
                   TRUE         ~ "Village")
}

komm_full <- kommune_lookup |>
  left_join(komm_stats, by="kommune_kode") |>
  mutate(
    POPULATION = if ("POPULATION" %in% names(komm_stats))
                   coalesce(POPULATION, 0L) else 0L,
    urban_rural_status = classify_urban_rural(POPULATION),
    settlement_class   = classify_settlement(POPULATION),
    density_class      = "Unknown"
  )


# ============================================================
# 10. Build Kommune entries
# ============================================================
message("Building Kommune entries...")

kommune_entries <- lapply(seq_len(nrow(komm_full)), function(i) {
  row <- komm_full[i, ]
  indicators <- build_indicator_list(row)
  c(list(Urban_rural_status = row$urban_rural_status,
         Settlement_class   = row$settlement_class,
         Density_class      = row$density_class,
         Region             = row$region_navn,
         Population         = as.integer(row$POPULATION)),
    indicators)
}) |> setNames(komm_full$kommune_kode)


# ============================================================
# 11. Build Region entries (aggregate from kommuner)
# ============================================================
message("Building Region entries...")

agg_weighted <- function(rows, col) {
  vals <- rows[[col]]; pops <- rows$POPULATION
  ok <- !is.na(vals) & !is.na(pops) & pops > 0
  if (!any(ok)) return(NA_real_)
  if (AGGREGATION_TYPE[[col]] == "sum") sum(vals[ok], na.rm=TRUE)
  else sum(vals[ok]*pops[ok])/sum(pops[ok])
}

region_codes <- unique(komm_full$region_kode)
region_entries <- lapply(region_codes, function(rc) {
  rows <- filter(komm_full, region_kode == rc)
  rname <- rows$region_navn[1]
  total_pop <- sum(rows$POPULATION, na.rm=TRUE)

  agg <- list()
  for (col in INDICATOR_COLS) {
    if (col == "POPULATION") agg[[col]] <- total_pop
    else if (col %in% names(rows)) agg[[col]] <- agg_weighted(rows, col)
    else agg[[col]] <- NA_real_
  }
  agg_row <- as_tibble(agg)
  indicators <- build_indicator_list(agg_row)

  majority <- function(x) { t<-table(x[!is.na(x)]); if(length(t)==0) NA_character_ else names(sort(t,decreasing=TRUE))[1] }

  c(list(Urban_rural_status = majority(rows$urban_rural_status),
         Settlement_class   = majority(rows$settlement_class),
         Density_class      = majority(rows$density_class),
         Region             = rname,
         Population         = as.integer(total_pop)),
    indicators)
}) |> setNames(region_codes)


# ============================================================
# 12. Build Denmark Total
# ============================================================
message("Building Denmark Total...")

total_pop <- sum(komm_full$POPULATION, na.rm=TRUE)
dk_row <- list()
for (col in INDICATOR_COLS) {
  if (col == "POPULATION") { dk_row[[col]] <- total_pop; next }
  if (!col %in% names(komm_full)) { dk_row[[col]] <- NA_real_; next }
  vals <- komm_full[[col]]; pops <- komm_full$POPULATION
  ok   <- !is.na(vals) & !is.na(pops) & pops > 0
  dk_row[[col]] <- if (!any(ok)) NA_real_
    else if (AGGREGATION_TYPE[[col]]=="sum") sum(vals[ok])
    else round(sum(vals[ok]*pops[ok])/sum(pops[ok]), 1)
}
denmark_total <- build_indicator_list(as_tibble(dk_row))


# ============================================================
# 13. Assemble final_json
# ============================================================
final_json <- list(
  "Denmark Total" = denmark_total,
  "Region"        = lapply(region_entries,  convert_to_named_list),
  "Kommune"       = lapply(kommune_entries, convert_to_named_list)
)

message(sprintf("Done. Denmark Total + %d Regions + %d Kommuner ready.",
  length(region_entries), length(kommune_entries)))
