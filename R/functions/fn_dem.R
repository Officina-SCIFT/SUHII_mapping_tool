# =============================================================================
# fn_dem.R — Digital Elevation Model download
# =============================================================================
#
# Provides download_dem(), which downloads SRTM GL1 (~30 m) via elevatr.
# The file is cached: if it already exists on disk it is not re-downloaded.
#
# Returns: absolute path to the saved DEM GeoTIFF (string).
# =============================================================================


#' Download SRTM GL1 DEM via OpenTopography / elevatr
#'
#' @param aoi       SpatVector of the study area boundary
#' @param city_slug City name with underscores
#' @param ot_key    OpenTopography API key string
#' @param dirs      Project directories from setup()
#'
#' @return Absolute path to <city_slug>_DEM.tif
download_dem <- function(aoi, city_slug, ot_key, dirs) {

  cli::cli_h2("DEM download")

  dem_path <- file.path(dirs$input, paste0(city_slug, "_DEM.tif"))

  if (file.exists(dem_path)) {
    cli::cli_alert_info("DEM already on disk: {basename(dem_path)} — skipped.")
    return(dem_path)
  }

  cli::cli_alert_info("Downloading SRTM GL1 (~30 m)...")

  # Validate key
  if (is.null(ot_key) || !nzchar(trimws(ot_key))) {
    cli::cli_abort(c(
      "OpenTopography API key is missing.",
      "i" = "Check that config/credentials.yml is mounted correctly in Docker.",
      "i" = "Key value received: '{ot_key}'"
    ))
  }

  # Set the key both ways — elevatr uses whichever it finds first
  Sys.setenv(OPENTOPO_KEY = ot_key)
  elevatr::set_opentopo_key(ot_key)

  # elevatr requires an sf object and a CRS from sp::CRS (via data(lake))
  data(lake)
  aoi_sf <- aoi |> terra::project(lake) |> tidyterra::as_sf()

  dem <- elevatr::get_elev_raster(
    locations = aoi_sf,
    src       = "gl1",     # SRTM GL1, ~30 m global
    expand    = 5000        # 5 km buffer to avoid edge effects
  )

  terra::writeRaster(
    dem, dem_path, overwrite = TRUE,
    wopt = list(filetype = "GTiff", datatype = "FLT4S",
                NAflag = -9999, gdal = "COMPRESS=LZW")
  )

  cli::cli_alert_success(
    "DEM saved: {basename(dem_path)}  (resolution: {round(terra::xres(dem), 4)} deg)"
  )
  rm(dem, aoi_sf)
  dem_path
}
