# =============================================================================
# fn_geocode.R — Resolving the study area (AOI) from a city name
# =============================================================================
#
# Provides resolve_aoi(), which turns a free-text place name into the AOI used
# by the whole workflow: a boundary polygon (when one can be found) and its
# bounding box. It replaces the old "smallest Nominatim bbox wins" rule.
#
# Principles
#   * The AOI is always the municipality / city, never a region or a country.
#     There is NO a-priori exclusion by area: megacities are legitimate. Size
#     only produces an informational warning.
#   * No fixed alias list. Matching is case-, accent- and punctuation-
#     insensitive and tolerates small spelling errors (edit distance), and it is
#     checked against ALL OSM names of the place (name, name:en, name:ja, ...),
#     so "Tokyo" can match an entry whose main name is in Japanese.
#   * Every candidate is VALIDATED, and the tool stops loudly rather than
#     guessing when the candidate itself is doubtful (ambiguous names). The
#     user also confirms the boundary on a map before anything is downloaded.
#   * Locating the municipality must never depend on Overpass: Overpass is only
#     a second-source check and never blocks the workflow by default.
#
# Resolution chain
#   1. Nominatim, as a ladder: free text -> featureType=city -> featureType=
#      settlement -> structured city=. A step is accepted only if it returns a
#      populated place (city/town/village/municipality/hamlet) whose name is
#      similar to the one requested.
#   2. If nothing is found: spelling suggestions from a city dictionary
#      (package 'maps', optional) and a new ladder run.
#   3. Ambiguity check: several valid places far apart (Valencia, Springfield).
#      A clearly larger settlement type wins (Phoenix: city vs. villages);
#      otherwise the function stops and returns the candidates.
#   4. Second source (NON-BLOCKING by default): Overpass `is_in` lists the
#      administrative boundaries that contain the candidate's point.
#        consensus / consensus-promoted : a boundary with a similar name exists
#                                         (if the candidate was only a node,
#                                         that relation is used for the polygon)
#        no-match   : Overpass lists boundaries but none has a similar name
#                     -> warning (stop only if require_consensus = TRUE)
#        unverified : Overpass unreachable, invalid or EMPTY answer
#                     -> warning only (an empty answer is a degraded server:
#                        any point on land lies in some administrative boundary)
#   5. Polygon: Nominatim /lookup; for nodes without a boundary, Nominatim
#      /reverse (zoom 10, then 12) with a name check. Only the main polygon and
#      the parts within `parts_radius_km` of it count towards the bbox (far
#      islands do not stretch it).
#   6. Last resort: Nominatim's own bbox. For a node this is a SYNTHETIC square
#      (not a boundary): flagged in $warnings and $bbox_synthetic.
#
# Error classes (so the caller / Shiny app can react):
#   suhii_ambiguous  : $candidates holds the valid candidates (column `id`)
#   suhii_unverified : (a) require_consensus = TRUE and Overpass lists
#                      boundaries but none with a similar name; or (b) no
#                      polygon available and the bbox spans more than 3 degrees
#   suhii_not_found  : nothing found even after spelling suggestions
#
# Known limits (not verified for every country): Nominatim's classification of
# `addresstype`, the shape of /reverse results, and the `importance` field
# used for ranking are Nominatim behaviours, not guaranteed by this code.
# =============================================================================

.SUHII_UA <- "SUHII_mapping/1.0 (heat island research)"

.OVERPASS_SERVERS <- c(
  "https://overpass-api.de/api/interpreter",
  "https://overpass.kumi.systems/api/interpreter",
  "https://maps.mail.ru/osm/tools/overpass/api/interpreter"
)

# Types of place accepted as "a city/municipality" (same set as the old geocoder)
.PLACE_TYPES <- c("city", "town", "village", "municipality", "hamlet")
# Rank used to break ties between valid places of different size
.PLACE_RANK  <- c(city = 4, town = 3, municipality = 3, village = 2, hamlet = 1)


# ── Name matching ─────────────────────────────────────────────────────────────

# Lower case, accents and punctuation removed.
.fold_name <- function(x) {
  x <- tolower(as.character(x))
  if (requireNamespace("stringi", quietly = TRUE)) {
    x <- stringi::stri_trans_general(x, "Latin-ASCII")
  } else {
    x <- chartr(
      "àáâãäåçèéêëìíîïñòóôõöùúûüýÿ",
      "aaaaaaceeeeiiiinooooouuuuyy", x)
  }
  trimws(gsub("[^a-z0-9 ]", "", x))
}

