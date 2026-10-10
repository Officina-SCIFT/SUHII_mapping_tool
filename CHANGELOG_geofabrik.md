# Change: automatic study area + OSM from Geofabrik

## What changed
- **Study area** (`R/functions/fn_geocode.R`, `resolve_aoi()`): replaces the "smallest Nominatim bbox" rule.
  Ladder of Nominatim queries; case/accent/typo-tolerant name matching against all OSM names of the place;
  spelling suggestions from a city dictionary; ambiguity detection (stops and lists candidates);
  second-source check with Overpass (`is_in`), which can also promote a point to its boundary relation;
  boundary polygon via Nominatim `/lookup` or `/reverse`; remote islands ignored (25 km rule);
  optional user polygon; no area-based exclusion (megacities allowed). Falls back to Nominatim's bbox only
  with an explicit warning (`bbox_synthetic`).
- **OSM data** (`R/functions/fn_geofabrik.R`): picks the Geofabrik extract(s) automatically (container or
  mosaic), resumable md5-checked download into a shared cache (`<working_dir>/_pbf_cache`), GDAL conversion
  of the AOI bbox only (attribute filter), same output files as before. Provenance in `Input/osm_source.json`.
- **`download_osm()`** (`fn_osm.R`): `osm_source = "auto" | "geofabrik" | "overpass"`. `auto` falls back to
  Overpass (original code, unchanged apart from reading shared tag lists) if Geofabrik fails.
- **Tag definitions** now live in one place (`fn_osm_tags.R`, `OSM_TAGS`) used by both strategies.
- **Cache guard**: OSM outputs carry an AOI fingerprint; a different AOI deletes stale OSM files.
- **Shiny**: map preview + confirmation before any download, chooser for ambiguous names, optional country
  code, optional boundary upload, OSM source selector (Advanced).
- **Docker/packages**: `osmextract`, `curl`, `maps`, `stringi` added (osmextract installed AFTER the
  from-source sf/terra step on purpose).

## Verified here (offline)
`Rscript tests/test_logic.R` (43 checks): name matching, ambiguity rule, island handling, `resolve_aoi()`
with mocked Nominatim/Overpass (relation, node promotion, reverse, synthetic bbox, ambiguity, typo, user
polygon), cache guard, tag selection, dispatcher fallback, and that GDAL's OSM driver accepts the `-where`
attribute filter on a small `.osm` file.

## NOT verified (needs network / Docker / a browser)
- Real Nominatim `/reverse` results (zoom 10/12) for point features; `importance` as a tie-breaker.
- `osmextract::oe_vectortranslate(vectortranslate_options = c("-where", ...))` together with osmextract's
  default options (if rejected, the code retries without the filter and still selects features in R).
- The Shiny modal flow in a browser; the Docker build (osmextract step).
- Behaviour on very large cities (memory), and on cities spanning two extracts (mosaic path).
- Geofabrik's usage policy for heavy automated use.

## Known limits
- Geofabrik extracts are daily snapshots, not live.
- DEM and Landsat caches are keyed by city slug and are NOT invalidated when the AOI changes.
- README performance figures were measured with the old Overpass-only pipeline.
