# =============================================================================
# server.R — SUHII Mapping Tool — Shiny Server
# =============================================================================
#
# Orchestrates the full analysis workflow reactively:
#   1. User clicks "Run" → validates inputs
#   2. Runs each function step, updating the progress log in real time
#   3. Renders output maps, charts, and download handlers on completion
#
# All heavy computation runs in a callr background process so the UI
# remains responsive during the analysis (no frozen browser).
# =============================================================================

library(shiny)
library(bslib)
library(leaflet)
library(terra)
library(dplyr)
library(plotly)
library(yaml)
library(sf)
library(osmdata)
library(httr)
library(cli)
library(rstac)
library(elevatr)
library(kgc)
library(lubridate)
library(jsonlite)
library(tidyterra)
library(colorRamps)

# ── Resolve project root ───────────────────────────────────────────────────────
# server.R lives in SUHI_docker/shiny/server.R
# → project root is always two levels up from this file.
# sys.frame(0)$ofile gives the path of the currently-sourced file in Shiny.
.find_project_root <- function() {

  # 1. Best: use this file's own path (works when Shiny sources server.R)
  this_file <- tryCatch(
    normalizePath(sys.frame(0)$ofile, mustWork = FALSE),
    error = function(e) ""
  )
  if (nzchar(this_file) && file.exists(this_file)) {
    # server.R is at <root>/shiny/server.R  → root = dirname(dirname(this_file))
    root <- dirname(dirname(this_file))
    if (dir.exists(file.path(root, "R", "functions"))) return(root)
  }

  # 2. Walk upward from working directory looking for R/functions/
  check <- function(p) dir.exists(file.path(normalizePath(p, mustWork=FALSE),
                                             "R", "functions"))
  candidates <- c(
    getwd(),
    dirname(getwd()),
    file.path(getwd(), ".."),
    file.path(getwd(), "../.."),
    "/srv/shiny-server/suhii"     # Docker
  )
  for (p in candidates) {
    p <- normalizePath(p, mustWork = FALSE)
    if (check(p)) return(p)
  }

  stop(paste0(
    "Cannot locate project root (R/functions/ not found).\n",
    "Working directory: ", getwd(), "\n",
    "Run shiny::runApp() with your working directory set to SUHI_docker/:\n",
    "  setwd('path/to/SUHI_docker'); shiny::runApp('shiny/')"
  ))
}

PROJECT_ROOT <- .find_project_root()
message("Project root: ", PROJECT_ROOT)

fn_dir <- file.path(PROJECT_ROOT, "R", "functions")

for (f in list.files(fn_dir, pattern = "\\.R$", full.names = TRUE)) {
  source(f)
}

# ── Constants ─────────────────────────────────────────────────────────────────
CLASS_COLOURS <- c("#4575b4","#ffffbf","#fee090","#f46d43","#d73027","#a50026")
CLASS_NAMES   <- c("Cool island","Neutral","Weak","Moderate","Strong","Extreme")
CREDENTIALS <- if (file.exists("/srv/shiny-server/suhii/config/credentials.yml")) {
  "/srv/shiny-server/suhii/config/credentials.yml"   # Docker
} else {
  file.path(PROJECT_ROOT, "config", "credentials.yml")  # local dev
}


