# =============================================================================
# fn_landsat.R — Landsat C2L2 download via STAC / Planetary Computer
# =============================================================================
#
# Provides download_landsat(), which:
#   1. Determines the seasonal analysis window from the Koppen-Geiger class
#   2. Queries the Planetary Computer STAC API
#   3. Downloads ST_B10/ST_B6 + QA_PIXEL for each valid scene (COG crop)
#
# Returns a named list:
#   $start_date, $end_date, $year   (analysis window)
#   $koppen_class                   (2-letter Koppen code)
# =============================================================================


# ── Season window helpers ─────────────────────────────────────────────────────

.warm_months <- function(kg, lat) {
  nh <- lat >= 0
  if (startsWith(kg, "A")) {
    if (kg == "Af") return(1:12)
    return(if (nh) c(11:12, 1:4) else 5:10)
  } else if (startsWith(kg, "B")) {
    return(if (nh) 4:9 else c(10:12, 1:3))
  } else if (startsWith(kg, "C")) {
    if (kg %in% c("Csa","Csb")) return(4:9)
    return(if (nh) 6:8 else c(12, 1, 2))
  } else {
    return(if (nh) 6:8 else c(12, 1, 2))
  }
}

.season_window <- function(warm_months, today = Sys.Date()) {
  y <- as.integer(format(today, "%Y"))
  if (max(warm_months) > min(warm_months)) {
    s <- as.Date(sprintf("%d-%02d-01", y, min(warm_months)))
    e <- as.Date(format(seq(as.Date(sprintf("%d-%02d-01", y, max(warm_months))),
                             by = "1 month", length.out = 2)[2] - 1, "%Y-%m-%d"))
    if (today <= e) {
      y <- y - 1
      s <- as.Date(sprintf("%d-%02d-01", y, min(warm_months)))
      e <- as.Date(format(seq(as.Date(sprintf("%d-%02d-01", y, max(warm_months))),
                               by = "1 month", length.out = 2)[2] - 1, "%Y-%m-%d"))
    }
  } else {
    sm <- min(warm_months); em <- max(warm_months)
    s  <- as.Date(sprintf("%d-%02d-01", y-1, sm))
    e  <- as.Date(format(seq(as.Date(sprintf("%d-%02d-01", y, em)),
                              by = "1 month", length.out = 2)[2] - 1, "%Y-%m-%d"))
    if (today <= e) {
      s <- as.Date(sprintf("%d-%02d-01", y-2, sm))
      e <- as.Date(format(seq(as.Date(sprintf("%d-%02d-01", y-1, em)),
                               by = "1 month", length.out = 2)[2] - 1, "%Y-%m-%d"))
    }
  }
  list(start_date = s, end_date = e)
}


# ── STAC helpers ──────────────────────────────────────────────────────────────

.band_info <- function(sensor_code) {
  # Planetary Computer landsat-c2-l2 STAC asset names (NOT the USGS band names):
  #   Landsat 8/9 thermal = "lwir11"  (surface temperature, band 10)
  #   Landsat 4/5/7 thermal = "lwir"  (surface temperature, band 6)
  #   QA band = "qa_pixel"
  switch(sensor_code,
    "04" = list(thermal = "lwir",   qa = "qa_pixel"),
    "05" = list(thermal = "lwir",   qa = "qa_pixel"),
    "07" = list(thermal = "lwir",   qa = "qa_pixel"),
    "08" = list(thermal = "lwir11", qa = "qa_pixel"),
    "09" = list(thermal = "lwir11", qa = "qa_pixel"),
    NULL)
}

