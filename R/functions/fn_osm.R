# =============================================================================
# fn_osm.R — OpenStreetMap data download
# =============================================================================
#
# Provides download_osm(), which downloads the administrative boundary,
# rural reference areas, and urban areas for a city from OpenStreetMap.
#
# Download strategy:
#   httr + raw OverpassQL POST, rotating across 3 mirrors, with explicit
#   timeout and retry logic. No osmdata::osmdata_sf() — its internal retry
#   backoff has no timeout and can hang 600+ seconds on large cities.
#
#   Split-query strategy, three layers:
#     1. Boundary: admin_level 8/7/6 fallback, single request each, NOT
#        spatially chunked (a relation query returns all its members
#        regardless of bbox; chunking would risk clipping/duplicating it).
#     2. Per-value/per-category: rural is split per individual value (22
#        requests: natural×11 + landuse×7 + leisure×4 — landuse excludes
#        farmyard and animal_keeping: bare/hard-packed ground around farm
#        buildings and livestock pens, not vegetated cool-reference land);
#        urban stays OR-combined per category (6 requests) — see rationale
#        below.
#     3. Per-chunk: EVERY rural value and urban category query above is
#        further split into an nx*ny (default 2x2 = 4) spatial grid over the
#        AOI, mirroring split_aoi_chunks() in the original SUHI_mapping.R.
#        A chunk that fails after retries is dropped rather than failing the
#        whole value/category — partial spatial coverage beats losing it
#        entirely, matching the original script's tolerance for skipped
#        sub-AOIs.
#   Total requests: ~1 (boundary) + 28*4 (rural+urban chunks) = ~113.
#   Cost: with the mandatory 8s pacing between every individual request
#   (rate-limit safety), the fixed pacing alone is ~16 minutes before
#   counting actual download time or retries on failures. This is a
#   deliberate trade for large-city robustness, not an oversight — but it
#   means small/medium cities pay a latency cost they may not need. If this
#   becomes a problem, the nx/ny parameters (threaded through
#   .download_feature() and .download_split_category()) are the place to
#   reduce granularity, e.g. only for known-heavy tags (wood, farmland).
#
#   Rural is split per value (not just per chunk) because rural natural/
#   landuse tags (forest, wood, farmland...) can correspond to very large
#   multipolygon relations — combining several such values in one OR query
#   times out server-side because of one heavy value, not because of rate
#   limiting. Urban POI-scale tags (amenity, tourism, leisure) are mostly
#   small point/polygon features and have not shown this failure mode, so
#   they stay OR-combined per category; they still get the same spatial
#   chunking as rural.
#
# CRITICAL query format note:
#   Every query below uses `out body; >; out skel qt;` — NOT `out geom;`.
#   `out geom;` embeds coordinates inline and prevents GDAL's OSM driver from
#   assembling the `multipolygons` layer for relations. `out body; >; out
#   skel qt;` recurses down to member ways/nodes, which GDAL needs.
#
#   This also requires OSM_USE_CUSTOM_INDEXING=NO (set once per session)
#   because `qt` (quadtile) output order does not guarantee ascending node
#   IDs, which GDAL's default indexing assumes.
#
# Returns a named list:
#   $aoi    : SpatVector of the municipal boundary (or bbox fallback)
#   $aoi_bb : bounding box matrix (same as input, returned for convenience)
#
# Depends on fn_utils.R: save_polygons() and merge_shapefiles() must already
# be sourced. Category merging here is a thin wrapper around
# merge_shapefiles() rather than a re-implementation of it — see
# .merge_category_files() below.
# =============================================================================

# Must be set before any sf::read_sf() call on OSM XML output.
Sys.setenv(OSM_USE_CUSTOM_INDEXING = "NO")


# ── Internal helpers ──────────────────────────────────────────────────────────

