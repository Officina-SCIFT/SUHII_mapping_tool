# =============================================================================
# fn_utils.R — Setup, validation, and shared helpers
# =============================================================================


# -----------------------------------------------------------------------------
# setup()
# Validates all user inputs, loads credentials, resolves the bounding box,
# creates the folder structure, and returns a single config list used by
# all downstream functions.
#
# Args:
#   city, working_dir, season, max_cloud, altitude_band_height : user params
#   credentials_file : path to credentials.yml
#   project_root     : resolved by run.R before sourcing this file
#
# Returns: named list with all config values needed by downstream functions.
# -----------------------------------------------------------------------------
setup <- function(city, working_dir, season, max_cloud,
                  altitude_band_height, credentials_file, project_root) {

  cli::cli_h1("SUHII Mapping — Setup")

  # ── Validate season ────────────────────────────────────────────────────────
  if (!season %in% c("warm", "cold")) {
    cli::cli_abort("SEASON must be 'warm' or 'cold', got: {season}")
  }

  # ── Validate max_cloud ─────────────────────────────────────────────────────
  if (!is.numeric(max_cloud) || max_cloud < 0 || max_cloud > 100) {
    cli::cli_abort("MAX_CLOUD must be a number between 0 and 100.")
  }

  # ── Credentials ───────────────────────────────────────────────────────────
  if (!file.exists(credentials_file)) {
    cli::cli_abort(c(
      "Credentials file not found: {credentials_file}",
      "i" = "Copy config/credentials.yml.example to config/credentials.yml",
      "i" = "Fill in your free OpenTopography API key from https://opentopography.org/"
    ))
  }
  creds  <- yaml::read_yaml(credentials_file)
  ot_key <- creds$opentopography$api_key
  if (is.null(ot_key) || !nzchar(trimws(ot_key)) ||
      ot_key == "YOUR_OPENTOPOGRAPHY_API_KEY") {
    cli::cli_abort(c(
      "OpenTopography API key is missing or still set to the placeholder.",
      "i" = "Register for free at https://opentopography.org/",
      "i" = "Add the key to: {credentials_file}"
    ))
  }

  # ── Bounding box via Nominatim ─────────────────────────────────────────────
  # NOT using osmdata::getbb()'s featuretype filter: internally osmdata sends
  # the query parameter as "featuretype" (lowercase), but Nominatim's API
  # expects the case-sensitive "featureType" (capital T) and silently ignores
  # the filter when the case doesn't match, falling back to unrestricted
  # ranking. This let a same-named province ("Provincia di Cuneo") outrank
  # the city even when featuretype = "city" was passed to getbb() — the
  # filter never reached Nominatim correctly. Querying Nominatim directly
  # sidesteps the bug entirely.
  cli::cli_alert_info("Resolving bounding box for '{city}'...")

  # Among same-named candidates (e.g. "Cuneo" the comune vs "Provincia di
  # Cuneo"), the city/comune footprint is always smaller than a same-named
  # province/region's — picking the smallest candidate is a robust,
  # filter-independent disambiguation, not reliant on Nominatim's featureType
  # (which even when correctly cased can behave surprisingly on OSM data;
  # see https://github.com/osm-search/Nominatim/discussions/3161).
  .geocode_city_bbox <- function(city) {
    resp <- tryCatch(
      httr::GET("https://nominatim.openstreetmap.org/search",
        query = list(q = city, format = "jsonv2", addressdetails = 1, limit = 10),
        httr::add_headers("User-Agent" = "SUHII_mapping/1.0 (heat island research)"),
        httr::timeout(30)),
      error = function(e) NULL)

    if (is.null(resp) || httr::status_code(resp) != 200) return(NULL)

    results <- tryCatch(
      jsonlite::fromJSON(httr::content(resp, "text", encoding = "UTF-8"),
                          simplifyDataFrame = TRUE),
      error = function(e) NULL)

    if (is.null(results) || !is.data.frame(results) || nrow(results) == 0) return(NULL)

    # Prefer settlement-type matches when present; otherwise keep every
    # candidate Nominatim returned (covers small places OSM tags loosely).
    addresstype <- results$addresstype %||% rep(NA_character_, nrow(results))
    is_settlement <- addresstype %in% c("city", "town", "village", "municipality", "hamlet")
    candidates <- if (any(is_settlement, na.rm = TRUE)) results[is_settlement, ] else results
    if (nrow(candidates) == 0) return(NULL)

    # Nominatim boundingbox order: [south, north, west, east] (strings)
    bbn   <- lapply(candidates$boundingbox, as.numeric)
    areas <- vapply(bbn, function(b) {
      lat_km <- abs(b[2] - b[1]) * 110.57
      lon_km <- abs(b[4] - b[3]) * 111.32 * cos(mean(b[1:2]) * pi / 180)
      lat_km * lon_km
    }, numeric(1))

    b <- bbn[[which.min(areas)]]
    matrix(c(b[3], b[4], b[1], b[2]), nrow = 2, byrow = TRUE,
           dimnames = list(c("x","y"), c("min","max")))
  }

  aoi_bb <- tryCatch(.geocode_city_bbox(city), error = function(e) NULL)

  if (is.null(aoi_bb) || !all(is.finite(aoi_bb))) {
    cli::cli_abort(c(
      "Cannot geocode: '{city}'",
      "i" = "Check the name matches its OpenStreetMap entry.",
      "i" = "For small municipalities try adding the province, e.g. 'Trofarello, Torino'",
      "i" = "Verify at: https://nominatim.openstreetmap.org/?q={utils::URLencode(city)}"
    ))
  }

  cli::cli_alert_success(
    "Bounding box: lon [{round(aoi_bb['x','min'],4)}, {round(aoi_bb['x','max'],4)}]  \\
     lat [{round(aoi_bb['y','min'],4)}, {round(aoi_bb['y','max'],4)}]"
  )

  # Rough plausibility check on the RECTANGULAR bbox (not the true polygon
  # area — that isn't known yet at this point) so a geocoding mismatch is
  # caught here, before any download starts, instead of ~1h20 into OSM/
  # Landsat downloads. A real municipality's bbox rarely exceeds ~1500 km²;
  # provinces/regions with a same-sounding name routinely do.
  lon_km <- (aoi_bb["x","max"] - aoi_bb["x","min"]) * 111.32 *
              cos(mean(aoi_bb["y",]) * pi / 180)
  lat_km <- (aoi_bb["y","max"] - aoi_bb["y","min"]) * 110.57
  bbox_area_km2 <- lon_km * lat_km
  if (is.finite(bbox_area_km2) && bbox_area_km2 > 1500) {
    cli::cli_alert_warning(c(
      "Bounding box area is ~{round(bbox_area_km2)} km\u00b2 \u2014 unusually large for a single municipality.",
      "i" = "Nominatim may have matched a province/region with the same name instead of the city.",
      "i" = "Verify at: https://nominatim.openstreetmap.org/?q={utils::URLencode(city)}"
    ))
  }

  # City slug: replace spaces with underscores for safe file/folder names
  # e.g. "Los Angeles" → "Los_Angeles", "São Paulo" → "São_Paulo"
  city_slug <- gsub(" ", "_", city)

  # ── Working directory writable? ────────────────────────────────────────────
  if (!dir.exists(working_dir)) {
    tryCatch(
      dir.create(working_dir, recursive = TRUE),
      error = function(e) cli::cli_abort(
        "Cannot create WORKING_DIR: {working_dir}\n{e$message}"
      )
    )
  }
  test_file <- file.path(working_dir, ".write_test")
  tryCatch({
    writeLines("ok", test_file)
    file.remove(test_file)
  }, error = function(e) {
    cli::cli_abort("WORKING_DIR is not writable: {working_dir}")
  })

  # ── Folder structure ───────────────────────────────────────────────────────
  dirs <- list(
    root       = file.path(working_dir, city_slug),
    input      = file.path(working_dir, city_slug, "Input"),
    landsat    = file.path(working_dir, city_slug, "Input", "Landsat"),
    output     = file.path(working_dir, city_slug, "Output"),
    processing = file.path(working_dir, city_slug, "Processing"),
    pbf_cache  = file.path(working_dir, city_slug, "Input", "pbf_cache")
  )
  for (d in dirs) dir.create(d, showWarnings = FALSE, recursive = TRUE)

  cli::cli_alert_success("Folder structure ready: {dirs$root}")

  # ── Summary ───────────────────────────────────────────────────────────────
  cli::cli_bullets(c(
    "*" = "City           : {city}",
    "*" = "Season         : {season}",
    "*" = "Max cloud      : {max_cloud}%",
    "*" = "Altitude band  : {altitude_band_height} m",
    "*" = "Working dir    : {working_dir}"
  ))

  list(
    city_name            = city,
    city_slug            = city_slug,
    aoi_bb               = aoi_bb,
    dirs                 = dirs,
    ot_key               = ot_key,
    season               = season,
    max_cloud            = max_cloud,
    altitude_band_height = altitude_band_height,
    project_root         = project_root
  )
}


