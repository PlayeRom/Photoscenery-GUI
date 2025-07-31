using FileIO, ImageIO, Colors, FixedPointNumbers

# Carica il modulo png2ddsDXT1
include("png2ddsDXT1.jl")
using .png2ddsDXT1


function save_canvas_as_png(canvas::Matrix{<:Colorant}, output_path::String)
    """
    Salva una matrice di pixel (canvas) come file PNG

    Args:
    - canvas: Matrice di pixel (es. Matrix{RGBA{N0f8}})
    - output_path: Percorso del file PNG da creare
    """
    try
        # Converti esplicitamente in RGBA{N0f8} se necessario
        img = convert(Matrix{RGBA{N0f8}}, canvas)

        # Salva come PNG
        FileIO.save(output_path, img)
        println("Canvas salvato correttamente come PNG: ", output_path)
        return true
    catch e
        println("Errore durante il salvataggio: ", e)
        return false
    end
end


function test_canvas_conversion(input_png::String, output_dds::String)
    # 1. Carica l'immagine PNG di test
    img = FileIO.load(input_png)
    println("Dimensioni originali: ", size(img))

    # 2. Crea un canvas (simulando un'immagine composta)
    ch_h, ch_w = size(img)
    canvas_h = ch_h * 2  # 2 righe
    canvas_w = ch_w * 2  # 2 colonne

    # Crea canvas con padding per DXT1 (multiplo di 4)
    padded_h = (canvas_h + 3) & ~3
    padded_w = (canvas_w + 3) & ~3
    canvas = zeros(RGBA{N0f8}, padded_h, padded_w)
    println("Dimensioni canvas: ", size(canvas))

    # 3. Posiziona 4 copie dell'immagine nel canvas (simulando 4 tile)
    positions = [
        (1, 1),          # alto-sinistra
        (1, ch_w + 1),   # alto-destra
        (ch_h + 1, 1),   # basso-sinistra
        (ch_h + 1, ch_w + 1) # basso-destra
    ]

    for (y, x) in positions
        canvas[y:y+ch_h-1, x:x+ch_w-1] .= img
    end

    # 4. Converti il canvas in DDS
    println("Avvio conversione canvas in DDS...")
    num_threads = Threads.nthreads()

    save_canvas_as_png(canvas, "test_canvas.png")

    png2ddsDXT1.convert(canvas, output_dds, num_threads)

    println("\nTest completato! File DDS generato: ", output_dds)
end

# Esegui il test
test_png = "test.png"
output_dds = "test_canvas.dds"

test_canvas_conversion(test_png, output_dds)
