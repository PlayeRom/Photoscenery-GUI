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

export prepare_paths_and_location, process_target_area, create_precoverage_jobs, create_chunk_jobs, process_fill_holes

function generate_all_tiles(
    area::MapCoordinates,
    cfg::Dict,
    rootPath::String,
    rootPath_save::String;
    heading_deg::Union{Nothing,Float64}=nothing,   # ← passato dal chiamante in DAA
    alt_ft::Union{Nothing,Float64}=nothing         # ← passato dal chiamante (quota AGL)
    )
    # (tile, metrica_per_ordinamento, distanza_radiale) per tie-break
    tiles_with_distance = Vector{Tuple{TileMetadata, Float64, Float64}}()

    lat_step      = 0.125
    base_size_id  = get(cfg, "size", 4)
    mode_is_daa   = get(cfg, "mode", "manual") == "daa"
    offset        = 0.0

    if mode_is_daa offset = 0.25 end  # ~1/4° leggera espansione bbox per sicurezza bordi (non altera il filtro circolare)

    # 1) Griglia base dal raggio (in gradi)
    # ATTENZIONE Questo algortmo per ricavare lat_min_grid lat_max_grid lon_min_grid lon_max_grid è essenziale che non venga variato in funzione
    # del metodo atottato di arrotondamento, altrimenti avremo disallineamento nei tiles!
    radius_deg   = area.radius * (1 / 60)
    lat_min_grid = floor((area.lat - radius_deg - offset) / lat_step) * lat_step
    lat_max_grid = ceil((area.lat + radius_deg + offset) / lat_step) * lat_step
    lon_min_grid = floor(((area.lon - offset) - radius_deg / cosd(area.lat)) / tileWidth(area.lat)) * tileWidth(area.lat)
    lon_max_grid = ceil(((area.lon + offset) + radius_deg / cosd(area.lat)) / tileWidth(area.lat)) * tileWidth(area.lat)

    @info "GeoEngine: Generazione griglia tile (filtro radiale; LOD anisotropo in DAA)…"

    # 3) Parametri ellisse DAA: larghezza = diametro area ⇒ B = radius
    A = get(cfg, "daa_forward_nm", area.radius * 1.5)  # semi‑asse lungo rotta
    B = area.radius                                    # semi‑asse laterale (richiesta)
    θ = mode_is_daa && heading_deg !== nothing ? deg2rad(heading_deg) : 0.0

    for lat in lat_min_grid:lat_step:lat_max_grid
        current_lon_step = tileWidth(lat)
        for lon in lon_min_grid:current_lon_step:lon_max_grid
            latC = lat + lat_step / 2
            lonC = lon + current_lon_step / 2
            tile_id = index(latC, lonC)

            # --- INCLUSIONE: SOLO cerchio centrato (copertura invariata) ---
            radial_nm = Geodesics.surface_distance(
                lonC, latC, area.lon, area.lat, Geodesics.localEarthRadius(latC)
                ) / 1852.0
            radial_nm <= area.radius || continue

            # --- METRICA per priorità/LOD ---
            metric_nm = radial_nm
            if mode_is_daa
                Δnorth_nm = (latC - area.lat) * 60.0
                Δeast_nm  = (lonC - area.lon) * Commons.longDegOnLatitudeNm(latC)
                x_forward =  Δnorth_nm * cos(θ) + Δeast_nm * sin(θ)
                y_side    = -Δnorth_nm * sin(θ) + Δeast_nm * cos(θ)
                # distanza “unitaria” ellittica riportata in NM (scala con radius)
                metric_nm = sqrt((x_forward/A)^2 + (y_side/B)^2) * area.radius
            end

            # --- LOD adattivo + pavimento sdwn ---
            alt_used_ft = alt_ft === nothing ? 1000.0 : alt_ft
            adaptive_id  = Commons.adaptive_size_id(base_size_id, alt_used_ft, metric_nm, 90.0)
            min_size_id  = get(cfg, "sdwn", base_size_id)
            effective_id = max(min_size_id, adaptive_id)

            params = getSizeAndCols(effective_id)
            if params === nothing
                @warn "ID risoluzione non valido ($effective_id) per tile $tile_id. Salto."
                continue
            end
            effective_width, effective_cols = params

            # Cache (salta se già presente / spostato)
            if ddsFindScanner.has_suitable_tile(tile_id, effective_id, rootPath, rootPath_save, cfg)
                @info "GeoEngine.generate_all_tiles: Tile $tile_id già presente con risoluzione adeguata. Salto."
                continue
            end

            tile = TileMetadata(
                tile_id, effective_id,
                lon, lat, lon + current_lon_step, lat + lat_step,
                Commons.x_index(latC, lonC), Commons.y_index(latC),
                lonC, latC, current_lon_step,
                effective_width, effective_cols
                )
            push!(tiles_with_distance, (tile, metric_nm, radial_nm))
        end
    end

    # Ordinamento con tie‑break: prima metrica ellittica (o radiale), poi distanza radiale
    sort!(tiles_with_distance, by = item -> (item[2], item[3]))
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
    save_path::String,
    heading_deg::Union{Nothing,Float64}=nothing,
    alt_ft::Union{Nothing,Float64}=nothing
    )
    tmp_dir = joinpath(save_path, "tmp")
    mkpath(tmp_dir)

    # --- 1. PREPARAZIONE ---
    # Genera la lista di tile ad alta risoluzione necessari.
    tiles = generate_all_tiles(
        area, cfg, root_path, save_path;
        heading_deg=heading_deg, alt_ft=alt_ft
    )
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

    # --- 2. LOGICA DI PRE-COPERTURA (dinamica) ---
    # Scegli un SOLO livello di preview in [0..2] in funzione del fabbisogno reale dell'area.
    # 1) peak_id = livello massimo richiesto tra i tile (più fine)
    # 2) dyn_preview = peak_id - 2 (clamp a [0,2]) per ridurre il "gap"
    # 3) sdwn_floor = rispetto il minimo scelto dall'utente (clamp a [0,2])
    # 4) precover_id = max(dyn_preview, sdwn_floor)

    # 1) ricavo il livello minimo effettivo richiesto dai tile generati
    min_required_unclamped = minimum(t -> t.size_id, tiles)

    # 2) gap configurabile (default 1), clamp a [0,2] e senza superare la size target
    precover_gap   = get(cfg, "precover_gap", 1)
    precover_level = clamp(min_required_unclamped - precover_gap, 0, 2)
    precover_level = min(precover_level, get(cfg, "size", 4))  # di fatto è già ≤2, ma resta coerente con size

    @info "GeoEngine: Fase 1 - Pre-coverage livello $(precover_level) (min_area=$(min_required_unclamped), gap=$(precover_gap))"
    precoverage_jobs = create_precoverage_jobs(tiles, precover_level, tmp_dir)
    if !isempty(precoverage_jobs)
        @info "GeoEngine: Accodamento di $(length(precoverage_jobs)) job di pre-copertura (lvl=$(precover_level))."
        Downloader.enqueue_high!(precoverage_jobs)
    end

    # --- 3. LOGICA DI DOWNLOAD PRINCIPALE ---
    @info "GeoEngine: Fase 2 - Generazione job ad alta risoluzione..."
    high_res_jobs = create_chunk_jobs(tiles, cfg, tmp_dir)
    @info "GeoEngine: Accodamento di $(length(high_res_jobs)) chunk-job ad alta risoluzione."
    ##Downloader.enqueue_chunk_jobs!(Downloader.CHUNK_QUEUE, high_res_jobs)
    if get(cfg, "mode", "manual") == "daa"
        frac = get(cfg, "daa_priority_frac", 0.35)
        cut  = clamp(ceil(Int, length(high_res_jobs) * frac), 1, length(high_res_jobs))
        jobs_hi = high_res_jobs[1:cut]
        jobs_lo = cut < length(high_res_jobs) ? high_res_jobs[(cut+1):end] : Commons.ChunkJob[]
        Downloader.enqueue_high!(jobs_hi)
        Downloader.enqueue_low!(jobs_lo)
        @info "GeoEngine: enqueue HI=$(length(jobs_hi)) / LO=$(length(jobs_lo)) (frac=$(frac))"
    else
        Downloader.enqueue_low!(high_res_jobs)
    end


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