server <- function(input, output, session) {

  # Register the data folder so generated HTML reports can be served.
  # Files in /data/<city>/Output/ become reachable at /suhii_data/<city>/Output/
  data_root <- if (nzchar(Sys.getenv("SUHII_DATA_DIR"))) Sys.getenv("SUHII_DATA_DIR") else "/data"
  try(shiny::addResourcePath("suhii_data", data_root), silent = TRUE)

  # ── Reactive values ─────────────────────────────────────────────────────────
  log_msgs  <- reactiveVal(character(0))
  results   <- reactiveVal(NULL)     # list with all output paths + objects
  running   <- reactiveVal(FALSE)

  # ── Log helpers ─────────────────────────────────────────────────────────────
  add_log <- function(msg, type = "info") {
    icon_map <- c(info = "ℹ", ok = "✓", warn = "⚠", error = "✗")
    prefix   <- icon_map[[type]] %||% "·"
    ts       <- format(Sys.time(), "%H:%M:%S")
    new_msg  <- sprintf("[%s] %s %s", ts, prefix, msg)
    log_msgs(c(log_msgs(), new_msg))
  }

  # ── Status badge ────────────────────────────────────────────────────────────
  output$status_badge <- renderUI({
    if (running()) {
      tags$span(class = "badge bg-warning text-dark", icon("spinner", class="fa-spin"), " Running...")
    } else if (!is.null(results())) {
      tags$span(class = "badge bg-success", icon("check"), " Complete")
    } else {
      tags$span(class = "badge bg-secondary", "Ready")
    }
  })

  # ── Progress log ─────────────────────────────────────────────────────────────
  output$log_output <- renderText({
    msgs <- log_msgs()
    if (length(msgs) == 0) return("Waiting for analysis to start...")
    paste(msgs, collapse = "\n")
  })

  # Auto-scroll log to bottom
  observe({
    log_msgs()   # take dependency
    session$sendCustomMessage("scrollLog", list())
  })

  # ── Run button ───────────────────────────────────────────────────────────────
  observeEvent(input$run_btn, {
    req(!running())

    # Reset state
    log_msgs(character(0))
    results(NULL)
    running(TRUE)

    # Capture inputs (must be done in the reactive context)
    city                 <- trimws(input$city)
    # Fixed parameters — not exposed to the user
    working_dir          <- "/data"   # always /data inside Docker
    season               <- "warm"    # cold season not yet implemented
    max_cloud            <- 30L       # recommended default
    altitude_band_height <- 100L      # 100 m elevation bands

    # Basic client-side validation
    if (!nzchar(city)) {
      add_log("City name cannot be empty.", "error")
      running(FALSE)
      return()
    }

    add_log(sprintf("Starting analysis for '%s'...", city))

    # ── Run workflow (withProgress keeps UI responsive) ──────────────────────
    withProgress(message = sprintf("Analysing %s...", city), value = 0, {

      tryCatch({

        # Step 1: Setup
        setProgress(0.05, detail = "Validating inputs...")
        add_log("Setting up...")
        cfg <- setup(
          city                 = city,
          working_dir          = working_dir,
          season               = season,
          max_cloud            = max_cloud,
          altitude_band_height = altitude_band_height,
          credentials_file     = CREDENTIALS,
          project_root         = PROJECT_ROOT
        )
        add_log(sprintf("City: %s | Season: %s | Cloud ≤ %d%%",
                        cfg$city_name, cfg$season, cfg$max_cloud), "ok")

        # Step 2: OSM
        setProgress(0.10, detail = "Downloading OSM data...")
        add_log("Downloading OpenStreetMap data (may take a few minutes)...")
        osm <- download_osm(cfg$city_name, cfg$aoi_bb, cfg$dirs)
        add_log("OSM download complete.", "ok")

        # Step 3: Landsat
        setProgress(0.25, detail = "Downloading Landsat imagery...")
        add_log("Querying Planetary Computer for Landsat scenes...")
        landsat <- download_landsat(cfg$aoi_bb, cfg$city_slug, cfg$season,
                                    cfg$max_cloud, cfg$dirs)
        add_log(sprintf("Season window: %s \u2192 %s (Koppen: %s) | %d scene(s) found",
                        landsat$start_date, landsat$end_date,
                        landsat$koppen_class,
                        landsat$n_scenes_found %||% -1L), "ok")

        # Count downloaded files and report
        n_downloaded <- length(list.files(cfg$dirs$landsat, pattern = "_ST_B"))
        add_log(sprintf("Landsat bands on disk: %d file(s) in %s",
                        n_downloaded, cfg$dirs$landsat),
                if (n_downloaded > 0) "ok" else "warn")

        # Step 4: DEM
        setProgress(0.45, detail = "Downloading DEM...")
        add_log("Downloading SRTM DEM...")
        dem_path <- download_dem(osm$aoi, cfg$city_slug, cfg$ot_key, cfg$dirs)
        add_log("DEM ready.", "ok")

        # Step 5: LST
        setProgress(0.55, detail = "Processing LST...")
        add_log("Computing Land Surface Temperature...")
        lst_result <- process_lst(osm$aoi, cfg$aoi_bb, cfg$dirs,
                                   landsat$start_date, landsat$end_date,
                                   landsat$year, cfg$season)
        rng <- terra::minmax(lst_result$lst_mean)
        add_log(sprintf("LST mean: %.1f–%.1f°C", rng[1], rng[2]), "ok")

        # Step 6: SUHII
        setProgress(0.70, detail = "Computing SUHII...")
        add_log("Computing thermal anomaly and SUHII index...")
        suhii_result <- compute_suhii(lst_result$lst_mean, osm$aoi,
                                       cfg$city_slug, cfg$dirs, dem_path,
                                       landsat$year, cfg$season,
                                       cfg$altitude_band_height)
        add_log("SUHII analysis complete.", "ok")

        # Step 7: Green distance
        setProgress(0.80, detail = "Computing green distances...")
        add_log("Computing distance from green areas...")
        compute_green_distance(suhii_result$aoi_utm, lst_result$lst_mean,
                                cfg$city_slug, cfg$dirs,
                                landsat$year, cfg$season)
        add_log("Green area distance complete.", "ok")

        # Step 8: Outputs
        setProgress(0.88, detail = "Producing outputs...")
        add_log("Producing classified raster, priority map, statistics...")
        city_stats <- produce_outputs(
          suhii_result$anomaly_map, suhii_result$suhi_map, lst_result$lst_mean,
          suhii_result$aoi_utm, suhii_result$aree_urb, suhii_result$aree_ref,
          cfg$city_name, cfg$city_slug, cfg$dirs,
          landsat$start_date, landsat$end_date, landsat$year,
          cfg$season, cfg$max_cloud)
        add_log("Outputs saved.", "ok")

        # Step 9: Report
        setProgress(0.95, detail = "Rendering HTML report...")
        add_log("Rendering HTML report (this may take 1–2 minutes)...")
        render_report(
          cfg$city_name, cfg$city_slug, cfg$dirs,
          landsat$start_date, landsat$end_date, landsat$year,
          cfg$season, cfg$max_cloud, cfg$altitude_band_height,
          landsat$koppen_class, cfg$project_root)
        add_log("Report ready.", "ok")

        # ── Store results for rendering ────────────────────────────────────────
        f <- function(...) file.path(cfg$dirs$output, sprintf(...))
        seas <- cfg$season; yr <- landsat$year; slug <- cfg$city_slug

        results(list(
          cfg        = cfg,
          dirs_output = cfg$dirs$output,
          landsat    = landsat,
          city_stats = city_stats,
          lst_mean   = lst_result$lst_mean,
          anomaly    = suhii_result$anomaly_map,
          suhi       = suhii_result$suhi_map,
          # File paths
          path_lst        = f("%s_%d_LST_MEAN.tif",             seas, yr),
          path_anomaly    = f("%s_%d_thermal_anomaly.tif",      seas, yr),
          path_suhi       = f("%s_%d_SUHI.tif",                 seas, yr),
          path_classified = f("%s_%d_anomaly_classified.tif",   seas, yr),
          path_priority   = f("%s_%d_priority_map.tif",         seas, yr),
          path_green      = f("%s_%d_distance_green_areas.tif", seas, yr),
          path_cls_json   = f("%s_%d_anomaly_classified.geojson", seas, yr),
          path_prio_json  = f("%s_%d_priority_map.geojson",       seas, yr),
          path_stats      = f("%s_%d_city_stats.csv",            seas, yr),
          path_report     = f("%s_%s_%d_report.html",            slug, seas, yr)
        ))

        setProgress(1.0, detail = "Done!")
        add_log(sprintf("Analysis complete. Outputs saved to %s", cfg$dirs$output), "ok")

      }, error = function(e) {
        add_log(sprintf("Error: %s", conditionMessage(e)), "error")
        add_log("Check the inputs and try again.", "warn")
      })
    })

    running(FALSE)
  })


  # ============================================================================
  # MAP OUTPUTS
  # ============================================================================

  # Helper: project SpatRaster to EPSG:4326 for leaflet
  to_4326 <- function(r) terra::project(r, "EPSG:4326")

  # ── LST map ─────────────────────────────────────────────────────────────────
  output$map_lst <- renderLeaflet({
    res <- results()
    req(res)
    r    <- to_4326(res$lst_mean)
    vals <- terra::values(r, na.rm = TRUE)
    pal  <- colorNumeric("Spectral", domain = quantile(vals, c(.02,.98)),
                          reverse = TRUE, na.color = "transparent")
    leaflet() |>
      addProviderTiles("CartoDB.Positron", group = "Light") |>
      addProviderTiles("Esri.WorldImagery", group = "Satellite") |>
      addRasterImage(r, colors = pal, opacity = 0.8) |>
      addLegend("bottomright", pal = pal, values = vals,
                title = "LST (°C)", labFormat = labelFormat(suffix = "°C", digits = 1)) |>
      addLayersControl(baseGroups = c("Light","Satellite"),
                       options = layersControlOptions(collapsed = FALSE))
  })

  # ── Classified anomaly map ───────────────────────────────────────────────────
  output$map_classified <- renderLeaflet({
    res <- results()
    req(res)
    req(file.exists(res$path_classified))
    r   <- to_4326(terra::rast(res$path_classified))
    pal <- colorFactor(CLASS_COLOURS, domain = 1:6, na.color = "transparent")
    leaflet() |>
      addProviderTiles("CartoDB.Positron", group = "Light") |>
      addProviderTiles("Esri.WorldImagery", group = "Satellite") |>
      addRasterImage(r, colors = pal, opacity = 0.8) |>
      addLegend("bottomright", colors = CLASS_COLOURS, labels = CLASS_NAMES,
                title = "LST anomaly class", opacity = 0.9) |>
      addLayersControl(baseGroups = c("Light","Satellite"),
                       options = layersControlOptions(collapsed = FALSE))
  })

  # ── Priority map ─────────────────────────────────────────────────────────────
  output$map_priority <- renderLeaflet({
    res <- results()
    req(res)
    req(file.exists(res$path_priority))
    r   <- to_4326(terra::rast(res$path_priority))
    pal <- colorNumeric(c("#ffffcc","#feb24c","#f03b20","#bd0026"),
                         domain = c(0,1), na.color = "transparent")
    leaflet() |>
      addProviderTiles("CartoDB.Positron", group = "Light") |>
      addProviderTiles("Esri.WorldImagery", group = "Satellite") |>
      addRasterImage(r, colors = pal, opacity = 0.85) |>
      addLegend("bottomright", pal = pal, values = c(0,1),
                title = "Priority index",
                labFormat = labelFormat(digits = 2)) |>
      addLayersControl(baseGroups = c("Light","Satellite"),
                       options = layersControlOptions(collapsed = FALSE))
  })

  # ── Green distance map ───────────────────────────────────────────────────────
  output$map_green <- renderLeaflet({
    res <- results()
    req(res)
    req(file.exists(res$path_green))
    r    <- to_4326(terra::rast(res$path_green))
    vals <- terra::values(r, na.rm = TRUE)
    max_d <- max(vals, na.rm = TRUE)
    pal  <- colorNumeric("YlOrRd", domain = c(300, max_d), na.color = "transparent")
    leaflet() |>
      addProviderTiles("CartoDB.Positron", group = "Light") |>
      addProviderTiles("Esri.WorldImagery", group = "Satellite") |>
      addRasterImage(r, colors = pal, opacity = 0.8) |>
      addLegend("bottomright", pal = pal, values = c(300L, as.integer(max_d)),
                title = "Distance (m)",
                labFormat = labelFormat(suffix = " m", digits = 0)) |>
      addLayersControl(baseGroups = c("Light","Satellite"),
                       options = layersControlOptions(collapsed = FALSE))
  })


  # ============================================================================
  # CHART OUTPUTS
  # ============================================================================

  # LST warning
  output$lst_warning <- renderUI({
    req(results())
    tags$div(
      class = "alert alert-info alert-dismissible fade show mx-3 mt-3",
      role  = "alert",
      tags$strong("Note: "), "The maps show Land Surface Temperature (LST), ",
      "not air temperature. LST ≈ 2× air temperature anomaly. ",
      tags$a("Learn more", href = "#", onclick = "shinymeta_tab('about')"),
      tags$button(type = "button", class = "btn-close", `data-bs-dismiss` = "alert")
    )
  })

  # Class distribution bar chart
  output$chart_classes <- renderPlotly({
    res <- results()
    req(res)
    s <- res$city_stats
    df <- data.frame(
      class = factor(CLASS_NAMES, levels = rev(CLASS_NAMES)),
      pct   = c(s$pct_urban_cool_island, s$pct_urban_neutral,
                s$pct_urban_weak, s$pct_urban_moderate,
                s$pct_urban_strong, s$pct_urban_extreme),
      colour = CLASS_COLOURS
    )
    plot_ly(df, x = ~pct, y = ~class, type = "bar", orientation = "h",
            marker = list(color = ~colour),
            text = ~paste0(round(pct,1),"%"), textposition = "outside",
            hovertemplate = "%{y}: %{x:.1f}%<extra></extra>") |>
      layout(
        xaxis = list(title = "% of urban area", ticksuffix = "%"),
        yaxis = list(title = ""),
        showlegend = FALSE,
        margin = list(l = 10, r = 60)
      )
  })

  # Urban vs rural LST comparison
  output$chart_urban_rural <- renderPlotly({
    res <- results()
    req(res)
    s <- res$city_stats
    df <- data.frame(
      zone   = c("Urban", "Rural reference"),
      mean_C = c(s$lst_mean_urban_C, s$lst_mean_rural_C),
      colour = c("#d73027","#4575b4")
    )
    plot_ly(df, x = ~zone, y = ~mean_C, type = "bar",
            marker = list(color = ~colour),
            text = ~paste0(round(mean_C,1),"°C"), textposition = "outside",
            hovertemplate = "%{x}: %{y:.1f}°C<extra></extra>") |>
      layout(
        xaxis = list(title = ""),
        yaxis = list(title = "Mean LST (°C)"),
        showlegend = FALSE
      )
  })

  # Key indicators table
  output$stats_table <- renderTable({
    res <- results()
    req(res)
    s <- res$city_stats
    data.frame(
      Indicator = c(
        "Mean urban LST",
        "Mean rural LST",
        "Mean LST anomaly (SUHII)",
        "Max LST anomaly",
        "SD LST anomaly",
        "Urban area — Strong/Extreme class",
        "Urban area beyond 300 m from green",
        "Landsat scenes used",
        "Analysis window"
      ),
      Value = c(
        sprintf("%.1f°C", s$lst_mean_urban_C),
        sprintf("%.1f°C", s$lst_mean_rural_C),
        sprintf("%.2f°C", s$suhii_mean_C),
        sprintf("%.2f°C", s$suhii_max_C),
        sprintf("%.2f°C", s$suhii_sd_C),
        sprintf("%.1f%%", (s$pct_urban_strong %||% 0) + (s$pct_urban_extreme %||% 0)),
        sprintf("%.1f%%", s$pct_urban_beyond_300m_green %||% NA_real_),
        as.character(s$n_landsat_scenes),
        sprintf("%s – %s", s$start_date, s$end_date)
      )
    )
  }, striped = TRUE, hover = TRUE, bordered = FALSE, spacing = "s")


  # ============================================================================
  # REPORT TAB
  # ============================================================================

  output$report_frame <- renderUI({
    res <- results()
    req(res)
    if (!file.exists(res$path_report)) {
      return(tags$div(class = "p-4 text-muted", "Report not yet generated."))
    }

    # Build URL relative to the registered resource path /suhii_data/
    # path_report is like /data/<city>/Output/<city>_warm_2025_report.html
    # → strip the data_root prefix and prepend the resource path.
    rel <- sub(paste0("^", data_root, "/?"), "", res$path_report)
    report_url <- paste0("suhii_data/", rel)

    tags$div(
      class = "p-2",
      tags$div(
        class = "mb-2 d-flex gap-2 align-items-center",
        tags$a(
          class  = "btn btn-primary btn-sm",
          href   = report_url,
          target = "_blank",
          icon("external-link"), " Open in new tab"
        ),
        tags$span(class = "text-muted small",
          "The report is a self-contained HTML file you can share or publish.")
      ),
      tags$iframe(
        src    = report_url,
        style  = "width:100%; height:80vh; border:1px solid #2a2a2a; border-radius:6px;"
      )
    )
  })


  # ============================================================================
  # OUTPUT FOLDER PATH DISPLAY
  # ============================================================================

  output$output_path <- renderUI({
    res <- results()
    if (is.null(res)) {
      return(tags$span("Run an analysis to generate outputs."))
    }
    # Show the host-visible path. Inside Docker, /data is mounted from ./data
    # on the user's machine, so the practical location is data/<city>/Output/
    city_slug <- res$cfg$city_slug
    tagList(
      tags$div(tags$strong("Inside the project folder:")),
      tags$div(sprintf("data/%s/Output/", city_slug)),
      tags$br(),
      tags$div(class = "text-muted", "Full path inside container:"),
      tags$div(res$dirs_output %||% sprintf("/data/%s/Output/", city_slug))
    )
  })


  # ============================================================================
  # EXPLAINER MODALS (for "What does X mean?" links)
  # ============================================================================

  observeEvent(input$explain_lst, {
    showModal(modalDialog(
      title = "Land Surface Temperature (LST) vs air temperature",
      tags$p("LST is the radiometric skin temperature of surfaces measured by",
             "Landsat's thermal infrared sensor. It is",
             tags$strong("not"), " the air temperature."),
      tags$p("Over dark impervious surfaces in summer, LST can be",
             tags$strong("20–40°C higher"), " than near-surface air temperature."),
      tags$p("A rough conversion: LST anomaly ÷ 2 ≈ air temperature anomaly",
             "(Voogt & Oke 2003)."),
      easyClose = TRUE,
      footer = modalButton("Close")
    ))
  })

  observeEvent(input$explain_classes, {
    showModal(modalDialog(
      title = "SUHII classification thresholds",
      tags$p("Classes are based on the LST anomaly (surface temperature",
             "difference between urban pixel and rural reference), in °C."),
      tags$p(tags$strong("Source:"),
             " Stewart & Oke (2012, BAMS); Chen et al. (2019, IJERPH)."),
      tags$p("The global average urban-rural LST difference across 419 cities",
             "is", tags$strong("1.5 ± 1.2°C"), "(Peng et al. 2012)."),
      easyClose = TRUE,
      footer = modalButton("Close")
    ))
  })

  observeEvent(input$explain_priority, {
    showModal(modalDialog(
      title = "Intervention priority index",
      tags$p("Priority = 0.50 × norm(thermal anomaly)",
             "+ 0.30 × norm(green deficit)",
             "+ 0.20 × urban mask"),
      tags$p("Only urban pixels are shown. High-priority areas are hot,",
             "poorly served by green infrastructure, and built-up."),
      tags$p(tags$strong("Sources:"),
             " Maragkogiannis et al. (2024, Urban Climate);",
             " Morabito et al. (2015, Sci Rep)."),
      easyClose = TRUE,
      footer = modalButton("Close")
    ))
  })
}
