# =============================================================================
# fn_geofabrik.R — OSM data from Geofabrik regional extracts (PBF)
# =============================================================================
#
# Provides download_osm_geofabrik(), the primary OSM strategy. Instead of ~110
# Overpass requests (rate limits, 504s, silently dropped chunks) it:
#   1. picks the Geofabrik extract(s) covering the AOI, automatically;
#   2. downloads the .osm.pbf once (resumable, md5-checked, shared cache);
#   3. converts only the AOI bbox with GDAL (osmextract), keeping only the
#      features that can matter (attribute filter), and reads the polygons;
#   4. selects rural / urban features with the SAME tag definitions as the
#      Overpass strategy (OSM_TAGS in fn_osm_tags.R) and writes the same files
#      (boundaries.shp, rural_areas.shp, urban_areas.shp).
#
# Why: a PBF is a complete, consistent snapshot, so there are no partial
# answers and no chunks to drop. Measured on test runs (Florence, Phoenix):
# minutes in total, identical feature counts on repeated runs.
#
# Extract selection
#   * CONTAINER: the smallest Geofabrik zone that contains the whole AOI.
#   * MOSAIC: when the container is huge (> max_mb_single) or the AOI sits on
#     a border, the leaf zones covering the AOI, minimal cover by ascending
#     area (Geofabrik also has overlapping grouping zones, e.g. South-East
#     Asia, which are skipped when they add no new coverage).
#   * Features present in two extracts are de-duplicated by OSM id.
#
# Limits worth knowing
#   * Geofabrik extracts are updated daily, not live; the extract date is
#     recorded in Input/osm_source.json.
#   * The shared PBF cache (working_dir/_pbf_cache) can use several GB.
#   * Heavy use of download.geofabrik.de is subject to their usage policy.
#   * Memory: very large cities hold many polygons in RAM at once.
#   * Needs the 'osmextract' package and a GDAL with the OSM driver.
# =============================================================================

.GEOFABRIK_UA <- "SUHII_mapping/1.0 (heat island research)"

# Is the Geofabrik strategy usable on this machine? -> list(ok, reason)
geofabrik_available <- function() {
  if (!requireNamespace("osmextract", quietly = TRUE))
    return(list(ok = FALSE, reason = "R package 'osmextract' is not installed"))
  if (!requireNamespace("curl", quietly = TRUE))
    return(list(ok = FALSE, reason = "R package 'curl' is not installed"))
  if (!"OSM" %in% sf::st_drivers()$name)
    return(list(ok = FALSE, reason = "this GDAL build has no OSM driver"))
  list(ok = TRUE, reason = "")
}

.head_url <- function(url) {
  h <- curl::new_handle(nobody = TRUE, useragent = .GEOFABRIK_UA, timeout = 60,
                        connecttimeout = 60, followlocation = TRUE)
  r <- tryCatch(curl::curl_fetch_memory(url, handle = h), error = function(e) NULL)
  if (is.null(r)) return(list(status = NA_integer_, size = NA_real_, modified = NA_character_))
  hd <- curl::parse_headers_list(r$headers)
  list(status = r$status_code,
       size = suppressWarnings(as.numeric(hd[["content-length"]])),
       modified = hd[["last-modified"]])
}

# ── 1. Choosing the extract(s) ────────────────────────────────────────────────

