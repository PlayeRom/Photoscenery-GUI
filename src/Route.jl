"""
# Route Module

Handles route loading and airport location lookup for flight planning.

    Key Features:
    - Supports multiple route file formats (FGFS, GPX)
    - Airport database lookup by ICAO code
    - Route point interpolation
    - Distance calculations between waypoints
    - Comprehensive error handling

    Dependencies:
    - LightXML: XML file parsing
    - Geodesy: Geographical calculations
    - CSV/DataFrames: Airport database handling
    - StatusMonitor: Progress reporting
"""


module Route

using Unicode, LightXML, Geodesy, Printf, CSV, DataFrames, Serialization
using ..StatusMonitor, ..Connector, ..Commons, ..ScanDir

export loadRoute, selectIcao


"""
findFileOfRoute(fileName::String, idTypeOfFile::Int=0)

Locates and parses route files in supported formats.
- fileName: Route file name or pattern
- idTypeOfFile: Format selector (0=auto, 1=FGFS, 2=GPX)

Returns: (route_xml, file_path, format_name) or (nothing, nothing, nothing)
"""
function findFileOfRoute(fileName::String, idTypeOfFile::Int=0)
    typeOfFile = [("FGFS", "route"), ("GPX", "rte")]
    date = 0.0
    fileId = 0
    route = nothing

    # Commons.findFile returns a vector of FoundFile structs
    files = Commons.findFile(fileName)
    if isempty(files); return nothing, nothing, nothing; end

    # Create mapping from file ID to array index for safe access
    file_map = Dict(f.id => i for (i, f) in enumerate(files))

    typeOfFileSelected = nothing

    for file in files
        if file.mtime >= date
            try
                if idTypeOfFile > 0
                    route = get_elements_by_tagname(LightXML.root(parse_file(file.path)), typeOfFile[idTypeOfFile][2])
                    typeOfFileSelected = typeOfFile[idTypeOfFile][1]
                else
                    for (nameFormat, selector) in typeOfFile
                        route = get_elements_by_tagname(LightXML.root(parse_file(file.path)), selector)
                        typeOfFileSelected = nameFormat
                        if size(route)[1] > 0 break end
                    end
                end

                fileId = file.id
                date = file.mtime

                catch e
                # If XML parsing fails, skip the file
                @warn "Unable to parse route file: $(file.path). Error: $e"
            end
        end
    end

    if fileId > 0
        file_index = file_map[fileId]
        return route, files[file_index].path, typeOfFileSelected
    else
        return nothing, nothing, nothing
    end
end