# Builds a single-category OverpassQL query: way + relation on one key,
# optionally restricted to a set of values (regex OR) and/or an extra tag
# filter (e.g. ["area"="yes"]).
.build_category_ql <- function(key, values = NULL, extra_filter = NULL, timeout = 180) {
  if (!is.null(values)) {
    val_regex <- paste0("^(", paste(values, collapse = "|"), ")$")
    tag_filter <- sprintf('["%s"~"%s"]', key, val_regex)
  } else {
    tag_filter <- sprintf('["%s"]', key)
  }
  if (!is.null(extra_filter)) tag_filter <- paste0(tag_filter, extra_filter)

  sprintf('[out:xml][timeout:%d];
    (
      way%s({{bbox}});
      relation%s({{bbox}});
    );
    out body;
    >;
    out skel qt;', timeout, tag_filter, tag_filter)
}

# Exact single key=value match — used for rural tags instead of the
# regex-OR builder above. Rural tags (natural=wood, landuse=farmland, ...)
# correspond to large multipolygon relations; combining several of them in
# one OR-regex query times out server-side even though each individual
# value resolves quickly on its own. Urban POI-scale tags don't have this
# problem, so .build_category_ql() (combined) stays fine for those.
.build_value_ql <- function(key, value, timeout = 300) {
  sprintf('[out:xml][timeout:%d];
    (
      way["%s"="%s"]({{bbox}});
      relation["%s"="%s"]({{bbox}});
    );
    out body;
    >;
    out skel qt;', timeout, key, value, key, value)
}

# httr: raw OverpassQL POST with retry across multiple mirrors.
# Fails loudly on non-200 responses and on empty/malformed geometry.
.overpass_query <- function(aoi_bb, ql, timeout_s = 180, max_retry = 3) {
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
    url <- servers[((attempt - 1) %% length(servers)) + 1]

    resp <- tryCatch(
      httr::POST(url,
        httr::add_headers("User-Agent" = "SUHII_mapping/1.0 (heat island research)"),
        httr::timeout(timeout_s),
        body = list(data = query), encode = "form"),
      error = function(e) {
        cli::cli_alert_danger("Attempt {attempt}/{max_retry} ({url}): connection error — {e$message}")
        NULL
      }
    )

    if (is.null(resp)) {
      if (attempt < max_retry) Sys.sleep(10 * attempt)  # progressive backoff
      next
    }

    status <- httr::status_code(resp)
    if (status != 200) {
      # 429 (rate limit), 504 (query too complex/timed out at Overpass),
      # and 400 (malformed query) need different fixes — log which one.
      cli::cli_alert_danger("Attempt {attempt}/{max_retry} ({url}): HTTP {status}")
      if (attempt < max_retry) {
        # 429 specifically needs more room than a fixed 10s — a burst of
        # back-to-back requests (e.g. the admin_level 8/7/6 boundary
        # fallback loop) can trip rate-limiting that a flat backoff doesn't
        # clear before the next attempt.
        wait_s <- if (status == 429) 20 * attempt else 10 * attempt
        Sys.sleep(wait_s)
      }
      next
    }

    tmp <- tempfile(fileext = ".osm")
    writeBin(httr::content(resp, "raw"), tmp)

    # Overpass sometimes answers with HTTP 200 but an embedded <remark> tag
    # instead of real data (rate limiting, quota exceeded, internal timeout).
    # That parses as a syntactically valid but EMPTY OSM file — indistinguishable
    # from "genuinely zero features in this AOI" unless checked explicitly.
    # This is the likely reason rural categories were returning 0 features on
    # every run: they run first (right after the boundary query) and are
    # more likely to land inside a rate-limit window than categories queried
    # much later in the same session.
    body_text <- tryCatch(httr::content(resp, "text", encoding = "UTF-8"), error = function(e) "")
    if (grepl("<remark>", body_text, fixed = TRUE)) {
      remark <- regmatches(body_text,
        regexpr("(?<=<remark>).*?(?=</remark>)", body_text, perl = TRUE))
      cli::cli_alert_danger("Attempt {attempt}/{max_retry} ({url}): Overpass returned a remark instead of data — \"{remark}\"")
      unlink(tmp)
      if (attempt < max_retry) Sys.sleep(30)  # rate-limit recovery needs longer than a transient connection error
      next
    }

    gdf <- tryCatch(
      sf::read_sf(tmp, layer = "multipolygons", quiet = TRUE),
      error = function(e) {
        cli::cli_alert_danger("Attempt {attempt}/{max_retry}: failed to read multipolygons layer — {e$message}")
        NULL
      }
    )
    unlink(tmp)

    if (!is.null(gdf)) return(gdf)  # empty result is a valid outcome (no remark found)
    if (attempt < max_retry) Sys.sleep(10)
  }

  cli::cli_alert_danger("All {max_retry} Overpass attempts failed for this query — returning NULL explicitly.")
  NULL
}

# Computes a roughly square nx*ny chunk grid sized so each chunk covers
# approximately `target_km2_per_chunk`. Small AOIs (a single small comune)
# collapse to nx=ny=1 — no chunking, no wasted pacing. Large AOIs scale up,
# capped at max_dim per axis so a metropolitan-sized city doesn't explode
# the total request count (uncapped, a ~1300 km^2 city would compute to a
# 6x6 grid = 36 chunks per value/category, on top of the per-value split).
#
# Caveat, worth keeping in mind: this sizes chunks for the AOI's OWN area,
# but an Overpass timeout on one huge relation comes from THAT relation's
# geometry, which can extend far beyond the AOI — `out body; >; out skel
# qt;` fetches a matched relation's full membership regardless of chunk
# size. This heuristic helps with "many scattered small features" (the
# common case, and the one that actually scales with city size) — it does
# NOT protect a small comune bordering one enormous regional forest or park,
# since that single relation gets pulled in full the moment any chunk
# touches it.
.compute_chunk_grid <- function(aoi, target_km2_per_chunk = 50, max_dim = 3) {
  area_km2 <- tryCatch(
    sum(terra::expanse(aoi, unit = "km", transform = TRUE)),
    error = function(e) NA_real_
  )

  if (is.na(area_km2) || area_km2 <= 0) {
    cli::cli_alert_warning("Could not compute AOI area — defaulting to 2x2 chunk grid.")
    return(list(nx = 2L, ny = 2L, area_km2 = NA_real_))
  }

  n_chunks <- max(1L, ceiling(area_km2 / target_km2_per_chunk))
  side <- min(max_dim, ceiling(sqrt(n_chunks)))

  cli::cli_alert_info(
    "AOI area: {round(area_km2,1)} km\u00b2 \u2192 chunk grid {side}x{side} ({side*side} chunks per value/category)"
  )
  list(nx = side, ny = side, area_km2 = area_km2)
}

# Splits a bounding box into an nx * ny grid of sub-bboxes. Identical logic
# to split_aoi_chunks() in the original SUHI_mapping.R script.
.split_bbox_chunks <- function(aoi_bb, nx = 2, ny = 2) {
  x_min <- aoi_bb["x","min"]; x_max <- aoi_bb["x","max"]
  y_min <- aoi_bb["y","min"]; y_max <- aoi_bb["y","max"]
  x_breaks <- seq(x_min, x_max, length.out = nx + 1)
  y_breaks <- seq(y_min, y_max, length.out = ny + 1)

  chunks <- list()
  for (i in seq_len(nx)) {
    for (j in seq_len(ny)) {
      chunks[[length(chunks) + 1]] <- matrix(
        c(x_breaks[i], y_breaks[j], x_breaks[i + 1], y_breaks[j + 1]),
        nrow = 2, byrow = FALSE,
        dimnames = list(c("x","y"), c("min","max")))
    }
  }
  chunks
}

# Download one feature category to its own shapefile. Cache-aware.
#
# Splits the AOI into nx*ny spatial chunks and queries each separately, then
# combines whatever chunks succeeded. This is orthogonal to the per-value
# split done for rural categories: per-value isolates one heavy TAG from
# breaking a whole category; per-chunk isolates one heavy REGION from
# breaking a whole tag, which matters once city size grows past what worked
# for Saluggia. A chunk that fails after retries is dropped, not fatal — the
# other chunks still contribute, so partial spatial coverage beats losing
# the whole value/category outright (same tolerance as the original script's
# download_osm_feature_chunks(), which skipped failed sub-AOIs the same way).
.download_feature <- function(label, aoi_bb, overpass_ql, out_path, nx = 2, ny = 2) {
  if (file.exists(out_path) && file.size(out_path) > 100) {
    cli::cli_alert_info("{label}: using cached file")
    return(invisible(NULL))
  }

  chunks <- .split_bbox_chunks(aoi_bb, nx, ny)
  cli::cli_alert_info("Downloading: {label} ({length(chunks)} spatial chunks)")

  chunk_results <- vector("list", length(chunks))
  for (i in seq_along(chunks)) {
    Sys.sleep(8)  # respect Overpass rate limits between every individual request
    gdf_i <- .overpass_query(chunks[[i]], overpass_ql, timeout_s = 300, max_retry = 3)

    if (!is.null(gdf_i) && nrow(gdf_i) > 0) {
      cli::cli_alert_success("  {label} [chunk {i}/{length(chunks)}]: {nrow(gdf_i)} features")
      chunk_results[[i]] <- gdf_i
    } else if (!is.null(gdf_i)) {
      cli::cli_alert_info("  {label} [chunk {i}/{length(chunks)}]: 0 features")
    } else {
      cli::cli_alert_danger("  {label} [chunk {i}/{length(chunks)}]: failed after all retries")
    }
  }

  chunk_results <- Filter(Negate(is.null), chunk_results)
  if (length(chunk_results) == 0) {
    cli::cli_alert_danger("{label}: no data from any of the {length(chunks)} chunks (saved empty).")
    return(invisible(NULL))
  }

  gdf <- tryCatch(
    dplyr::bind_rows(chunk_results) |> sf::st_sf(),
    error = function(e) {
      cli::cli_alert_danger("{label}: failed to combine chunk results — {e$message}")
      NULL
    }
  )

  if (!is.null(gdf)) {
    cli::cli_alert_success("{label}: {nrow(gdf)} features from {length(chunk_results)}/{length(chunks)} chunks")
  }

  save_polygons(gdf, out_path)
}

# Deletes a set of shapefiles (all sidecar extensions). Only called after a
# successful merge — on failure the caller keeps these files on disk as the
# diagnostic evidence of which category failed.
.cleanup_category_files <- function(files) {
  exts  <- c(".shp", ".shx", ".dbf", ".prj", ".cpg")
  bases <- unique(tools::file_path_sans_ext(files))
  for (b in bases) {
    for (ext in exts) {
      f <- paste0(b, ext)
      if (file.exists(f)) file.remove(f)
    }
  }
}

# Downloads one value at a time (exact match, not OR-combined) for a given
# key, each to its own file. Used for rural categories: combining many
# values in one OR query risks one heavy value (e.g. a huge forest/farmland
# relation) timing out the entire request. Splitting isolates that risk to
# a single small query instead of failing the whole category.
.download_split_category <- function(aoi_bb, key, values, label_prefix, file_prefix, dirs,
                                      timeout = 300, nx = 2, ny = 2) {
  for (v in values) {
    ql <- sprintf(
      '[out:xml][timeout:%d];
       (
         way["%s"="%s"]({{bbox}});
         relation["%s"="%s"]({{bbox}});
       );
       out body;
       >;
       out skel qt;', timeout, key, v, key, v)

    .download_feature(sprintf("%s: %s=%s", label_prefix, key, v), aoi_bb,
      overpass_ql = ql,
      out_path = file.path(dirs$input, sprintf("%s_%s.shp", file_prefix, v)),
      nx = nx, ny = ny)
  }
}

# Prints ok/MISSING for each expected value file, and a compact count summary.
.category_status_summary <- function(dirs, file_prefix, values) {
  ok <- 0
  for (v in values) {
    fp <- file.path(dirs$input, sprintf("%s_%s.shp", file_prefix, v))
    status <- if (file.exists(fp) && file.size(fp) > 100) { ok <- ok + 1; "ok" } else "MISSING"
    cli::cli_alert_info("  {file_prefix}_{v}.shp: {status}")
  }
  cli::cli_alert_info("{file_prefix}: {ok}/{length(values)} values retrieved")
}
# Merges all shapefiles matching a prefix using the shared merge_shapefiles()
# utility from fn_utils.R (rather than duplicating that logic here), then
# deletes the per-category intermediates ONLY if the merge actually
# produced something. On failure (no files, no valid geometry, merge error)
# the intermediates are left on disk untouched — they are the only
# diagnostic evidence of which specific category failed. Deleting them
# unconditionally was a bug in an earlier version of this file.
.merge_category_files <- function(dir, prefix, out_name) {
  files <- list.files(dir, pattern = paste0("^", prefix, ".*\\.shp$"), full.names = TRUE)
  if (length(files) == 0) {
    cli::cli_alert_danger("No intermediate files found for prefix '{prefix}' — every category download failed before writing a file. Check the per-category status above.")
    return(NULL)
  }

  merged <- merge_shapefiles(files, dir, out_name)

  if (is.null(merged)) {
    cli::cli_alert_danger("Merge produced no valid output for '{prefix}' — files LEFT ON DISK for inspection: {paste(basename(files), collapse=', ')}")
    return(NULL)
  }

  .cleanup_category_files(files)
  merged
}


# ── Main function ─────────────────────────────────────────────────────────────

#' Download OSM boundary, rural and urban areas
#'
#' @param city_name  Original city name string (with spaces)
#' @param aoi_bb     Bounding box matrix from osmdata::getbb()
#' @param dirs       Named list of project directories from setup()
#'
#' @return Named list: $aoi (SpatVector), $aoi_bb (matrix)
download_osm <- function(city_name, aoi_bb, dirs) {

  cli::cli_h2("OSM data download")

  # ── Administrative boundary ───────────────────────────────────────────────
  bound_path <- file.path(dirs$input, "boundaries.shp")

  if (file.exists(bound_path) && file.size(bound_path) > 100) {
    cli::cli_alert_info("Administrative boundary: using cached boundaries.shp")
    aoi <- terra::vect(bound_path)
  } else {

    aoi_sf <- NULL
    nome <- gsub("_", " ", city_name)

    for (lvl in c("8", "7", "6")) {
      cli::cli_alert_info("Trying admin_level {lvl} for '{city_name}'...")

      # Pace out the fallback attempts themselves — three admin_level tries
      # fired back-to-back at the same mirrors is exactly the kind of burst
      # that can trip Overpass rate-limiting right before the rural queries
      # start immediately after.
      if (lvl != "8") Sys.sleep(8)

      ql <- sprintf(
        '[out:xml][timeout:120];
         relation["admin_level"="%s"]["name"~"%s",i]({{bbox}});
         out body;
         >;
         out skel qt;', lvl, nome)

      gdf <- .overpass_query(aoi_bb, ql, timeout_s = 120, max_retry = 3)

      if (!is.null(gdf) && nrow(gdf) > 0) {
        cli::cli_alert_success("Boundary found at admin_level {lvl} ({nrow(gdf)} polygon(s))")
        aoi_sf <- gdf
        break
      }
    }

    if (is.null(aoi_sf) || nrow(aoi_sf) == 0) {
      cli::cli_alert_warning("No boundary found at any admin_level — using bounding box as fallback.")
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

  # Chunk grid sized to the AOI's own area — computed once here and reused
  # for every rural (per-value) and urban (per-category) query below.
  grid <- .compute_chunk_grid(aoi)

  # ── Rural / reference areas — 24 values × spatial chunks ───────────────────
  cli::cli_h3("Rural / reference areas")

  rural_areas_path <- file.path(dirs$input, "rural_areas.shp")

  if (!(file.exists(rural_areas_path) && file.size(rural_areas_path) > 100)) {

    natural_values <- c("fell","grassland","heath","moor","scrub","shrubbery",
                         "tree","tree_row","tree_stump","tundra","wood")
    agri_values    <- c("farmland","paddy","flowerbed",
                         "forest","meadow","orchard","grass")
    leisure_values <- c("garden","golf_course","nature_reserve","park")

    .download_split_category(aoi_bb, "natural", natural_values,
      label_prefix = "rural: natural", file_prefix = "rural_cat_natural", dirs = dirs,
      nx = grid$nx, ny = grid$ny)

    .download_split_category(aoi_bb, "landuse", agri_values,
      label_prefix = "rural: agricultural", file_prefix = "rural_cat_agri", dirs = dirs,
      nx = grid$nx, ny = grid$ny)

    .download_split_category(aoi_bb, "leisure", leisure_values,
      label_prefix = "rural: green/leisure", file_prefix = "rural_cat_leisure", dirs = dirs,
      nx = grid$nx, ny = grid$ny)

    # Per-value status summary — makes it obvious which specific value is
    # missing without needing to scroll through raw download logs.
    .category_status_summary(dirs, "rural_cat_natural", natural_values)
    .category_status_summary(dirs, "rural_cat_agri", agri_values)
    .category_status_summary(dirs, "rural_cat_leisure", leisure_values)

    # merge_shapefiles() (fn_utils.R) merges and writes rural_areas.shp
    # directly — no dissolve needed for rural (matches the original script,
    # which only bound the rural categories together, never aggregated them).
    .merge_category_files(dirs$input, "rural_cat_", "rural_areas.shp")

    if (!(file.exists(rural_areas_path) && file.size(rural_areas_path) > 100)) {
      cli::cli_alert_danger("rural_areas.shp NOT written — no valid features across any of the 22 rural value queries.")
    }
  } else {
    cli::cli_alert_info("Rural areas: using cached rural_areas.shp")
  }

  # ── Urban / built-up areas — 6 categories × spatial chunks ─────────────────
  cli::cli_h3("Urban / built-up areas")

  urban_areas_path <- file.path(dirs$input, "urban_areas.shp")

  if (!(file.exists(urban_areas_path) && file.size(urban_areas_path) > 100)) {

    .download_feature("urban: general landuse", aoi_bb,
      overpass_ql = .build_category_ql("landuse",
        c("commercial","construction","education","fairground","industrial",
          "residential","retail","institutional","railway","aerodrome",
          "landfill","port","depot","quarry","military"), timeout = 300),
      out_path = file.path(dirs$input, "urban_cat_landuse.shp"),
      nx = grid$nx, ny = grid$ny)

    .download_feature("urban: amenity", aoi_bb,
      overpass_ql = .build_category_ql("amenity", timeout = 300),
      out_path = file.path(dirs$input, "urban_cat_amenity.shp"),
      nx = grid$nx, ny = grid$ny)

    .download_feature("urban: tourism", aoi_bb,
      overpass_ql = .build_category_ql("tourism", timeout = 300),
      out_path = file.path(dirs$input, "urban_cat_tourism.shp"),
      nx = grid$nx, ny = grid$ny)

    .download_feature("urban: leisure", aoi_bb,
      overpass_ql = .build_category_ql("leisure",
        c("adult_gaming_centre","amusement_arcade","bandstand","beach_resort",
          "bleachers","bowling_alley","common","dance","disc_golf_course",
          "fitness_centre","fitness_station","hackerspace","ice_rink","marina",
          "miniature_golf","outdoor_seating","playground","resort","sauna",
          "slipway","sports_centre","sport_hall","stadium","summer_camp",
          "swimming_pool","tanning_salon","track","trampoline_park","water_park"),
        timeout = 300),
      out_path = file.path(dirs$input, "urban_cat_leisure.shp"),
      nx = grid$nx, ny = grid$ny)

    .download_feature("urban: aeroway", aoi_bb,
      overpass_ql = .build_category_ql("aeroway",
        c("aerodrome","apron","gate","hangar","spaceport","helipad",
          "runway","taxiway","terminal"), timeout = 300),
      out_path = file.path(dirs$input, "urban_cat_aeroway.shp"),
      nx = grid$nx, ny = grid$ny)

    # area=yes keeps this to polygon-like highway features (squares,
    # pedestrian zones) instead of pulling the entire line network —
    # deliberate improvement over the original script, not a regression.
    .download_feature("urban: highway (areas only)", aoi_bb,
      overpass_ql = .build_category_ql("highway", extra_filter = '["area"="yes"]', timeout = 300),
      out_path = file.path(dirs$input, "urban_cat_highway.shp"),
      nx = grid$nx, ny = grid$ny)

    # Per-category status summary — same rationale as the rural block above.
    urban_cats <- c("urban_cat_landuse.shp", "urban_cat_amenity.shp", "urban_cat_tourism.shp",
                     "urban_cat_leisure.shp", "urban_cat_aeroway.shp", "urban_cat_highway.shp")
    for (uc in urban_cats) {
      up <- file.path(dirs$input, uc)
      status <- if (file.exists(up) && file.size(up) > 100) "ok" else "MISSING"
      cli::cli_alert_info("  {uc}: {status}")
    }

    # merge_shapefiles() writes a raw merged file first; urban (unlike rural)
    # still needs the dissolve step (aggregate + makeValid), so the raw
    # merge goes to a temp name and gets deleted once the final dissolved
    # urban_areas.shp is written.
    urban_merged <- .merge_category_files(dirs$input, "urban_cat_", "urban_areas_raw_tmp.shp")

    if (!is.null(urban_merged) && nrow(urban_merged) > 0) {
      urb_v <- terra::vect(urban_merged) |> terra::aggregate() |> terra::makeValid()
      terra::writeVector(urb_v, urban_areas_path,
        filetype = "ESRI Shapefile", overwrite = TRUE, options = "ENCODING=UTF-8")
      cli::cli_alert_success("Saved: urban_areas.shp (dissolved from {nrow(urban_merged)} raw features)")
      # Remove the raw (pre-dissolve) intermediate now that the final file exists
      for (ext in c(".shp",".shx",".dbf",".prj",".cpg")) {
        f <- file.path(dirs$input, paste0("urban_areas_raw_tmp", ext))
        if (file.exists(f)) file.remove(f)
      }
    } else {
      cli::cli_alert_danger("urban_areas.shp NOT written — no valid features across the 6 urban categories.")
    }
  } else {
    cli::cli_alert_info("Urban areas: using cached urban_areas.shp")
  }

  cli::cli_alert_success("OSM download complete.")
  list(aoi = aoi, aoi_bb = aoi_bb)
}
