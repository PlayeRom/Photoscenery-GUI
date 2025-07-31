# Salva come: src/Downloader.jl
module Downloader

using ..Commons, ..StatusMonitor, Images, Downloads, Printf, LightXML
using Base.Threads: @spawn
using FileIO, PNGFiles

export MapServer, populate_queue!, start_chunk_downloads_parallel!, enqueue_chunk_jobs


"""
const CHUNK_QUEUE = Channel{Commons.ChunkJob}(100)
Channel{Any}: Crea un canale (coda FIFO) in grado di trasmettere dati di qualsiasi tipo (Any).
Inf: Specifica che il canale ha capacità illimitata (può contenere un numero infinito di elementi).

const JOBS_DONE_COUNTER = Ref{Int}(0)
Ref{Int}: Crea un riferimento mutabile a un valore intero.
(0): Inizializza il contatore a 0.
Scopo:
Tiene traccia del numero di lavori completati con successo.

const FAILED_JOBS_COUNT = Ref{Int}(0)
Struttura identica a JOBS_DONE_COUNTER.
Scopo:
Tiene traccia dei lavori falliti (es. a causa di eccezioni).

Un produttore accoda lavori in CHUNK_QUEUE.
Worker multipli prelevano lavori dal canale.
I contatori tengono traccia dello stato dell'elaborazione:
JOBS_DONE_COUNTER: Lavori completati.
FAILED_JOBS_COUNT: Lavori falliti.
Sincronizzazione: Il canale gestisce automaticamente l'accesso concorrente.
"""
const CHUNK_QUEUE = Channel{Commons.ChunkJob}(100)

const JOBS_DONE_COUNTER = Threads.Atomic{Int}(0)
const FAILED_JOBS_COUNT = Threads.Atomic{Int}(0)
const PENDING_JOBS = Threads.Atomic{Int}(0)

struct MapServer
    id::Int64
    webUrlBase::Union{String,Nothing}
    webUrlCommand::Union{String,Nothing}
    name::Union{String,Nothing}
    comment::Union{String,Nothing}
    proxy::Union{String,Nothing}
    errorCode::Int64

    function MapServer(id::Int, aProxy::Union{String, Nothing}=nothing)
        try
            serversRoot = get_elements_by_tagname(LightXML.root(parse_file("params.xml")), "servers")
            for server in get_elements_by_tagname(serversRoot[1], "server")
                if server !== nothing && strip(content(find_element(server, "id"))) == string(id)
                    webUrlBase = strip(content(find_element(server, "url-base")))
                    webUrlCommand = map(c -> c == '|' ? '&' : c, strip(content(find_element(server, "url-command"))))
                    name = strip(content(find_element(server, "name")))
                    comment = strip(content(find_element(server, "comment")))
                    return new(id, webUrlBase, webUrlCommand, name, comment, aProxy, 0)
                end
            end
            @warn "Map server with ID=$id not found in params.xml."
            return new(id, nothing, nothing, nothing, nothing, nothing, 410)
            catch err
            @error "Failed to parse params.xml. Error: $err"
            return new(id, nothing, nothing, nothing, nothing, nothing, 411)
        end
    end
end

function _getMapServerReplace(urlCmd::String, varString::String, varValue)
    return replace(urlCmd, varString => string(round(varValue, digits=6)))
end

function _getMapServerURL(m::MapServer, bbox, pixel_size)
    if m.errorCode != 0; return "", 412; end
    urlCmd = m.webUrlCommand
    urlCmd = _getMapServerReplace(urlCmd, "{latLL}", bbox.latLL)
    urlCmd = _getMapServerReplace(urlCmd, "{lonLL}", bbox.lonLL)
    urlCmd = _getMapServerReplace(urlCmd, "{latUR}", bbox.latUR)
    urlCmd = _getMapServerReplace(urlCmd, "{lonUR}", bbox.lonUR)
    urlCmd = _getMapServerReplace(urlCmd, "{szWidth}", pixel_size.width)
    urlCmd = _getMapServerReplace(urlCmd, "{szHight}", pixel_size.height)
    return m.webUrlBase * urlCmd, 0
