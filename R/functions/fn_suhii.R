# =============================================================================
# fn_suhii.R — SUHII analysis and green distance
# =============================================================================
#
# compute_suhii(): thermal anomaly + SUHII index, elevation-stratified
# compute_green_distance(): distance from green areas (3-30-300 rule)
# =============================================================================


# ── Internal: per-band anomaly + SUHII ───────────────────────────────────────

.band_products <- function(lst_band, aree_urb, aree_ref, aoi_utm,
                            proc_dir, season, yr, band_label) {
  # Urban mean LST
  mean_urb <- as.numeric(terra::global(
    terra::mask(terra::crop(lst_band, aree_urb), aree_urb), "mean", na.rm = TRUE))
  # Rural mean LST
  lst_ref <- terra::mask(
    terra::mask(terra::crop(lst_band, aree_ref), aree_ref),
    aree_urb, inverse = TRUE)
  mean_ref <- as.numeric(terra::global(lst_ref, "mean", na.rm = TRUE))

  cli::cli_bullets(c(
    " " = "  Urban LST: {round(mean_urb,2)}°C | Rural LST: {round(mean_ref,2)}°C"
  ))

  # Thermal anomaly: LST - mean_rural (°C difference)
  anomaly <- terra::crop(lst_band - mean_ref, aoi_utm) |> terra::mask(aoi_utm)
  terra::writeRaster(anomaly,
    file.path(proc_dir, sprintf("%s_%d_thermal_anomaly_band%s.tif", season, yr, band_label)),
    overwrite = TRUE,
    wopt = list(filetype="GTiff", datatype="FLT4S", NAflag=-9999, gdal="COMPRESS=LZW"))

  # SUHII index: min-max normalisation within band
  lst_max <- as.numeric(terra::global(lst_band, "max", na.rm = TRUE))
  lst_min <- as.numeric(terra::global(lst_band, "min", na.rm = TRUE))
  suhi    <- terra::crop((lst_band - lst_min) / (lst_max - lst_min), aoi_utm) |>
               terra::mask(aoi_utm)
  suhi[suhi < 0] <- 0; suhi[suhi > 1] <- 1
  terra::writeRaster(suhi,
    file.path(proc_dir, sprintf("%s_%d_SUHI_band%s.tif", season, yr, band_label)),
    overwrite = TRUE,
    wopt = list(filetype="GTiff", datatype="FLT4S", NAflag=-9999, gdal="COMPRESS=LZW"))

  list(anomaly = anomaly, suhi = suhi)
}


# ── Main functions ────────────────────────────────────────────────────────────