"""
selectIcao(icaoToSelect, centralPointRadiusDistance)

Looks up airport coordinates by ICAO code or name.
- icaoToSelect: Airport identifier or name
- centralPointRadiusDistance: Search radius in nautical miles

Returns: (latitude, longitude, errorCode)
"""
function selectIcao(icaoToSelect, centralPointRadiusDistance)
    StatusMonitor.log_message("selectIcao: Starting search for ICAO='$(icaoToSelect)' with radius=$(centralPointRadiusDistance) nm")

        centralPointLat = nothing
        centralPointLon = nothing
        errorCode = 0
        retryNumber = 0

    while retryNumber <= 1
        # Check if CSV database is newer than serialized version
        if stat("airports.csv").mtime > stat("airports.jls").mtime
            StatusMonitor.log_message("Converting airport database...")
            serialize("airports.jls", DataFrame(CSV.File("airports.csv")))
            StatusMonitor.log_message("Airport database converted to 'airports.jls'.")
            elseif stat("airports.jls").mtime == 0.0
            StatusMonitor.log_message("Error: Both airports.jls and airports.csv are unavailable.")
            errorCode = 403
            retryNumber = 9
        end

        if errorCode == 0
            try
                db = deserialize("airports.jls")
                searchString = Unicode.normalize(uppercase(icaoToSelect), stripmark=true)

                # Search by ICAO code
                foundDatas = filter(i -> (i.ident == searchString), db)

                # Fallback to municipality name
                if size(foundDatas)[1] == 0
                    foundDatas = filter(i -> occursin(searchString, Unicode.normalize(uppercase(i.municipality), stripmark=true)), dropmissing(db, :municipality))
                end

                # Fallback to airport name
                if size(foundDatas)[1] == 0
                    foundDatas = filter(i -> occursin(searchString, Unicode.normalize(uppercase(i.name), stripmark=true)), dropmissing(db, :name))
                end

                if size(foundDatas)[1] == 1
                    if centralPointRadiusDistance === nothing || centralPointRadiusDistance <= 1.0
                        centralPointRadiusDistance = 10.0
                    end
                    centralPointLat = foundDatas[1, :latitude_deg]
                    centralPointLon = foundDatas[1, :longitude_deg]

                    # Handle potential coordinate format issues
                    if !(Commons.inValue(centralPointLat, 90) && Commons.inValue(centralPointLon, 180))
                        if abs(centralPointLat) > 1000.0; centralPointLat /= 1000.0; end
                        if abs(centralPointLon) > 1000.0; centralPointLon /= 1000.0; end
                    end

                    StatusMonitor.log_message("Found ICAO: $(foundDatas[1,:ident]) - $(foundDatas[1,:name])")
                    StatusMonitor.log_message("Center: Lat $(round(centralPointLat,digits=4)), Lon $(round(centralPointLon,digits=4)), Radius: $centralPointRadiusDistance nm")
                else
                    if size(foundDatas)[1] > 1
                        errorCode = 401
                        StatusMonitor.log_message("Error: ICAO '$(icaoToSelect)' is ambiguous, found $(size(foundDatas)[1]) results.")
                        for i in 1:min(size(foundDatas)[1], 5)
                            StatusMonitor.log_message("  -> Id: $(foundDatas[i,:ident]), Name: $(foundDatas[i,:name]) ($(foundDatas[i,:municipality]))")
                        end
                    else
                        errorCode = 400
                        StatusMonitor.log_message("Error: ICAO '$(icaoToSelect)' not found in database.")
                    end
                end
                retryNumber = 9
                catch err
                if retryNumber == 0
                    retryNumber = 1
                    StatusMonitor.log_message("Error: airports.csv is corrupt or missing. Retrying.")
                    errorCode = 403
                else
                    StatusMonitor.log_message("CRITICAL ERROR: airports.csv is corrupt. Please check and restart. Error: $err")
                    errorCode = 404
                    retryNumber = 9
                end
            end
        end
        if retryNumber == 0; retryNumber = 9; end
    end

    StatusMonitor.log_message("selectIcao: Search completed. Lat=$(centralPointLat), Lon=$(centralPointLon), ErrorCode=$(errorCode)")

    return centralPointLat, centralPointLon, errorCode
end


"""
getRouteListFormatFGFS!(routeList, route, minDistance)

Processes FGFS format route waypoints with interpolation.
- routeList: Array to store waypoints
- route: XML route data
- minDistance: Minimum distance between interpolated points
"""
function getRouteListFormatFGFS!(routeList,route,minDistance)
    wps = LightXML.get_elements_by_tagname(route[1][1], "wp")
    centralPointLatPrec = nothing
    centralPointLonPrec = nothing
    for wp in wps
        foundData = false
        if wp != nothing
            if find_element(wp,"icao") != nothing
                icao = strip(content(find_element(wp,"icao")))
                (centralPointLat, centralPointLon, errorCode) = selectIcao(icao,minDistance)
                if errorCode == 0 foundData = true end
                elseif find_element(wp,"lon") != nothing
                centralPointLat = Base.parse(Float64, strip(content(find_element(wp,"lat"))))
                centralPointLon = Base.parse(Float64, strip(content(find_element(wp,"lon"))))
                foundData = true
            end
            if foundData
                # Calculate distance from previous point
                if centralPointLatPrec != nothing && centralPointLonPrec != nothing
                    posPrec = Geodesy.LLA(centralPointLatPrec,centralPointLonPrec, 0.0)
                    pos = Geodesy.LLA(centralPointLat,centralPointLon, 0.0)
                    distanceNm = euclidean_distance(pos,posPrec) / 1852.0
                else
                    distanceNm = 0.0
                end

                # Interpolate points if distance exceeds threshold
                if minDistance < distanceNm
                    numberTrunk = Int32(round(distanceNm / minDistance))
                    for i in 1:(numberTrunk - 1)
                        degLat = centralPointLatPrec + i * (centralPointLat - centralPointLatPrec) / numberTrunk
                        deglon = centralPointLonPrec + i * (centralPointLon - centralPointLonPrec) / numberTrunk
                        dist = euclidean_distance(Geodesy.LLA(degLat,deglon, 0.0),posPrec) / 1852.0
                        push!(routeList,(degLat, deglon, dist))
                        StatusMonitor.log_message(@sprintf("Route segment %d.%d -> Lat: %.4f, Lon: %.4f", size(routeList)[1], i, routeList[end][1], routeList[end][2]))
                    end
                end
                push!(routeList,(centralPointLat, centralPointLon, distanceNm))
                StatusMonitor.log_message(@sprintf("Waypoint %d -> Lat: %.4f, Lon: %.4f, Dist: %.1f nm", size(routeList)[1], routeList[end][1], routeList[end][2], distanceNm))
                centralPointLatPrec = centralPointLat
                centralPointLonPrec = centralPointLon
            end
        end
    end
    return routeList