# TRUE if the names are equal after folding or differ by a small edit distance
# (at most `tol` of the shorter name, e.g. 30%: one slip in a 4-letter name,
# two in an 8-letter one).
.similar_name <- function(a, b, tol = 0.3) {
  a <- .fold_name(a); b <- .fold_name(b)
  if (!nzchar(a) || !nzchar(b)) return(FALSE)
  drop(utils::adist(a, b)) <= floor(tol * min(nchar(a), nchar(b)))
}

.any_similar <- function(candidates, target) {
  candidates <- candidates[!is.na(candidates) & nzchar(candidates)]
  length(candidates) > 0 &&
    any(vapply(candidates, .similar_name, logical(1), b = target))
}

# Spelling suggestions from a world city dictionary (package 'maps', optional).
.suggest_names <- function(core, n = 3) {
  if (!requireNamespace("maps", quietly = TRUE)) return(character(0))
  wc  <- maps::world.cities
  pop <- tapply(wc$pop, wc$name, max)
  nm  <- names(pop)
  x <- .fold_name(core); f <- .fold_name(nm)
  d <- as.numeric(utils::adist(x, f))
  ok <- d <= floor(0.3 * pmin(nchar(x), nchar(f)))
  if (!any(ok, na.rm = TRUE)) return(character(0))
  s <- data.frame(nome = nm[ok], d = d[ok], pop = as.numeric(pop[nm[ok]]),
                  stringsAsFactors = FALSE)
  utils::head(s[order(s$d, -s$pop), "nome"], n)
}


# ── Nominatim ─────────────────────────────────────────────────────────────────

.nominatim_get <- function(endpoint, query) {
  Sys.sleep(1.1)   # usage policy: at most 1 request per second
  resp <- httr::GET(paste0("https://nominatim.openstreetmap.org/", endpoint),
                    query = query,
                    httr::add_headers("User-Agent" = .SUHII_UA),
                    httr::timeout(60))
  if (httr::status_code(resp) != 200)
    stop("Nominatim HTTP ", httr::status_code(resp), call. = FALSE)
  httr::content(resp, "text", encoding = "UTF-8")
}

# One Nominatim search -> list(nomi, tab) or NULL.
#   tab: one row per result; nomi: list of all name variants per result.
.nominatim_candidates <- function(params) {
  txt <- .nominatim_get("search",
           c(params, list(format = "jsonv2", limit = 10, namedetails = 1)))
  d <- jsonlite::fromJSON(txt)
  if (!is.data.frame(d) || nrow(d) == 0) return(NULL)

  nd <- d$namedetails
  nomi <- lapply(seq_len(nrow(d)), function(i) {
    v <- if (is.data.frame(nd)) unlist(nd[i, , drop = TRUE], use.names = FALSE)
         else unlist(nd[[i]], use.names = FALSE)
    unique(as.character(c(v[!is.na(v)], strsplit(d$display_name[i], ",")[[1]][1])))
  })

  b <- if (is.matrix(d$boundingbox)) {            # south, north, west, east
    matrix(as.numeric(d$boundingbox), nrow = nrow(d$boundingbox))
  } else do.call(rbind, lapply(d$boundingbox, as.numeric))
  lat_mid <- (b[, 1] + b[, 2]) / 2

  tab <- data.frame(
    i           = seq_len(nrow(d)),
    nome        = substr(d$display_name, 1, 70),
    addresstype = if (!is.null(d$addresstype)) d$addresstype else NA_character_,
    osm_type    = d$osm_type,
    osm_id      = d$osm_id,
    importance  = if (!is.null(d$importance)) as.numeric(d$importance) else NA_real_,
    lat         = as.numeric(d$lat),
    lon         = as.numeric(d$lon),
    xmin = b[, 3], ymin = b[, 1], xmax = b[, 4], ymax = b[, 2],
    km2_bbox    = round((b[, 4] - b[, 3]) * 111.32 * cos(lat_mid * pi / 180) *
                          (b[, 2] - b[, 1]) * 110.57),
    stringsAsFactors = FALSE)
  tab$id <- paste0(tab$osm_type, ":", tab$osm_id)
  list(nomi = nomi, tab = tab)
}

