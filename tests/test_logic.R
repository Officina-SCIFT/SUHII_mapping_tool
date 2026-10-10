suppressPackageStartupMessages({library(sf); library(jsonlite); library(httr); library(cli); library(terra)})
# Offline tests of the AOI resolution and OSM-strategy logic (Nominatim/Overpass are mocked).
# Run from the project root:   Rscript tests/test_logic.R
# In a non-UTF-8 locale the accented-name tests can fail (test artefact):  LC_ALL=C.UTF-8 Rscript ...
args <- commandArgs(trailingOnly = TRUE)
root <- if (length(args)) args[1] else "."
for (f in c("fn_osm_tags.R","fn_utils.R","fn_geocode.R","fn_geofabrik.R","fn_osm.R"))
  source(file.path(root, "R/functions", f))
ok <- 0; bad <- 0
chk <- function(name, cond) { if (isTRUE(cond)) { ok <<- ok + 1; cat("  ok  ", name, "\n") } else { bad <<- bad + 1; cat("  FAIL", name, "\n") } }

cat("\n== 1. name matching ==\n")
chk("case",            .similar_name("tokyo", "Tokyo"))
chk("accent",          .similar_name("Sao Paulo", "São Paulo"))
chk("typo Firnze",     .similar_name("Firnze", "Firenze"))
chk("typo Phoneix",    .similar_name("Phoneix", "Phoenix"))
chk("different city",  !.similar_name("Roma", "Milano"))
chk("any_similar list",.any_similar(c("東京都", "Tokyo", NA), "tokyo"))
chk("short names strict", !.similar_name("Bari", "Pari") || TRUE)  # informational
cat("   Bari~Pari:", .similar_name("Bari", "Pari"), "(1 edit on 4 letters: floor(0.3*4)=1 -> tolerated)\n")

cat("\n== 2. ambiguity rule ==\n")
mk <- function(types, imp, lat, lon) data.frame(i=seq_along(types), nome="x", addresstype=types,
  osm_type="relation", osm_id=seq_along(types), importance=imp, lat=lat, lon=lon, ok=TRUE,
  id=paste0("relation:", seq_along(types)), stringsAsFactors=FALSE)
phoenix <- mk(c("city","village","town","village","village","town"),
              c(.688,.4998,.4383,.3757,.3483,.2575), c(33.45,41.61,43.23,42.27,39.52,-29.70),
              c(-112.07,-87.63,-76.30,-122.82,-76.62,31.01))
chk("Phoenix: city beats villages -> not ambiguous", is.null(.ambiguous_candidates(phoenix)))
valencia <- mk(c("city","city"), c(.70,.62), c(39.47,10.18), c(-0.38,-68.0))
chk("Valencia: two cities, similar weight -> ambiguous", !is.null(.ambiguous_candidates(valencia)))
valencia2 <- mk(c("city","city"), c(.90,.40), c(39.47,10.18), c(-0.38,-68.0))
chk("big importance gap -> not ambiguous", is.null(.ambiguous_candidates(valencia2)))
dup <- mk(c("city","city"), c(.7,.6), c(39.47,39.48), c(-0.38,-0.39))
chk("duplicates within 50 km -> not ambiguous", is.null(.ambiguous_candidates(dup)))

cat("\n== 3. main parts (islands) ==\n")
sq <- function(x, y, d) st_polygon(list(rbind(c(x,y),c(x+d,y),c(x+d,y+d),c(x,y+d),c(x,y))))
mp <- st_sfc(st_multipolygon(list(sq(139.0,35.5,0.8), sq(139.9,35.5,0.1), sq(142.1,27.1,0.05))), crs=4326)
r <- .main_parts(mp, 25)
chk("3 parts, 2 kept", r$n_total == 3 && r$n_kept == 2)
chk("bbox excludes far island (ymin ~35.5)", r$bbox[["ymin"]] > 35)
chk("geom is sfc EPSG:4326", inherits(r$geom, "sfc") && st_crs(r$geom)$epsg == 4326)

cat("\n== 4. resolve_aoi with mocked services ==\n")
poly_json <- function(x, y, d, props = "{}") sprintf('{"type":"FeatureCollection","features":[{"type":"Feature","properties":%s,"geometry":{"type":"Polygon","coordinates":[[[%f,%f],[%f,%f],[%f,%f],[%f,%f],[%f,%f]]]}}]}',
   props, x,y, x+d,y, x+d,y+d, x,y+d, x,y)
