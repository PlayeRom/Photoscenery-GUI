# Salva come: src/Connector.jl (Versione Finale, Pulita e Unificata)
module Connector

export TelnetConnection, FGFSPosition, FGFSPositionRoute, getFGFSPositionSetTask

using Sockets, EzXML, Dates
using ..Geodesics

# =============================================================================
# Structs (TUE VERSIONI ORIGINALI, SENZA DUPLICATI)
# =============================================================================

mutable struct TelnetConnection
    ipAddress::IPv4
    ipPort::Int
    sock::Union{TCPSocket,Nothing}
    telnetData::Vector{Any}

    function TelnetConnection(address::String)
        (ipAddress,ipPort) = getFGFSPositionIpAndPort(address)
        new(IPv4(ipAddress),ipPort,nothing,Any[])
    end
end

struct FGFSPosition
    latitudeDeg::Float64; longitudeDeg::Float64; altitudeFt::Float64
    directionDeg::Float64; distanceNm::Float64; speedMph::Float64; time::Float64

    function FGFSPosition(lat::Float64,lon::Float64,alt::Float64)
        new(lat,lon,alt,0.0,0.0,0.0,time())
    end

    function FGFSPosition(lat::Float64,lon::Float64,alt::Float64,precPosition::FGFSPosition)
        t = time()
        try
            dir = Geodesics.azimuth(precPosition.longitudeDeg,precPosition.latitudeDeg,lon,lat)
            dist = Geodesics.surface_distance(precPosition.longitudeDeg,precPosition.latitudeDeg,lon,lat,Geodesics.localEarthRadius(lat)) / 1852.0
            deltaTime = t - precPosition.time
            speedMph = deltaTime > 0 ? (dist-precPosition.distanceNm) * 3600 / deltaTime : 0.0
            new(lat,lon,alt,dir,dist,speedMph,t)
        catch err
            println("FGFSPosition - Error: $err")
            new(lat,lon,alt,precPosition.directionDeg,precPosition.distanceNm,precPosition.speedMph,t)
        end
    end
end

mutable struct FGFSPositionRoute
    marks::Vector{FGFSPosition}
    size::Int64
    actual::Union{FGFSPosition,Nothing}
    precPosition::Union{FGFSPosition,Nothing}
    actualDistance::Float64
    actualSpeed::Float64
    actualDirectionDeg::Float64
    radiusStep::Float64
    radiusStepFactor::Float64
    stepTime::Float64
    telnetLastTime::Float64
    telnet::Union{TelnetConnection,Nothing}

    function FGFSPositionRoute(centralPointRadiusDistance,radiusStepFactor = 0.5)
        new(FGFSPosition[],0,nothing,nothing,0.0,0.0,0.0,centralPointRadiusDistance,radiusStepFactor,2.0,0.0,nothing)
    end
end

# =============================================================================
# Funzioni Helper (TUE VERSIONI ORIGINALI)
# =============================================================================
telnetConnectionSockIsOpen(telnet) = (telnet !== nothing && telnet.sock !== nothing) ? isopen(telnet.sock) : false
telnetConnectionSockIsOpen(positionRoute::FGFSPositionRoute) = telnetConnectionSockIsOpen(positionRoute.telnet)

function getFGFSPositionIpAndPort(ipAddressAndPort::String)
    s = split(ipAddressAndPort,":")
    ip = length(s[1]) > 0 ? string(s[1]) : "127.0.0.1"
    p = length(s) > 1 ? tryparse(Int, s[2]) : 5000
    return ip, something(p, 5000)
end

function setFGFSConnect(telnet::TelnetConnection,debugLevel::Int)
    @async begin
        try
            if !telnetConnectionSockIsOpen(telnet)
                telnet.sock = connect(telnet.ipAddress,telnet.ipPort)
                sleep(0.5)
            end
            while telnetConnectionSockIsOpen(telnet)
                line = Sockets.readline(telnet.sock)
                if length(line) > 0
                    push!(telnet.telnetData,line)
                end
            end
        catch err; telnet.sock = nothing; end
    end
    return telnet
end

function getFGFSPosition(telnet::TelnetConnection, precPosition::Union{FGFSPosition,Nothing},debugLevel::Int)
    telnetDataXML = ""
    telnet.telnetData = Any[]
    try
        retray = 1
        while telnetConnectionSockIsOpen(telnet) && retray <= 3
            write(telnet.sock, "dump /position\r\n")
            sleep(0.5)
            if length(telnet.telnetData) >= 8
                for td in telnet.telnetData[2:end] telnetDataXML *= td end
                try
                    primates = EzXML.root(EzXML.parsexml(telnetDataXML))
                    lat = parse(Float64,EzXML.nodecontent.(findall("//latitude-deg",primates))[1])
                    lon = parse(Float64,EzXML.nodecontent.(findall("//longitude-deg",primates))[1])
                    alt_msl = parse(Float64,EzXML.nodecontent.(findall("//altitude-ft",primates))[1])
                    alt_gnd = parse(Float64,EzXML.nodecontent.(findall("//ground-elev-ft",primates))[1])

                    position = (precPosition === nothing) ? FGFSPosition(lat,lon,alt_msl-alt_gnd) : FGFSPosition(lat,lon,alt_msl-alt_gnd,precPosition)
                    return position
                catch err
                    return nothing
                end
            end
            retray += 1
        end
        return nothing
    catch err
        return nothing
    end
end

# =============================================================================
# Funzione Principale (LOGICA ORIGINALE RIPRISTINATA E CORRETTA)
# =============================================================================
function getFGFSPositionSetTask(host::String, port::Int, centralPointRadiusDistance::Float64, radiusStepFactor::Float64, debugLevel::Int)

    ipAddressAndPort = "$host:$port"
    positionRoute = FGFSPositionRoute(centralPointRadiusDistance,radiusStepFactor)
    maxRetray = 10

    @async while true
        # Stabiliamo la connessione usando la tua logica originale
        positionRoute.telnet = setFGFSConnect(TelnetConnection(ipAddressAndPort),debugLevel)
        sleep(1.0) # Diamo tempo al task asincrono di connettersi

        if telnetConnectionSockIsOpen(positionRoute)
            while telnetConnectionSockIsOpen(positionRoute)
                retray = 1
                while telnetConnectionSockIsOpen(positionRoute) && retray <= maxRetray
                    position = getFGFSPosition(positionRoute.telnet,positionRoute.precPosition,debugLevel)

                    if position === nothing
                        if !telnetConnectionSockIsOpen(positionRoute) break end
                        debugLevel > 0 && println("\ngetFGFSPositionSetTask - Error: contact lost | n. retray: $retray")
                        retray += 1
                        sleep(1.0)
                    else
                        sleep(positionRoute.stepTime)
                        retray = 1

                        if positionRoute.size == 0
                            push!(positionRoute.marks,position)
                            positionRoute.size += 1
                        end

                        positionRoute.actual = position
                        positionRoute.actualDirectionDeg = position.directionDeg # Usiamo la direzione calcolata dal costruttore

                        if positionRoute.actualDistance >= (positionRoute.radiusStep * positionRoute.radiusStepFactor)
                            push!(positionRoute.marks,position)
                            positionRoute.size += 1
                        end

                        positionRoute.precPosition = position

                        # RIMOSSO IL 'break' CHE FERMAVA L'AGGIORNAMENTO CONTINUO
                    end
                end # Fine ciclo retry
            end # Fine ciclo "while open"
        end # Fine "if open"
        sleep(5.0) # Pausa prima di ritentare il ciclo principale in caso di disconnessione totale
    end
    return positionRoute
end

end # module Connector