# Ladder of Nominatim queries for one query string; first step that yields a
# populated place with a similar name wins. Returns NULL if none does.
.find_place <- function(q, country = NULL) {
  core <- trimws(strsplit(q, ",")[[1]][1])
  steps <- list(
    "free text"          = list(q = q),
    "featureType=city"   = list(q = q, featureType = "city", layer = "address"),
    "featureType=settle" = list(q = q, featureType = "settlement", layer = "address"),
    "structured city="   = list(city = core))
  if (!is.null(country) && nzchar(country))
    steps <- lapply(steps, function(s) c(s, list(countrycodes = tolower(country))))

  for (nm in names(steps)) {
    cl <- tryCatch(.nominatim_candidates(steps[[nm]]),
                   error = function(e) {
                     cli::cli_alert_warning("Nominatim [{nm}]: {conditionMessage(e)}")
                     NULL
                   })
    if (is.null(cl)) next
    cl$tab$name_ok <- vapply(cl$nomi, .any_similar, logical(1), target = core)
    cl$tab$ok      <- cl$tab$addresstype %in% .PLACE_TYPES & cl$tab$name_ok
    if (any(cl$tab$ok))
      return(list(tab = cl$tab, first = which(cl$tab$ok)[1], step = nm, query = q))
  }
  NULL
}

# Valid candidates far apart and of comparable weight -> ambiguous.
# Rule (thresholds are judgement calls, not calibrated):
#   - the best candidate is the first valid one in Nominatim's own order;
#   - others within 50 km are the same place (duplicates / sub-objects);
#   - if the best has a strictly higher settlement rank than every far
#     candidate (city vs. villages) it wins;
#   - otherwise, if its `importance` is at least twice the next one, it wins;
#   - otherwise: ambiguous.
.ambiguous_candidates <- function(tab) {
  ok <- tab[tab$ok, , drop = FALSE]
  if (nrow(ok) < 2) return(NULL)
  rad <- pi / 180
  dkm <- 2 * 6371 * asin(sqrt(
    sin((ok$lat - ok$lat[1]) * rad / 2)^2 +
    cos(ok$lat[1] * rad) * cos(ok$lat * rad) * sin((ok$lon - ok$lon[1]) * rad / 2)^2))
  far <- ok[dkm > 50, , drop = FALSE]
  if (nrow(far) == 0) return(NULL)
  rk <- function(t) unname(.PLACE_RANK[t])
  if (rk(ok$addresstype[1]) > max(rk(far$addresstype), na.rm = TRUE)) return(NULL)
  imp_far <- max(far$importance, na.rm = TRUE)
  if (is.finite(imp_far) && !is.na(ok$importance[1]) && ok$importance[1] >= 2 * imp_far)
    return(NULL)
  rbind(ok[1, , drop = FALSE], far)
}


# ── Overpass (second source) ──────────────────────────────────────────────────

# POST with mirror rotation and backoff; returns the JSON text or NULL.
.overpass_post_json <- function(q, attempts = 6) {
  for (a in seq_len(attempts)) {
    u <- .OVERPASS_SERVERS[((a - 1) %% length(.OVERPASS_SERVERS)) + 1]
    resp <- tryCatch(
      httr::POST(u, httr::add_headers("User-Agent" = .SUHII_UA),
                 httr::config(connecttimeout = 40), httr::timeout(60),
                 body = list(data = q), encode = "form"),
      error = function(e) {
        cli::cli_alert_warning("Overpass {a}/{attempts} ({sub('/api.*', '', u)}): {conditionMessage(e)}")
        NULL
      })
    if (!is.null(resp)) {
      if (httr::status_code(resp) == 200) {
        txt <- httr::content(resp, "text", encoding = "UTF-8")
        if (!grepl('"remark"', txt, fixed = TRUE)) return(txt)
        cli::cli_alert_warning("Overpass {a}/{attempts}: partial answer (remark)")
      } else {
        cli::cli_alert_warning("Overpass {a}/{attempts} ({sub('/api.*', '', u)}): HTTP {httr::status_code(resp)}")
      }
    }
    if (a < attempts) Sys.sleep(min(5 * a, 20))
  }
  NULL
}

