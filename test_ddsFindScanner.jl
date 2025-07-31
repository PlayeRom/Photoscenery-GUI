# Test script for the extended ddsFindScanner.jl module
# Make sure you have already run include("ddsFindScanner.jl") in your REPL or main

import Pkg; Pkg.activate(@__DIR__); Pkg.instantiate()

include("Commons.jl")      # <-- questa riga nuova
using .Commons             # facoltativo, ma rende esplicito l'uso del modulo

include("AppLogger.jl")
AppLogger.init_logger("photoscenary.log")

include("ddsFindScanner.jl")
using .ddsFindScanner: syncScan, startFind

ddsFindScanner.syncScan()

println(">> Starting test for ddsFindScanner compatibility functions")

# Start scanning
println("> Scanning directories...")
ddsFindScanner.startFind()
sleep(2)  # give it a second to populate (especially useful for threaded scans)

# Example index to test — replace with a valid one from your PNG/DDS filenames
test_index = 3138088  # <-- Change this to match your test data

println("> Testing getTailGroupByIndex(index)")
file_path = ddsFindScanner.getTailGroupByIndex(test_index)
println("  Result: ", file_path)

println("> Testing getTailGroupByIndex(index, path)")
result = ddsFindScanner.getTailGroupByIndex(test_index, "Orthophotos")
println("  Result: ", result)

println("> Testing copyTilesByIndex(index, \"./TestOutput\")")
mkpath("./TestOutput")  # Ensure target exists
copied_path = ddsFindScanner.copyTilesByIndex(test_index, "./TestOutput")
println("  File copied to: ", copied_path)

println("> Testing createFilesListTypeDDSandPNG()")
file_list = ddsFindScanner.createFilesListTypeDDSandPNG()
println("  Found ", length(file_list), " PNG/DDS files.")
for f in first(file_list, min(5, length(file_list)))
    println("    - ", f)
end

println(">> Test completed.")