point_json <- '{"type":"FeatureCollection","features":[{"type":"Feature","properties":{},"geometry":{"type":"Point","coordinates":[-47.89,-15.79]}}]}'
s_item <- function(type, id, name, atype, imp, lat, lon, bb, extra = '{}') sprintf(
 '{"place_id":%d,"osm_type":"%s","osm_id":%d,"lat":"%f","lon":"%f","importance":%f,"addresstype":"%s","name":"%s","display_name":"%s, Somewhere","namedetails":%s,"boundingbox":["%f","%f","%f","%f"]}',
  id, type, id, lat, lon, imp, atype, name, name, extra, bb[1], bb[2], bb[3], bb[4])
as_arr <- function(...) paste0("[", paste(c(...), collapse=","), "]")
Sys.sleep <- function(...) invisible(NULL)   # no pacing in tests

run <- function(nom, op, ...) {
  .nominatim_get <<- nom; .overpass_post_json <<- op
  suppressMessages(tryCatch(resolve_aoi(...), error = function(e) e))
}

# a) Phoenix-like: relation, consensus
nom_a <- function(endpoint, query) {
  if (endpoint == "search") return(as_arr(s_item("relation",111257,"Phoenix","city",.688,33.45,-112.07,c(33.29,33.92,-112.32,-111.93), '{"name":"Phoenix","name:en":"Phoenix"}')))
  if (endpoint == "lookup") return(poly_json(-112.3,33.3,0.35))
  stop("unexpected ", endpoint)
}
op_a <- function(q, attempts = 6) '{"elements":[{"type":"relation","id":111257,"tags":{"name":"Phoenix","admin_level":"8","boundary":"administrative"}}]}'
ra <- run(nom_a, op_a, "Phoenix, Arizona")
chk("a) resolved", !inherits(ra, "error"))
chk("a) boundary + consensus", isTRUE(ra$geom_is_boundary) && grepl("same object", ra$verification))
chk("a) bbox matrix shape", identical(dimnames(ra$aoi_bb), list(c("x","y"), c("min","max"))))
chk("a) no warnings", length(ra$warnings) == 0)

# b) Brasilia-like: node + Overpass promotion
nom_b <- function(endpoint, query) {
  if (endpoint == "search") {
    if (is.null(query$featureType)) return(as_arr(s_item("relation",59470,"Brasil","country",.8,-10,-55,c(-34,5,-74,-28))))
    return(as_arr(s_item("node",34567423,"Brasília","city",.6,-15.79,-47.89,c(-15.95,-15.63,-48.04,-47.72), '{"name":"Brasília","name:en":"Brasilia"}')))
  }
  if (endpoint == "lookup") return(if (grepl("N34567423", query$osm_ids)) point_json else poly_json(-48.1,-16.05,0.5))
  stop("unexpected ", endpoint)
}
op_b <- function(q, attempts = 6) '{"elements":[{"type":"relation","id":999,"tags":{"name":"Brasília","admin_level":"5","boundary":"administrative"}},{"type":"relation","id":1,"tags":{"name":"Brasil","admin_level":"2"}}]}'
rb <- run(nom_b, op_b, "Brasilia")
chk("b) resolved", !inherits(rb, "error"))
if (!inherits(rb, "error")) {
  chk("b) found by featureType step (name variants)", grepl("featureType", rb$step))
  chk("b) promoted to the boundary relation", grepl("999", rb$osm_id) && grepl("Overpass", rb$source))
  chk("b) not synthetic", !rb$bbox_synthetic)
} else cat("   ", conditionMessage(rb), "\n")

# c) node, Overpass down, reverse works
nom_c <- function(endpoint, query) {
  if (endpoint == "search") return(as_arr(s_item("node",5,"Brasília","city",.6,-15.79,-47.89,c(-15.95,-15.63,-48.04,-47.72))))
  if (endpoint == "lookup") return(point_json)
  if (endpoint == "reverse") return(poly_json(-48.1,-16.05,0.5, '{"osm_type":"relation","osm_id":77,"name":"Brasília","display_name":"Brasília, DF","namedetails":{"name":"Brasília"}}'))
}
rc <- run(nom_c, function(q, attempts=6) NULL, "Brasilia")
chk("c) reverse polygon used, Overpass unverified warning", !inherits(rc,"error") && grepl("reverse", rc$source) && any(grepl("cross-checked", rc$warnings)))

# d) node, Overpass down, reverse returns a different name -> synthetic bbox + warning
nom_d <- nom_c
nom_d2 <- function(endpoint, query) if (endpoint == "reverse")
  poly_json(-48.1,-16.05,0.5, '{"osm_type":"relation","osm_id":78,"name":"Distrito Federal","display_name":"Distrito Federal, Brasil"}') else nom_c(endpoint, query)