#' Compute thermal anomaly and SUHII index
#'
#' @param lst_mean             SpatRaster, seasonal mean LST
#' @param aoi                  SpatVector, study area boundary
#' @param city_slug            City slug string
#' @param dirs                 Project directories
#' @param dem_path             Path to DEM GeoTIFF
#' @param year                 Integer year
#' @param season               "warm" or "cold"
#' @param altitude_band_height Band height in metres
#'
#' @return Named list: $anomaly_map, $suhi_map, $aoi_utm, $aree_urb, $aree_ref
compute_suhii <- function(lst_mean, aoi, city_slug, dirs, dem_path,
                           year, season, altitude_band_height) {

  cli::cli_h2("SUHII analysis")

  # ── Load and validate spatial masks ───────────────────────────────────────
  urb_path <- file.path(dirs$input, "urban_areas.shp")
  ref_path <- file.path(dirs$input, "rural_areas.shp")
  for (p in c(urb_path, ref_path, dem_path)) {
    if (!file.exists(p) || file.size(p) == 0)
      cli::cli_abort("Required file not found or empty: {p}")
  }

  dem      <- terra::rast(dem_path) |> terra::project(lst_mean) |>
                terra::resample(lst_mean)
  urb_vect <- terra::vect(urb_path) |> terra::project(lst_mean)
  ref_vect <- terra::vect(ref_path) |> terra::aggregate() |>
                terra::project(lst_mean)

  if (length(urb_vect) == 0) cli::cli_abort("urban_areas.shp is empty after reprojection.")
  if (length(ref_vect) == 0) cli::cli_abort("rural_areas.shp is empty after reprojection.")

  # Rasterise masks
  aree_urb <- terra::rasterize(urb_vect, lst_mean, field = 1, background = NA)
  aree_ref <- terra::rasterize(ref_vect, lst_mean, field = 1, background = NA)

  # Remove overlaps; buffer 100 m around urban to exclude transitional pixels
  aree_urb     <- terra::mask(aree_urb, aree_ref, inverse = TRUE)
  urb_buf      <- terra::buffer(aree_urb, width = 100, background = NA)
  urb_buf[urb_buf == 0] <- NA
  aree_ref     <- terra::mask(aree_ref, urb_buf, inverse = TRUE)

  # Elevation statistics over urban area
  dem_urb      <- terra::mask(dem, aree_urb)
  mean_elev    <- as.integer(terra::global(dem_urb, "mean", na.rm = TRUE))
  max_elev     <- as.integer(terra::global(dem_urb, "max",  na.rm = TRUE))
  min_elev     <- as.integer(terra::global(dem_urb, "min",  na.rm = TRUE))

  cli::cli_alert_info(
    "Urban elevation: mean {mean_elev} m | min {min_elev} m | max {max_elev} m"
  )

  aoi_utm <- terra::project(aoi, lst_mean)
  n_bands <- max(1L, round((max_elev - min_elev) / altitude_band_height))
  cli::cli_alert_info("Elevation bands: {n_bands} (height: {altitude_band_height} m each)")

  # ── Compute per band ──────────────────────────────────────────────────────
  if (n_bands > 1) {
    lo <- round(min_elev, -1)
    hi <- lo + altitude_band_height
    for (b in seq_len(n_bands)) {
      cli::cli_alert_info("Band {b}: {lo}–{hi} m")
      dem_b <- dem
      dem_b[dem_b > hi | dem_b <= lo] <- NA
      .band_products(terra::mask(lst_mean, dem_b),
                     aree_urb, aree_ref, aoi_utm,
                     dirs$processing, season, year, b)
      lo <- lo + altitude_band_height; hi <- hi + altitude_band_height
    }

    # Mosaic
    a_files <- list.files(dirs$processing,
      pattern = glob2rx(sprintf("%s_%d_thermal_anomaly_band*.tif", season, year)),
      full.names = TRUE)
    anomaly_map <- terra::merge(terra::sprc(a_files))

    s_files <- list.files(dirs$processing,
      pattern = glob2rx(sprintf("%s_%d_SUHI_band*.tif", season, year)),
      full.names = TRUE)
    suhi_map <- terra::merge(terra::sprc(s_files))
    suhi_map[suhi_map < 0] <- 0; suhi_map[suhi_map > 1] <- 1

  } else {
    # Single band (flat terrain)
    dem2 <- dem
    dem2[dem2 > (mean_elev + altitude_band_height / 2)] <- NA
    dem2[dem2 < (mean_elev - altitude_band_height / 2)] <- NA
    res  <- .band_products(terra::mask(lst_mean, dem2),
                            aree_urb, aree_ref, aoi_utm,
                            dirs$processing, season, year, 1)
    anomaly_map <- res$anomaly
    suhi_map    <- res$suhi
    file.copy(
      file.path(dirs$processing, sprintf("%s_%d_thermal_anomaly_band1.tif", season, year)),
      file.path(dirs$output,     sprintf("%s_%d_thermal_anomaly.tif", season, year)),
      overwrite = TRUE)
    file.copy(
      file.path(dirs$processing, sprintf("%s_%d_SUHI_band1.tif", season, year)),
      file.path(dirs$output,     sprintf("%s_%d_SUHI.tif", season, year)),
      overwrite = TRUE)
  }

  # Save final outputs
  terra::writeRaster(anomaly_map,
    file.path(dirs$output, sprintf("%s_%d_thermal_anomaly.tif", season, year)),
    overwrite = TRUE,
    wopt = list(filetype="GTiff", datatype="FLT4S", NAflag=-9999, gdal="COMPRESS=LZW"))
  terra::writeRaster(suhi_map,
    file.path(dirs$output, sprintf("%s_%d_SUHI.tif", season, year)),
    overwrite = TRUE,
    wopt = list(filetype="GTiff", datatype="FLT4S", NAflag=-9999, gdal="COMPRESS=LZW"))

  write_metadata(anomaly_map,
    title       = sprintf("Thermal anomaly — %s %d", season, year),
    description = sprintf("LST deviation from rural reference (°C), %s %d", season, year),
    keywords    = c("UHI","thermal anomaly","LST","Landsat"),
    out_path    = file.path(dirs$output,
                    sprintf("%s_%d_thermal_anomaly_metadata.json", season, year)),
    raster_path = file.path(dirs$output,
                    sprintf("%s_%d_thermal_anomaly.tif", season, year)))
  write_metadata(suhi_map,
    title       = sprintf("SUHII — %s %d", season, year),
    description = sprintf("Surface Urban Heat Island Intensity index (0–1), %s %d", season, year),
    keywords    = c("SUHII","UHI","LST","Landsat"),
    out_path    = file.path(dirs$output,
                    sprintf("%s_%d_SUHI_metadata.json", season, year)),
    raster_path = file.path(dirs$output,
                    sprintf("%s_%d_SUHI.tif", season, year)))

  # Interactive previews
  pal_a <- leaflet::colorNumeric("Spectral",
    domain = c(terra::minmax(anomaly_map)[1], terra::minmax(anomaly_map)[2]),
    reverse = TRUE, na.color = "transparent")
  leaflet::leaflet() |> leaflet::addTiles() |>
    leaflet::addRasterImage(terra::project(anomaly_map, "EPSG:4326"),
                            colors = pal_a, opacity = 0.8) |>
    leaflet::addLegend("bottomright", pal = pal_a,
      values = c(terra::minmax(anomaly_map)[1], terra::minmax(anomaly_map)[2]),
      title = "Thermal anomaly (°C)") |> print()

  pal_s <- leaflet::colorNumeric("Spectral", domain = c(0,1),
                                  reverse = TRUE, na.color = "transparent")
  leaflet::leaflet() |> leaflet::addTiles() |>
    leaflet::addRasterImage(terra::project(suhi_map, "EPSG:4326"),
                            colors = pal_s, opacity = 0.8) |>
    leaflet::addLegend("bottomright", pal = pal_s, values = c(0,1),
                       title = "SUHII index") |> print()

  cli::cli_alert_success("SUHII analysis complete.")
  list(anomaly_map = anomaly_map, suhi_map = suhi_map,
       aoi_utm = aoi_utm, aree_urb = aree_urb, aree_ref = aree_ref)
}


