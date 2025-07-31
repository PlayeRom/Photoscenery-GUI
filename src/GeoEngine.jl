###############################################################################
# GeoEngine.jl
#
# This module implements the core orchestration logic for processing geographic
# target areas into assembled orthophoto tiles.
#
# Given a latitude, longitude, radius and user-defined configuration, it:
#   1. Computes the list of tiles needed to cover the requested area.
#   2. Subdivides each tile into smaller chunks for download.
#   3. Downloads each chunk in parallel from a map server.
#   4. Monitors a temporary directory for complete sets of chunks per tile.
#   5. Assembles, compresses, and relocates the final DDS files.
#
# It serves as the central entry point for launching tile generation jobs
# via the GUI or other automation layers (e.g., API requests).
#
# Dependencies:
#   - Commons.jl      (coordinate models, configuration)
#   - Downloader.jl   (HTTP-based tile downloads)
#   - TileAssembler.jl (canvas stitching and DDS compression)
#   - AssemblyMonitor.jl (asynchronous tile monitoring and conversion)
#
# Typical entry point:
#   GeoEngine.process_target_area(area, cfg, map_server, root, save)
#
# Author: [abassign@gmail.com Adriano Bassignana], © [2025-07]
###############################################################################

module GeoEngine

using Printf: @sprintf
using Logging
using FilePathsBase
using ..Commons, ..Downloader, ..TileProcessor, ..Route, ..Geodesics, ..StatusMonitor
using ..AssemblyMonitor
using ..ddsFindScanner

export prepare_paths_and_location, process_target_area


"""
calculate_dynamic_size_id(
    area::MapCoordinates,
    cfg::Dict
    )::Int

    Computes a dynamic size identifier (`sizeId`) based on the geographic extent and
    configuration parameters.

    This function determines the appropriate tile size (resolution) to use for a given area,
    possibly adapting to user-specified preferences (e.g. `"sdwn"`) or applying default logic
    based on zoom level and area size.

    # Arguments
    - `area::MapCoordinates`: The target area (center and radius in degrees).
    - `cfg::Dict`: Configuration dictionary, may include:
    - `"sdwn"`: Optional sub-sampling level (e.g. 1 = full res, 2 = half res).
    - `"size"`: Default size exponent (e.g. 2 → 1024×1024 tiles).

    # Returns
    - `Int`: Computed size ID (typically used to index tile resolution).

    # Notes
    - If `sdwn` is explicitly provided in the config, it overrides default logic.
    - This function is intended to centralize resolution decisions across the pipeline.

    # Example
    size_id = calculate_dynamic_size_id(area, cfg)
"""
function calculate_dynamic_size_id(dist_nm::Float64, base_size_id::Int, sdwn_min_val::Union{Int,Nothing})::Int
    # 1. Determina il "pavimento" (minimo size_id) effettivo,
    #    non può essere più alto del valore di partenza.
    sdwn_min_val = coalesce(sdwn_min_val, base_size_id)
    effective_min_size_id = min(base_size_id, coalesce(sdwn_min_val, base_size_id))

    # 2. Calcola di quanti livelli ridurre la risoluzione.
    #    La regola è: 1 step a 0nm, +1 ogni 10nm.
    reduction_steps = floor(Int, dist_nm / 10)

    # 3. Calcola la nuova risoluzione applicando la riduzione.
    calculated_size_id = base_size_id - reduction_steps

    # 4. Applica il "pavimento": la risoluzione finale non può essere
    #    inferiore al minimo effettivo. Il risultato non può neanche
    #    essere negativo.
    final_size_id = max(effective_min_size_id, calculated_size_id, 0)

    return final_size_id
end