.geofabrik_select <- function(aoi_sfc, max_mb_single) {
  z <- osmextract::geofabrik_zones
  need <- c("id", "name", "parent", "pbf")
  if (!all(need %in% names(z)))
    stop("geofabrik_zones lacks the expected columns (", paste(need, collapse = ", "), ").", call. = FALSE)
  z <- sf::st_transform(z, 4326)
  s2 <- sf::sf_use_s2(); suppressMessages(sf::sf_use_s2(FALSE))
  on.exit(suppressMessages(sf::sf_use_s2(s2)), add = TRUE)
  quiet <- function(x) suppressMessages(suppressWarnings(x))
  area_km2 <- function(g) as.numeric(sf::st_area(sf::st_transform(sf::st_make_valid(g), 6933))) / 1e6

  # a) container: smallest zone covering the whole AOI
  cop <- lengths(quiet(sf::st_covers(z, aoi_sfc))) > 0
  if (!any(cop)) stop("No Geofabrik zone contains the AOI (does it cross the antimeridian?).", call. = FALSE)
  cand <- z[cop, ]
  cand$area_km2 <- area_km2(cand)
  cand <- cand[order(cand$area_km2), ]
  container <- cand[1, ]

  # b) mosaic: leaf zones, minimal cover by ascending area
  inter  <- z[lengths(quiet(sf::st_intersects(z, aoi_sfc))) > 0, ]
  leaves <- inter[!(inter$id %in% inter$parent), ]
  aoi_m2 <- as.numeric(sf::st_area(sf::st_transform(aoi_sfc, 6933)))
  leaves$zone_km2 <- area_km2(leaves)
  leaves <- leaves[order(leaves$zone_km2), ]
  kept <- integer(0); covered <- NULL; cover <- 0
  for (i in seq_len(nrow(leaves))) {
    x <- quiet(sf::st_intersection(sf::st_geometry(sf::st_make_valid(leaves[i, ])),
                                   sf::st_geometry(aoi_sfc)))
    if (length(x) == 0) next
    nu <- if (is.null(covered)) x else c(covered, x)
    cv <- as.numeric(sf::st_area(sf::st_transform(quiet(sf::st_union(nu)), 6933))) / aoi_m2
    if (cv - cover > 0.001) { kept <- c(kept, i); covered <- nu; cover <- cv }
  }
  leaves <- leaves[kept, ]

  cont_mb <- .head_url(container$pbf)$size / 1e6
  mos_mb  <- if (nrow(leaves)) vapply(leaves$pbf, function(u) .head_url(u)$size / 1e6, 0) else numeric(0)
  mosaic_ok <- nrow(leaves) > 0 && cover >= 0.99 && !anyNA(mos_mb)

  if (!is.na(cont_mb) && cont_mb <= max_mb_single) {
    strategy <- "container"; sel <- container
    why <- sprintf("container %s is %.0f MB (<= %d MB)", container$id, cont_mb, max_mb_single)
  } else if (mosaic_ok) {
    strategy <- "mosaic"; sel <- leaves
    why <- sprintf("container %s is %.0f MB; mosaic of %d file(s) covers %.1f%% of the AOI",
                   container$id, cont_mb, nrow(leaves), 100 * cover)
  } else {
    strategy <- "container"; sel <- container
    why <- sprintf("container %s is large (%.0f MB) and no valid mosaic exists", container$id, cont_mb)
  }
  list(strategy = strategy, why = why,
       extracts = data.frame(id = sel$id, name = sel$name, url = sel$pbf, stringsAsFactors = FALSE))
}

# ── 2. Download (resumable, md5-checked) ──────────────────────────────────────

.md5_remote <- function(url) {
  tryCatch({
    rr <- curl::curl_fetch_memory(paste0(url, ".md5"),
                                  handle = curl::new_handle(useragent = .GEOFABRIK_UA, timeout = 60))
    strsplit(trimws(rawToChar(rr$content)), "\\s+")[[1]][1]
  }, error = function(e) NA_character_)
}