"""
count_existing_neighbors(latC::Float64, lonC::Float64) -> Int

Data la coordinata centrale di un potenziale tassello, calcola gli ID dei suoi
4 vicini cardinali (N, E, S, O) e restituisce il numero di quelli che esistono già.
"""
function count_existing_neighbors(latC::Float64, lonC::Float64)::Int
    neighbor_count = 0
    lat_step = 0.125
    lon_step = Commons.tileWidth(latC)

    # Definiamo SOLO le 4 direzioni cardinali (Nord, Sud, Est, Ovest)
    neighbor_offsets = [
        (lat_step, 0.0),      # N (Nord)
        (-lat_step, 0.0),     # S (Sud)
        (0.0, lon_step),      # E (Est)
        (0.0, -lon_step)      # O (Ovest)
        ]

    for (d_lat, d_lon) in neighbor_offsets
        # Calcola il centro e l'ID del vicino
        neighbor_latC = latC + d_lat
        neighbor_lonC = lonC + d_lon
        neighbor_id = Commons.index(neighbor_latC, neighbor_lonC)

        # Controlla se il vicino esiste
        if !isempty(ddsFindScanner.find_file_by_id(neighbor_id))
            neighbor_count += 1
        end
    end

    return neighbor_count
end


"""
process_fill_holes(bounds, cfg, map_server, root_path, save_path, tmp_dir)

Analizza un'area definita da `bounds`, identifica i tasselli mancanti che
hanno almeno 3 vicini cardinali e accoda i job per il loro download.
"""
function process_fill_holes(bounds, cfg::Dict, map_server::Downloader.MapServer, root_path::String, save_path::String, tmp_dir::String)
    @info "GeoEngine: Inizio analisi 'fill holes' per l'area" bounds

    # ... (tutta la logica di scansione della griglia e identificazione dei buchi rimane identica) ...
    lat_min = floor(bounds.south / 0.125) * 0.125
    lat_max = ceil(bounds.north / 0.125) * 0.125
    lon_min = bounds.west
    lon_max = bounds.east

    missing_tiles = Vector{Commons.TileMetadata}()
    base_size_id = get(cfg, "size", 4)

    @info "Scansione griglia da lat ($lat_min, $lat_max) e lon ($lon_min, $lon_max)"
    for lat in lat_min:0.125:lat_max
        lon_step = Commons.tileWidth(lat)
        for lon in floor(lon_min / lon_step) * lon_step : lon_step : ceil(lon_max / lon_step) * lon_step
            latC = lat + 0.125 / 2
            lonC = lon + lon_step / 2
            tile_id = Commons.index(latC, lonC)

            if isempty(ddsFindScanner.find_file_by_id(tile_id))
                neighbor_count = count_existing_neighbors(latC, lonC)
                if neighbor_count >= 3
                    @info "Trovato buco interno da riempire: ID $tile_id (vicini: $neighbor_count)"
                    width, cols = Commons.getSizeAndCols(base_size_id)
                    x_idx, y_idx = Commons.x_index(latC, lonC), Commons.y_index(latC)

                    tile = Commons.TileMetadata(
                        tile_id, base_size_id,
                        lon, lat, lon + lon_step, lat + 0.125,
                        x_idx, y_idx,
                        lonC, latC, lon_step,
                        width, cols
                        )
                    push!(missing_tiles, tile)
                end
            end
        end
    end
    # ... (fine della logica di scansione) ...

    if isempty(missing_tiles)
        @info "GeoEngine: Nessun buco interno trovato nell'area visibile."
        return
    end

    @info "GeoEngine: Trovati $(length(missing_tiles)) buchi da riempire. Generazione dei job..."

    # 1. Avvia i servizi in background (worker e fallback manager) che ascolteranno le code.
    #    Questo è il passaggio che mancava.
    nworkers = get(cfg, "workers", 8)
    Downloader.start_chunk_downloads_parallel!(nworkers, map_server, cfg, root_path, save_path, tmp_dir)

    # 2. Crea e accoda i job (questa parte era già presente e corretta)
    high_res_jobs = create_chunk_jobs(missing_tiles, cfg, tmp_dir)
    Downloader.enqueue_low!(high_res_jobs)

    @info "GeoEngine: $(length(high_res_jobs)) chunk job accodati per riempire i buchi."
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

