using Dates

"""
    watch_and_clone_polling(dir::String = pwd(); interval::Int = 10)

    Monitora una directory controllando ogni `interval` secondi.
    Quando un file .jl viene creato o modificato, crea una copia con estensione .jl.txt.
    Se un file .jl viene eliminato, rimuove anche la sua copia.
"""
function watch_and_clone_polling(dir::String = pwd(); interval::Int = 10)
    println("▶️  Avvio monitoraggio periodico di: $dir")
    println("    Controllo ogni $interval secondi...")

    # Dizionario per memorizzare lo stato dei file: path -> timestamp
    file_states = Dict{String, Float64}()

    # --- Funzioni Ausiliarie ---
    function clone_file(filepath::String)
        dest_path = filepath * ".txt"
        try
            cp(filepath, dest_path, force=true)
            println("✅ ($(now())) [CLONATO] Creato/aggiornato: $(basename(dest_path))")
        catch e
            println("⚠️  Errore durante la copia di $filepath: $e")
        end
    end

    function remove_clone(filepath::String)
        clone_path = filepath * ".txt"
        try
            if isfile(clone_path)
                rm(clone_path)
                println("❌ ($(now())) [RIMOSSO] Eliminato clone: $(basename(clone_path))")
            end
        catch e
            println("⚠️  Errore durante la rimozione di $clone_path: $e")
        end
    end

    # --- Fase Iniziale ---
    # Scansiona la directory all'avvio per impostare lo stato iniziale
    # e creare i cloni per i file già presenti.
    println("🔎 Effettuo la scansione iniziale...")
    try
        initial_files = filter(f -> endswith(f, ".jl"), readdir(dir))
        for filename in initial_files
            filepath = joinpath(dir, filename)
            file_states[filepath] = mtime(filepath)
            clone_file(filepath)
        end
        println("✨ Scansione iniziale completata. Inizio monitoraggio.")
    catch e
        println("🛑 Errore durante la scansione iniziale: $e")
        return
    end


    # --- Loop Principale di Monitoraggio ---
    try
        while true
            sleep(interval)

            current_files = filter(f -> endswith(f, ".jl"), readdir(dir))
            current_filepaths = Set(joinpath(dir, f) for f in current_files)

            # 1. Controlla file nuovi o modificati
            for filepath in current_filepaths
                current_mtime = mtime(filepath)
                # Se il file non è tracciato, get() restituisce 0.0
                last_mtime = get(file_states, filepath, 0.0)

                if current_mtime > last_mtime
                    clone_file(filepath)
                    file_states[filepath] = current_mtime # Aggiorna lo stato
                end
            end

            # 2. Controlla file eliminati
            tracked_files = Set(keys(file_states))
            deleted_files = setdiff(tracked_files, current_filepaths)

            for filepath in deleted_files
                remove_clone(filepath)
                delete!(file_states, filepath) # Rimuovi dallo stato di tracciamento
            end
        end
    catch e
        # Gestisce l'interruzione manuale (Ctrl+C)
        if e isa InterruptException
            println("\n🛑 Monitoraggio interrotto dall'utente.")
        else
            println("\n🛑 Si è verificato un errore critico: $e")
        end
    finally
        println("👋 Applicazione terminata.")
    end
end

# --- Per avviare lo script ---
# 1. Salva questo codice come `watcher_polling.jl`
# 2. Apri la Julia REPL nella directory che vuoi monitorare
# 3. Esegui:
#    include("watcher_polling.jl")
#    watch_and_clone_polling()