# Returns list(path, md5, status, modified, mb, seconds).
# The final file is only ever written by a completed download (via a .part file
# that may be resumed), so an interrupted transfer can never pass as a PBF.
.fetch_pbf <- function(url, dest_dir, refresh = TRUE) {
  hd <- .head_url(url)
  if (is.na(hd$status) || hd$status != 200)
    stop("Geofabrik URL not reachable (status ", hd$status, "): ", url, call. = FALSE)
  pbf  <- file.path(dest_dir, basename(url))
  part <- paste0(pbf, ".part")
  md5r <- .md5_remote(url)

  if (file.exists(pbf)) {
    md5l <- unname(tools::md5sum(pbf))
    if (is.na(md5r) || identical(md5l, md5r) || !refresh) {
      cli::cli_alert_info("Extract already in cache: {basename(pbf)} (last modified {hd$modified})")
      return(list(path = pbf, md5 = md5l, status = if (is.na(md5r)) "cached (md5 not checkable)" else "cached, md5 OK",
                  modified = hd$modified, mb = file.size(pbf) / 1e6, seconds = NA_real_))
    }
    cli::cli_alert_info("Cached extract is out of date or damaged: downloading again.")
    file.remove(pbf)
  }

  cli::cli_alert_info("Downloading {basename(url)} ({round(hd$size / 1e6)} MB)...")
  t0 <- Sys.time()
  for (k in 1:3) {
    tryCatch(
      curl::multi_download(url, part, resume = TRUE, progress = TRUE,
                           useragent = .GEOFABRIK_UA, connecttimeout = 120),
      error = function(e) cli::cli_alert_warning("Download error: {conditionMessage(e)}"))
    if (file.exists(part) && !is.na(hd$size) && file.size(part) == hd$size) break
    cli::cli_alert_warning("Attempt {k}/3 incomplete; retrying in 10 s.")
    Sys.sleep(10)
  }
  if (!(file.exists(part) && !is.na(hd$size) && file.size(part) == hd$size))
    stop("Geofabrik download incomplete: ", url, call. = FALSE)

  md5l <- unname(tools::md5sum(part))
  if (!is.na(md5r) && !identical(md5l, md5r)) {
    file.remove(part)
    stop("md5 mismatch after download of ", basename(url), "; file discarded.", call. = FALSE)
  }
  file.rename(part, pbf)
  secs <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  cli::cli_alert_success("Downloaded {basename(url)} in {round(secs)} s ({if (is.na(md5r)) 'md5 not checkable' else 'md5 OK'})")
  list(path = pbf, md5 = md5l, status = if (is.na(md5r)) "downloaded (md5 not checkable)" else "downloaded, md5 OK",
       modified = hd$modified, mb = file.size(pbf) / 1e6, seconds = secs)
}

# ── 3. Conversion + reading ───────────────────────────────────────────────────

# Attribute filter applied while converting: only features that can belong to a
# rural or urban category are written. The exact value lists are applied later
# in R, so this filter only has to be a superset (and if GDAL rejects it, the
# conversion is repeated without it).
.where_clause <- function() {
  keys <- c("natural", "landuse", "leisure", "amenity", "tourism", "aeroway")
  paste(c(sprintf('"%s" IS NOT NULL', keys),
          "\"other_tags\" LIKE '%\"highway\"=>%'"), collapse = " OR ")
}

# The GeoPackage is written next to the PBF with a name that does NOT encode
# the AOI, so a fingerprint (file size + md5 + bbox + filter) is stored beside
# it; a different AOI forces a new conversion instead of reading a wrong clip.
.convert_multipolygons <- function(pbf, md5, aoi_sfc, force = FALSE) {
  gpkg_expected <- sub("\\.osm\\.pbf$", ".gpkg", pbf)
  fp_file <- sub("\\.osm\\.pbf$", ".cache_aoi.rds", pbf)
  where   <- .where_clause()
  key <- paste(md5, paste(round(sf::st_bbox(aoi_sfc), 5), collapse = ","), where)
  fp  <- if (file.exists(fp_file)) tryCatch(readRDS(fp_file), error = function(e) list()) else list()
  if (!force && file.exists(gpkg_expected) && identical(fp[["multipolygons"]], key)) {
    cli::cli_alert_info("Converted layer already cached for this AOI.")
    return(list(gpkg = gpkg_expected, seconds = NA_real_, filtered = TRUE))
  }
  t0 <- Sys.time()
  filtered <- TRUE
  g <- tryCatch(
    osmextract::oe_vectortranslate(pbf, layer = "multipolygons", force_vectortranslate = TRUE,
                                   boundary = aoi_sfc, boundary_type = "spat",
                                   vectortranslate_options = c("-where", where), quiet = TRUE),
    error = function(e) {
      cli::cli_alert_warning("Filtered conversion failed ({conditionMessage(e)}); converting without the attribute filter.")
      filtered <<- FALSE
      osmextract::oe_vectortranslate(pbf, layer = "multipolygons", force_vectortranslate = TRUE,
                                     boundary = aoi_sfc, boundary_type = "spat", quiet = TRUE)
    })
  fp[["multipolygons"]] <- key; saveRDS(fp, fp_file)
  list(gpkg = g, seconds = as.numeric(difftime(Sys.time(), t0, units = "secs")), filtered = filtered)
}