# -----------------------------------------------------------------------------
# write_metadata()
# Writes metadata BOTH as GDAL tags embedded in the GeoTIFF (visible via
# gdalinfo) AND as a JSON sidecar file. The embedded tags travel with the
# raster so the provenance is never lost.
# -----------------------------------------------------------------------------
write_metadata <- function(raster_obj, title, description, keywords, out_path,
                           raster_path = NULL) {
  rs   <- terra::crs(raster_obj, proj = TRUE, describe = TRUE, parse = TRUE)
  info <- list(
    title         = title,
    description   = description,
    keywords      = keywords,
    format        = "GeoTIFF",
    crs           = paste0(rs$name, ", ", rs$authority, ":", rs$code),
    extent        = as.list(terra::ext(raster_obj)),
    resolution    = terra::res(raster_obj),
    ncol          = terra::ncol(raster_obj),
    nrow          = terra::nrow(raster_obj),
    nbands        = terra::nlyr(raster_obj),
    values_range  = terra::minmax(raster_obj),
    creation_date = as.character(Sys.Date()),
    author        = "Officina SCIFT",
    license       = "GNU General Public License v3.0",
    url           = "https://municipiozero.it/scift/",
    DOI           = "https://doi.org/10.1016/j.susgeo.2025.100006"
  )
  # JSON sidecar (human-readable, kept for backward compatibility)
  write(jsonlite::toJSON(info, pretty = TRUE), file = out_path)

  # Embed the same info as GDAL metadata tags inside the GeoTIFF, so that
  # `gdalinfo <file>.tif` shows them under the "Metadata:" section.
  if (!is.null(raster_path) && file.exists(raster_path)) {
    embed_metadata(raster_path, info)
  }
}


