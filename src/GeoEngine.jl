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
using Dates
using ..Commons, ..Downloader, ..TileProcessor, ..Route, ..Geodesics, ..StatusMonitor
using ..AssemblyMonitor
using ..ddsFindScanner, ..JobFactory
using .Commons: chunk_pixel_size

export prepare_paths_and_location, process_target_area, create_precoverage_jobs, create_chunk_jobs


function generate_all_tiles(area::MapCoordinates, cfg::Dict, rootPath::String, rootPath_save::String)
    tiles_with_distance = Vector{Tuple{TileMetadata, Float64}}()
    lat_step = 0.125
    base_size_id = get(cfg, "size", 4)
    offset_dist_deg = 0.0 # Inizializza l'offset a zero

    # 1. Calcolo dei limiti della griglia standard, basata sul raggio
    radius_deg = area.radius * (1 / 60)
    lat_min_grid = floor((area.lat - radius_deg) / lat_step) * lat_step
    lat_max_grid = ceil((area.lat + radius_deg) / lat_step) * lat_step
    lon_min_grid = floor((area.lon - radius_deg / cosd(area.lat)) / tileWidth(area.lat)) * tileWidth(area.lat)
    lon_max_grid = ceil((area.lon + radius_deg / cosd(area.lat)) / tileWidth(area.lat)) * tileWidth(area.lat)

    # --- 2. ESPANSIONE DINAMICA DELLA GRIGLIA ---
    # Applichiamo un offset solo se siamo in modalità "Download Around Aircraft"
    if get(cfg, "mode", "manual") == "daa"
        heading_deg = 0.0
        has_heading = false
        try
            # Recuperiamo la direzione dalla connessione FGFS
            if GuiMode.FGFS_CONNECTION[] !== nothing && GuiMode.FGFS_CONNECTION[].actual !== nothing
                heading_deg = GuiMode.FGFS_CONNECTION[].actual.directionDeg
                has_heading = true
            end
        catch
            # Ignora, non applicheremo l'offset se ci sono problemi
        end

        if has_heading
            @info "GeoEngine: Applicazione espansione dinamica per DAA con heading: $heading_deg"
            offset_dist_deg = 0.25 # 1/4 di grado, come richiesto

            heading_rad = deg2rad(heading_deg)
            offset_lat_component = offset_dist_deg * cos(heading_rad)
            offset_lon_component = offset_dist_deg * sin(heading_rad)

            # Estendiamo il riquadro di ricerca nella direzione del moto
            if offset_lat_component > 0
                lat_max_grid += offset_dist_deg # Aumenta il limite superiore (Nord)
            else
                lat_min_grid -= offset_dist_deg # Diminuisce il limite inferiore (Sud)
            end

            # La correzione con cosd(area.lat) è necessaria per la longitudine
            if offset_lon_component > 0
                lon_max_grid += offset_dist_deg / cosd(area.lat) # Aumenta il limite Est
            else
                lon_min_grid -= offset_dist_deg / cosd(area.lat) # Diminuisce il limite Ovest
            end
        end
    end
    # --- FINE LOGICA DI ESPANSIONE ---

    @info "GeoEngine: Generazione griglia tile con ordinamento dal centro..."

    # 3. La scansione ora utilizzerà la griglia potenzialmente espansa
    for lat in lat_min_grid:lat_step:lat_max_grid
        current_lon_step = tileWidth(lat)
        for lon in lon_min_grid:current_lon_step:lon_max_grid
            latC = lat + lat_step / 2
            lonC = lon + current_lon_step / 2
            tile_id = index(latC, lonC)

            dist_nm = Geodesics.surface_distance(lonC, latC, area.lon, area.lat, Geodesics.localEarthRadius(latC)) / 1852.0

            # Filtra i tile fuori dal raggio, tenendo conto dell'offset applicato
            if dist_nm > (area.radius + offset_dist_deg * 60) # converti offset in gradi a NM per il confronto
                continue
            end

            # --- Logica di risoluzione adattiva e controllo sovrascrittura (invariata) ---
            alt_ft = 1000.0 # Valore di default
            try
                if GuiMode.FGFS_CONNECTION[] !== nothing && GuiMode.FGFS_CONNECTION[].actual !== nothing
                    alt_ft = GuiMode.FGFS_CONNECTION[].actual.altitudeFt
                end
            catch
            end
            adaptive_id = Commons.adaptive_size_id(base_size_id, alt_ft, dist_nm, 90.0)
            min_size_id = get(cfg, "sdwn", base_size_id)
            effective_size_id = max(min_size_id, adaptive_id)

            effective_params = getSizeAndCols(effective_size_id)
            if effective_params === nothing
                @warn "ID risoluzione non valido ($effective_size_id) per tile $tile_id. Salto."
                continue
            end
            effective_width, effective_cols = effective_params
            if ddsFindScanner.moveImage(rootPath, rootPath_save, tile_id, effective_size_id, cfg) in ("moved", "skip")
                @info "GeoEngine.generate_all_tiles: Tile $tile_id recuperato dalla cache o già presente."
                continue
            end

            tile = TileMetadata(
                tile_id, effective_size_id,
                lon, lat, lon + current_lon_step, lat + lat_step,
                Commons.x_index(latC, lonC), Commons.y_index(latC),
                lonC, latC, current_lon_step,
                effective_width,
                effective_cols
            )
            push!(tiles_with_distance, (tile, dist_nm))
        end
    end

    sort!(tiles_with_distance, by = item -> item[2])
    sorted_tiles = [item[1] for item in tiles_with_distance]
    return unique(t -> t.id, sorted_tiles)
