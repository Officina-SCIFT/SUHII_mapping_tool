# =============================================================================
# fn_osm.R — OpenStreetMap data download
# =============================================================================
#
# Provides download_osm(), which downloads the administrative boundary,
# rural reference areas, and urban areas for a city from OpenStreetMap.
#
# Download strategy — identical to the original R workflow:
#   Method 1 — osmdata (opq + osmdata_sf):
#     Queries the Overpass API using the bounding box. Lightweight — downloads
#     only the features needed for the study area. Works for any city worldwide.
#   Method 2 — httr + raw OverpassQL (automatic fallback):
#     Used when osmdata times out (large cities). Sends the same query directly
#     via HTTP POST with explicit timeout and retry logic.
#
# Both methods query Overpass API — no large .pbf downloads, no Geofabrik,
# no interactive prompts, no file size issues.
#
# Returns a named list:
#   $aoi    : SpatVector of the municipal boundary (or bbox fallback)
#   $aoi_bb : bounding box matrix (same as input, returned for convenience)
# =============================================================================


# ── Internal helpers ──────────────────────────────────────────────────────────

# osmdata query: uses opq() + add_osm_feature() + osmdata_sf()
# Identical to the original SUHI_mapping.R workflow.
.osmdata_query <- function(aoi_bb, key, value = NULL, timeout = 180) {
  tryCatch({
    bb_vec <- c(aoi_bb["x","min"], aoi_bb["y","min"],
                aoi_bb["x","max"], aoi_bb["y","max"])
    q <- osmdata::opq(bb_vec, timeout = timeout)
    if (!is.null(value)) {
      q <- osmdata::add_osm_feature(q, key, value = value)
    } else {
      q <- osmdata::add_osm_feature(q, key)
    }
    res <- osmdata::osmdata_sf(q)
    # Return merged polygons + multipolygons
    parts <- list()
    if (!is.null(res$osm_polygons)      && nrow(res$osm_polygons)      > 0)
      parts[[length(parts)+1]] <- res$osm_polygons
    if (!is.null(res$osm_multipolygons) && nrow(res$osm_multipolygons) > 0)
      parts[[length(parts)+1]] <- res$osm_multipolygons
    if (length(parts) == 0) return(NULL)
    dplyr::bind_rows(parts) |> sf::st_sf()
  }, error = function(e) {
    cli::cli_alert_warning("osmdata failed ({key}): {e$message}")
    NULL
  })
}

# httr fallback: raw OverpassQL POST with retry
# httr fallback: raw OverpassQL POST with retry across multiple servers
.overpass_query <- function(aoi_bb, ql, timeout_s = 180, max_retry = 3) {
  # Multiple Overpass endpoints — if one is rate-limiting, try the next.
  servers <- c(
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter"
  )
  bbox_str <- sprintf("%.6f,%.6f,%.6f,%.6f",
    aoi_bb["y","min"], aoi_bb["x","min"],
    aoi_bb["y","max"], aoi_bb["x","max"])
  query <- gsub("{{bbox}}", bbox_str, ql, fixed = TRUE)

  for (attempt in seq_len(max_retry)) {
    # Rotate through servers on each attempt
    url <- servers[((attempt - 1) %% length(servers)) + 1]
    resp <- tryCatch(
      httr::POST(url,
        httr::add_headers("User-Agent" = "SUHII_mapping/1.0 (heat island research)"),
        httr::timeout(timeout_s),
        body = list(data = query), encode = "form"),
      error = function(e) NULL
    )
    if (!is.null(resp) && httr::status_code(resp) == 200) {
      tmp <- tempfile(fileext = ".osm")
      writeBin(httr::content(resp, "raw"), tmp)
      gdf <- tryCatch(
        sf::read_sf(tmp, layer = "multipolygons", quiet = TRUE),
        error = function(e) NULL)
      unlink(tmp)
      if (!is.null(gdf) && nrow(gdf) > 0) return(gdf)
      # Empty result is valid (no features of this type) — return empty
      if (!is.null(gdf)) return(gdf)
    }
    if (attempt < max_retry) {
      cli::cli_alert_warning("Overpass attempt {attempt}/{max_retry} failed, trying next server in 10s...")
      Sys.sleep(10)
    }
  }
  cli::cli_alert_warning("All Overpass attempts failed for this feature.")
  NULL
}