# Which administrative boundaries contain the candidate's point, and does one of
# them carry a name similar to `core`? Returns list(status, relation_id, detail).
#   status: "consensus" | "consensus-promoted" | "no-match" | "unverified"
#
# An EMPTY answer is "unverified", not "no-match": a point on land always lies
# inside at least one administrative boundary (country, region, ...), so an
# empty `elements` array means a degraded server, not a wrong name. "no-match"
# is reserved for answers that list boundaries none of which is named like the
# requested place; the names found are returned in `detail`.
.overpass_verify <- function(lat, lon, osm_type, osm_id, core) {
  q <- sprintf(
    '[out:json][timeout:60];is_in(%.6f,%.6f)->.a;rel(pivot.a)["boundary"="administrative"];out tags;',
    lat, lon)
  txt <- .overpass_post_json(q, attempts = 3)
  if (is.null(txt)) return(list(status = "unverified", relation_id = NA,
                                detail = "Overpass unreachable"))
  el <- tryCatch(jsonlite::fromJSON(txt, simplifyVector = FALSE)$elements,
                 error = function(e) NULL)
  if (is.null(el)) return(list(status = "unverified", relation_id = NA,
                               detail = "invalid Overpass answer"))

  if (length(el) == 0)
    return(list(status = "unverified", relation_id = NA,
                detail = "empty Overpass answer (a point on land always lies in some administrative boundary)"))

  hit <- Filter(function(e) {
    t <- e$tags
    k <- names(t)[grepl("^(name|int_name|official_name|alt_name)", names(t))]
    length(k) > 0 && .any_similar(unlist(t[k]), core)
  }, el)

  if (length(hit) == 0) {
    found <- unique(unlist(lapply(el, function(e) e$tags$name)))
    found <- if (length(found) > 0) paste(found, collapse = ", ") else "no named boundary"
    return(list(status = "no-match", relation_id = NA,
                detail = paste0("boundaries at this point: ", found)))
  }

  if (osm_type == "relation" && any(vapply(hit, function(e) e$id == osm_id, logical(1))))
    return(list(status = "consensus", relation_id = osm_id, detail = "same object"))

  lv <- vapply(hit, function(e) suppressWarnings(as.integer(e$tags$admin_level)), integer(1))
  lv[is.na(lv)] <- -1L
  best <- hit[[which.max(lv)]]
  list(status = "consensus-promoted", relation_id = best$id,
       detail = sprintf("boundary relation %s (admin_level %s)", best$id, best$tags$admin_level))
}


# ── Geometry ──────────────────────────────────────────────────────────────────

# Polygon of an OSM object through Nominatim /lookup (NULL for nodes).
.lookup_polygon <- function(osm_type, osm_id) {
  id  <- paste0(toupper(substr(osm_type, 1, 1)), osm_id)
  txt <- .nominatim_get("lookup", list(osm_ids = id, format = "geojson", polygon_geojson = 1))
  g <- sf::read_sf(txt, quiet = TRUE)
  if (nrow(g) == 0) return(NULL)
  geom <- sf::st_geometry(g)[1]
  if (!as.character(sf::st_geometry_type(geom)) %in% c("POLYGON", "MULTIPOLYGON")) return(NULL)
  geom
}

# Boundary containing a point through Nominatim /reverse, accepted only if its
# name is similar to the requested one (guards against returning a region).
.reverse_polygon <- function(lat, lon, core, zooms = c(10, 12)) {
  for (z in zooms) {
    txt <- tryCatch(
      .nominatim_get("reverse", list(lat = lat, lon = lon, zoom = z, format = "geojson",
                                     polygon_geojson = 1, namedetails = 1)),
      error = function(e) NULL)
    if (is.null(txt)) next
    f <- tryCatch(jsonlite::fromJSON(txt, simplifyVector = FALSE)$features[[1]],
                  error = function(e) NULL)
    if (is.null(f)) next
    p <- f$properties
    nm <- c(unlist(p$namedetails), p$name, strsplit(p$display_name %||% "", ",")[[1]][1])
    if (!.any_similar(nm, core)) next
    g <- tryCatch(sf::read_sf(txt, quiet = TRUE), error = function(e) NULL)
    if (is.null(g) || nrow(g) == 0) next
    geom <- sf::st_geometry(g)[1]
    if (as.character(sf::st_geometry_type(geom)) %in% c("POLYGON", "MULTIPOLYGON"))
      return(list(geom = geom, osm_type = p$osm_type, osm_id = p$osm_id, zoom = z))
  }
  NULL
}