.download_band <- function(item, band_key, out_path, aoi_bb) {
  if (file.exists(out_path)) return(TRUE)

  asset <- item$assets[[band_key]]
  if (is.null(asset)) {
    cli::cli_alert_warning("  Asset '{band_key}' not found in item.")
    return(FALSE)
  }

  url <- asset$href
  if (is.null(url) || !nzchar(url)) {
    cli::cli_alert_warning("  No URL for asset '{band_key}'.")
    return(FALSE)
  }

  # Strategy 1: vsicurl (streaming COG — lightweight, downloads only AOI tiles)
  r <- tryCatch({
    terra::rast(paste0("/vsicurl/", url))
  }, error = function(e) NULL)

  # Strategy 2: download full file via httr then read locally
  if (is.null(r)) {
    cli::cli_alert_info("  vsicurl failed for {band_key}, trying direct download...")
    tmp <- tempfile(fileext = ".tif")
    resp <- tryCatch(
      httr::GET(url,
        httr::add_headers("User-Agent" = "SUHII_mapping/1.0"),
        httr::write_disk(tmp, overwrite = TRUE),
        httr::timeout(300)),
      error = function(e) NULL)
    if (!is.null(resp) && httr::status_code(resp) == 200) {
      r <- tryCatch(terra::rast(tmp), error = function(e) NULL)
    }
    if (is.null(r)) {
      cli::cli_alert_warning("  {band_key} download failed (both vsicurl and httr).")
      if (file.exists(tmp)) unlink(tmp)
      return(FALSE)
    }
  }

  tryCatch({
    aoi_v <- terra::vect(
      rbind(c(aoi_bb["x","min"], aoi_bb["y","min"]),
            c(aoi_bb["x","min"], aoi_bb["y","max"]),
            c(aoi_bb["x","max"], aoi_bb["y","max"]),
            c(aoi_bb["x","max"], aoi_bb["y","min"]),
            c(aoi_bb["x","min"], aoi_bb["y","min"])),
      type = "polygons", crs = "EPSG:4326")
    r_crop <- terra::crop(r, terra::project(aoi_v, terra::crs(r)))
    terra::writeRaster(r_crop, out_path, overwrite = TRUE,
      wopt = list(filetype = "GTiff", datatype = "INT2U",
                  NAflag = 0, gdal = "COMPRESS=LZW"))
    TRUE
  }, error = function(e) {
    cli::cli_alert_warning("  {band_key} crop/write failed: {e$message}")
    FALSE
  })
}


# ── Main function ─────────────────────────────────────────────────────────────

