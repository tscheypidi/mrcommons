#' @title calcFAOForestRelocate
#' @description Calculates the cellular MAgPIE forest and other land area correction based on FAO forestry data and LUH2v2.
#'
#'
#'
#' @param selectyears default on "past"
#' @param nclasses options are either "six", "seven" or "nine".
#' \itemize{
#' \item "six" includes the original land use classes "crop", "past", "forestry", "forest", "urban" and "other"
#' \item "seven" separates primary and secondary forest and includes "crop", "past", "forestry", "primforest", "secdforest", "urban" and "other"
#' \item "nine" adds the separation of pasture and rangelands, as well as a differentiation of primary and secondary non-forest vegetation and therefore returns "crop", "past", "range", "forestry", "primforest", "secdforest", "urban", "primother" and "secdother"
#' }
#' @param cells    if cellular is TRUE: "magpiecell" for 59199 cells or "lpjcell" for 67420 cells
#' @return List of magpie object with results on cellular level, weight on cellular level, unit and description.
#' @author Kristine Karstens, Felicitas Beier, Patrick v. Jeetze
#' @examples
#'
#' \dontrun{
#' calcOutput("FAOForestRelocate")
#' }
#' @import madrat
#' @importFrom magclass setNames new.magpie
#' @importFrom nleqslv nleqslv
#' 
#' @export