end

function enqueue_chunk_jobs!(channel::Channel{ChunkJob}, jobs::Vector{ChunkJob})
    @info "download_worker.enqueue_chunk_jobs!: Enqueued $(length(jobs)) jobs into the channel"
    for job in jobs
        put!(channel, job)
    end
    @info "download_worker.enqueue_chunk_jobs!: #1"
    Threads.atomic_add!(Downloader.PENDING_JOBS, length(jobs))
    @info "download_worker.enqueue_chunk_jobs!: #2"
end

function validate_png_file(path::String)::Bool
    try
        # Controllo firma PNG
        open(path, "r") do io
            signature = read(io, 8)
            return signature == UInt8[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        end
    catch e
        @warn "Downloader.validate_png_file: PNG validation failed for $path: $e"
        return false
    end
end

"""
download_and_validate_png(...)

Scarica un chunk PNG, gestendo manualmente i reindirizzamenti (HTTP 301/302).
Valida la firma e l'header del file PNG, e lo scrive su disco in modo atomico
per prevenire file corrotti.
"""
function download_and_validate_png(url::String, dest_path::String; headers::Dict=Dict(), timeout::Real=60.0, max_redirects::Int=5)
    current_url = url

    # Ciclo per gestire fino a 'max_redirects' reindirizzamenti
    for i in 1:max_redirects
        buffer = IOBuffer()
        try
            @info "Downloader.download_and_validate_png: Tentativo di download da $(current_url)"
            Downloads.download(current_url, buffer; headers=headers, timeout=timeout)

            # Se il download ha successo, valida e salva il file
            data = take!(buffer)
            if isempty(data); throw(ErrorException("Risposta vuota dal server")); end

            # Logica di validazione PNG
            try
                if length(data) < 24 || view(data, 1:8) != UInt8[0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A]
                    throw(ArgumentError("Downloader.download_and_validate_png: Firma PNG non valida"))
                end
                if view(data, 13:16) != b"IHDR"; throw(ArgumentError("Chunk IHDR mancante")); end
                ihdr_len = Int(data[9]) << 24 | Int(data[10]) << 16 | Int(data[11]) << 8 | Int(data[12])
                if ihdr_len != 13; throw(ArgumentError("Downloader.download_and_validate_png: Lunghezza IHDR non valida")); end
                catch e
                rethrow(ErrorException("Downloader.download_and_validate_png: Validazione PNG fallita: $e"))
            end

            # Logica di scrittura atomica su disco
            temp_path = dest_path * ".tmp"
            try
                # Assicura che la directory di destinazione esista prima di scrivere.
                mkpath(dirname(temp_path))
                write(temp_path, data)
                FileIO.load(temp_path)
                mv(temp_path, dest_path, force=true)
                @info "Downloader.download_and_validate_png: write image $(dest_path)"
                catch e
                ispath(temp_path) && rm(temp_path, force=true)
                rethrow(ErrorException("Downloader.download_and_validate_png: Scrittura su disco fallita: $e"))
            end

            return filesize(dest_path)

        catch e
            # Gestione dell'errore di redirect
            if e isa Downloads.RequestError && (e.response.status == 301 || e.response.status == 302)
                # Gli header sono una lista di coppie, non un dizionario. Cerca la chiave "location".
                location_idx = findfirst(p -> lowercase(p.first) == "location", e.response.headers)

                if location_idx !== nothing
                    # Estrai il valore della coppia trovata
                    new_url = e.response.headers[location_idx].second
                    @info "Downloader.download_and_validate_png: Reindirizzato a $new_url"
                    current_url = new_url # Aggiorna l'URL e il ciclo for tenterà di nuovo
                else
                    throw(ErrorException("Downloader.download_and_validate_png: Errore di redirect (301/302), ma header 'Location' non trovato."))
                end
            else
                # Se è un altro tipo di errore (es. timeout), lancialo di nuovo
                rethrow(e)
            end
        end
    end # Fine del ciclo for

    throw(ErrorException("Downloader.download: Troppi reindirizzamenti ($max_redirects) per l'URL: $url"))
end


function download_worker(worker_id::Int, map_server::MapServer, cfg::Dict)
    @show CHUNK_QUEUE
    @info "Download.download_worker: ✅ Started worker id: $download_worker"
    start_time = time()
    downloaded_bytes = 0
    for job in CHUNK_QUEUE
        job === :stop && break

        # Controlla se il file è già stato scaricato correttamente
        if isfile(job.temp_path) && filesize(job.temp_path) > 1024
            try
                # Validazione rapida del file esistente
                if validate_png_file(job.temp_path)
                    bytes = filesize(job.temp_path)
                    StatusMonitor.update_chunk_state(job.tile_id, job.chunk_xy, :completed, bytes)
                    Threads.atomic_add!(JOBS_DONE_COUNTER, 1)
                    Threads.atomic_add!(PENDING_JOBS, -1)
                    continue  # Passa al prossimo job
                end
            catch e
                @warn "Download.download_worker: file validation failed, re-downloading: $(job.temp_path)"
                rm(job.temp_path, force=true)
            end
        end

        StatusMonitor.update_chunk_state(job.tile_id, job.chunk_xy, :in_progress)
        url, err = _getMapServerURL(map_server, job.bbox, job.pixel_size)

        if err != 0
            @warn "Download.download_worker: Worker $worker_id: URL generation FAILED for chunk $(job.tile_id)-$(job.chunk_xy)."
            local error_message::String
            if err isa Downloads.RequestError
                # Se è un errore di rete, estraiamo solo il messaggio
                error_message = "Errore di Rete: $(err.message)"
            else
                # Per qualsiasi altro errore, indichiamo il tipo
                error_message = "Errore Inatteso: $(typeof(err))"
            end
            # Logghiamo SOLO la nostra stringa personalizzata, senza l'oggetto "exception"
            @warn "Worker $worker_id: Download fallito. Causa: $error_message"
            Threads.atomic_add!(FAILED_JOBS_COUNT, 1)
            Threads.atomic_add!(JOBS_DONE_COUNTER, 1)
            Threads.atomic_add!(PENDING_JOBS, -1)
            continue
        end

        try
            timeout_sec = get(cfg, "timeout", 90)
            headers = Dict("User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/104.0.0.0 Safari/537.36")
            bytes = download_and_validate_png(url, job.temp_path; headers=headers, timeout=Float64(timeout_sec) ,max_redirects=5)
            StatusMonitor.update_chunk_state(job.tile_id, job.chunk_xy, :completed, bytes)
            Threads.atomic_add!(JOBS_DONE_COUNTER, 1)
            downloaded_bytes += bytes
        catch e
            # Controlliamo se l'errore è un HTTP 500 del server
            if e isa Downloads.RequestError && (e.response.status == 500 || occursin("Operation too slow", string(e)))
                # CASO 1: Errore del server (es. mare, nessuna immagine).
                # Registriamo un avviso specifico e saltiamo il chunk.
                @warn "Downloader: chunk $(job.tile_id)-$(job.chunk_xy) skipped (slow/missing)"
                # Consideriamo il lavoro "fatto" per non bloccare la coda.
                # Non lo contiamo come fallito, ma semplicemente come completato (senza risultato).
                StatusMonitor.update_chunk_state(job.tile_id, job.chunk_xy, :completed, 0) # Segna come completato con 0 bytes
                Threads.atomic_add!(Downloader.JOBS_DONE_COUNTER, 1)
                Threads.atomic_add!(Downloader.PENDING_JOBS, -1)
            else
                # CASO 2: Per tutti gli altri errori (es. timeout di rete),
                # manteniamo la logica dei tentativi.
                @warn "Downloader: Worker $worker_id failed chunk $(job.tile_id)-$(job.chunk_xy)" exception=(e, catch_backtrace())
                isfile(job.temp_path) && rm(job.temp_path, force=true)

                if job.retries_left > 0
                    @info "Downloader: Retrying chunk $(job.tile_id)-$(job.chunk_xy) ($(job.retries_left - 1) retries left)"
                    new_job = Commons.ChunkJob(
                        job.tile_id, job.size_id, job.chunk_xy,
                        job.bbox, job.pixel_size, job.temp_path,
                        job.retries_left - 1
                    )
                    put!(Downloader.CHUNK_QUEUE, new_job)
                    Threads.atomic_add!(Downloader.PENDING_JOBS, 1)
                else
                    @warn "Downloader: Permanent failure for chunk $(job.tile_id)-$(job.chunk_xy)"
                    StatusMonitor.update_chunk_state(job.tile_id, job.chunk_xy, :failed)
                    Threads.atomic_add!(Downloader.FAILED_JOBS_COUNT, 1)
                    Threads.atomic_add!(Downloader.JOBS_DONE_COUNTER, 1)
                end
            end
        finally
            @info "Worker $worker_id end of job."
            Threads.atomic_add!(PENDING_JOBS, -1)  # Job completato
        end
        elapsed = time() - start_time
        speed_MBps = downloaded_bytes / 1_048_576 / elapsed
        @info "Worker $worker_id finished. Time: $(round(elapsed, digits=2)) s, Downloaded: $(round(downloaded_bytes / 1_048_576, digits=2)) MB, Speed: $(round(speed_MBps, digits=2)) MB/s"
    end
end


function populate_queue!(jobs::Vector{ChunkJob})
    while isready(CHUNK_QUEUE) take!(CHUNK_QUEUE) end
    JOBS_DONE_COUNTER[] = 0
    FAILED_JOBS_COUNT[] = 0
    PENDING_JOBS[] = length(jobs)  # Inizializza il contatore

    if isempty(jobs)
        close(CHUNK_QUEUE)
        return
    end

    for job in jobs
        put!(CHUNK_QUEUE, job)
    end
    @info "Downloader.populate_queue: populated with $(length(jobs)) jobs."
end

"""
    start_chunk_downloads_parallel!(nworkers::Int, map_server::MapServer, cfg::Dict)

    Launches `nworkers` asynchronous download workers that process chunk jobs from the shared
    `CHUNK_QUEUE`. Each worker repeatedly pulls jobs from the queue, attempts to download the
    corresponding image from the specified `map_server`, and validates it before marking it as completed.

    # Arguments
    - `nworkers::Int`: Number of concurrent asynchronous download workers to start.
    - `map_server::MapServer`: Server configuration used to build the URL for each chunk.
    - `cfg::Dict`: User or system configuration options (e.g. timeout, retry policies).

    # Behavior
    - Each worker runs independently and pulls jobs from the global channel `CHUNK_QUEUE`.
    - The process continues until a `:stop` symbol is received or the queue is empty.
    - Worker state updates (progress, failures, etc.) are managed via the `StatusMonitor`.

    # Note
    - Ensure `CHUNK_QUEUE` is populated before calling this function.
    - This function is non-blocking: it spawns workers via `@async`.

    # Example
    start_chunk_downloads_parallel!(4, map_server, cfg)
"""
function start_chunk_downloads_parallel!(nworkers::Int, map_server::MapServer, cfg::Dict)
     @info "✅ Downloader.start_chunk_downloads_parallel: Started $nworkers download workers"
    for i in 1:nworkers
        @async download_worker(i, map_server, cfg)
    end
    @info "✅ Downloader.start_chunk_downloads_parallel: Started $nworkers download workers"
end


end