end


"""
Crea una lista di job a bassa risoluzione per una pre-copertura veloce.
Viene generato un solo "chunk job" per ogni tile.
"""
function create_precoverage_jobs(
    tiles::Vector{TileMetadata},
    precover_size_id::Int,   # es. viene da cfg["sdwn"]
    tmp_dir::String
    )::Vector{ChunkJob}
    jobs = Vector{ChunkJob}()
    # livello preview: 1×1 per tile, ma con height proporzionata a Δlat/Δlon
    # ricavo una width coerente per quel livello
    width, _ = Commons.getSizeAndCols(precover_size_id)
    retries = 3  # oppure rendilo un parametro, se preferisci

    for tile in tiles
        # bbox unico: copre l’intero tile
        bbox = (
            lonLL = tile.lonLL, latLL = tile.latLL,
            lonUR = tile.lonUR, latUR = tile.latUR
            )

        # dimensioni chunk coerenti (1×1) = usa la variant tipizzata
        ps = Commons.chunk_pixel_size(
            width, 1,
            tile.latUR - tile.latLL,
            tile.lonUR - tile.lonLL
        )

        # naming coerente con l’assembler: tileId_sizeId_total_yflipped_x.png
        total_chunks = 1
        x, y = 1, 1
        y_flipped = 1
        temp_filename = "$(tile.id)_$(precover_size_id)_$(total_chunks)_$(y_flipped)_$(x).png"
        temp_path = joinpath(tmp_dir, temp_filename)

        # se già presente e “sano”, segna completato e salta
        if isfile(temp_path) && filesize(temp_path) > 64
            StatusMonitor.update_chunk_state(tile.id, (x, y), :completed, filesize(temp_path))
            continue
        end

        push!(jobs, ChunkJob(
            tile.id,
            precover_size_id,
            (x, y),
            bbox,
            (width = ps.width, height = ps.height),
            temp_path,
            retries
        ))
    end
    return jobs
end