# Keeps the largest polygon part plus the parts within `radius_km` of it.
# Returns list(geom, bbox, area_km2, n_kept, n_total).
.main_parts <- function(geom, radius_km = 25) {
  s2 <- sf::sf_use_s2(); suppressMessages(sf::sf_use_s2(FALSE))
  on.exit(suppressMessages(sf::sf_use_s2(s2)), add = TRUE)
  p  <- suppressWarnings(sf::st_cast(sf::st_make_valid(geom), "POLYGON"))
  pm <- sf::st_transform(p, 6933)                       # equal-area, metres
  ar <- as.numeric(sf::st_area(pm))
  buf  <- sf::st_buffer(pm[which.max(ar)], radius_km * 1000)
  keep <- lengths(sf::st_intersects(pm, buf)) > 0
  kept <- sf::st_union(p[keep])
  list(geom = sf::st_set_crs(kept, 4326), bbox = sf::st_bbox(p[keep]),
       area_km2 = sum(ar[keep]) / 1e6, n_kept = sum(keep), n_total = length(p))
}

.bbox_matrix <- function(xmin, ymin, xmax, ymax) {
  matrix(c(xmin, xmax, ymin, ymax), nrow = 2, byrow = TRUE,
         dimnames = list(c("x", "y"), c("min", "max")))
}

.bbox_polygon <- function(bb) {
  sf::st_as_sfc(sf::st_bbox(c(xmin = bb["x", "min"], ymin = bb["y", "min"],
                              xmax = bb["x", "max"], ymax = bb["y", "max"]), crs = 4326))
}

# Reads a user-supplied boundary (gpkg, geojson, shp, or a .zip holding a shp).
.read_user_polygon <- function(path) {
  if (grepl("\\.zip$", path, ignore.case = TRUE)) {
    td <- tempfile("userpoly_"); dir.create(td)
    utils::unzip(path, exdir = td)
    shp <- list.files(td, pattern = "\\.shp$", recursive = TRUE, full.names = TRUE)
    if (length(shp) == 0) stop("The zip file contains no .shp file.", call. = FALSE)
    path <- shp[1]
  }
  x <- sf::read_sf(path)
  x <- x[as.character(sf::st_geometry_type(x)) %in% c("POLYGON", "MULTIPOLYGON"), ]
  if (nrow(x) == 0) stop("No polygon found in the supplied boundary file.", call. = FALSE)
  if (is.na(sf::st_crs(x))) stop("The supplied boundary has no CRS.", call. = FALSE)
  s2 <- sf::sf_use_s2(); suppressMessages(sf::sf_use_s2(FALSE))
  on.exit(suppressMessages(sf::sf_use_s2(s2)), add = TRUE)
  sf::st_union(sf::st_make_valid(sf::st_transform(sf::st_geometry(x), 4326)))
}

.area_km2 <- function(geom) {
  s2 <- sf::sf_use_s2(); suppressMessages(sf::sf_use_s2(FALSE))
  on.exit(suppressMessages(sf::sf_use_s2(s2)), add = TRUE)
  sum(as.numeric(sf::st_area(sf::st_transform(geom, 6933)))) / 1e6
}

.stop_cls <- function(cls, msg, ...) {
  stop(structure(class = c(cls, "error", "condition"),
                 list(message = msg, call = NULL, ...)))
}


# ── Main function ─────────────────────────────────────────────────────────────

