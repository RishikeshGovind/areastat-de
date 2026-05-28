## config ##

#### install packages ####

suppressWarnings(if(!require(pacman)) install.packages("pacman"))
library(pacman)
p_load("dplyr",
       "openxlsx",
       "readxl",
       "rjson",
       "jsonlite",
       "janitor",
       "gtools",
       "httr",
       "stringr",
       "readr",
       "tidyr",
       "tibble",
       "purrr")

#### set-up folders & file names ####
data_source_root <- "create-js/inputs/"

#### Danish data settings ####
# All data is fetched freely from public APIs — no API key or registration required.
# Primary sources:
#   DAWA (Danmarks Adressers Web API)  https://api.dataforsyningen.dk/
#   DST  (Danmarks Statistik)          https://api.statbank.dk/v1/
DST_BASE  <- "https://api.statbank.dk/v1/"
DAWA_BASE <- "https://api.dataforsyningen.dk/"

#### Utility functions ####

transform_URL <- function(URL) {
  URL %>%
    gsub(" ", "%20", .) %>%
    gsub('"', "%22", .) %>%
    gsub("\\{", "%7B", .) %>%
    gsub("\\}", "%7D", .) %>%
    gsub("\\[", "%5B", .) %>%
    gsub("\\]", "%5D", .)
}

convert_named_vectors <- function(x) {
  if (is.list(x)) {
    lapply(x, convert_named_vectors)
  } else if (!is.null(names(x))) {
    as.list(x)
  } else {
    x
  }
}

convert_to_named_list <- function(x) {
  lapply(x, function(category) {
    if (is.list(category)) category else unname(category)
  })
}