end


"""
getRouteListFormatGPX!(routeList, route, minDistance)

Processes GPX format route waypoints with interpolation.
- routeList: Array to store waypoints (modified in-place)
- route: XML route data from GPX file
- minDistance: Minimum distance between interpolated points (in nautical miles)

Handles GPX route points (<rtept> elements) with lat/lon attributes.
Automatically interpolates additional points when distance between
waypoints exceeds minDistance.
"""
function getRouteListFormatGPX!(routeList, route, minDistance)
    wps = LightXML.get_elements_by_tagname(route[1][1], "rtept")
    centralPointLatPrec = nothing
    centralPointLonPrec = nothing

    for wp in wps
        if wp != nothing
            if attribute(wp,"lon") != nothing && attribute(wp,"lat") != nothing
                centralPointLat = Base.parse(Float64, strip(attribute(wp,"lat")))
                centralPointLon = Base.parse(Float64, strip(attribute(wp,"lon")))

                # Calculate distance from previous point
                if centralPointLatPrec != nothing && centralPointLonPrec != nothing
                    posPrec = Geodesy.LLA(centralPointLatPrec, centralPointLonPrec, 0.0)
                    pos = Geodesy.LLA(centralPointLat, centralPointLon, 0.0)
                    distanceNm = euclidean_distance(pos, posPrec) / 1852.0
                else
                    distanceNm = 0.0
                end

                # Interpolate additional points if needed
                if minDistance < distanceNm
                    numberTrunk = Int32(round(distanceNm / minDistance))
                    for i in 1:(numberTrunk - 1)
                        degLat = centralPointLatPrec + i * (centralPointLat - centralPointLatPrec) / numberTrunk
                        deglon = centralPointLonPrec + i * (centralPointLon - centralPointLonPrec) / numberTrunk
                        dist = euclidean_distance(Geodesy.LLA(degLat, deglon, 0.0), posPrec) / 1852.0
                        push!(routeList, (degLat, deglon, dist))
                        StatusMonitor.log_message(@sprintf("Route segment %d.%d -> Lat: %.4f, Lon: %.4f",
                                                            size(routeList)[1], i, routeList[end][1], routeList[end][2]))
                    end
                end

                # Add the main waypoint
                push!(routeList, (centralPointLat, centralPointLon, distanceNm))
                StatusMonitor.log_message(@sprintf("Waypoint %d -> Lat: %.4f, Lon: %.4f, Dist: %.1f nm",
                                                    size(routeList)[1], routeList[end][1], routeList[end][2], distanceNm))

                # Update previous point reference
                centralPointLatPrec = centralPointLat
                centralPointLonPrec = centralPointLon
            end
        end
    end
    return routeList
end


"""
loadRoute(fileOfRoute, centralPointRadiusDistance) -> (routeList, pointCount)

Main function to load and process route files in supported formats (FGFS/GPX).

    Arguments:
    - fileOfRoute: Path or name of the route file to load
    - centralPointRadiusDistance: Base radius distance in nautical miles that determines waypoint density

    Returns:
    - Tuple containing:
    - routeList: Array of waypoints as (latitude, longitude, distance) tuples
    - pointCount: Number of waypoints in the route

    Behavior:
    1. Automatically detects file format (FGFS or GPX)
    2. Calculates minimum distance between points as half the input radius
    3. Loads and processes the route file using appropriate parser
    4. Returns empty list if file cannot be found/parsed
    5. Provides detailed logging through StatusMonitor
"""
function loadRoute(fileOfRoute, centralPointRadiusDistance)
    # Calculate minimum distance between waypoints as fraction of input radius
    centralPointRadiusDistanceFactor = 0.5
    minDistance = centralPointRadiusDistance * centralPointRadiusDistanceFactor

    # Locate and parse the route file
    route = findFileOfRoute(fileOfRoute)
    routeList = Any[]

    if route != nothing
        StatusMonitor.log_message("Loading route from file: $(basename(route[2])) in $(route[3]) format")

        # Dispatch to appropriate format handler
        if route[3] == "FGFS"
            getRouteListFormatFGFS!(routeList, route, minDistance)
            elseif route[3] == "GPX"
            getRouteListFormatGPX!(routeList, route, minDistance)
        end
    else
        StatusMonitor.log_message("Error: Unable to find or load route file: $fileOfRoute")
    end

    return routeList, size(routeList)[1]
end


end # module