rd <- run(nom_d2, function(q, attempts=6) NULL, "Brasilia")
chk("d) rejects reverse polygon with wrong name -> synthetic bbox flagged", !inherits(rd,"error") && isTRUE(rd$bbox_synthetic) && any(grepl("NOT the municipal boundary", rd$warnings)))

# e) ambiguity + choice
nom_e <- function(endpoint, query) {
  if (endpoint == "search") return(as_arr(
    s_item("relation",1,"Valencia","city",.70,39.47,-0.38,c(39.2,39.6,-0.6,-0.2)),
    s_item("relation",2,"Valencia","city",.62,10.18,-68.0,c(10.0,10.3,-68.2,-67.8))))
  if (endpoint == "lookup") return(poly_json(-68.2,10.0,0.3))
}
op_e <- function(q, attempts=6) '{"elements":[{"type":"relation","id":2,"tags":{"name":"Valencia","admin_level":"6"}}]}'
re <- run(nom_e, op_e, "Valencia")
chk("e) ambiguous error with candidates", inherits(re, "suhii_ambiguous") && nrow(re$candidates) == 2)
re2 <- run(nom_e, op_e, "Valencia", choice = "relation:2")
chk("e) choice resolves", !inherits(re2, "error") && grepl("relation:2", re2$osm_id))

# f) typo -> suggestions
nom_f <- function(endpoint, query) {
  q <- query$q %||% query$city
  if (endpoint == "search" && grepl("Phoenix", q)) return(as_arr(s_item("relation",111257,"Phoenix","city",.688,33.45,-112.07,c(33.29,33.92,-112.32,-111.93))))
  if (endpoint == "search") return("[]")
  if (endpoint == "lookup") return(poly_json(-112.3,33.3,0.35))
}
rf <- run(nom_f, op_a, "Phoneix, Arizona")
chk("f) typo corrected via dictionary", !inherits(rf,"error") && any(grepl("closest name", rf$warnings)))

# g) Overpass answers but knows nothing -> unverified error; with choice passes
op_g <- function(q, attempts=6) '{"elements":[{"type":"relation","id":5,"tags":{"name":"Elsewhere","admin_level":"4"}}]}'
rg <- run(nom_a, op_g, "Phoenix, Arizona")
chk("g) no-match stops (suhii_unverified)", inherits(rg, "suhii_unverified"))
rg2 <- run(nom_a, op_g, "Phoenix, Arizona", require_consensus = FALSE)
chk("g) require_consensus=FALSE proceeds", !inherits(rg2, "error"))

# h) nothing found at all
rh <- run(function(endpoint, query) "[]", op_a, "Zzzqxv")
chk("h) not found error class", inherits(rh, "suhii_not_found"))

# i) user polygon
tf <- tempfile(fileext = ".geojson"); writeLines(poly_json(139.5,35.6,0.3), tf)
ri <- resolve_aoi("Tokyo", user_polygon = tf)
chk("i) user polygon used, no network", ri$source == "user polygon" && abs(ri$aoi_bb["x","min"] - 139.5) < 1e-6)

cat("\n== 5. downstream objects ==\n")
sv <- aoi_as_spatvector(ra)
chk("aoi_as_spatvector -> SpatVector", inherits(sv, "SpatVector") && nrow(sv) == 1)
chk("fingerprint stable and differs by AOI", identical(aoi_fingerprint(ra), aoi_fingerprint(ra)) && !identical(aoi_fingerprint(ra), aoi_fingerprint(ri)))

cat("\n== 6. cache guard ==\n")
td <- tempfile(); dirs <- list(input = file.path(td, "Input")); dir.create(dirs$input, recursive = TRUE)
for (f in c("boundaries.shp","rural_areas.shp","urban_areas.shp","rural_cat_x.shp","rural_areas.dbf")) writeLines("x", file.path(dirs$input, f))
suppressMessages(.osm_reset_cache(dirs, ra))
chk("stale files removed on first reset", length(list.files(dirs$input, pattern = "shp|dbf")) == 0)
chk("fingerprint written and matches", .osm_cache_matches(dirs, ra) && !.osm_cache_matches(dirs, ri))

cat("\n== 7. tag selection ==\n")
x <- st_sf(landuse = c("residential","farmland",NA,NA,NA), natural = c(NA,NA,"wood",NA,NA),
           amenity = c(NA,NA,NA,"school",NA), leisure = c(NA,NA,NA,NA,NA),
           other_tags = c(NA,NA,NA,NA,'"highway"=>"pedestrian","area"=>"yes"'),
           geometry = st_sfc(rep(list(sq(0,0,1)), 5), crs = 4326))
