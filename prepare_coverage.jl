# Salva come: prepare_coverage.jl (versione finale)

# Carica l'intero pacchetto Photoscenary.
# Julia userà l'ambiente del progetto per trovare e caricare tutto correttamente.
using Photoscenary

println("Avvio dello script di generazione report...")

# Chiama la funzione che ora fa parte del pacchetto.
Photoscenary.generate_coverage_json()

println("Script terminato.")