#' Compute distance from green areas (3-30-300 rule)
#'
#' @param aoi_utm   SpatVector of AOI in LST raster CRS
#' @param lst_mean  SpatRaster (used as reference grid)
#' @param city_slug City slug string
#' @param dirs      Project directories
#' @param year      Integer year
#' @param season    "warm" or "cold"
compute_green_distance <- function(aoi_utm, lst_mean, city_slug,
                                    dirs, year, season, edge_buffer_m = 1000) {

  cli::cli_h2("Green area distance (3-30-300 rule)")

  green_raw <- terra::vect(file.path(dirs$input, "rural_areas.shp"))
  cli::cli_alert_info("rural_areas.shp: {length(green_raw)} raw feature(s), {round(sum(terra::expanse(green_raw))/1e4, 1)} ha total")

  green_vect <- green_raw |> terra::aggregate() |> terra::project(lst_mean)

  if (length(green_vect) == 0) {
    cli::cli_alert_warning("rural_areas.shp is empty — distance map skipped.")
    return(invisible(NULL))
  }

  # Rasterize + compute distance on a BUFFERED template, not on lst_mean's
  # tight extent. lst_mean is already cropped to the administrative
  # boundary's bounding box, so any green polygon just outside that line
  # (extremely common at town edges) is invisible to terra::distance() if
  # we rasterize straight onto it — edge pixels then get an artificially
  # inflated distance even when real green space is a few dozen metres
  # away, just across the AOI line. We buffer the grid, run the distance
  # calculation on that, and only crop/mask down to the AOI at the end.
  buffered_ext <- terra::ext(lst_mean) + edge_buffer_m
  template     <- terra::rast(buffered_ext, resolution = terra::res(lst_mean),
                               crs = terra::crs(lst_mean))

  green_rast      <- terra::rasterize(green_vect, template, field = 1, background = NA)
  distance_full   <- terra::distance(green_rast)
  distance_raster <- terra::crop(distance_full, lst_mean) |> terra::mask(aoi_utm)
  distance_raster[distance_raster < 300] <- NA

  cli::cli_alert_info("green cells rasterized: {sum(!is.na(terra::values(green_rast)))} / {terra::ncell(green_rast)} template cells")
  cli::cli_alert_info("distance_raster range (pre-legend): {paste(round(range(terra::values(distance_raster, na.rm = TRUE))), collapse = ' - ')} m")

  dist_path <- file.path(dirs$output,
    sprintf("%s_%d_distance_green_areas.tif", season, year))
  terra::writeRaster(distance_raster, dist_path, overwrite = TRUE,
    wopt = list(filetype="GTiff", datatype="INT2S", NAflag=-9999, gdal="COMPRESS=LZW"))

  write_metadata(distance_raster,
    title       = sprintf("Distance from green areas — %d", year),
    description = paste0("Distance (m) to nearest green area; NA = within 300 m ",
                         "(3-30-300 rule, Konijnendijk 2022)"),
    keywords    = c("green areas","3-30-300","distance","raster"),
    out_path    = file.path(dirs$output,
                    sprintf("%s_%d_GUA_distance_metadata.json", season, year)),
    raster_path = dist_path)

  max_d   <- as.integer(terra::global(distance_raster, "max", na.rm = TRUE))
  pal_d   <- leaflet::colorNumeric("YlOrRd", domain = c(300, max_d),
                                    na.color = "transparent")
  leaflet::leaflet() |> leaflet::addTiles() |>
    leaflet::addRasterImage(terra::project(distance_raster, "EPSG:4326"),
                            colors = pal_d, opacity = 0.8) |>
    leaflet::addLegend("bottomright", pal = pal_d, values = c(300L, max_d),
                       title = "Distance from green (m)") |> print()

  cli::cli_alert_success("Distance raster saved. Max: {max_d} m from green areas.")
  invisible(dist_path)
}
