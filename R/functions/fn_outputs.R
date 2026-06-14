# =============================================================================
# fn_outputs.R — Classification, priority map, statistics, GeoJSON exports
# =============================================================================
#
# Provides produce_outputs(), which takes the SUHII analysis results and
# produces all derived outputs: classified raster, priority map, CSV stats,
# and GeoJSON exports.
#
# Classification thresholds (LST anomaly, °C difference surface–rural):
#   < 0          Cool island    (Stewart & Oke 2012; Chen et al. 2019)
#   0 – 1        Neutral
#   1 – 2.5      Weak
#   2.5 – 4.5    Moderate
#   4.5 – 6.5    Strong
#   > 6.5        Extreme
#
# NOTE: these are LST differences, NOT air temperature differences.
# Approx. conversion: LST anomaly / 2 ≈ T_air anomaly (Voogt & Oke 2003).
#
# Priority index = 0.50 × norm(anomaly) + 0.30 × norm(green_deficit)
#               + 0.20 × urban_mask
# (Maragkogiannis et al. 2024; Morabito et al. 2015)
#
# Returns: city_stats data.frame
# =============================================================================


#' Produce all derived outputs
#'
#' @param anomaly_map  SpatRaster, thermal anomaly (°C)
#' @param suhi_map     SpatRaster, SUHII index (0–1)
#' @param lst_mean     SpatRaster, seasonal mean LST (°C)
#' @param aoi_utm      SpatVector, AOI in raster CRS
#' @param aree_urb     SpatRaster, urban mask (1/NA)
#' @param aree_ref     SpatRaster, rural mask (1/NA)
#' @param city_name    Original city name string
#' @param city_slug    City slug string
#' @param dirs         Project directories
#' @param start_date   Date
#' @param end_date     Date
#' @param year         Integer
#' @param season       "warm" or "cold"
#' @param max_cloud    Integer
#'
#' @return data.frame of summary statistics
produce_outputs <- function(anomaly_map, suhi_map, lst_mean,
                             aoi_utm, aree_urb, aree_ref,
                             city_name, city_slug, dirs,
                             start_date, end_date, year,
                             season, max_cloud) {

  cli::cli_h2("Outputs: classification, priority map, statistics")

  # ── Classification thresholds ──────────────────────────────────────────────
  # Source: Stewart & Oke (2012, BAMS 93:1879–1900); Chen et al. (2019, IJERPH)
  BREAKS        <- c(-Inf, 0, 1, 2.5, 4.5, 6.5, Inf)
  CLASS_LABELS  <- c("1_cool_island","2_neutral","3_weak",
                     "4_moderate","5_strong","6_extreme")
  CLASS_NAMES   <- c("Cool island (< 0°C)","Neutral (0–1°C)",
                     "Weak (1–2.5°C)","Moderate (2.5–4.5°C)",
                     "Strong (4.5–6.5°C)","Extreme (> 6.5°C)")

  # Classify anomaly → integer 1–6
  anomaly_classified <- terra::classify(
    anomaly_map,
    rcl = cbind(BREAKS[-length(BREAKS)], BREAKS[-1], seq_along(CLASS_LABELS)),
    include.lowest = TRUE, right = FALSE)

  cls_path <- file.path(dirs$output, sprintf("%s_%d_anomaly_classified.tif", season, year))
  terra::writeRaster(anomaly_classified, cls_path,
    overwrite = TRUE,
    wopt = list(filetype="GTiff", datatype="INT1U", NAflag=255, gdal="COMPRESS=LZW"))
  write_metadata(anomaly_classified,
    title       = sprintf("Classified thermal anomaly — %s %d", season, year),
    description = paste0("6-class heat island severity (1=cool island, 2=neutral, ",
                         "3=weak, 4=moderate, 5=strong, 6=extreme) based on LST anomaly. ",
                         "Thresholds: Stewart & Oke 2012, Chen et al. 2019."),
    keywords    = c("SUHII","classification","heat island","LST"),
    out_path    = file.path(dirs$output,
                    sprintf("%s_%d_anomaly_classified_metadata.json", season, year)),
    raster_path = cls_path)
  cli::cli_alert_success("Classified raster saved.")

  # ── Priority map ───────────────────────────────────────────────────────────
  # Weights: thermal 50%, green deficit 30%, urban 20%
  # Reference: Maragkogiannis et al. (2024); Morabito et al. (2015)
  W_THERMAL <- 0.50
  W_GREEN   <- 0.30
  W_URBAN   <- 0.20

  # Component A: normalised thermal anomaly (clip negative to 0)
  anom_pos  <- terra::ifel(anomaly_map < 0, 0, anomaly_map)
  anom_max  <- as.numeric(terra::global(anom_pos, "max", na.rm = TRUE))
  anom_min2 <- as.numeric(terra::global(anom_pos, "min", na.rm = TRUE))
  comp_th   <- terra::clamp((anom_pos - anom_min2) / (anom_max - anom_min2), 0, 1)

  # Component B: normalised green access deficit
  dist_path <- file.path(dirs$output,
    sprintf("%s_%d_distance_green_areas.tif", season, year))
  if (file.exists(dist_path)) {
    dr        <- terra::rast(dist_path) |> terra::resample(anomaly_map)
    dr_fill   <- terra::ifel(is.na(dr), 0, dr)
    d_max     <- as.numeric(terra::global(dr_fill, "max", na.rm = TRUE))
    comp_gr   <- if (d_max > 0) terra::clamp(dr_fill / d_max, 0, 1) else dr_fill * 0
  } else {
    comp_gr <- anomaly_map * 0
  }

  # Component C: urban mask (0/1)
  comp_urb <- terra::ifel(is.na(aree_urb), 0, aree_urb)

  priority_map <- terra::mask(
    terra::clamp(W_THERMAL * comp_th + W_GREEN * comp_gr + W_URBAN * comp_urb, 0, 1),
    aoi_utm)
  priority_map <- terra::ifel(is.na(aree_urb), NA, priority_map)

  prio_path <- file.path(dirs$output, sprintf("%s_%d_priority_map.tif", season, year))
  terra::writeRaster(priority_map, prio_path,
    overwrite = TRUE,
    wopt = list(filetype="GTiff", datatype="FLT4S", NAflag=-9999, gdal="COMPRESS=LZW"))
  write_metadata(priority_map,
    title       = sprintf("Intervention priority map — %s %d", season, year),
    description = paste0("Composite priority index [0-1] for urban pixels: ",
                         "0.50*thermal_anomaly + 0.30*green_deficit + 0.20*urban_mask. ",
                         "Weights: Maragkogiannis et al. 2024, Morabito et al. 2015."),
    keywords    = c("priority","intervention","green infrastructure","UHI"),
    out_path    = file.path(dirs$output,
                    sprintf("%s_%d_priority_map_metadata.json", season, year)),
    raster_path = prio_path)
  cli::cli_alert_success("Priority map saved.")

  # ── Summary statistics ─────────────────────────────────────────────────────
  safe_g <- function(r, s) tryCatch(
    as.numeric(terra::global(r, s, na.rm = TRUE)), error = function(e) NA_real_)

  lst_urb_m <- terra::mask(lst_mean, aree_urb)
  lst_ref_m <- terra::mask(lst_mean, aree_ref)
  pixel_km2 <- prod(terra::res(anomaly_classified)) / 1e6
  cls_vals  <- as.integer(terra::values(anomaly_classified))
  cls_tot   <- sum(!is.na(cls_vals))
  pct_cls   <- sapply(1:6, function(i) round(100 * sum(cls_vals == i, na.rm = TRUE) / cls_tot, 1))

  # Green deficit
  pct_no_green <- if (file.exists(dist_path)) {
    dr2     <- terra::rast(dist_path) |> terra::resample(aree_urb)
    n_beyond <- sum(!is.na(terra::values(terra::mask(dr2, aree_urb))))
    round(100 * n_beyond / cls_tot, 1)
  } else NA_real_

  city_stats <- data.frame(
    city                        = city_name,
    season                      = season,
    year                        = year,
    start_date                  = as.character(start_date),
    end_date                    = as.character(end_date),
    max_cloud_pct               = max_cloud,
    n_landsat_scenes            = length(list.files(dirs$landsat, pattern = "_ST_B")),
    lst_mean_urban_C            = round(safe_g(lst_urb_m, "mean"), 2),
    lst_mean_rural_C            = round(safe_g(lst_ref_m, "mean"), 2),
    lst_max_urban_C             = round(safe_g(lst_urb_m, "max"),  2),
    suhii_mean_C                = round(safe_g(anomaly_map, "mean"), 2),
    suhii_max_C                 = round(safe_g(anomaly_map, "max"),  2),
    suhii_sd_C                  = round(safe_g(anomaly_map, "sd"),   2),
    note_lst_vs_tair            = paste0(
      "LST anomaly values are surface temperature differences (°C), ",
      "not near-surface air temperature differences. ",
      "Approx: LST anomaly / 2 ≈ T_air anomaly (Voogt & Oke 2003)."),
    pct_urban_cool_island       = pct_cls[1],
    pct_urban_neutral           = pct_cls[2],
    pct_urban_weak              = pct_cls[3],
    pct_urban_moderate          = pct_cls[4],
    pct_urban_strong            = pct_cls[5],
    pct_urban_extreme           = pct_cls[6],
    pct_urban_beyond_300m_green = pct_no_green,
    priority_weight_thermal     = W_THERMAL,
    priority_weight_green       = W_GREEN,
    priority_weight_urban       = W_URBAN,
    stringsAsFactors = FALSE
  )

  write.csv(city_stats,
    file.path(dirs$output, sprintf("%s_%d_city_stats.csv", season, year)),
    row.names = FALSE)
  cli::cli_alert_success("Summary statistics saved.")

  # ── GeoJSON exports ────────────────────────────────────────────────────────
  .to_geojson <- function(r, out_path, field_name = "value") {
    r4326 <- terra::project(r, "EPSG:4326")
    polys <- terra::as.polygons(r4326, dissolve = TRUE)
    if (length(polys) == 0) return(invisible(NULL))
    names(polys)[1] <- field_name
    terra::writeVector(polys, out_path, filetype = "GeoJSON", overwrite = TRUE)
    cli::cli_alert_success("GeoJSON saved: {basename(out_path)}")
  }

  cls_export <- anomaly_classified
  levels(cls_export) <- data.frame(value = 1:6, label = CLASS_NAMES)
  .to_geojson(cls_export,
    file.path(dirs$output, sprintf("%s_%d_anomaly_classified.geojson", season, year)),
    "heat_island_class")
  .to_geojson(round(priority_map, 2),
    file.path(dirs$output, sprintf("%s_%d_priority_map.geojson", season, year)),
    "priority_index")

  invisible(city_stats)
}