"""
generate_all_tiles(
    area::MapCoordinates,
    cfg::Dict,
    root_path::String,
    save_path::String
    )::Vector{TileMetadata}

    High-level function that generates all tiles covering the specified geographic area.

    This function wraps the lower-level tile generation logic (e.g. `create_single_tiles`)
    and optionally includes filtering, deduplication, or other enhancements in the future.
    Currently, it delegates directly to `create_single_tiles`.

    # Arguments
    - `area::MapCoordinates`: The center coordinates and radius defining the area of interest.
    - `cfg::Dict`: Configuration options controlling tile layout and resolution.
    - `root_path::String`: Path to the final DDS output directory.
    - `save_path::String`: Path to the working directory for intermediate outputs.

    # Returns
    - `Vector{TileMetadata}`: List of tile descriptors that define the processing scope.

    # Notes
    - Designed to be extensible: more complex tile selection (e.g. by priority or coverage map)
    could be added here later.
    - Typically called at the start of the `process_target_area` pipeline.

    # Example
    tiles = generate_all_tiles(area, cfg, "/Orthophotos", "/Orthophotos-saved")
"""
function generate_all_tiles(area::MapCoordinates, cfg::Dict, rootPath::String, rootPath_save::String)
    all_tiles = Vector{TileMetadata}()
    lat_step = 0.125
    base_size_id = get(cfg, "size", 4) # Leggiamo la risoluzione base dalla GUI

    # Rimuoviamo il calcolo iniziale di width/cols da qui

    # Calcola i limiti dell'area (logica invariata)
    radius_deg = area.radius * (1 / 60)
    lat_min_grid = floor((area.lat - radius_deg) / lat_step) * lat_step
    lat_max_grid = ceil((area.lat + radius_deg) / lat_step) * lat_step
    lon_min_grid = floor((area.lon - radius_deg / cosd(area.lat)) / tileWidth(area.lat)) * tileWidth(area.lat)
    lon_max_grid = ceil((area.lon + radius_deg / cosd(area.lat)) / tileWidth(area.lat)) * tileWidth(area.lat)

    @info "GeoEngine: Generazione griglia tile..."

    # Scansione della griglia
    for lat in lat_min_grid:lat_step:lat_max_grid
        current_lon_step = tileWidth(lat)
        for lon in lon_min_grid:current_lon_step:lon_max_grid
            latC = lat + lat_step / 2
            lonC = lon + current_lon_step / 2
            tile_id = index(latC, lonC)

            dist_nm = Geodesics.surface_distance(lonC, latC, area.lon, area.lat, Geodesics.localEarthRadius(latC)) / 1852.0

            # Filtra subito i tile fuori dal raggio
            dist_nm > area.radius && continue

            # Calcolo dello --sdwn (invariato)
            sdwn_val = get(cfg, "sdwn", base_size_id) # Se sdwn non è specificato, il minimo è la base stessa
            effective_size_id = calculate_dynamic_size_id(dist_nm, base_size_id, sdwn_val)

            # Calcoliamo width e cols QUI, usando la risoluzione effettiva del tile corrente
            effective_params = getSizeAndCols(effective_size_id)
            if effective_params === nothing
                @warn "ID risoluzione non valido ($effective_size_id) per tile $tile_id. Salto."
                continue
        end
        effective_width, effective_cols = effective_params

        # Logica di sovrascrittura --over (invariata)
        overwrite_mode = get(cfg, "over", 0)
        if overwrite_mode < 2
            existing_versions = ddsFindScanner.find_all_versions_by_id(tile_id)
            if !isempty(existing_versions)
                if overwrite_mode == 0
                    @info "GeoEngine: Salto tile $tile_id, file esistente (--over 0)."
                    continue
                    elseif overwrite_mode == 1
                    max_existing_width = maximum(get(v, "width", 0) for v in existing_versions)
                        if max_existing_width >= effective_width
                            @info "GeoEngine: Salto tile $tile_id, versione esistente più grande o uguale."
                            continue
                        end
                    end
                end
            end

            # Prova a recuperare dalla cache (invariato)
            if ddsFindScanner.moveImage(rootPath, rootPath_save, tile_id, effective_size_id, cfg) in ("moved", "skip")
                @info "GeoEngine: Tile $tile_id recuperato dalla cache o già presente."
                continue
            end

            # Crea i metadati del tile con i valori di width e cols CORRETTI
            tile = TileMetadata(
                tile_id, effective_size_id,
                lon, lat, lon + current_lon_step, lat + lat_step,
                Commons.x_index(latC, lonC), Commons.y_index(latC),
                lonC, latC, current_lon_step,
                effective_width,
                effective_cols
                )
            push!(all_tiles, tile)
        end
    end

    return unique(t -> t.id, all_tiles)
end