# ── 4. Selecting rural / urban features ───────────────────────────────────────

.has_tag <- function(x, key, values = NULL) {
  if (key == "highway") {   # not a column of the multipolygons layer: lives in other_tags
    if (!"other_tags" %in% names(x)) return(rep(FALSE, nrow(x)))
    return(!is.na(x$other_tags) & grepl('"highway"=>', x$other_tags, fixed = TRUE))
  }
  if (!key %in% names(x)) {
    cli::cli_alert_warning("Column '{key}' missing from the converted layer: no feature selected for it.")
    return(rep(FALSE, nrow(x)))
  }
  v <- x[[key]]
  if (is.null(values)) !is.na(v) else v %in% values
}

.select_features <- function(x, spec, labels) {
  # spec: named list key -> values (NULL = any). Returns list(sel, counts)
  sel <- rep(FALSE, nrow(x)); counts <- integer(0)
  for (nm in names(spec)) {
    key <- if (nm == "agri") "landuse" else nm
    s <- .has_tag(x, key, spec[[nm]])
    counts[paste0(labels, ":", nm)] <- sum(s)
    sel <- sel | s
  }
  list(sel = sel, counts = counts)
}

# ── Main function ─────────────────────────────────────────────────────────────

#' Download OSM rural/urban areas from Geofabrik extracts
#'
#' @param aoi_res         Result of resolve_aoi()
#' @param dirs            Project directories from setup()
#' @param max_mb_single   Largest single extract accepted before using a mosaic
#' @param refresh_pbf     Re-download a cached PBF when Geofabrik's md5 differs
#'
#' @return Named list: $aoi (SpatVector), $aoi_bb, $source (provenance list)
download_osm_geofabrik <- function(aoi_res, dirs, max_mb_single = 3000, refresh_pbf = TRUE) {

  chk <- geofabrik_available()
  if (!chk$ok) stop("Geofabrik strategy unavailable: ", chk$reason, call. = FALSE)

  cli::cli_h2("OSM data: Geofabrik extract")
  t_all <- Sys.time()
  dir.create(dirs$pbf_cache, showWarnings = FALSE, recursive = TRUE)

  s2 <- sf::sf_use_s2(); suppressMessages(sf::sf_use_s2(FALSE))
  on.exit(suppressMessages(sf::sf_use_s2(s2)), add = TRUE)

  bb <- aoi_res$aoi_bb
  aoi_box <- sf::st_as_sfc(sf::st_bbox(
    c(xmin = bb["x", "min"], ymin = bb["y", "min"], xmax = bb["x", "max"], ymax = bb["y", "max"]),
    crs = 4326))

  # Boundary file: always rewritten from the resolved AOI
  aoi <- aoi_as_spatvector(aoi_res)
  terra::writeVector(aoi, file.path(dirs$input, "boundaries.shp"),
                     filetype = "ESRI Shapefile", overwrite = TRUE, options = "ENCODING=UTF-8")
  cli::cli_alert_success("Saved: boundaries.shp ({aoi_res$source}, {round(aoi_res$area_km2)} km²)")

  # Extracts
  sel <- .geofabrik_select(aoi_box, max_mb_single)
  cli::cli_alert_info("Extract strategy: {sel$strategy} — {sel$why}")

  mp_list <- list(); info <- list()
  for (i in seq_len(nrow(sel$extracts))) {
    id <- sel$extracts$id[i]
    cli::cli_h3("[{i}/{nrow(sel$extracts)}] {id}")
    f  <- .fetch_pbf(sel$extracts$url[i], dirs$pbf_cache, refresh = refresh_pbf)
    cv <- .convert_multipolygons(f$path, f$md5, aoi_box)
    t0 <- Sys.time()
    x  <- sf::read_sf(cv$gpkg, layer = "multipolygons")
    mp_list[[i]] <- x
    info[[i]] <- list(id = id, url = sel$extracts$url[i], pbf_last_modified = f$modified,
                      pbf_mb = round(f$mb), md5 = f$md5, md5_status = f$status,
                      convert_s = cv$seconds, read_s = as.numeric(difftime(Sys.time(), t0, units = "secs")),
                      polygons_read = nrow(x), attribute_filter_applied = cv$filtered)
    cli::cli_alert_success("{nrow(x)} polygon features read in the AOI bbox")
  }

  # Merge extracts, de-duplicate
  common <- Reduce(intersect, lapply(mp_list, names))
  mp <- do.call(rbind, lapply(mp_list, function(d) d[, common]))
  key <- paste(mp$osm_id, mp$osm_way_id)
  n_dup <- sum(duplicated(key)); mp <- mp[!duplicated(key), ]
  if (n_dup > 0) cli::cli_alert_info("{n_dup} duplicate feature(s) across extracts removed")

  # Rural and urban selection (shared tag definitions)
  rur <- .select_features(mp, OSM_TAGS$rural, "rural")
  urb <- .select_features(mp, OSM_TAGS$urban, "urban")
  cli::cli_alert_info("Rural features: {sum(rur$sel)} | urban features: {sum(urb$sel)}")
  for (nm in names(c(rur$counts, urb$counts)))
    cli::cli_alert_info("  {nm}: {c(rur$counts, urb$counts)[[nm]]}")

  geom_only <- function(d) sf::st_sf(geometry = sf::st_geometry(d))

  # Rural: written as is (not dissolved), like the Overpass strategy
  rural_path <- file.path(dirs$input, "rural_areas.shp")
  if (sum(rur$sel) > 0) {
    save_polygons(geom_only(mp[rur$sel, ]), rural_path)
  } else {
    cli::cli_alert_danger("rural_areas.shp NOT written: no rural feature in the AOI bbox.")
  }

  # Urban: dissolved, like the Overpass strategy
  urban_path <- file.path(dirs$input, "urban_areas.shp")
  if (sum(urb$sel) > 0) {
    t0 <- Sys.time()
    u <- terra::vect(sf::st_make_valid(geom_only(mp[urb$sel, ]))) |>
      terra::aggregate() |> terra::makeValid()
    terra::writeVector(u, urban_path, filetype = "ESRI Shapefile",
                       overwrite = TRUE, options = "ENCODING=UTF-8")
    cli::cli_alert_success("Saved: urban_areas.shp (dissolved from {sum(urb$sel)} features in {round(as.numeric(difftime(Sys.time(), t0, units = 'secs')))} s)")
  } else {
    cli::cli_alert_danger("urban_areas.shp NOT written: no urban feature in the AOI bbox.")
  }

  prov <- list(strategy = "geofabrik", extract_strategy = sel$strategy, why = sel$why,
               extracts = info, features = list(rural = sum(rur$sel), urban = sum(urb$sel),
                                                counts = as.list(c(rur$counts, urb$counts))),
               aoi = list(source = aoi_res$source, osm_id = aoi_res$osm_id,
                          verification = aoi_res$verification, area_km2 = round(aoi_res$area_km2, 1),
                          bbox_synthetic = aoi_res$bbox_synthetic),
               generated = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"),
               seconds_total = round(as.numeric(difftime(Sys.time(), t_all, units = "secs"))),
               licence = "OpenStreetMap contributors, ODbL 1.0 (https://www.openstreetmap.org/copyright)")
  writeLines(jsonlite::toJSON(prov, pretty = TRUE, auto_unbox = TRUE, na = "null"),
             file.path(dirs$input, "osm_source.json"))

  if (!(file.exists(rural_path) && file.exists(urban_path)))
    stop("Geofabrik extract read, but rural and/or urban areas are empty for this AOI.", call. = FALSE)

  cli::cli_alert_success("OSM (Geofabrik) complete in {prov$seconds_total} s.")
  list(aoi = aoi, aoi_bb = aoi_res$aoi_bb, source = prov)
}
