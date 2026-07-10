# =============================================================================
# ui.R — SUHII Mapping Tool — Shiny User Interface
# =============================================================================
#
# Built with bslib for a modern, responsive layout.
# No installation required — runs entirely in the browser via Docker.
#
# Layout:
#   Sidebar  : all user inputs + run button + progress log
#   Main area: tabbed output (maps, charts, report, downloads)
# =============================================================================

library(shiny)
library(bslib)
library(leaflet)
library(plotly)

ui <- page_sidebar(

  # ── Theme ──────────────────────────────────────────────────────────────────
  title = tags$span(
    tags$img(
      src   = "scift.jpg",
      height = "36px",
      style  = "margin-right:10px; vertical-align:middle; border-radius:4px;"
    ),
    tags$span(
      "SUHII Mapping Tool",
      style = "font-weight:500; letter-spacing:0.02em;"
    )
  ),
  theme = bs_theme(
    version      = 5,
    bg           = "#111111",
    fg           = "#e8e8e8",
    primary      = "#ffffff",
    secondary    = "#2a2a2a",
    success      = "#4caf7d",
    info         = "#5b9bd5",
    warning      = "#e6a817",
    danger       = "#d73027",
    base_font    = font_google("Inter"),
    heading_font = font_google("Inter"),
    "sidebar-bg"       = "#1a1a1a",
    "sidebar-fg"       = "#e8e8e8",
    "sidebar-border-color" = "#2a2a2a",
    "navbar-bg"        = "#000000",
    "navbar-fg"        = "#ffffff",
    "card-bg"          = "#1c1c1c",
    "card-border-color"= "#2a2a2a",
    "body-bg"          = "#111111",
    "sidebar-width"    = "300px"
  ),
  fillable = TRUE,

  # ── Custom CSS ─────────────────────────────────────────────────────────────
  tags$head(tags$style(HTML("
    /* Navbar */
    .bslib-page-sidebar > .navbar {
      background: #000 !important;
      border-bottom: 1px solid #2a2a2a;
    }
    /* Sidebar */
    .sidebar-panel, .bslib-sidebar-layout > .sidebar {
      background: #1a1a1a !important;
      border-right: 1px solid #2a2a2a !important;
    }
    /* Cards */
    .card {
      background: #1c1c1c !important;
      border: 1px solid #2a2a2a !important;
    }
    .card-header {
      background: #222 !important;
      border-bottom: 1px solid #2a2a2a !important;
      font-weight: 500;
      font-size: 0.88rem;
      letter-spacing: 0.03em;
      text-transform: uppercase;
      color: #aaa !important;
    }
    /* Nav tabs */
    .nav-tabs .nav-link {
      color: #aaa !important;
      border: none !important;
      font-size: 0.88rem;
      letter-spacing: 0.02em;
    }
    .nav-tabs .nav-link.active {
      color: #fff !important;
      background: transparent !important;
      border-bottom: 2px solid #fff !important;
    }
    .nav-tabs { border-bottom: 1px solid #2a2a2a !important; }
    /* Run button */
    #run_btn {
      background: #fff !important;
      color: #000 !important;
      border: none !important;
      font-weight: 600;
      letter-spacing: 0.03em;
    }
    #run_btn:hover { background: #ddd !important; }
    /* Inputs */
    .form-control, .form-select {
      background: #222 !important;
      border: 1px solid #333 !important;
      color: #e8e8e8 !important;
    }
    .form-control:focus, .form-select:focus {
      border-color: #666 !important;
      box-shadow: 0 0 0 2px rgba(255,255,255,0.08) !important;
    }
    /* Progress log */
    #log_output {
      background: #0d0d0d !important;
      color: #b0e8b0 !important;
      border: 1px solid #2a2a2a !important;
      font-family: 'Courier New', monospace;
      font-size: 11px;
    }
    /* Status badge */
    .badge { font-weight: 500; }
    /* Links */
    a { color: #7eb8e8 !important; }
    a:hover { color: #aad4f5 !important; }
    /* Leaflet */
    .leaflet-container { border-radius: 4px; }
    /* hr */
    hr { border-color: #2a2a2a !important; }
    /* Alert info */
    .alert-info {
      background: #1a2535 !important;
      border: 1px solid #2a3f5f !important;
      color: #8fbfe8 !important;
    }
    /* Small muted text */
    .text-muted { color: #888 !important; }
    /* Table */
    .table { color: #e8e8e8 !important; }
    .table-striped > tbody > tr:nth-of-type(odd) > * {
      background: #222 !important;
      color: #e8e8e8;
    }
    /* SCIFT footer bar */
    .scift-footer {
      border-top: 1px solid #2a2a2a;
      padding-top: 12px;
      margin-top: 8px;
    }
  ")))
,
  # ── Sidebar ────────────────────────────────────────────────────────────────
  sidebar = sidebar(
    width = 320,
    open  = "always",

    # Header
    tags$div(
      class = "text-muted small mb-3",
      "Map surface urban heat islands for any city worldwide.",
      "Enter a city name and click ", tags$strong("Run analysis"), "."
    ),
    tags$div(
      class = "alert alert-info py-2 px-3 small mb-2",
      tags$strong("First time?"), " Read the ",
      tags$a("Quick Start Guide",
        href   = "https://github.com/Officina-SCIFT/SUHII_mapping/blob/main/DOCKER_QUICKSTART.md",
        target = "_blank"),
      ". An OpenTopography API key is required (free)."
    ),

    hr(),

    # ── Step 1: City ─────────────────────────────────────────────────────────
    tags$h6("1. City", class = "text-primary fw-semibold"),

    textInput(
      "city", "City name",
      value       = "",
      placeholder = "e.g. Florence, Berlin, São Paulo"
    ),
    tags$div(
      class = "text-muted small mb-3",
      "Use the name as it appears in OpenStreetMap.",
      "For small towns add the province: ", tags$code("Trofarello, Torino"), "."
    ),

    hr(),

    # ── Step 2: Run ───────────────────────────────────────────────────────────
    tags$h6("2. Run", class = "text-primary fw-semibold"),

    actionButton(
      "run_btn", "Run analysis",
      class = "btn-primary w-100 mb-2",
      icon  = icon("play")
    ),

    # Status indicator
    uiOutput("status_badge"),

    hr(),

    # ── Progress log ──────────────────────────────────────────────────────────
    tags$h6("Progress", class = "text-muted"),
    verbatimTextOutput("log_output") |>
      tagAppendAttributes(
        style = paste(
          "max-height:200px; overflow-y:auto;",
          "font-size:11px; background:#1e1e1e; color:#d4d4d4;",
          "border-radius:6px; padding:8px;"
        )
      ),

    hr(),

    # ── Footer ────────────────────────────────────────────────────────────────
    tags$div(
      class = "scift-footer",
      tags$div(
        class = "d-flex align-items-center gap-2 mb-2",
        tags$img(src = "scift.jpg", height = "28px",
                 style = "border-radius:3px;"),
        tags$span(
          style = "font-size:0.8rem; font-weight:500; color:#aaa;",
          "Officina SCIFT"
        )
      ),
      tags$div(
        class = "text-muted",
        style = "font-size:0.75rem; line-height:1.6;",
        tags$a("municipiozero.it/scift",
               href = "https://municipiozero.it/scift/", target = "_blank"),
        " · ",
        tags$a("Richiardi et al. (2025)",
               href = "https://doi.org/10.1016/j.susgeo.2025.100006",
               target = "_blank"),
        tags$br(),
        tags$a("Planetary Computer",
               href = "https://planetarycomputer.microsoft.com/", target = "_blank"),
        " · ",
        tags$a("OpenStreetMap",
               href = "https://www.openstreetmap.org/", target = "_blank"),
        " · ",
        tags$a("OpenTopography",
               href = "https://opentopography.org/", target = "_blank")
      )
    )
  ),

  # ── Main output area ───────────────────────────────────────────────────────
  navset_card_tab(
    id = "main_tabs",

    # Tab 1: Maps
    nav_panel(
      title = tagList(icon("map"), " Maps"),
      value = "maps",

      # LST warning callout
      uiOutput("lst_warning"),

      layout_columns(
        col_widths = c(6, 6),

        card(
          card_header("Mean Land Surface Temperature (LST)"),
          leafletOutput("map_lst", height = "380px"),
          card_footer(
            class = "text-muted small",
            "Morning (~10:00 local time) surface temperature, °C. ",
            actionLink("explain_lst", "What does LST mean?")
          )
        ),

        card(
          card_header("Thermal anomaly — SUHII classification"),
          leafletOutput("map_classified", height = "380px"),
          card_footer(
            class = "text-muted small",
            "LST anomaly vs rural reference. ",
            actionLink("explain_classes", "About the classes")
          )
        )
      ),

      layout_columns(
        col_widths = c(6, 6),

        card(
          card_header("Intervention priority map"),
          leafletOutput("map_priority", height = "380px"),
          card_footer(
            class = "text-muted small",
            "Hot + poorly-served by green infrastructure + urban. ",
            actionLink("explain_priority", "How is this calculated?")
          )
        ),

        card(
          card_header("Distance from green areas (3-30-300 rule)"),
          leafletOutput("map_green", height = "380px"),
          card_footer(
            class = "text-muted small",
            "Areas > 300 m from any park or green space.",
            tags$a(
              "Konijnendijk (2022)",
              href   = "https://doi.org/10.1007/s11676-022-01523-z",
              target = "_blank"
            )
          )
        )
      )
    ),

    # Tab 2: Charts
    nav_panel(
      title = tagList(icon("chart-bar"), " Charts"),
      value = "charts",

      layout_columns(
        col_widths = c(6, 6),

        card(
          card_header("SUHII class distribution"),
          plotlyOutput("chart_classes", height = "340px"),
          card_footer(
            class = "text-muted small",
            "% of urban area in each LST anomaly class."
          )
        ),

        card(
          card_header("Urban vs rural LST"),
          plotlyOutput("chart_urban_rural", height = "340px"),
          card_footer(
            class = "text-muted small",
            "Mean surface temperature of built-up vs reference areas."
          )
        )
      ),

      card(
        card_header("Key indicators"),
        tableOutput("stats_table")
      )
    ),

    # Tab 3: Report
    nav_panel(
      title = tagList(icon("file-lines"), " Report"),
      value = "report",
      uiOutput("report_frame")
    ),

    # Tab 4: Output files
    nav_panel(
      title = tagList(icon("folder-open"), " Output files"),
      value = "outputs",

      card(
        card_header("Where to find your results"),
        card_body(
          tags$p(
            "All outputs have been saved automatically to your computer, in the",
            "folder you mounted as ", tags$code("data/"), " when starting Docker:"
          ),
          tags$div(
            class = "alert alert-secondary",
            style = "font-family: monospace; font-size: 0.9rem;",
            uiOutput("output_path")
          ),
          tags$p(
            class = "text-muted small",
            "No download needed — the files are already on your machine,",
            "ready to open in QGIS, Excel, or any web browser."
          ),

          tags$hr(),

          tags$h6("What's in the folder", class = "text-primary"),
          tags$div(
            class = "table-responsive",
            tags$table(
              class = "table table-sm table-striped",
              tags$thead(tags$tr(
                tags$th("File"), tags$th("Type"), tags$th("What it contains")
              )),
              tags$tbody(
                tags$tr(tags$td(tags$code("*_LST_MEAN.tif")),
                        tags$td("Raster"),
                        tags$td("Mean seasonal land surface temperature (°C)")),
                tags$tr(tags$td(tags$code("*_thermal_anomaly.tif")),
                        tags$td("Raster"),
                        tags$td("LST anomaly vs rural reference (°C)")),
                tags$tr(tags$td(tags$code("*_SUHI.tif")),
                        tags$td("Raster"),
                        tags$td("Normalised SUHII index (0–1)")),
                tags$tr(tags$td(tags$code("*_anomaly_classified.tif")),
                        tags$td("Raster"),
                        tags$td("6-class heat island severity map")),
                tags$tr(tags$td(tags$code("*_priority_map.tif")),
                        tags$td("Raster"),
                        tags$td("Intervention priority index (0–1)")),
                tags$tr(tags$td(tags$code("*_distance_green_areas.tif")),
                        tags$td("Raster"),
                        tags$td("Distance from green areas, 3-30-300 rule (m)")),
                tags$tr(tags$td(tags$code("*_anomaly_classified.geojson")),
                        tags$td("Vector"),
                        tags$td("Classified anomaly polygons for GIS")),
                tags$tr(tags$td(tags$code("*_priority_map.geojson")),
                        tags$td("Vector"),
                        tags$td("Priority polygons for GIS")),
                tags$tr(tags$td(tags$code("*_city_stats.csv")),
                        tags$td("Table"),
                        tags$td("All summary statistics (open in Excel)")),
                tags$tr(tags$td(tags$code("*_report.html")),
                        tags$td("Report"),
                        tags$td("Full interactive report (open in any browser)"))
              )
            )
          )
        )
      )
    ),

    # Tab 5: Methodology
    nav_panel(
      title = tagList(icon("circle-info"), " About"),
      value = "about",

      layout_columns(
        col_widths = c(8, 4),

        card(
          card_header("What this tool measures — and what it does not"),
          card_body(
            tags$div(
              class = "alert alert-warning",
              tags$strong("Important: LST \u2260 air temperature"),
              tags$p(
                "This tool measures ", tags$strong("Land Surface Temperature (LST)"),
                ": the radiometric skin temperature of surfaces (asphalt, rooftops,",
                "soil) as seen from Landsat satellite. It is ",
                tags$strong("not"), " the air temperature you feel when walking outside."
              ),
              tags$p(
                "LST can be 20–40°C higher than near-surface air temperature over",
                "dark impervious surfaces in summer. A rule of thumb: a ",
                tags$strong("2°C LST anomaly"), " corresponds roughly to ",
                tags$strong("~1°C"), " of air temperature anomaly",
                " (Voogt & Oke 2003, Remote Sens. Environ.)."
              )
            ),
            tags$h5("Classification thresholds (LST anomaly)"),
            tags$table(
              class = "table table-sm table-striped",
              tags$thead(tags$tr(
                tags$th("Class"), tags$th("LST anomaly"), tags$th("Interpretation")
              )),
              tags$tbody(
                tags$tr(tags$td(tags$span(class="badge bg-primary", "Cool island")),   tags$td("< 0°C"),       tags$td("Urban cooler than rural")),
                tags$tr(tags$td(tags$span(class="badge bg-info text-dark", "Neutral")),     tags$td("0–1°C"),     tags$td("No significant heat island")),
                tags$tr(tags$td(tags$span(class="badge bg-warning text-dark","Weak")),      tags$td("1–2.5°C"),   tags$td("Detectable surface heat island")),
                tags$tr(tags$td(tags$span(class="badge bg-orange text-dark","Moderate"),
                                style="--bs-badge-bg:#f46d43"),                              tags$td("2.5–4.5°C"), tags$td("Significant surface heat island")),
                tags$tr(tags$td(tags$span(class="badge bg-danger", "Strong")),          tags$td("4.5–6.5°C"), tags$td("Intense surface heat island")),
                tags$tr(tags$td(tags$span(class="badge", style="background:#a50026;color:#fff","Extreme")), tags$td("> 6.5°C"), tags$td("Extreme hotspot"))
              )
            ),
            tags$p(
              class = "text-muted small",
              "Sources: Stewart & Oke (2012, BAMS); Chen et al. (2019, IJERPH);",
              "Peng et al. (2012, Environ. Sci. Technol.)"
            ),
            tags$h5("Intervention priority index"),
            tags$p(
              "Priority = 0.50 × thermal anomaly + 0.30 × green deficit + 0.20 × urban mask.",
              " Urban pixels only."
            ),
            tags$p(
              class = "text-muted small",
              "Weights: Maragkogiannis et al. (2024); Morabito et al. (2015, Sci Rep)."
            )
          )
        ),

        card(
          card_header("Data sources"),
          card_body(
            tags$ul(
              class = "list-unstyled",
              tags$li(icon("satellite"), " ",
                tags$strong("Landsat C2L2"),
                tags$br(),
                tags$span(class="text-muted small",
                  "USGS / Microsoft Planetary Computer. Free, anonymous.")),
              tags$li(class="mt-2", icon("map"), " ",
                tags$strong("OpenStreetMap"),
                tags$br(),
                tags$span(class="text-muted small",
                  "osmdata / Overpass API. ODbL licence.")),
              tags$li(class="mt-2", icon("mountain"), " ",
                tags$strong("SRTM GL1 DEM"),
                tags$br(),
                tags$span(class="text-muted small",
                  "OpenTopography. Free API key required.")),
              tags$li(class="mt-3", icon("book-open"), " ",
                tags$strong("Scientific reference"),
                tags$br(),
                tags$span(class="text-muted small",
                  tags$a(
                    "Richiardi et al. (2025) — Sustainable Geosciences",
                    href   = "https://doi.org/10.1016/j.susgeo.2025.100006",
                    target = "_blank"
                  )
                )
              )
            )
          )
        ),

        # SCIFT card
        card(
          card_header("Developed by"),
          card_body(
            tags$div(
              class = "d-flex align-items-center gap-3 mb-3",
              tags$img(
                src   = "scift.jpg",
                height = "64px",
                style  = "border-radius:6px;"
              ),
              tags$div(
                tags$p(
                  style = "font-size:1.1rem; font-weight:600; margin:0;",
                  "Officina SCIFT"
                ),
                tags$p(
                  class = "text-muted small",
                  style = "margin:2px 0 0;",
                  "Science, Craft, Innovation, Future, Technology"
                )
              )
            ),
            tags$ul(
              class = "list-unstyled small",
              tags$li(
                tags$i(class="fa fa-map-marker", `aria-hidden`="true"), " Italy"
              ),
              tags$li(class="mt-1",
                tags$a(
                  href   = "https://municipiozero.it/scift/",
                  target = "_blank",
                  "municipiozero.it/scift"
                )
              ),
              tags$li(class="mt-1",
                tags$a(
                  href   = "https://www.instagram.com/scift_officina/",
                  target = "_blank",
                  icon("instagram"), " scift_officina"
                )
              ),
              tags$li(class="mt-1",
                tags$a(
                  href = "mailto:sciftofficina@protonmail.com",
                  icon("envelope"), " sciftofficina@protonmail.com"
                )
              )
            ),
            tags$hr(),
            tags$p(
              class = "text-muted small mb-0",
              "This tool is open source and released under the GNU GPL v3 licence.",
              tags$br(),
              tags$a(
                href   = "https://github.com/Officina-SCIFT/SUHII_mapping",
                target = "_blank",
                icon("github"), " GitHub repository"
              )
            )
          )
        )
      )
    )
  )
)
