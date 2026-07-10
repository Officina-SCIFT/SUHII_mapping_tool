# =============================================================================
# fn_report.R — Render the Quarto HTML report
# =============================================================================
#
# Provides render_report(), which renders report/report_template.qmd into
# a self-contained HTML file using Quarto.
# =============================================================================


#' Render the SUHII Quarto HTML report
#'
#' @param city_name            Original city name
#' @param city_slug            City slug
#' @param dirs                 Project directories
#' @param start_date           Date
#' @param end_date             Date
#' @param year                 Integer
#' @param season               "warm" or "cold"
#' @param max_cloud            Integer
#' @param altitude_band_height Integer
#' @param koppen_class         Two-letter Koppen code
#' @param project_root         Absolute path to project root
render_report <- function(city_name, city_slug, dirs,
                           start_date, end_date, year,
                           season, max_cloud, altitude_band_height,
                           koppen_class, project_root) {

  cli::cli_h2("HTML report")

  if (!nzchar(Sys.which("quarto"))) {
    cli::cli_alert_warning(c(
      "Quarto not found — report not generated.",
      "i" = "Install from https://quarto.org/docs/get-started/",
      "i" = "All other outputs (rasters, CSV, GeoJSON) are complete."
    ))
    return(invisible(NULL))
  }

  # Install report packages if needed
  extra <- c("quarto","knitr","kableExtra","leaflet.extras","tibble","scales")
  miss  <- extra[!(extra %in% installed.packages()[,"Package"])]
  if (length(miss) > 0) install.packages(miss, dependencies = TRUE)
  invisible(lapply(extra, function(p)
    suppressPackageStartupMessages(library(p, character.only = TRUE))))

  # Copy report assets to a temp render dir alongside the output
  report_src <- file.path(project_root, "report")
  render_dir <- file.path(dirs$output, "_report_render")
  dir.create(render_dir, showWarnings = FALSE, recursive = TRUE)
  for (f in c("report_template.qmd","report_style.css","references.bib")) {
    file.copy(file.path(report_src, f), file.path(render_dir, f), overwrite = TRUE)
  }

  report_filename <- sprintf("%s_%s_%d_report.html", city_slug, season, year)
  report_out_path <- file.path(dirs$output, report_filename)

  cli::cli_alert_info("Rendering {report_filename} (1–3 min)...")

  tryCatch({
    quarto::quarto_render(
      input          = file.path(render_dir, "report_template.qmd"),
      output_format  = "html",
      output_file    = report_filename,
      execute_params = list(
        city                 = city_name,
        city_slug            = city_slug,
        season               = season,
        year                 = year,
        start_date           = as.character(start_date),
        end_date             = as.character(end_date),
        max_cloud            = max_cloud,
        altitude_band_height = altitude_band_height,
        output_dir           = normalizePath(dirs$output),
        koppen_class         = koppen_class
      ),
      quiet = FALSE
    )
    # Move rendered file to output dir
    candidates <- c(
      file.path(render_dir, report_filename),
      file.path(getwd(),    report_filename)
    )
    for (cand in candidates) {
      if (file.exists(cand)) {
        file.copy(cand, report_out_path, overwrite = TRUE)
        break
      }
    }
    if (file.exists(report_out_path)) {
      cli::cli_alert_success("Report ready: {report_out_path}")
      cli::cli_alert_info('Open with: browseURL("{report_out_path}")')
    } else {
      cli::cli_alert_warning("Report file not found after rendering.")
    }
  }, error = function(e) {
    cli::cli_alert_warning(c(
      "Report rendering failed: {e$message}",
      "i" = "All other outputs are still complete.",
      "i" = 'Render manually: quarto::quarto_render("{file.path(render_dir, \\"report_template.qmd\\")}")'
    ))
  })

  unlink(render_dir, recursive = TRUE)
  invisible(report_out_path)
}
