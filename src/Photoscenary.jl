# ───────────────────────────────────────────────────────────────────────────────
#  Photoscenary – Root Module
# ───────────────────────────────────────────────────────────────────────────────
#  Responsibilities:
#    • CLI argument parsing (delegated to AppConfig)
#    • Logger initialization (delegated to AppLogger)
#    • TUI status monitoring (StatusMonitor)
#    • Geographical data preparation (GeoEngine)
#    • Tile processing dispatch (TileProcessor via GeoEngine)
#    • Background task management
# ───────────────────────────────────────────────────────────────────────────────

module Photoscenary

# -----------------------------------------------------------------------------
# External Dependencies
# -----------------------------------------------------------------------------

# Set this environment variable to suppress warnings when methods are overwritten,
# which can occur frequently during interactive development and testing.
if !haskey(ENV, "JULIA_WARN_OVERWRITE")
    ENV["JULIA_WARN_OVERWRITE"] = "no"
end

# -----------------------------------------------------------------------------
# Internal Modules (Order is important due to inter-dependencies)
# -----------------------------------------------------------------------------

# Module loading order is critical for dependency resolution

# Base modules with no internal dependencies
# 1. Moduli Base (poche o nessuna dipendenza interna)
include("png2ddsDXT1.jl")
include("dds2pngDXT1.jl")
include("Geodesics.jl")
include("Connector.jl")         # Dipende da Geodesics
include("Commons.jl")
include("AppLogger.jl")
include("ScanDir.jl")
include("ddsFindScanner.jl")    # Dipende da Commons
include("TileAssembler.jl")     # Dipende da Commons, png2ddsDXT1, ddsFindScanner
include("StatusMonitor.jl")

# 2. Moduli di Utilità (dipendono dai moduli base)
include("JobFactory.jl")        # Dipende da Commons
include("TileProcessor.jl")     # Dipende da Commons
include("Route.jl")             # Dipende da Commons, Geodesics
include("Downloader.jl")        # Dipende da Commons, JobFactory, StatusMonitor
include("AssemblyMonitor.jl")   # Dipende da Commons

# 3. Moduli Principali (usano i moduli di utilità)
include("GeoEngine.jl")         # Dipende da molti moduli, va caricato dopo di essi
# 4. Moduli di alto livello (interfaccia e configurazione)

include("AppConfig.jl")

include("BatchMode.jl")
include("GuiMode.jl")           # Dipende da quasi tutto, va caricato per ultimo

using .dds2pngDXT1

# -----------------------------------------------------------------------------
# Public Symbols
# -----------------------------------------------------------------------------

export BatchMode, GuiMode

end # module Photoscenary

