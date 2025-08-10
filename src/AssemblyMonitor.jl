# src/AssemblyMonitor.jl
# Author Kimi 2025-07 – crash-proof edition

module AssemblyMonitor

using Logging
using ..Commons
using ..TileProcessor
using ..StatusMonitor

const MONITOR_DEBUG = Ref(false)

# Regex per file: tileId_sizeId_total_y_x.png
const CHUNK_RE = r"^(\d+)_(\d+)_([1-9]\d*)_([1-9]\d*)_([1-9]\d*)\.png$"

# Struttura semplice per un gruppo pronto
struct TileGroup
    tile_id::Int
    size_id::Int
    total_chunks::Int
    files::Vector{String}
end



function collect_complete_groups(tmp_dir::AbstractString)::Vector{TileGroup}
    d = Dict{Tuple{Int,Int,Int}, Vector{String}}()
    for f in readdir(tmp_dir; join=true)
        endswith(f, ".png") || continue
        name = basename(f)
        m = match(CHUNK_RE, name)
        m === nothing && continue
        tile_id  = parse(Int, m.captures[1])
        size_id  = parse(Int, m.captures[2])
        total    = parse(Int, m.captures[3])
        key = (tile_id, size_id, total)
        push!(get!(d, key, String[]), f)
    end

    groups = TileGroup[]
    for ((tile_id, size_id, total), paths) in d
        if length(paths) == total
            push!(groups, TileGroup(tile_id, size_id, total, sort(paths)))
        end
    end
    return groups
end

"Logga cosa c’è in tmp e quanti gruppi completi vede."
function debug_snapshot(tmp_dir::AbstractString)
    files = readdir(tmp_dir; join=true)
    pngs  = filter(f -> endswith(lowercase(f), ".png"), files)
    @info "🔎 [MONITOR] Snapshot tmp" total_files=length(files) pngs=length(pngs) tmp_dir
    groups = collect_complete_groups(tmp_dir)
    @info "🔎 [MONITOR] Completed groups" count=length(groups)
    for g in groups
        @info "   • group" tile_id=g.tile_id size_id=g.size_id total=g.total_chunks
    end
end


"""
monitor_and_assemble(root, save, tmp, cfg, needed_tiles; check_interval=2)

Gira in loop: scansiona tmp/, trova gruppi completi e prova ad assemblarli.
"""
function monitor_and_assemble(root_path::String, save_path::String, tmp_dir::String,
                              cfg::Dict, all_tiles_needed::Vector{Int};
                              check_interval::Int=2, max_passes::Int=0)

    MONITOR_DEBUG[] = get(cfg, "monitor_debug", true)
    @info "▶️  [MONITOR] START" tmp_dir check_interval max_passes debug=MONITOR_DEBUG[]

    passes = 0
    seen    = Set{Tuple{Int,Int}}()        # (tile_id, size_id) già assemblati   ← (tenere questa)
    claimed = Set{Tuple{Int,Int,Int}}()    # (tile_id, size_id, total) in lavorazione
    min_bytes = get(cfg, "min_chunk_bytes", 64)
    interval  = get(cfg, "monitor_interval", check_interval)

    while true
        passes += 1
        MONITOR_DEBUG[] && @info "🔄 [MONITOR] Loop tick" pass=passes

        # 1) snapshot/log
        MONITOR_DEBUG[] && debug_snapshot(tmp_dir)

        # 2) gruppi completi
        groups = collect_complete_groups(tmp_dir)
        MONITOR_DEBUG[] && @info "🔎 [MONITOR] Completed groups found" n=length(groups)

        # 3) assemble
        for g in groups
            key_seen  = (g.tile_id, g.size_id)
            key_claim = (g.tile_id, g.size_id, g.total_chunks)
            if key_seen in seen || key_claim in claimed
                continue
            end

            # tutti i file presenti e “sani” (evita race su file non flushati)
            present = [f for f in g.files if isfile(f) && filesize(f) >= min_bytes]
            if length(present) != g.total_chunks
                MONITOR_DEBUG[] && @info "🕒 [MONITOR] waiting group" tile_id=g.tile_id size_id=g.size_id have=length(present) need=g.total_chunks
                continue
            end

            push!(claimed, key_claim)  # CLAIM
            @info "🧩 [MONITOR] Assemble TRY" tile_id=g.tile_id size_id=g.size_id total=g.total_chunks
            try
                ok = TileProcessor.assemble_group_from_tmp(g.tile_id, g.size_id, g.total_chunks, present,
                                                            root_path, save_path, tmp_dir, cfg)
                if ok
                    push!(seen, key_seen)
                    @info "✅ [MONITOR] Assemble OK" tile_id=g.tile_id size_id=g.size_id
                else
                    @warn "⚠️ [MONITOR] Assemble returned false; will retry later" tile_id=g.tile_id size_id=g.size_id
                end
                catch e
                @error "💥 [MONITOR] Exception assembling" tile_id=g.tile_id size_id=g.size_id exception=(e,catch_backtrace())
            finally
                delete!(claimed, key_claim)  # RELEASE
            end
        end

        # 4) stop opzionale
        if max_passes>0 && passes>=max_passes
            @info "⏹️  [MONITOR] STOP by max_passes"
            break
        end

        sleep(interval)
    end

    @info "🏁 [MONITOR] COMPLETED"
    return nothing
end


end # module

