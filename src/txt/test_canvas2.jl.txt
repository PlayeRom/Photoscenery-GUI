using FileIO, ImageIO
include("png2ddsDXT1.jl")  # Assicurati che sia nel path corrente

function verifica_convert_canvas_vs_file(path_png::String)
    # Generazione nomi file dds
    path_dds_png = replace(path_png, ".png" => "_png.dds")
    path_dds_canvas = replace(path_png, ".png" => "_canvas.dds")

    println("Conversione da PNG file: $path_png → $path_dds_png")
    png2ddsDXT1.convert(path_png, path_dds_png, 2)

    # Caricamento immagine e creazione "canvas"
    img_matrix = FileIO.load(path_png)

    println("Conversione da canvas (matrice immagine) → $path_dds_canvas")
    png2ddsDXT1.convert(img_matrix, path_dds_canvas, 2)

    println("Conversione terminata.")
    println("File DDS da PNG:     $path_dds_png")
    println("File DDS da Canvas:  $path_dds_canvas")
end
