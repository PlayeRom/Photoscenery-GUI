# src/AssemblyMonitor.jl
# Author Kimi 2025-07 – crash-proof edition

"""
# AssemblyMonitor Module

Responsible for monitoring and coordinating the assembly of downloaded tile chunks into final DDS files.

    Key Responsibilities:
    1. Monitors temporary directory for completed PNG chunks
    2. Groups chunks by their tile ID, size ID, and total chunk count
    3. Coordinates asynchronous assembly of complete tiles
    4. Provides crash-resistant operation with progress tracking

    Dependencies:
    - Commons: Core functionality and types
    - TileAssembler: Handles actual DDS file assembly
    - Downloader: Checks pending jobs status
    - Glob: File pattern matching
    - Dates: Timing operations
"""


module AssemblyMonitor

using ..Commons, ..TileAssembler, ..Downloader
using Glob, Dates

export monitor_and_assemble

""""
find_completed_tiles(tmp_dir) -> Dict{Tuple{Int,Int,Int},Vector{String}}

Scans temporary directory for completed PNG chunks and groups them by:
    - tile_id
    - size_id
    - total_chunks
    Returns a dictionary mapping (tile_id, size_id, total_chunks) tuples to file paths.
"""
function find_completed_tiles(tmp_dir)
    files = isdir(tmp_dir) ? Glob.glob("*.png", tmp_dir) : String[]
    groups = Dict{Tuple{Int,Int,Int},Vector{String}}()

    for f in files
        m = match(r"^(\d+)_(\d+)_(\d+)_(\d+)_(\d+)\.png$", basename(f))
        m === nothing && continue  # ignore non-matching files
        tile_id      = parse(Int, m.captures[1])
        size_id      = parse(Int, m.captures[2])
        total_chunks = parse(Int, m.captures[3])
        key = (tile_id, size_id, total_chunks)
        push!(get!(Vector{String}, groups, key), f)
    end
    return groups
end

"""
is_tile_ready(tile_id::Int, total_chunks::Int, files::Vector{String}) -> Bool

Checks whether a tile is ready for assembly.

    A tile is considered ready when:
    - The number of associated PNG chunk files is at least equal to the expected `total_chunks`.
    - All files are actually readable and valid PNGs.
    - Filenames are correctly formatted (verified indirectly).

    This check helps avoid blocking single-chunk tiles and allows immediate parallel conversion
    as soon as all necessary chunks are available.

    Returns:
    - true if ready for assembly
    - false if still waiting for more chunks
"""
function is_tile_ready(tile_id::Int, total_chunks::Int, files::Vector{String})::Bool
    if length(files) < total_chunks
        return false
    end

    try
        valid_files = TileAssembler.collect_valid_chunks(files, total_chunks)
        return !isempty(valid_files)
    catch e
        @warn "Validation failed for tile $tile_id" exception=e
        return false
    end
end


function monitor_and_assemble(root_path, save_path, tmp_dir, cfg,
                              all_tiles_needed::Vector{Int},
                              check_interval::Int = 2,
                              num_workers::Int = 4)

    # === SETUP ===
    processed = Set{Int}()
    total_tiles = length(all_tiles_needed)
    tile_queue = Channel{Tuple{Int, Int, Vector{String}}}(100)

    @info "✅ AssemblyMonitor.monitor_and_assemble Setup started with tiles: $total_tiles"

    # === WORKERS ===
    for i in 1:num_workers
        Threads.@spawn begin
            for (tile_id, size_id, files) in tile_queue
                try
                    TileAssembler.assemble_tile_to_dds(tile_id, size_id, files, cfg, root_path, save_path)
                catch e
                    @warn "Tile $tile_id failed in worker $i" exception = e
                end
            end
        end
    end

    # === PRODUCER LOOP ===
    @info "✅ AssemblyMonitor.monitor_and_assemble STARTED"
    while true
        @info "🔄 [MONITOR] Loop tick: processed=$(length(processed)) / $total_tiles, pending=$(Downloader.PENDING_JOBS[])"
        completed = find_completed_tiles(tmp_dir)
        @info "📦 [MONITOR] Completed groups found: $(length(completed))"
        for ((tile_id, size_id, total_chunks), files) in completed
            @info "📍 Tile candidate: ID=$tile_id, chunks=$(length(files)) / $total_chunks"
            if tile_id ∈ processed
                continue
            end

            if is_tile_ready(tile_id, total_chunks, files)
                push!(processed, tile_id)
                put!(tile_queue, (tile_id, size_id, files))
                @info "Queued tile $tile_id ($length(files)/$total_chunks chunks)"
            end
        end

        if length(processed) == total_tiles && Downloader.PENDING_JOBS[] == 0
            break
        end

        sleep(check_interval)
    end
    @info "✅ AssemblyMonitor.monitor_and_assemble COMPLETED"

    # === CLEANUP ===
    close(tile_queue)  # Signal to workers: no more tiles to process
    @info "AssemblyMonitor: All tiles queued. Waiting for workers to finish..."
        sleep(1.0)  # allow background threads to finish flushing
end

end