# Download one feature category: httr first (full control), osmdata fallback
.download_feature <- function(label, aoi_bb,
                               key = NULL, value = NULL,
                               overpass_ql,
                               out_path) {
  # Skip if already cached on disk
  if (file.exists(out_path) && file.size(out_path) > 100) {
    cli::cli_alert_info("{label}: using cached file")
    return(invisible(NULL))
  }

  # Pause between queries to respect Overpass API rate limits
  Sys.sleep(8)

  cli::cli_alert_info("Downloading: {label}")

  # httr + raw OverpassQL across multiple servers (no osmdata fallback —
  # the osmdata internal retry backoff can hang for many minutes on large cities).
  # 300s timeout for the large combined rural/urban queries.
  gdf <- .overpass_query(aoi_bb, overpass_ql, timeout_s = 300, max_retry = 3)

  if (!is.null(gdf) && nrow(gdf) > 0) {
    cli::cli_alert_success("Overpass: {nrow(gdf)} features")
  } else {
    cli::cli_alert_warning("No features retrieved for {label} (saved empty).")
  }

  save_polygons(gdf, out_path)
}


# ── Main function ─────────────────────────────────────────────────────────────

#' Download OSM boundary, rural and urban areas
#'
#' Uses osmdata (identical to original workflow) with httr fallback.
#' No Geofabrik downloads, no large .pbf files, no interactive prompts.
#'
#' @param city_name  Original city name string (with spaces)
#' @param aoi_bb     Bounding box matrix from osmdata::getbb()
#' @param dirs       Named list of project directories from setup()
#'
#' @return Named list: $aoi (SpatVector), $aoi_bb (matrix)
download_osm <- function(city_name, aoi_bb, dirs) {

  cli::cli_h2("OSM data download")

  # ── Administrative boundary ───────────────────────────────────────────────
  # Strategy identical to original SUHI_mapping.R:
  #   Try admin_level 8 → 7 → 6, filtering by name in R after download.
  #   Fallback to bounding box if no boundary is found.
  bound_path <- file.path(dirs$input, "boundaries.shp")

  if (file.exists(bound_path) && file.size(bound_path) > 100) {
    cli::cli_alert_info("Administrative boundary: using cached boundaries.shp")
    aoi <- terra::vect(bound_path)
  } else {

    aoi_sf <- NULL

    for (lvl in c("8", "7", "6")) {
      cli::cli_alert_info("Trying admin_level {lvl} for '{city_name}'...")

      # httr + raw OverpassQL across multiple servers (no osmdata fallback)
      nome <- gsub("_", " ", city_name)
      ql <- sprintf(
        '[out:xml][timeout:120];
         relation["admin_level"="%s"]["name"~"%s",i]({{bbox}});
         out geom;', lvl, nome)
      gdf <- .overpass_query(aoi_bb, ql, timeout_s = 120, max_retry = 3)

      if (!is.null(gdf) && nrow(gdf) > 0) {
        cli::cli_alert_success("Boundary found at admin_level {lvl} ({nrow(gdf)} polygon(s))")
        aoi_sf <- gdf
        break
      }
    }

    # Fallback: bounding box (same as original)
    if (is.null(aoi_sf) || nrow(aoi_sf) == 0) {
      cli::cli_alert_warning("No boundary found — using bounding box as fallback.")
      aoi <- terra::vect(
        rbind(c(aoi_bb["x","min"], aoi_bb["y","min"]),
              c(aoi_bb["x","min"], aoi_bb["y","max"]),
              c(aoi_bb["x","max"], aoi_bb["y","max"]),
              c(aoi_bb["x","max"], aoi_bb["y","min"]),
              c(aoi_bb["x","min"], aoi_bb["y","min"])),
        type = "polygons", crs = "EPSG:4326")
    } else {
      aoi <- terra::vect(aoi_sf)
    }

    terra::writeVector(aoi, bound_path,
      filetype = "ESRI Shapefile", overwrite = TRUE, options = "ENCODING=UTF-8")
    cli::cli_alert_success("Saved: boundaries.shp")
  }

  # ── Rural / reference areas — SINGLE combined query ───────────────────────
  # One Overpass query with all green/natural/agricultural tags in OR.
  # Far faster than separate queries: 1 round-trip instead of 3, much less
  # rate-limiting on large cities.
  cli::cli_h3("Rural / reference areas")

  .download_feature("rural areas (combined)", aoi_bb,
    key = NULL, value = NULL,
    overpass_ql = '[out:xml][timeout:300];
      (
        way["natural"~"^(fell|grassland|heath|moor|scrub|shrubbery|tree|tree_row|tree_stump|tundra|wood)$"]({{bbox}});
        relation["natural"~"^(fell|grassland|heath|moor|scrub|shrubbery|tree|tree_row|tree_stump|tundra|wood)$"]({{bbox}});
        way["landuse"~"^(farmland|farmyard|paddy|animal_keeping|flowerbed|forest|meadow|orchard|grass)$"]({{bbox}});
        relation["landuse"~"^(farmland|farmyard|paddy|animal_keeping|flowerbed|forest|meadow|orchard|grass)$"]({{bbox}});
        way["leisure"~"^(garden|golf_course|nature_reserve|park)$"]({{bbox}});
        relation["leisure"~"^(garden|golf_course|nature_reserve|park)$"]({{bbox}});
      );
      out geom;',
    out_path = file.path(dirs$input, "rural_areas.shp"))

  # ── Urban / built-up areas — SINGLE combined query ────────────────────────
  # All built-up tags in OR. highway limited to area=yes (squares, pedestrian
  # zones) — line highways are excluded as they contribute little to urban area
  # and make the query enormous on large cities.
  cli::cli_h3("Urban / built-up areas")

  .download_feature("urban areas (combined)", aoi_bb,
    key = NULL, value = NULL,
    overpass_ql = '[out:xml][timeout:300];
      (
        way["landuse"~"^(commercial|construction|education|fairground|industrial|residential|retail|institutional|railway|aerodrome|landfill|port|depot|quarry|military)$"]({{bbox}});
        relation["landuse"~"^(commercial|construction|education|fairground|industrial|residential|retail|institutional|railway|aerodrome|landfill|port|depot|quarry|military)$"]({{bbox}});
        way["amenity"]({{bbox}});
        relation["amenity"]({{bbox}});
        way["tourism"]({{bbox}});
        relation["tourism"]({{bbox}});
        way["leisure"~"^(adult_gaming_centre|amusement_arcade|bandstand|beach_resort|bleachers|bowling_alley|common|dance|disc_golf_course|fitness_centre|fitness_station|hackerspace|ice_rink|marina|miniature_golf|outdoor_seating|playground|resort|sauna|slipway|sports_centre|sport_hall|stadium|summer_camp|swimming_pool|tanning_salon|track|trampoline_park|water_park)$"]({{bbox}});
        relation["leisure"~"^(adult_gaming_centre|amusement_arcade|bandstand|beach_resort|bleachers|bowling_alley|common|dance|disc_golf_course|fitness_centre|fitness_station|hackerspace|ice_rink|marina|miniature_golf|outdoor_seating|playground|resort|sauna|slipway|sports_centre|sport_hall|stadium|summer_camp|swimming_pool|tanning_salon|track|trampoline_park|water_park)$"]({{bbox}});
        way["aeroway"~"^(aerodrome|apron|gate|hangar|spaceport|helipad|runway|taxiway|terminal)$"]({{bbox}});
        relation["aeroway"~"^(aerodrome|apron|gate|hangar|spaceport|helipad|runway|taxiway|terminal)$"]({{bbox}});
        way["highway"]["area"="yes"]({{bbox}});
        relation["highway"]["area"="yes"]({{bbox}});
      );
      out geom;',
    out_path = file.path(dirs$input, "urban_areas_raw.shp"))

  # Dissolve/aggregate the urban polygons
  if (file.exists(file.path(dirs$input, "urban_areas_raw.shp"))) {
    urb_raw <- tryCatch(sf::read_sf(file.path(dirs$input, "urban_areas_raw.shp")),
                        error = function(e) NULL)
    if (!is.null(urb_raw) && nrow(urb_raw) > 0) {
      urb_v <- terra::vect(urb_raw) |> terra::aggregate() |> terra::makeValid()
      terra::writeVector(urb_v, file.path(dirs$input, "urban_areas.shp"),
        filetype = "ESRI Shapefile", overwrite = TRUE, options = "ENCODING=UTF-8")
    }
    # Remove the raw intermediate
    for (ext in c(".shp",".shx",".dbf",".prj",".cpg")) {
      f <- file.path(dirs$input, paste0("urban_areas_raw", ext))
      if (file.exists(f)) file.remove(f)
    }
  }

  cli::cli_alert_success("OSM download complete.")
  list(aoi = aoi, aoi_bb = aoi_bb)
}