#' Resolve the study area for a city
#'
#' @param city               Free-text place name ("Florence", "Phoenix, Arizona")
#' @param country            Optional ISO 3166-1 alpha-2 code ("it", "jp")
#' @param user_polygon       Optional path of the user's own boundary file; skips
#'                           geocoding entirely
#' @param choice             Optional candidate to force: an `id` such as
#'                           "relation:111257" (as listed in the ambiguity error)
#' @param require_consensus  If TRUE, stop when Overpass lists boundaries at the
#'                           candidate's point but none has a similar name.
#'                           Default FALSE: that case only warns. An empty or
#'                           unavailable Overpass answer never stops (warning).
#' @param parts_radius_km    Polygon parts farther than this from the main part
#'                           (islands) are ignored for bbox and AOI
#' @param warn_km2           Informational threshold only; nothing is excluded
#'
#' @return list: city, name, geom (sfc, EPSG:4326: boundary polygon or bbox
#'         rectangle), aoi_bb (matrix x/y min/max), geom_is_boundary,
#'         bbox_synthetic, source, osm_id, verification, area_km2, step,
#'         query, warnings (character), candidates (data.frame)
resolve_aoi <- function(city, country = NULL, user_polygon = NULL, choice = NULL,
                        require_consensus = FALSE, parts_radius_km = 25,
                        warn_km2 = 20000) {

  warns <- character(0)
  add_warn <- function(msg) { warns <<- c(warns, msg); cli::cli_alert_warning(msg) }

  # ── 0. The user brings their own boundary ──────────────────────────────────
  if (!is.null(user_polygon) && nzchar(user_polygon)) {
    geom <- .read_user_polygon(user_polygon)
    bb   <- sf::st_bbox(geom)
    ar   <- .area_km2(geom)
    cli::cli_alert_success("Using the supplied boundary ({round(ar)} km²): geocoding skipped.")
    return(list(city = city, name = basename(user_polygon), geom = geom,
                aoi_bb = .bbox_matrix(bb[["xmin"]], bb[["ymin"]], bb[["xmax"]], bb[["ymax"]]),
                geom_is_boundary = TRUE, bbox_synthetic = FALSE, source = "user polygon",
                osm_id = NA_character_, verification = "supplied by the user",
                area_km2 = ar, step = NA_character_, query = city,
                warnings = warns, candidates = NULL))
  }

  # ── 1. Find candidates (ladder, then spelling suggestions) ─────────────────
  core <- trimws(strsplit(city, ",")[[1]][1])
  rest <- sub("^[^,]*", "", city)
  found <- .find_place(city, country)

  if (is.null(found)) {
    sugg <- .suggest_names(core)
    if (length(sugg) > 0)
      cli::cli_alert_info("No match for '{core}'. Trying spelling suggestions: {paste(sugg, collapse = ', ')}")
    for (s in sugg) {
      found <- .find_place(paste0(s, rest), country)
      if (!is.null(found)) {
        add_warn(sprintf("'%s' not found: using the closest name '%s'.", core, s))
        core <- s
        break
      }
    }
  }
  if (is.null(found)) {
    .stop_cls("suhii_not_found", paste0(
      "No populated place found for '", city, "'. ",
      "Check the spelling, add the region or country (e.g. 'Springfield, Illinois'), ",
      "or upload your own boundary."))
  }

  tab <- found$tab
  cli::cli_alert_info("Geocoding step: {found$step} | {sum(tab$ok)} valid candidate(s)")

  # ── 2. Choose the candidate ────────────────────────────────────────────────
  if (!is.null(choice)) {
    k <- match(as.character(choice), tab$id)
    if (is.na(k)) .stop_cls("suhii_not_found",
      paste0("The chosen candidate '", choice, "' is not among the results: ",
             paste(tab$id[tab$ok], collapse = ", ")))
  } else {
    amb <- .ambiguous_candidates(tab)
    if (!is.null(amb)) {
      .stop_cls("suhii_ambiguous", paste0(
        "'", city, "' is ambiguous: ", nrow(amb), " different places of similar weight. ",
        "Add the region or country (e.g. 'Valencia, Spain'), choose one, or upload your own boundary."),
        candidates = amb)
    }
    k <- found$first
  }
  cand <- tab[k, ]
  cli::cli_alert_success("Candidate: {cand$nome} ({cand$addresstype}, {cand$id})")

  # ── 3. Second source: Overpass boundaries containing the point ─────────────
  # Non-blocking by default: locating the municipality must not depend on
  # Overpass (see header). The user still confirms the boundary on a map.
  ver <- .overpass_verify(cand$lat, cand$lon, cand$osm_type, cand$osm_id, core)
  verification <- switch(ver$status,
    "consensus"          = "confirmed by Overpass (same object)",
    "consensus-promoted" = paste("confirmed by Overpass:", ver$detail),
    "unverified"         = paste("NOT verified:", ver$detail),
    "no-match"           = paste("NOT confirmed by Overpass:", ver$detail))
  cli::cli_alert_info("Verification: {verification}")

  if (ver$status == "no-match") {
    if (require_consensus && is.null(choice))
      .stop_cls("suhii_unverified", paste0(
        "Overpass lists boundaries at the chosen point but none named like '", core,
        "' (", ver$detail, "). Add the region or country, or upload your own boundary."),
        candidates = tab[tab$ok, , drop = FALSE])
    add_warn(sprintf("Second-source check: no boundary named like '%s' (%s). Check the AOI preview.",
                     core, ver$detail))
  }
  if (ver$status == "unverified")
    add_warn("Second-source check (Overpass) unavailable: the place was not cross-checked.")

  # ── 4. Polygon ─────────────────────────────────────────────────────────────
  poly <- NULL; src <- NULL; osm_used <- cand$id
  try_lookup <- function(type, id, label) {
    g <- tryCatch(.lookup_polygon(type, id), error = function(e) NULL)
    if (!is.null(g)) { poly <<- g; src <<- label; osm_used <<- paste0(type, ":", id) }
  }
  if (cand$osm_type %in% c("relation", "way")) try_lookup(cand$osm_type, cand$osm_id, "Nominatim polygon")
  if (is.null(poly) && ver$status == "consensus-promoted")
    try_lookup("relation", ver$relation_id, "administrative boundary found via Overpass")
  if (is.null(poly)) {
    rv <- .reverse_polygon(cand$lat, cand$lon, core)
    if (!is.null(rv)) {
      poly <- rv$geom; src <- sprintf("Nominatim reverse (zoom %s)", rv$zoom)
      osm_used <- paste0(rv$osm_type, ":", rv$osm_id)
    }
  }

  synthetic <- FALSE
  if (!is.null(poly)) {
    mp <- .main_parts(poly, parts_radius_km)
    geom <- mp$geom; ar <- mp$area_km2
    bb <- .bbox_matrix(mp$bbox[["xmin"]], mp$bbox[["ymin"]], mp$bbox[["xmax"]], mp$bbox[["ymax"]])
    if (mp$n_total > mp$n_kept)
      cli::cli_alert_info("Polygon: {mp$n_kept} of {mp$n_total} parts kept (others > {parts_radius_km} km away, e.g. islands)")
    cli::cli_alert_success("Boundary: {src} | {round(ar)} km²")
  } else {
    # Last resort: Nominatim's bbox. For nodes it is a fixed-size square.
    bb <- .bbox_matrix(cand$xmin, cand$ymin, cand$xmax, cand$ymax)
    geom <- .bbox_polygon(bb); ar <- .area_km2(geom); synthetic <- TRUE
    src  <- "Nominatim bbox (no boundary polygon found)"
    add_warn(paste0(
      "No boundary polygon could be found: the AOI is Nominatim's bounding box (",
      round(ar), " km²), which is NOT the municipal boundary",
      if (cand$osm_type == "node") " (for a point feature it is a fixed-size square)" else "",
      ". Check the preview, or upload your own boundary."))
    if ((bb["x", "max"] - bb["x", "min"] > 3) || (bb["y", "max"] - bb["y", "min"] > 3))
      .stop_cls("suhii_unverified", paste0(
        "No polygon available and the bounding box spans more than 3 degrees: ",
        "it may include far islands. Upload your own boundary."))
  }

  if (ar > warn_km2)
    cli::cli_alert_info("Large area ({round(ar)} km²): downloads and processing will take longer and need more memory (no exclusion applied).")

  list(city = city, name = cand$nome, geom = geom, aoi_bb = bb,
       geom_is_boundary = !synthetic, bbox_synthetic = synthetic, source = src,
       osm_id = osm_used, verification = verification, area_km2 = ar,
       step = found$step, query = found$query, warnings = warns,
       candidates = tab[tab$ok, , drop = FALSE])
}

# SpatVector of the AOI geometry (what the rest of the workflow calls `aoi`).
aoi_as_spatvector <- function(aoi_res) {
  terra::vect(sf::st_sf(geometry = aoi_res$geom))
}

# Short fingerprint used to detect a changed AOI between runs (stale caches).
aoi_fingerprint <- function(aoi_res) {
  paste(c(round(aoi_res$aoi_bb, 5), aoi_res$osm_id, aoi_res$source), collapse = "|")
}
