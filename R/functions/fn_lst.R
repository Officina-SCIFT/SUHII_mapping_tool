# =============================================================================
# fn_lst.R — Land Surface Temperature processing
# =============================================================================
#
# Provides process_lst(), which:
#   1. Converts Landsat C2L2 ST bands to LST in °C
#   2. Applies QA cloud masking
#   3. Applies Landsat 7 destriping where needed
#   4. Discards scenes with > 70% cloud/NA coverage
#   5. Computes the pixel-wise seasonal mean (+ SD, IQR, N_obs if > 2 scenes)
#
# Returns: named list with $lst_mean (SpatRaster, seasonal mean LST in °C)
# =============================================================================


#' Process Landsat scenes to seasonal mean LST
#'
#' @param aoi        SpatVector of study area boundary
#' @param aoi_bb     Bounding box matrix
#' @param dirs       Project directories from setup()
#' @param start_date Date, start of analysis window
#' @param end_date   Date, end of analysis window
#' @param year       Integer year (derived from end_date)
#' @param season     "warm" or "cold"
#'
#' @return Named list: $lst_mean (SpatRaster)
process_lst <- function(aoi, aoi_bb, dirs, start_date, end_date, year, season) {

  cli::cli_h2("LST processing")

  # AOI polygon for cropping (EPSG:4326, reprojected per scene inside the loop)
  aoi_poly_4326 <- terra::vect(
    rbind(c(aoi_bb["x","min"], aoi_bb["y","min"]),
          c(aoi_bb["x","min"], aoi_bb["y","max"]),
          c(aoi_bb["x","max"], aoi_bb["y","max"]),
          c(aoi_bb["x","max"], aoi_bb["y","min"]),
          c(aoi_bb["x","min"], aoi_bb["y","min"])),
    type = "polygons", crs = "EPSG:4326")

  # Scan available ST band files
  lst_files <- list.files(dirs$landsat, pattern = "_ST_B", full.names = FALSE)
  if (length(lst_files) == 0) {
    cli::cli_abort(c(
      "No Landsat ST band files found in {dirs$landsat}",
      "i" = "Ensure Step 2 (Landsat download) completed successfully."
    ))
  }
  cli::cli_alert_info("Found {length(lst_files)} ST band file(s).")

  season_dir <- file.path(dirs$processing, paste0(year, "_", season))
  dir.create(season_dir, showWarnings = FALSE, recursive = TRUE)

  # ── Per-scene processing ───────────────────────────────────────────────────
  n_ok <- 0L
  cli::cli_progress_bar("Processing scenes", total = length(lst_files))

  for (fname in lst_files) {
    scene_id    <- sub("_ST_B(10|6)\\.tif$", "", fname)
    sensor_code <- substr(scene_id, 3, 4)
    acq_date    <- tryCatch(
      as.Date(substr(scene_id, 18, 25), format = "%Y%m%d"),
      error = function(e) NA)

    cli::cli_progress_update()

    if (is.na(acq_date) ||
        !acq_date %within% lubridate::interval(start_date, end_date)) next

    qa_path <- file.path(dirs$landsat, paste0(scene_id, "_QA_PIXEL.tif"))
    st_path <- file.path(dirs$landsat,
      paste0(scene_id, "_ST_",
             if (sensor_code %in% c("08","09")) "B10" else "B6", ".tif"))

    if (!file.exists(qa_path) || !file.exists(st_path)) next

    # Skip if already processed
    lst_out <- file.path(season_dir, paste0(scene_id, "_LST.tif"))
    if (file.exists(lst_out)) { n_ok <- n_ok + 1L; next }

    QA <- terra::rast(qa_path)
    ST <- terra::rast(st_path)
    aoi_utm <- terra::project(aoi_poly_4326, QA)
    QA <- terra::crop(QA, aoi_utm)
    ST <- terra::crop(ST, aoi_utm)

    # QA masking (C2L2 clear-land bitmask values)
    valid_qa <- if (sensor_code %in% c("08","09")) 21824L else 5440L
    QA[QA != valid_qa] <- NA
    ST <- terra::mask(ST, QA, maskvalues = NA, updatevalue = NA)

    # Scale factor → LST in °C
    LST <- (ST * 0.00341802 + 149.0) - 273.15

    # Landsat 7 destriping (scan-line corrector failure, post-May 2003)
    if (sensor_code == "07" && year > 2003) {
      LST <- terra::focal(LST, w = 11, fun = mean, na.policy = "only", na.rm = TRUE)
    }

    LST <- terra::mask(LST, QA) |> terra::extend(terra::ext(aoi_utm))

    # Skip if > 70% cloud/NA
    na_pct <- terra::ncell(LST[is.na(LST)]) * 100 / terra::ncell(LST)
    if (na_pct > 70) { rm(QA, ST, LST); next }

    terra::writeRaster(LST, lst_out, overwrite = TRUE,
      wopt = list(filetype = "GTiff", datatype = "FLT4S",
                  NAflag = -9999, gdal = "COMPRESS=LZW"))
    n_ok <- n_ok + 1L
    rm(ST, QA, LST)
  }
  cli::cli_progress_done()

  if (n_ok == 0) {
    cli::cli_abort(c(
      "No valid LST scenes found.",
      "i" = "Window: {start_date} to {end_date}",
      "i" = "Try increasing MAX_CLOUD or widening the date range."
    ))
  }
  cli::cli_alert_success("{n_ok} scene(s) processed successfully.")

  # ── Seasonal mean ──────────────────────────────────────────────────────────
  scene_files <- list.files(season_dir, pattern = "\\.tif$", full.names = TRUE)
  cli::cli_alert_info("Computing seasonal mean from {length(scene_files)} scene(s)...")

  rlist     <- lapply(scene_files, terra::rast)
  ref       <- rlist[[1]]
  aligned   <- lapply(rlist, function(r) {
    terra::resample(terra::project(r, terra::crs(ref)), ref, method = "bilinear")
  })
  stack     <- terra::rast(aligned)
  aoi_utm_c <- terra::project(aoi, stack[[1]])
  lst_mean  <- terra::app(stack, fun = mean, na.rm = TRUE) |>
                 terra::crop(aoi_utm_c)

  if ((terra::ncell(lst_mean[is.na(lst_mean)]) * 100 /
       terra::ncell(lst_mean)) == 100) {
    cli::cli_abort("Seasonal mean LST is entirely NA over the study area.")
  }

  # Save
  mean_path <- file.path(dirs$output,
    sprintf("%s_%d_LST_MEAN.tif", season, year))
  terra::writeRaster(lst_mean, mean_path, overwrite = TRUE, datatype = "FLT4S")
  write_metadata(lst_mean,
    title       = sprintf("Mean LST — %s %d — %s", season, year, basename(dirs$root)),
    description = sprintf("Pixel-wise mean LST (°C), %s season %d", season, year),
    keywords    = c("LST","Landsat","raster"),
    out_path    = file.path(dirs$output, sprintf("%s_%d_LST_MEAN_metadata.json", season, year)),
    raster_path = mean_path)

  # Extra statistics when enough scenes are available
  if (terra::nlyr(stack) > 2) {
    for (stat_name in c("sd","IQR")) {
      s <- terra::app(stack, fun = get(stat_name), na.rm = TRUE) |>
             terra::crop(aoi_utm_c)
      terra::writeRaster(s,
        file.path(dirs$output,
          sprintf("%s_%d_LST_%s.tif", season, year, toupper(stat_name))),
        overwrite = TRUE, datatype = "FLT4S")
    }
    n_obs <- terra::app(stack, function(x) sum(!is.na(x))) |> terra::crop(aoi_utm_c)
    terra::writeRaster(n_obs,
      file.path(dirs$output, sprintf("%s_%d_LST_N_OBS.tif", season, year)),
      overwrite = TRUE, datatype = "FLT4S")
  }

  # Interactive preview
  rng <- terra::minmax(lst_mean)
  pal <- leaflet::colorNumeric("Spectral", domain = rng, reverse = TRUE,
                                na.color = "transparent")
  leaflet::leaflet() |> leaflet::addTiles() |>
    leaflet::addRasterImage(terra::project(lst_mean, "EPSG:4326"),
                            colors = pal, opacity = 0.8) |>
    leaflet::addLegend("bottomright", pal = pal, values = rng,
                       title = "Mean LST (°C)") |> print()

  cli::cli_alert_success(
    "LST mean saved: [{round(rng[1],1)}, {round(rng[2],1)}] °C"
  )
  list(lst_mean = lst_mean)
}