function create_chunk_jobs(
    tiles::Vector{TileMetadata},
    cfg::Dict,
    tmp_dir::String
    )::Vector{ChunkJob}
    jobs = Vector{ChunkJob}()
    # accetta sia "attempts" che lo storico "attemps"
    retries = get(cfg, "attempts", get(cfg, "attemps", 5))

    for tile in tiles
        # passo angolare di un chunk in gradi
        ΔLon_deg = (tile.lonUR - tile.lonLL) / tile.cols
        ΔLat_deg = (tile.latUR - tile.latLL) / tile.cols
        abs(ΔLon_deg) < 1e-12 && continue  # evita div/0 ai poli

        # dimensioni pixel del chunk (coerenti tra producer e assembler)
        ps = Commons.chunk_pixel_size(tile)
        chunk_w = ps.width
        chunk_h = ps.height
        chunk_h <= 0 && continue

        total_chunks = tile.cols * tile.cols

        for y in 1:tile.cols, x in 1:tile.cols
            # flip Y per compatibilità con l’assembler
            y_flipped = tile.cols - y + 1

            # nome file: tileId_sizeId_total_yflipped_x.png
            temp_filename = "$(tile.id)_$(tile.size_id)_$(total_chunks)_$(y_flipped)_$(x).png"
            temp_path = joinpath(tmp_dir, temp_filename)

            # se già presente e "sano", segna completato e salta
            if isfile(temp_path) && filesize(temp_path) > 1024
                StatusMonitor.update_chunk_state(tile.id, (x, y), :completed, filesize(temp_path))
                continue
            end

            # bbox del chunk
            chunk_lonLL = tile.lonLL + (x - 1) * ΔLon_deg
            chunk_latLL = tile.latLL + (y - 1) * ΔLat_deg
            chunk_bbox  = (
                lonLL = chunk_lonLL,
                latLL = chunk_latLL,
                lonUR = chunk_lonLL + ΔLon_deg,
                latUR = chunk_latLL + ΔLat_deg
            )

            # job
            push!(jobs, ChunkJob(
                tile.id,
                tile.size_id,
                (x, y),
                chunk_bbox,
                (width = chunk_w, height = chunk_h),
                temp_path,
                retries
            ))
        end
    end

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

    # --- 1. PREPARAZIONE ---
    # Genera la lista di tile ad alta risoluzione necessari.
    tiles = generate_all_tiles(area, cfg, root_path, save_path)
    if isempty(tiles)
        @info "GeoEngine: Nessun tile da processare per l'area specificata."
        return nothing
    end

    # Avvia i servizi in background che ascolteranno le code.
    monitor_task = @async AssemblyMonitor.monitor_and_assemble(
        root_path, save_path, tmp_dir,
        merge(cfg, Dict("monitor_debug" => true)),   # <— attiva snapshot/log del monitor
        [t.id for t in tiles]
    )
    nworkers = get(cfg, "workers", 8)
    Downloader.start_chunk_downloads_parallel!(nworkers, map_server, cfg, root_path, save_path, tmp_dir)

    # --- 2. LOGICA DI PRE-COPERTURA (preview 0→2) ---
    # Mettiamo SEMPRE in coda, in quest’ordine, i livelli più grossolani (0..2)
    # prima di generare i job ad alta risoluzione. Questo garantisce una preview rapida.
    preview_levels = 0:min(2, get(cfg, "size", 4))  # limita a 0..2 e non supera la size target
    for lvl in preview_levels
        @info "GeoEngine: Fase 1 - Pre-coverage livello $lvl..."
        precoverage_jobs = create_precoverage_jobs(tiles, lvl, tmp_dir)
        if !isempty(precoverage_jobs)
            @info "GeoEngine: Accodamento di $(length(precoverage_jobs)) job di pre-copertura (lvl=$lvl)."
            Downloader.enqueue_chunk_jobs!(Downloader.CHUNK_QUEUE, precoverage_jobs)
        end
    end

    # --- 3. LOGICA DI DOWNLOAD PRINCIPALE ---
    @info "GeoEngine: Fase 2 - Generazione job ad alta risoluzione..."
    high_res_jobs = create_chunk_jobs(tiles, cfg, tmp_dir)
    @info "GeoEngine: Accodamento di $(length(high_res_jobs)) chunk-job ad alta risoluzione."
    Downloader.enqueue_chunk_jobs!(Downloader.CHUNK_QUEUE, high_res_jobs)


    # --- 4. ATTESA COMPLETAMENTO ---
    # Il ciclo di attesa rimane invariato, gestirà il completamento di TUTTI i job accodati.
    total_chunks = Downloader.PENDING_JOBS[]
    timeout_seconds = 600
    start_time = time()

    @info "In attesa del completamento di $total_chunks chunk totali (pre-copertura + alta risoluzione)..."
    while true
        if Downloader.PENDING_JOBS[] == 0 && !isready(Downloader.FALLBACK_QUEUE)
            sleep(2) # Periodo di grazia
            if Downloader.PENDING_JOBS[] == 0 && !isready(Downloader.FALLBACK_QUEUE)
                @info "Tutti i lavori e i potenziali fallback sono completati."
                break
            end
        end

        if time() - start_time > timeout_seconds
            @warn "Timeout attesa download superato! Procedo con l'assemblaggio."
            break
        end

        if second(now()) % 10 == 0
            percent_done = round((total_chunks - Downloader.PENDING_JOBS[]) / total_chunks * 100, digits=1)
            @info "Download in corso... $(Downloader.PENDING_JOBS[]) chunks rimanenti ($percent_done %)"
            sleep(1)
        end

        sleep(1)
    end

    @info "Fase di download terminata. Attendo l'assemblaggio finale..."
    wait(monitor_task)

    @info "GeoEngine: process_target_area terminato."
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