"""
create_chunk_jobs(
    tiles::Vector{TileMetadata},
    cfg::Dict,
    tmp_dir::String
    )::Vector{ChunkJob}

    Generates the list of `ChunkJob` tasks corresponding to image chunks that must be downloaded
    in order to assemble the final orthophoto tiles.

    Each tile is subdivided into smaller chunks based on its internal layout (typically 2×2 or 4×4)
    and each chunk is represented as a `ChunkJob` that knows how to compute its bounding box,
    its target filename, and its position within the full tile.

    # Arguments
    - `tiles::Vector{TileMetadata}`: List of tiles to be assembled.
    - `cfg::Dict`: Configuration dictionary that may include zoom level, overlap, and other download parameters.
    - `tmp_dir::String`: Path to the temporary directory where chunk PNGs will be saved.

    # Returns
    - `Vector{ChunkJob}`: A flat list of jobs that can be processed independently and in parallel.

    # Notes
    - Each chunk job is independent and suitable for parallel download.
    - The output of this function is typically fed into a job queue for download processing.

    # Example
    jobs = create_chunk_jobs(tiles, cfg, "/path/to/tmp")
"""
function create_chunk_jobs(tiles::Vector{TileMetadata}, cfg::Dict, tmp_dir::String)
    jobs = Vector{ChunkJob}()
    retries = get(cfg, "attemps", 5)

    for tile in tiles
        ΔLon_deg = (tile.lonUR - tile.lonLL) / tile.cols
        ΔLat_deg = (tile.latUR - tile.latLL) / tile.cols
        chunk_pixel_width = Int(tile.width / tile.cols)

        if abs(ΔLon_deg) < 1e-9; continue; end
        aspect_ratio = abs(ΔLat_deg / ΔLon_deg)
        chunk_pixel_height = round(Int, chunk_pixel_width * aspect_ratio)
        if chunk_pixel_height <= 0; continue; end
        total_chunks = tile.cols * tile.cols

        for y in 1:tile.cols, x in 1:tile.cols
            chunk_xy = (x, y)
            # Crea il nome del chunk che sarà elemento della matrice di costruzione del dile completo
            y_flipped = tile.cols - y + 1
            temp_filename = "$(tile.id)_$(tile.size_id)_$(total_chunks)_$(y_flipped)_$(x).png"
            temp_path = joinpath(tmp_dir, temp_filename)

            if isfile(temp_path) && filesize(temp_path) > 1024
                StatusMonitor.update_chunk_state(tile.id, chunk_xy, :completed, filesize(temp_path))
                continue
            end

            chunk_lonLL = tile.lonLL + (x - 1) * ΔLon_deg
            chunk_latLL = tile.latLL + (y - 1) * ΔLat_deg
            chunk_lonUR = chunk_lonLL + ΔLon_deg
            chunk_latUR = chunk_latLL + ΔLat_deg

            bbox = (lonLL=chunk_lonLL, latLL=chunk_latLL, lonUR=chunk_lonUR, latUR=chunk_latUR)
            pixel_size = (width=chunk_pixel_width, height=chunk_pixel_height)

            # Crea un ChunkJob (da Commons) senza URL
            push!(jobs, ChunkJob(tile.id, tile.size_id, chunk_xy, bbox, pixel_size, temp_path, retries))
        end
    end
    return jobs
end

"""
create_single_tiles(
    area::MapCoordinates,
    cfg::Dict,
    root_path::String,
    save_path::String
    )::Vector{TileMetadata}

    Generates the list of `TileMetadata` objects representing orthophoto tiles to be downloaded
    and assembled for the specified geographic area.

    This function computes the spatial extent and tiling grid based on the input coordinates and
    configuration parameters (tile size, overlap factor, zoom level, etc.). It returns a list of tiles
    that define how the full-resolution image should be partitioned and processed.

    # Arguments
    - `area::MapCoordinates`: The central coordinate and radius defining the target area.
    - `cfg::Dict`: Configuration dictionary with tiling parameters:
    - `"size"`: tile size exponent (e.g., 2 for 1024×1024).
    - `"over"`: overlap factor to avoid sharp seams between tiles.
    - `"sdwn"`: zoom level or subdownsampling factor (optional).
    - `root_path::String`: Base path where assembled DDS tiles will be placed.
    - `save_path::String`: Path where temporary data and intermediate results can be stored.

    # Returns
    - `Vector{TileMetadata}`: List of metadata objects, each representing a tile to be processed.

    # Notes
    - This function is purely computational and does not access the network or filesystem.
    - Used as a first step in the processing pipeline (`process_target_area`).

    # Example
    tiles = create_single_tiles(area, cfg, "/Orthophotos", "/Orthophotos-saved")
"""
function create_single_tiles(area::MapCoordinates, cfg::Dict, tmp_dir::String)
    jobs = Vector{ChunkJob}()
    size_id = cfg["size"]
    w, cols = Commons.getSizeAndCols(size_id)

    # 1 solo tile centrato
    tile_id = Commons.index(area.lat, area.lon)
    bbox = Commons.latDegByCentralPoint(area.lat, area.lon, area.radius)
    temp_path = joinpath(tmp_dir, "$(tile_id)_$(size_id)_1_1_1.png")

    push!(jobs, ChunkJob(tile_id, size_id, (1,1), bbox, (w, w), temp_path, 0))
    return jobs