#' Download Landsat C2L2 thermal bands via STAC
#'
#' @param aoi_bb    Bounding box matrix
#' @param city_slug City name (underscores)
#' @param season    "warm" or "cold"
#' @param max_cloud Maximum cloud cover percentage
#' @param dirs      Project directories from setup()
#'
#' @return Named list: $start_date, $end_date, $year, $koppen_class
download_landsat <- function(aoi_bb, city_slug, season, max_cloud, dirs) {

  cli::cli_h2("Landsat download")

  # Koppen-Geiger classification
  lon <- mean(c(aoi_bb["x","min"], aoi_bb["x","max"]))
  lat <- mean(c(aoi_bb["y","min"], aoi_bb["y","max"]))
  kgc_df <- data.frame(Site = city_slug, Longitude = lon, Latitude = lat)
  kgc_df <- data.frame(kgc_df,
    rndCoord.lon = kgc::RoundCoordinates(kgc_df$Longitude),
    rndCoord.lat = kgc::RoundCoordinates(kgc_df$Latitude))
  kgc_df       <- data.frame(kgc_df, ClimateZ = kgc::LookupCZ(kgc_df))
  koppen_full  <- kgc_df$ClimateZ
  kg           <- substr(koppen_full, 1, 2)

  cli::cli_alert_info("Koppen-Geiger class: {kg}  |  lat: {round(lat,3)}")

  warm_m  <- .warm_months(kg, lat)
  win     <- .season_window(warm_m, today = Sys.Date())
  start_d <- win$start_date
  end_d   <- win$end_date
  yr      <- as.integer(format(end_d, "%Y"))

  cli::cli_alert_info(
    "Season window: {start_d} \u2192 {end_d}  (year: {yr}, cloud \u2264 {max_cloud}%)"
  )

  # STAC query — with automatic cloud cover fallback
  # If no scenes found at max_cloud, retry with progressively higher thresholds
  stac_url  <- "https://planetarycomputer.microsoft.com/api/stac/v1"
  bbox_vec  <- c(aoi_bb["x","min"], aoi_bb["y","min"],
                 aoi_bb["x","max"], aoi_bb["y","max"])
  dt_range  <- paste0(start_d, "T00:00:00Z/", end_d, "T23:59:59Z")

  .stac_query <- function(cloud_limit, max_retry = 4) {
    last_err <- NULL
    for (attempt in seq_len(max_retry)) {
      result <- tryCatch({
        # Query without server-side filters — filter client-side after retrieval.
        # ext_filter (CQL2) and query= are unreliable across rstac versions.
        items <- rstac::stac(stac_url) |>
          rstac::stac_search(
            collections = "landsat-c2-l2",
            bbox        = bbox_vec,
            datetime    = dt_range,
            limit       = 200
          ) |>
          rstac::get_request() |>
          rstac::items_sign(rstac::sign_planetary_computer())

        # Filter client-side: cloud cover only
        features <- items$features
        if (length(features) > 0) {
          keep <- sapply(features, function(f) {
            cc <- f$properties[["eo:cloud_cover"]]
            !is.null(cc) && as.numeric(cc) <= cloud_limit
          })
          items$features <- features[keep]
        }
        items
      }, error = function(e) {
        last_err <<- conditionMessage(e)
        NULL
      })

      if (!is.null(result)) return(result)

      # Transient error (timeout, text/plain response, rate limit) — retry
      if (attempt < max_retry) {
        cli::cli_alert_warning(
          "STAC query attempt {attempt}/{max_retry} failed ({last_err}). Retrying in {15*attempt}s..."
        )
        Sys.sleep(15 * attempt)
      }
    }
    cli::cli_abort(c(
      "STAC query failed after {max_retry} attempts.",
      "i" = "Last error: {last_err}",
      "i" = "Planetary Computer may be temporarily overloaded. Try again in a few minutes."
    ))
  }

  cli::cli_alert_info("Querying STAC: landsat-c2-l2  {start_d} \u2192 {end_d}  (cloud \u2264 {max_cloud}%)")
  items <- .stac_query(max_cloud)

  # Detailed diagnostics
  n_total    <- length(items$features)
  n_filtered <- n_total  # already filtered in .stac_query
  cli::cli_alert_info("STAC raw results: {n_total} scene(s) after client-side filter (cloud \u2264 {max_cloud}%, T1)")

  # Log first 3 scenes for debugging
  if (n_total > 0) {
    for (i in seq_len(min(3L, n_total))) {
      f  <- items$features[[i]]
      cc <- f$properties[["eo:cloud_cover"]] %||% "?"
      ct <- f$properties[["landsat:collection_category"]] %||% "?"
      pl <- f$properties[["platform"]] %||% "?"
      cli::cli_alert_info("  [{i}] id={f$id} | cloud={cc}% | cat={ct} | platform={pl}")
    }
  }

  n_scenes <- n_total
  if (n_scenes == 0) {
    cli::cli_abort(c(
      "No Landsat scenes found for this area and season.",
      "i" = "Window: {start_d} to {end_d}, cloud \u2264 {max_cloud}%",
      "i" = "Check Planetary Computer availability for this area and period."
    ))
  }
  cli::cli_alert_success("{n_scenes} scene(s) found. Downloading...")

  n_ok <- 0L
  dir.create(dirs$landsat, showWarnings = FALSE, recursive = TRUE)

  for (item in items$features) {
    props    <- item$properties
    scene_id <- item$id
    platform <- props[["platform"]] %||% ""
    cloud    <- props[["eo:cloud_cover"]] %||% NA_real_

    # platform can be "landsat-8", "LANDSAT_8", "OLI_TIRS" etc.
    # Use the scene_id prefix (LC08, LC09, LT05, LE07) as ground truth
    sensor_code <- dplyr::case_when(
      grepl("^LC08", scene_id) ~ "08",
      grepl("^LC09", scene_id) ~ "09",
      grepl("^LT05", scene_id) ~ "05",
      grepl("^LE07", scene_id) ~ "07",
      grepl("^LT04", scene_id) ~ "04",
      # Fallback: parse platform string
      grepl("8",  platform) ~ "08",
      grepl("9",  platform) ~ "09",
      grepl("5",  platform) ~ "05",
      grepl("7",  platform) ~ "07",
      TRUE ~ NA_character_
    )

    cli::cli_alert_info(
      "Scene: {scene_id} | sensor: L{sensor_code} | cloud: {round(cloud %||% -1)}%"
    )

    if (is.na(sensor_code)) {
      cli::cli_alert_warning("  Unrecognised sensor for {scene_id} — skipped.")
      next
    }
    band_info <- .band_info(sensor_code)
    if (is.null(band_info)) next

    # Saved filenames keep USGS-style names (_ST_B10/_ST_B6/_QA_PIXEL) so that
    # fn_lst.R can find them with its "_ST_B" pattern. The STAC asset keys
    # (lwir11/lwir/qa_pixel) are used only for the download call.
    thermal_suffix <- if (sensor_code %in% c("08","09")) "ST_B10" else "ST_B6"
    f_th <- file.path(dirs$landsat, paste0(scene_id, "_", thermal_suffix, ".tif"))
    f_qa <- file.path(dirs$landsat, paste0(scene_id, "_QA_PIXEL.tif"))

    if (file.exists(f_th) && file.exists(f_qa)) {
      cli::cli_alert_info("  Already on disk — skipped.")
      n_ok <- n_ok + 1L
      next
    }

    ok_th <- .download_band(item, band_info$thermal, f_th, aoi_bb)
    ok_qa <- .download_band(item, band_info$qa,      f_qa, aoi_bb)

    if (ok_th && ok_qa) {
      n_ok <- n_ok + 1L
      cli::cli_alert_success("  Saved: {basename(f_th)} + {basename(f_qa)}")
    } else {
      if (file.exists(f_th)) file.remove(f_th)
      if (file.exists(f_qa)) file.remove(f_qa)
    }
  }
  cli::cli_alert_success("Downloaded {n_ok}/{n_scenes} scenes.")

  list(start_date = start_d, end_date = end_d, year = yr,
       koppen_class = kg, n_scenes_found = n_scenes)
}
