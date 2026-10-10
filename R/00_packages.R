# =============================================================================
# 00_packages.R — Install and load all required packages

required_packages <- c(
  # Spatial raster / vector
  "terra", "tidyterra", "sf", "osmdata",
  # OSM from Geofabrik regional extracts (primary strategy; Overpass is the fallback)
  "osmextract", "curl",
  # Satellite / STAC
  "rstac",
  # DEM
  "elevatr",
  # Data wrangling
  "dplyr", "purrr", "tidyr", "tibble", "scales",
  # Visualisation
  "leaflet", "leaflet.extras", "ggplot2", "colorRamps", "colorspace",
  # Report
  "quarto", "knitr", "kableExtra",
  # Date/time
  "lubridate",
  # HTTP (Overpass fallback)
  "httr",
  # Climate classification
  "kgc",
  # Serialisation
  "jsonlite", "yaml",
  # User interface / progress
  "cli",
  # Misc
  "sp", "sfdep", "spdep"
)
# Optional, improves place-name matching (spelling suggestions); the tool works without them:
#   maps (city dictionary), stringi (accent folding)
optional_packages <- c("maps", "stringi")
missing_pkg <- required_packages[
  !(required_packages %in% installed.packages()[, "Package"])
]
if (length(missing_pkg) > 0) {
  cli::cli_alert_info(
    "Installing {length(missing_pkg)} missing package(s): {missing_pkg}"
  )
  install.packages(missing_pkg, dependencies = TRUE)
}
for (p in optional_packages) {
  if (!requireNamespace(p, quietly = TRUE)) try(install.packages(p), silent = TRUE)
}
invisible(lapply(required_packages, function(p)
  suppressPackageStartupMessages(library(p, character.only = TRUE))
))
cli::cli_alert_success("All packages loaded.")
