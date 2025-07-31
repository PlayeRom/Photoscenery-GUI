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
include("AppLogger.jl")
include("Geodesics.jl")  # Has no internal dependencies

# Modules depending on base modules
include("Connector.jl")  # Requires Geodesics
include("Commons.jl")    # Requires Connector

# Modules with higher-level dependencies
include("StatusMonitor.jl")
include("ScanDir.jl")
include("Route.jl")           # Requires Commons and Geodesics
include("ddsFindScanner.jl")  # Requires Commons
include("Downloader.jl")      # Requires Commons
include("png2ddsDXT1.jl")
include("TileProcessor.jl")   # Requires Commons
include("TileAssembler.jl")   # Uses png2ddsDXT1 + Commons
include("AssemblyMonitor.jl") # Requires Commons

# Configuration and core logic modules
include("AppConfig.jl")
include("GeoEngine.jl")

# Application mode modules
include("BatchMode.jl")
include("dds2pngDXT1.jl")
include("GuiMode.jl")

using .dds2pngDXT1

# -----------------------------------------------------------------------------
# Public Symbols
# -----------------------------------------------------------------------------

export BatchMode, GuiMode

end # module Photoscenary

