# =============================================================================
# fn_osm_tags.R — OSM tag definitions shared by BOTH download strategies
# =============================================================================
#
# Single source of truth for which OSM tags define the rural reference areas
# and the urban areas. fn_osm.R (Overpass) and fn_geofabrik.R (regional PBF
# extract) both read this list, so the two strategies cannot drift apart.
#
# NULL values mean "any value of that key".
#
# Rural landuse excludes farmyard and animal_keeping: bare/hard-packed ground
# around farm buildings and livestock pens, not vegetated cool-reference land.
# Urban highway is restricted to area features (squares, pedestrian zones),
# not the whole road network.
# =============================================================================

OSM_TAGS <- list(
  rural = list(
    natural = c("fell", "grassland", "heath", "moor", "scrub", "shrubbery",
                "tree", "tree_row", "tree_stump", "tundra", "wood"),
    agri    = c("farmland", "paddy", "flowerbed", "forest", "meadow", "orchard", "grass"),
    leisure = c("garden", "golf_course", "nature_reserve", "park")
  ),
  urban = list(
    landuse = c("commercial", "construction", "education", "fairground", "industrial",
                "residential", "retail", "institutional", "railway", "aerodrome",
                "landfill", "port", "depot", "quarry", "military"),
    amenity = NULL,
    tourism = NULL,
    leisure = c("adult_gaming_centre", "amusement_arcade", "bandstand", "beach_resort",
                "bleachers", "bowling_alley", "common", "dance", "disc_golf_course",
                "fitness_centre", "fitness_station", "hackerspace", "ice_rink", "marina",
                "miniature_golf", "outdoor_seating", "playground", "resort", "sauna",
                "slipway", "sports_centre", "sport_hall", "stadium", "summer_camp",
                "swimming_pool", "tanning_salon", "track", "trampoline_park", "water_park"),
    aeroway = c("aerodrome", "apron", "gate", "hangar", "spaceport", "helipad",
                "runway", "taxiway", "terminal"),
    highway = NULL
  )
)