# -----------------------------------------------------------------------------
# embed_metadata()
# Re-opens a GeoTIFF and writes key/value GDAL metadata tags into it.
# These are visible with `gdalinfo file.tif` under "Metadata:".
# -----------------------------------------------------------------------------
embed_metadata <- function(raster_path, info) {
  tryCatch({
    r <- terra::rast(raster_path)

    # Flatten the info list into character key=value pairs.
    # GDAL tags must be simple strings, so collapse vectors/lists.
    flatten <- function(x) {
      if (is.list(x)) {
        paste(vapply(x, function(e) paste(as.character(e), collapse = ","),
                     character(1)), collapse = "; ")
      } else {
        paste(as.character(x), collapse = ", ")
      }
    }

    tags <- c(
      TIFFTAG_DOCUMENTNAME    = info$title,
      TIFFTAG_IMAGEDESCRIPTION = info$description,
      TIFFTAG_DATETIME        = info$creation_date,
      SUHII_TITLE             = info$title,
      SUHII_DESCRIPTION       = info$description,
      SUHII_KEYWORDS          = flatten(info$keywords),
      SUHII_CRS               = info$crs,
      SUHII_VALUES_RANGE      = flatten(info$values_range),
      SUHII_CREATION_DATE     = info$creation_date,
      SUHII_AUTHOR            = info$author,
      SUHII_LICENSE           = info$license,
      SUHII_URL               = info$url,
      SUHII_DOI               = info$DOI
    )

    terra::metags(r) <- tags

    # Rewrite the file in place with the embedded tags
    tmp <- paste0(tools::file_path_sans_ext(raster_path), "_meta.tif")
    terra::writeRaster(r, tmp, overwrite = TRUE,
      wopt = list(filetype = "GTiff", gdal = "COMPRESS=LZW"))
    file.rename(tmp, raster_path)
  }, error = function(e) {
    cli::cli_alert_warning("Could not embed metadata in {basename(raster_path)}: {e$message}")
  })
}


# -----------------------------------------------------------------------------
# save_polygons()
# Filters an sf object to Polygon/MultiPolygon, validates, writes shapefile.
# -----------------------------------------------------------------------------
save_polygons <- function(sf_obj, out_path) {
  if (is.null(sf_obj) || nrow(sf_obj) == 0) return(invisible(NULL))
  geom_types <- sf::st_geometry_type(sf_obj)
  sf_obj     <- sf_obj[geom_types %in% c("POLYGON", "MULTIPOLYGON"), ]
  if (nrow(sf_obj) == 0) return(invisible(NULL))
  sf_obj <- sf::st_make_valid(sf_obj)
  sf_obj <- sf_obj[!sf::st_is_empty(sf_obj), ]
  if (nrow(sf_obj) == 0) return(invisible(NULL))
  sf::write_sf(sf_obj["geometry"], out_path,
               driver = "ESRI Shapefile", delete_layer = TRUE)
  cli::cli_alert_success("Saved: {basename(out_path)} ({nrow(sf_obj)} features)")
}


# -----------------------------------------------------------------------------
# merge_shapefiles()
# Merges a list of shapefiles matched by a glob pattern into one file.
# Returns the merged sf invisibly.
# -----------------------------------------------------------------------------
merge_shapefiles <- function(files, output_dir, out_name) {
  files <- files[file.exists(files)]
  if (length(files) == 0) {
    cli::cli_alert_warning("No files to merge for {out_name}")
    return(invisible(NULL))
  }
  sf_list <- lapply(files, function(f) tryCatch(sf::read_sf(f), error = function(e) NULL))
  sf_list <- Filter(function(x) !is.null(x) && nrow(x) > 0, sf_list)
  if (length(sf_list) == 0) return(invisible(NULL))
  merged   <- dplyr::bind_rows(sf_list) |> sf::st_sf() |> sf::st_make_valid()
  out_path <- file.path(output_dir, out_name)
  sf::write_sf(merged["geometry"], out_path,
               driver = "ESRI Shapefile", delete_layer = TRUE)
  cli::cli_alert_success("Merged: {out_name} ({nrow(merged)} features)")
  invisible(merged)
}


# -----------------------------------------------------------------------------
# %||%  null-coalescing operator
# -----------------------------------------------------------------------------
`%||%` <- function(a, b) if (!is.null(a) && length(a) > 0 && !is.na(a[1])) a else b