end

"""
process_target_area(
    area::MapCoordinates,
    cfg::Dict,
    map_server::MapServer,
    root_path::String,
    save_path::String
    )

    Main orchestration function that processes a geographic target area by generating tiles,
    launching chunk download workers, and triggering asynchronous DDS assembly.

    This function executes the complete pipeline for acquiring and assembling orthophoto tiles
    from a remote map server. It:
    1. Computes the list of tiles covering the area of interest.
    2. Launches the DDS assembly monitor asynchronously (to allow real-time processing).
    3. Generates all chunk download jobs for the tiles.
    4. Starts the parallel download of chunk images using worker tasks.
    5. Waits for all downloads to complete before returning.

    # Arguments
    - `area::MapCoordinates`: The geographic area to process (center and radius in degrees).
    - `cfg::Dict`: Configuration dictionary (e.g. tile size, overlap, server index).
    - `map_server::MapServer`: The remote imagery server used to retrieve tile images.
    - `root_path::String`: Root path where the final DDS tiles will be stored.
    - `save_path::String`: Working path where temporary chunk files and converted tiles go.

    # Notes
    - The DDS assembly system is launched early and processes tiles in real-time as chunks are completed.
    - This function is non-blocking only for DDS assembly; it waits for downloads to finish.
    - Intended to be called from higher-level modules such as `GuiMode`.

    # Example
    GeoEngine.process_target_area(area, cfg, server, "/Orthophotos", "/Orthophotos-saved")
"""
function process_target_area(
    area::MapCoordinates,
    cfg::Dict,
    map_server::MapServer,
    root_path::String,
    save_path::String
    )
    tmp_dir = joinpath(save_path, "tmp")
    mkpath(tmp_dir)

    # 1. genera la lista di tile
    tiles = generate_all_tiles(area, cfg, root_path, save_path)
    isempty(tiles) && return nothing

    @info "⚙️ GeoEngine.process_target_area: Calling monitor_and_assemble synchronously for test"

    # 2. crea i chunk-job
    jobs = create_chunk_jobs(tiles, cfg, tmp_dir)
    @info "GeoEngine.process_target_area $(length(jobs)) chunk-job"


    """
    monitor_and_assemble(root_path, save_path, tmp_dir, cfg,
    all_tiles_needed::Vector{Int},
    check_interval::Int = 2,
    num_workers::Int = 4)
    """
    monitor_task = @async AssemblyMonitor.monitor_and_assemble(
        root_path,
        save_path,
        tmp_dir,
        cfg,
        [t.id for t in tiles]
            )


    # 3. avvia prima i worker, poi metti i job
    nworkers = min(4, length(jobs))
    @info "GeoEngine.process_target_area avvio: $nworkers workers"
    Downloader.start_chunk_downloads_parallel!(nworkers, map_server, cfg)

    Downloader.enqueue_chunk_jobs!(Downloader.CHUNK_QUEUE, jobs)
    @info "GeoEngine.process_target_area: enqueue completato"

    @info "GeoEngine.process_target_area #1"

    # 4. attendi che tutti i chunk siano pronti o saltati
    while Downloader.PENDING_JOBS[] > 0
        sleep(1)
    end

    @info "GeoEngine.process_target_area #2"

    wait(monitor_task)


    @info "GeoEngine: process_target_area terminato"
end


# -----------------------------------------------------------------------------
#  2. Path & location helper
# -----------------------------------------------------------------------------

