"""
# TileProcessor Module

Core module responsible for assembling individual tile chunks into complete image files.

    Key Responsibilities:
    1. Assembles multiple PNG chunks into a single composite image
    2. Handles both DDS and PNG output formats
    3. Manages temporary files and cleanup
    4. Coordinates with tile placement system

    Dependencies:
    - Commons: Core functionality and metadata types
    - StatusMonitor: Progress tracking and logging
    - png2ddsDXT1: DDS conversion utilities
    - ddsFindScanner: Final tile placement
    - Images/FileIO: Image processing
    - SharedArrays: Thread-safe image assembly
"""


module TileProcessor

using Printf: @sprintf
using Logging, Images, FilePathsBase, SharedArrays, Glob
using ..Commons, ..StatusMonitor, ..png2ddsDXT1, ..ddsFindScanner

export assemble_single_tile


"""
assemble_single_tile(tile::TileMetadata, root_path::String, save_path::String,
tmp_dir::String, cfg::Dict)::Bool

Worker function that assembles a single tile from its component chunks.

    Arguments:
    - tile: Tile metadata containing dimensions and location info
    - root_path: Main output directory path
    - save_path: Backup directory path
    - tmp_dir: Temporary directory containing chunks
    - cfg: Configuration dictionary

    Returns true if assembly succeeded, false otherwise.
"""
function assemble_single_tile(
    tile::TileMetadata,
    root_path::String,
    save_path::String,
    tmp_dir::String,
    cfg::Dict
    )::Bool

    StatusMonitor.log_message("Assembling tile $(tile.id)...")

    try
        # Calculate final image dimensions
        total_width = tile.width
        total_height = round(Int, total_width * abs((tile.latUR - tile.latLL) / (tile.lonUR - tile.lonLL)))
        chunk_pixel_width = Int(total_width / tile.cols)
        chunk_pixel_height = Int(total_height / tile.cols)
        final_image = SharedArray{RGB{N0f8}}(total_height, total_width)

        # Assemble chunks into final image
        for y in 1:tile.cols, x in 1:tile.cols
            chunk_path = joinpath(tmp_dir, "$(tile.id)_$(tile.size_id)_$(tile.cols^2)_$(y)_$(x).png")
            if !isfile(chunk_path); continue; end
            chunk_img = Images.load(chunk_path)

            # Calculate positioning
            row_start = 1 + total_height - (chunk_pixel_height * y)
            row_end = row_start + size(chunk_img, 1) - 1
            col_start = 1 + chunk_pixel_width * (x - 1)
            col_end = col_start + size(chunk_img, 2) - 1

            # Handle edge cases
            if row_end > total_height; row_end = total_height; end
            if col_end > total_width; col_end = total_width; end

            # Copy chunk data to final image
            view_h = row_end - row_start + 1
            view_w = col_end - col_start + 1
            final_image[row_start:row_end, col_start:col_end] = @view chunk_img[1:view_h, 1:view_w]
        end

        # Handle output format (DDS or PNG)
        if !get(cfg, "png", false) # DDS output
            StatusMonitor.finish_tile_download(tile.id, "Converting to DDS...")

            # Create intermediate files
            temp_png_path = joinpath(tmp_dir, "$(tile.id)_intermediate.png")
            Images.save(temp_png_path, final_image)

            temp_dds_path = joinpath(tmp_dir, "$(tile.id).dds")
            mkpath(dirname(temp_dds_path))

            @info "TileProcessor: Converting $(temp_png_path) to DDS $(temp_dds_path)"
            png2ddsDXT1.convert(temp_png_path, temp_dds_path)

            # Verify DDS creation
            if !isfile(temp_dds_path)
                @error "DDS conversion failed to create output file: $temp_dds_path"
                rm(temp_png_path, force=true) # Clean intermediate PNG
                return false
            end

            rm(temp_png_path, force=true)
            ddsFindScanner.place_tile!(temp_dds_path, tile, root_path, save_path, cfg)
        else # PNG output
            temp_png_path = joinpath(tmp_dir, "$(tile.id).png")
            Images.save(temp_png_path, final_image)
            ddsFindScanner.place_tile!(temp_png_path, tile, root_path, save_path, cfg)
        end
        return true
    catch e
        @error "TileProcessor: Error during image assembly for tile $(tile.id)." exception=(e, catch_backtrace())
        StatusMonitor.finish_tile_download(tile.id, "Assembly Error")
        return false
    end
end

end # module TileProcessor