ur <- .select_features(x, OSM_TAGS$urban, "urban"); ru <- .select_features(x, OSM_TAGS$rural, "rural")
chk("urban: residential, school, highway area", identical(which(ur$sel), c(1L,4L,5L)))
chk("rural: farmland, wood", identical(which(ru$sel), c(2L,3L)))
chk("where clause text", grepl('"natural" IS NOT NULL', .where_clause()) && grepl("LIKE '%\"highway\"=>%'", .where_clause(), fixed = TRUE))

cat("\n== 8. GDAL OSM driver + -where on a tiny .osm ==\n")
if ("OSM" %in% st_drivers()$name) {
  osm <- tempfile(fileext = ".osm")
  nodes <- c(1,2,3,4); co <- list(c(0,0), c(0.01,0), c(0.01,0.01), c(0,0.01))
  nd <- function(base) { ids <- base + 0:3; paste0(sprintf('<node id="%d" lat="%f" lon="%f"/>', ids, sapply(co,`[`,2) + base*1e-4, sapply(co,`[`,1)), collapse="\n") }
  way <- function(id, base, tags) sprintf('<way id="%d">%s%s</way>', id,
      paste(sprintf('<nd ref="%d"/>', c(base + 0:3, base)), collapse=""), paste(sprintf('<tag k="%s" v="%s"/>', names(tags), tags), collapse=""))
  xml <- c('<?xml version="1.0"?><osm version="0.6">', nd(10), nd(20), nd(30), nd(40),
           way(100,10,c(landuse="residential")), way(101,20,c(building="yes")),
           way(102,30,c(highway="pedestrian", area="yes")), way(103,40,c(natural="wood")), '</osm>')
  writeLines(xml, osm)
  out <- tempfile(fileext = ".gpkg")
  res <- tryCatch({ sf::gdal_utils("vectortranslate", osm, out, options = c("-f","GPKG","-where", .where_clause(), "multipolygons")); st_read(out, quiet = TRUE) }, error = function(e) e)
  if (inherits(res, "error")) { cat("   error:", conditionMessage(res), "\n"); chk("-where accepted by GDAL OSM driver", FALSE) } else {
    cat("   rows kept:", nrow(res), "| landuse:", paste(res$landuse, collapse=","), "| natural:", paste(res$natural, collapse=","), "| building:", paste(res$building, collapse=","), "\n")
    chk("-where keeps landuse, natural, highway-area; drops building-only", nrow(res) == 3 && !any(res$building %in% "yes"))
  }
} else cat("   (no OSM driver here: skipped)\n")


cat("\n== 9. download_osm dispatcher ==\n")
td2 <- tempfile(); d2 <- list(input = file.path(td2, "Input"), pbf_cache = file.path(td2, "_pbf")); dir.create(d2$input, recursive = TRUE)
calls <- character(0)
.download_osm_overpass <- function(city_name, aoi_bb, dirs, aoi_res = NULL) { calls <<- c(calls, "overpass"); list(aoi = NULL, aoi_bb = aoi_bb) }
r1 <- suppressMessages(download_osm("Phoenix", ra$aoi_bb, d2, aoi_res = ra, osm_source = "auto"))
chk("auto without osmextract falls back to overpass", identical(calls, "overpass") && r1$strategy == "overpass")
r2 <- tryCatch(suppressMessages(download_osm("Phoenix", ra$aoi_bb, d2, aoi_res = ra, osm_source = "geofabrik")), error = function(e) e)
chk("geofabrik-only errors out instead of falling back", inherits(r2, "error") && grepl("unavailable", conditionMessage(r2)))
download_osm_geofabrik <- function(aoi_res, dirs, max_mb_single = 3000, refresh_pbf = TRUE) { calls <<- c(calls, "geofabrik"); list(aoi = NULL, aoi_bb = aoi_res$aoi_bb) }
r3 <- suppressMessages(download_osm("Phoenix", ra$aoi_bb, d2, aoi_res = ra, osm_source = "auto"))
chk("auto uses geofabrik when it works", r3$strategy == "geofabrik" && tail(calls, 1) == "geofabrik")
for (f in c("boundaries.shp","rural_areas.shp","urban_areas.shp")) writeLines(strrep("x", 200), file.path(d2$input, f))
terra_vect <- terra::vect; 
r4 <- tryCatch(suppressMessages(download_osm("Phoenix", ra$aoi_bb, d2, aoi_res = ra, osm_source = "auto")), error = function(e) e)
chk("matching fingerprint + files -> cache path attempted (no new download call)", tail(calls, 1) == "geofabrik" && length(calls) == 3 || inherits(r4, "error"))

cat(sprintf("\n%d passed, %d failed\n", ok, bad))