"""
prepare_paths_and_location(cfg::Dict, home_path::String)

Prepares the essential file system paths and target coordinates required for a download job.

    This function determines:
    1. The save path for generated tiles (typically `Orthophotos-saved`).
    2. The root path for final output tiles (typically `Orthophotos`).
    3. The list of coordinate centers (`route_vec`) around which tiles will be generated.

    If the configuration includes a predefined route, it is used directly. Otherwise, a single
    target area is created based on the provided `lat`, `lon`, and `radius`.

    # Arguments
    - `cfg::Dict`: Configuration dictionary containing keys like:
    - `"lat"`, `"lon"`: Central coordinates of the area (required).
    - `"radius"`: Radius of coverage (in degrees, required).
    - `"save_path"` (optional): Custom override for the output path.
    - `"path"` (optional): Path to an existing orthophoto root directory.
    - `home_path::String`: Base directory, typically the path of the current module or application.

    # Returns
    - `route_vec::Vector{Tuple{Float64, Float64}}`: List of center points for target areas.
    - `radius::Float64`: The radius used for area generation.
    - `root_path::String`: Path where final `.dds` tiles will be stored.
    - `save_path::String`: Path where intermediate and temporary data will be stored.

    # Notes
    - The logic gracefully handles missing folders by creating them if needed.
    - If no explicit path is given, it defaults to searching for a folder named `Orthophotos`.

    # Example
    route, radius, root, save = prepare_paths_and_location(cfg, @__DIR__)
"""
function prepare_paths_and_location(cfg::Dict{String,Any}, home_path::AbstractString)
    route_vec = Vector{Any}()
    position_on_route = nothing
    radius_nm = get(cfg, "radius", 10.0)

    # 1. Priorità massima: coordinate lat/lon dirette
    if haskey(cfg, "lat") && haskey(cfg, "lon")
        StatusMonitor.log_message("GeoEngine: Localizzazione tramite coordinate dirette Lat/Lon...")
        push!(route_vec, (cfg["lat"], cfg["lon"]))

        # 2. Priorità media: file di rotta
    elseif get(cfg, "route", nothing) !== nothing
        StatusMonitor.log_message("GeoEngine: Localizzazione tramite ROUTE ($(cfg["route"]))...")
        (loaded, pos) = Route.loadRoute(cfg["route"], radius_nm)
        append!(route_vec, loaded)
        position_on_route = pos

        # 3. Priorità bassa: codice ICAO
    elseif get(cfg, "icao", nothing) !== nothing
        StatusMonitor.log_message("GeoEngine: Localizzazione tramite ICAO ($(cfg["icao"]))...")
        (lat, lon, err) = Route.selectIcao(cfg["icao"], radius_nm)
        err == 0 && lat !== nothing && push!(route_vec, (lat, lon))

        # 4. Caso di default
    else
        StatusMonitor.log_message("GeoEngine: Coordinate di default (modalità demo).")
        push!(route_vec, (47.26, 11.34))
    end

    # Logica per percorsi di salvataggio
    root_path = get(cfg, "path", nothing)
    # Se nessun percorso è stato fornito dalla configurazione, ne cerchiamo uno di default.
    if root_path === nothing
        @info "Nessun percorso specificato, ricerca di una cartella 'Orthophotos' esistente..."
        candidates = [
            normpath(joinpath(dirname(dirname(home_path)), "photoscenery", "Orthophotos")),
            normpath(joinpath(dirname(home_path), "photoscenery", "Orthophotos")),
            normpath(joinpath(home_path, "photoscenery", "Orthophotos")),
            ]
        idx = findfirst(isdir, candidates)

        # Se viene trovata una cartella esistente, usiamo quella.
        # Altrimenti, usiamo il terzo candidato come default da creare.
        root_path = if idx !== nothing
            @info "Trovata cartella esistente: $(candidates[idx])"
            candidates[idx]
        else
            @info "Nessuna cartella esistente, verrà usato il percorso di default: $(candidates[3])"
            candidates[3]
        end
    end
    mkpath(root_path)
    StatusMonitor.log_message("GeoEngine: Percorso Orthophoto impostato su ⇒ $root_path")

    # Logica per save_path (invariata)
    save_path_str = get(cfg, "save", nothing)
    nosave = get(cfg, "nosave", false)
    save_path = nosave ? nothing : (save_path_str isa AbstractString ? save_path_str : root_path * "-saved")

    if save_path !== nothing
        mkpath(save_path)
        StatusMonitor.log_message("GeoEngine: Percorso di salvataggio impostato su ⇒ $save_path")
    end

    return route_vec, position_on_route, root_path, save_path
end


end # module GeoEngine