calcFAOForestRelocate <- function(selectyears = "past", nclasses = "seven", cells = "magpiecell") {

  # Load cellular and country data
  countrydata <- calcOutput("LanduseInitialisation", aggregate = FALSE, nclasses = "seven", fao_corr = TRUE, selectyears = selectyears, cellular = FALSE)
  LUH2v2_init <- calcOutput("LanduseInitialisation", aggregate = FALSE, nclasses = "seven", fao_corr = FALSE, selectyears = selectyears, cellular = TRUE, cells = cells)

  totalarea <- dimSums(LUH2v2_init, dim = c(1, 3))

  if (cells == "lpjcell") {
    mapping   <- toolGetMappingCoord2Country()
    cellvegc  <- calcOutput("LPJmL_new", version = "LPJmL4_for_MAgPIE_84a69edd", climatetype = "GSWP3-W5E5:historical", subtype = "vegc", stage="smoothed", aggregate = FALSE)[,getYears(countrydata),]
    countries <- unique(gsub("[^A-Z]","", getCells(cellvegc)))
    getCells(LUH2v2_init) <-  paste(c(1:67420), gsub("[^A-Z]","", getCells(cellvegc)), sep=".")
    getCells(cellvegc)    <-  paste(c(1:67420), gsub("[^A-Z]","", getCells(cellvegc)), sep=".")
    names(dimnames(LUH2v2_init))[1] <- "celliso"
    names(dimnames(cellvegc))[1]    <- "celliso"
    mapping   <- data.frame(mapping, celliso= paste(c(1:67420), gsub("[^A-Z]","", getCells(cellvegc)), sep="."), stringsAsFactors = F)
  } else {
    mapping   <- toolMappingFile(type = "cell", name = "CountryToCellMapping.csv", readcsv = TRUE)
    countries <- unique(mapping$iso)

    cellvegc <- calcOutput("LPJmL_new", version = "LPJmL4_for_MAgPIE_84a69edd", climatetype = "GSWP3-W5E5:historical", subtype = "vegc", stage="smoothed", aggregate = FALSE)[,getYears(countrydata),]
    # reduce to 59199 cells and rename cells
    cellvegc <- toolCoord2Isocell(cellvegc)
  }

  forests <- c("primforest", "secdforest", "forestry")
  nature  <- c(forests, "other")
  landuse <- c(nature, "urban", "crop", "past")

  # reduce, if nessessary to FAO
  reduce <- increase <- round(countrydata - toolCountryFill(toolAggregate(LUH2v2_init, rel = mapping, from = "celliso", to = "iso", partrel = TRUE), fill = 0), 8)
  reduce[reduce > 0]     <- 0
  increase[increase < 0] <- 0

  LUH2v2_init <- add_columns(LUH2v2_init, "to_be_allocated", dim = 3.1)
  LUH2v2_init[, , "to_be_allocated"] <- 0

  # grep land areas dependent on vegetation carbon density
  if (is.null(getYears(cellvegc))) getYears(cellvegc) <- getYears(countrydata)

  # normalized vegetation carbon (with small correction to ensure values between [0,1))
  .calcMax <- function(x) {
    x <- as.data.table(as.data.frame(x))
    y <- merge(x[,-5],x[,max(Value), by = Region:Year])
    return(as.magpie(y,tidy=TRUE, spatial=c(1,3)))
  }
  cellvegc_n <- cellvegc/(setNames(.calcMax(cellvegc),NULL) + 10^-10)
  
  # weight function to determine correct cellweights for area removal
  findweight <- function(p, cellarea, isoreduction, cellweight) {
    dimSums(cellarea * (1 - (1 - cellweight)^p), dim = 1) + isoreduction + 10^-10
  }

  # loop over countries and years
  for (iso in countries) {
    for (t in getYears(countrydata)) {

      ###########################
      ### Reduction procedure ###
      ###########################

      # loop over all land use categories, that has to be reallocated
      for (cat in nature) {

        # check if area has to be cleared
        if (reduce[iso, t, cat] != 0) {

          # for other land cell with highest vegc and for all forest categories lowest vegc should be cleared first
          if (cat == "other") {
            cellweight <- cellvegc_n[iso, t, ]
          } else {
            cellweight <- (1 - 10^-16 - cellvegc_n[iso, t, ])
          }

          # check for one cell countries
          if (length(getCells(LUH2v2_init[iso, t, cat])) == 1) {
            # trivial case of one cell countries
            remove <- -setCells(reduce[iso, t, cat], nm = "GLO")
          } else {
            # determine correct parameter for weights for multiple cell countries (weights below zero indicate an error)
            p <- nleqslv(1, findweight, cellarea = LUH2v2_init[iso, t, cat], isoreduction = reduce[iso, t, cat], cellweight = cellweight)$x
            if (p < 0) stop(verbosity = 2, paste0("Negative weight of p=", p, " for: ", cat, " ", iso, " ", t))
            remove <- LUH2v2_init[iso, t, cat] * (1 - (1 - cellweight)^p)
          }

          # remove area from cells and put to "to_be_allocated" area
          LUH2v2_init[iso, t, cat] <- LUH2v2_init[iso, t, cat] - remove
          LUH2v2_init[iso, t, "to_be_allocated"] <- LUH2v2_init[iso, t, "to_be_allocated"] + remove
          reduce[iso, t, cat] <- 0
        }
      }

      ############################
      ### Allocation procedure ###
      ############################

      # relocate other land to areas with low vegetation carbon density
      # check if other land has to be filled
      if (increase[iso, t, "other"] != 0) {
        cellweight <- (1 - 10^-16 - cellvegc_n[iso, t, ])


        # check for one cell countries
        if (length(getCells(LUH2v2_init[iso, t, "other"])) == 1) {
          # trivial case of one cell countries
          add <- setCells(increase[iso, t, cat], nm = "GLO")
        } else {
          # determine correct parameter for weights for multiple cell countries (weights below zero indicate an error)
          p <- nleqslv(1, findweight, cellarea = LUH2v2_init[iso, t, "to_be_allocated"], isoreduction = -increase[iso, t, "other"], cellweight = cellweight)$x
          if (p < 0) stop(verbosity = 2, paste0("Negative weight of p=", p, " for: ", cat, " ", iso, " ", t))
          add <- LUH2v2_init[iso, t, "to_be_allocated"] * (1 - (1 - cellweight)^p)
        }

        # move area from "to_be_allocated" area to other land
        LUH2v2_init[iso, t, "other"] <- LUH2v2_init[iso, t, "other"] + add
        LUH2v2_init[iso, t, "to_be_allocated"] <- LUH2v2_init[iso, t, "to_be_allocated"] - add
        increase[iso, t, "other"] <- 0
      }

      # relocate forest land to remaining "to_be_allocated" area
      # check if forests has to be filled
      if (any(increase[iso, t, forests] != 0)) {

        # move area from "to_be_allocated" area to forests
        forests_share <- increase[iso, t, forests] / setNames(dimSums(increase[iso, t, forests], dim = 3), NULL)
        LUH2v2_init[iso, t, forests] <- LUH2v2_init[iso, t, forests] + setCells(forests_share, "GLO") * setNames(LUH2v2_init[iso, t, "to_be_allocated"], NULL)

        LUH2v2_init[iso, t, "to_be_allocated"] <- 0
        increase[iso, t, ] <- 0
      }

      ############################
      ### Check reallocation   ###
      ############################

      if (!all(round(dimSums(LUH2v2_init[iso, t, landuse], dim = 1), 3) == round(countrydata[iso, t, landuse], 3))) {
        warning(paste0("Missmatch in data for in ", iso, " ", t))
      } 
    }
  }

  if (nclasses == "nine") {
    LUH2v2_nocorr <- calcOutput("LUH2v2", aggregate = FALSE, landuse_types = "LUH2v2", irrigation = FALSE, cellular = TRUE, selectyears = selectyears, round=8)

    # calculate shares of primary and secondary non-forest vegetation
    totother_luh <- dimSums(LUH2v2_nocorr[, , c("primn", "secdn")], dim = 3)
    primother_shr <- LUH2v2_nocorr[, , "primn"] / setNames(totother_luh, NULL)
    primother_shr[is.na(primother_shr)] <- 0
    secdother_shr <- LUH2v2_nocorr[, , "secdn"] / setNames(totother_luh, NULL)
    secdother_shr[is.na(secdother_shr)] <- 0
    # multiply shares of primary and secondary non-forest veg with corrected other land
    primother <- primother_shr * setNames(LUH2v2_init[, , "other"], NULL)
    secdother <- secdother_shr * setNames(LUH2v2_init[, , "other"], NULL)

    out <- mbind(
      LUH2v2_init[, , "crop"],
      setNames(LUH2v2_nocorr[, , c("pastr")], "past"),
      setNames(LUH2v2_nocorr[, , c("range")], "range"),
      LUH2v2_init[, , "urban"],
      LUH2v2_init[, , forests],
      setNames(primother, "primother"),
      setNames(secdother, "secdother")
    )
  } else if (nclasses == "seven") {
    out <- LUH2v2_init[, , landuse]
  } else if (nclasses == "six") {
    out <- mbind(
      LUH2v2_init[, , "crop"],
      LUH2v2_init[, , "past"],
      LUH2v2_init[, , "urban"],
      LUH2v2_init[, , "forestry"],
      setNames(LUH2v2_init[, , "primforest"] + LUH2v2_init[, , "secdforest"], "forest"),
      LUH2v2_init[, , "other"]
    )
  }

  if (!all(round(dimSums(out, dim = c(1, 3)), 3) == round(totalarea, 3))) {
    vcat(2, "Something went wrong. Missmatch in total land cover area after reallocation.")
  }

  return(list(
    x = out,
    weight = NULL,
    unit = "Mha",
    description = "Cellular land use initialisation data for different land pools FAO forest corrected",
    isocountries = FALSE
  ))
}
