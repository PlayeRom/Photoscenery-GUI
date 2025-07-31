document.addEventListener("DOMContentLoaded", function() {
    // =========================================================================
    // SETUP INIZIALE E RIFERIMENTI AGLI ELEMENTI HTML
    // =========================================================================
    const map = L.map('map').setView([45, 12], 5);
    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
        attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
    }).addTo(map);

    // Riferimenti ai Controlli
    const icaoInput = document.getElementById('icao');
    const latInput = document.getElementById('lat');
    const lonInput = document.getElementById('lon');
    const sizeInput = document.getElementById('size');
    const sdwnSelect = document.getElementById('sdwn-value');

    // Contenitori per la visibilità dinamica
    const icaoContainer = document.getElementById('icao-container');
    const latlonContainer = document.getElementById('latlon-container');

    // Bottoni
    const btnGetCoords = document.getElementById('btn-get-coords');
    const btnSelectFromMap = document.getElementById('btn-select-from-map');
    const btnRun = document.getElementById('btn-run');
    const btnStop = document.getElementById('btn-stop');
    const btnConnect = document.getElementById('btn-connect');
    const btnRefresh = document.getElementById('btn-refresh');
    const fgfsPortInput = document.getElementById('fgfs-port');
    const mapContainer = document.getElementById('map');

    // Check Box Tiles by ID
    const resSvgContainer = document.getElementById('res-svg-container');
    const resState = Array(7).fill(true); // inizialmente tutti attivi

    // Layer e Stato Globale
    let coverageLayer = L.layerGroup().addTo(map);
    let aircraftMarker = null;
    let isConnected = false;
    let isMapSelectionMode = false;
    let currentOpacity = 0.3;

    // =========================================================================
    // FUNZIONI DI VISUALIZZAZIONE E LOGICA INTERFACCIA
    // =========================================================================

    function getStyleForSizeId(sizeId) {
        const colors = ['#0000FF', '#2A00D5', '#5500AA', '#800080', '#AA0055', '#D5002A', '#FF0000'];
        const opacities = [0.1, 0.15, 0.2, 0.3, 0.4, 0.5, 0.6];
        const index = (sizeId >= 0 && sizeId < colors.length) ? sizeId : 0;
        return { color: colors[index], weight: 1, fillColor: colors[index], fillOpacity: opacities[index] };
    }

    function applyResolutionFilter() {
        const allowed = new Set(allowedSizes());
        coverageLayer.eachLayer(layer => {
            const tileId = layer.options.tileId; // we store it in options
            const size   = coverageLayer._layers[layer._leaflet_id].options.sizeId;
            layer.setStyle({
                opacity: currentOpacity,                          // keep border always visible
                fillOpacity: allowed.has(size) ? currentOpacity : 0
            });
        });
    }

    function updateMapCoverage() {
        fetch('coverage.json')
        .then(r => r.ok ? r.json() : [])
        .then(data => {
            coverageLayer.clearLayers();
            data.forEach(tile => {
                const bounds = [[tile.bbox.latLL, tile.bbox.lonLL],
                [tile.bbox.latUR, tile.bbox.lonUR]];
                L.rectangle(bounds, {
                    ...getStyleForSizeId(tile.sizeId),
                            fillOpacity: currentOpacity,
                            opacity: (currentOpacity / 2)  // <-- borders too
                })
                .bindTooltip(`ID: ${tile.id}<br>Risoluzione: ${tile.sizeId}`)
                .addTo(coverageLayer);
            });
        }).catch(e => console.error('Errore aggiornamento copertura:', e));
    }

    function updateAircraftPosition(data) {
        if (!data.active) {
            if (aircraftMarker) map.removeLayer(aircraftMarker);
            aircraftMarker = null;
            return;
        }
        const latLng = [data.lat, data.lon];
        const tooltipContent = `<b>Prua:</b> ${Math.round(data.heading)}°<br><b>Quota:</b> ${Math.round(data.altitude)} ft AGL<br><b>Velocità:</b> ${Math.round(data.speed)} kts`;
        if (!aircraftMarker) {
            const aircraftSVG = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="28" height="28"><path d="M21 16v-2l-8-5V3.5c0-.83-.67-1.5-1.5-1.5S10 2.67 10 3.5V9l-8 5v2l8-2.5V19l-2 1.5V22l3.5-1 3.5 1v-1.5L13 19v-5.5l8 2.5z" fill="#d9534f" stroke="black" stroke-width="1"/></svg>';
            const icon = L.divIcon({ html: aircraftSVG, className: 'aircraft-icon', iconSize: [28, 28] });
            aircraftMarker = L.marker(latLng, { icon: icon, rotationAngle: data.heading }).addTo(map).bindTooltip(tooltipContent);
        } else {
            aircraftMarker.setLatLng(latLng);
            aircraftMarker.setRotationAngle(data.heading);
            aircraftMarker.setTooltipContent(tooltipContent);
        }
    }

    function populateSdwnDropdown() {
        const maxSize = parseInt(sizeInput.value, 10);

        // 1. rebuild list
        sdwnSelect.innerHTML = '';
        sdwnSelect.add(new Option("Disattivo", "-1"));
        for (let i = 0; i <= maxSize; i++) {
            sdwnSelect.add(new Option(`Da ${maxSize} a ${i}`, i));
        }
        // 2. always select "Disattivo" on first load / refresh
        sdwnSelect.value = "-1";
    }

    function showIcaoMode() {
        latlonContainer.style.display = 'none';
        btnGetCoords.style.display = 'none';
        if (isMapSelectionMode) toggleMapSelectionMode(true); // Disattiva la modalità selezione
    }

    function toggleMapSelectionMode(forceOff = false) {
        isMapSelectionMode = forceOff ? false : !isMapSelectionMode;
        if (isMapSelectionMode) {
            btnSelectFromMap.classList.add('active');
            mapContainer.style.cursor = 'crosshair';
            latlonContainer.style.display = 'block';
        } else {
            btnSelectFromMap.classList.remove('active');
            mapContainer.style.cursor = '';
        }
    }

    // Check Box Tiles by ID
    function renderSvgButtons() {
        resSvgContainer.innerHTML = '';
        resState.forEach((isActive, index) => {
            const div = document.createElement('div');
            div.classList.add('res-svg-button');
            div.innerHTML = createSvgCircle(index, isActive);
            div.addEventListener('click', () => {
                resState[index] = !resState[index];
                renderSvgButtons();
                applyResolutionFilter(); // già esistente nel tuo codice
            });
            resSvgContainer.appendChild(div);
        });
    }

    const allowedSizes = () => {
        return resState.map((on, i) => on ? i : null).filter(v => v !== null);
    };

    renderSvgButtons();

    // store sizeId in layer options when drawing
    function updateMapCoverage() {
        fetch('coverage.json')
        .then(r => r.ok ? r.json() : [])
        .then(data => {
            coverageLayer.clearLayers();
            data.forEach(tile => {
                const bounds = [[tile.bbox.latLL, tile.bbox.lonLL],
                [tile.bbox.latUR, tile.bbox.lonUR]];
                const rect = L.rectangle(bounds, {
                    ...getStyleForSizeId(tile.sizeId),
                                         fillOpacity: currentOpacity,
                                         opacity: 1,
                                         sizeId: tile.sizeId
                })
                .bindTooltip(`ID: ${tile.id}<br>Risoluzione: ${tile.sizeId}`)
                .addTo(coverageLayer);
            });
            applyResolutionFilter(); // apply immediately
        }).catch(console.error);
    }

    // --- Logica di Aggiornamento e Connessione ---
    function mainUpdateLoop() {
        if (isConnected) {
            fetch('/api/fgfs-status').then(r => r.json()).then(updateAircraftPosition).catch(e => console.error("Polling FGFS fallito:", e));
        }
        updateMapCoverage();
    }

    function handleConnect() {
        isConnected = true;
        const port = parseInt(fgfsPortInput.value, 10);
        fetch('/api/connect', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({ port }) });
        btnConnect.textContent = 'Disconnect from FGFS';
        btnConnect.classList.add('active');
        btnGetCoords.style.display = 'block';
    }

    function handleDisconnect() {
        isConnected = false;
        fetch('/api/disconnect', { method: 'POST' });
        btnConnect.textContent = 'Connect to FGFS';
        btnConnect.classList.remove('active');
        showIcaoMode(); // Resetta l'interfaccia
        updateAircraftPosition({ active: false });
    }

    function createSvgCircle(index, selected) {
        const fillColor = selected ? '#0088cc' : 'white';
        const strokeColor = '#0088cc';
        const textColor = selected ? 'white' : '#0088cc';

        return `
        <svg viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg">
        <circle cx="16" cy="16" r="14" fill="${fillColor}" stroke="${strokeColor}" stroke-width="2"/>
        <text x="16" y="21" text-anchor="middle" fill="${textColor}" font-size="16" font-family="sans-serif">${index}</text>
        </svg>
        `;
    }

    // =========================================================================
    // EVENT LISTENERS
    // =========================================================================

    sizeInput.addEventListener('input', populateSdwnDropdown);

    btnSelectFromMap.addEventListener('click', () => {
        toggleMapSelectionMode();
    });

    map.on('click', function(e) {
        if (!isMapSelectionMode) return;
        const { lat, lng } = e.latlng;
        latInput.value = lat.toFixed(6);
        lonInput.value = lng.toFixed(6);
        icaoInput.value = `Coords: ${lat.toFixed(4)}, ${lng.toFixed(4)}`;
        toggleMapSelectionMode(true); // Disattiva automaticamente dopo il click
    });

    btnGetCoords.addEventListener('click', () => {
        if (!isConnected) return;
        fetch('/api/fgfs-status').then(r => r.json()).then(data => {
            if(data.active) {
                latlonContainer.style.display = 'block';
                latInput.value = data.lat.toFixed(6);
                lonInput.value = data.lon.toFixed(6);
                icaoInput.value = `Coords: ${data.lat.toFixed(4)}, ${data.lon.toFixed(4)}`;
            }
        });
    });

    btnRun.addEventListener('click', () => {
        const jobParams = {
            radius: parseFloat(document.getElementById('radius').value),
                            size: parseInt(sizeInput.value, 10),
                            over: parseInt(document.getElementById('over-mode').value, 10)
        };
        const sdwnValue = parseInt(sdwnSelect.value, 10);
        if (sdwnValue !== -1) { jobParams.sdwn = sdwnValue; }

        if (latlonContainer.style.display === 'block' && latInput.value && lonInput.value) {
            jobParams.lat = parseFloat(latInput.value);
            jobParams.lon = parseFloat(lonInput.value);
        } else {
            jobParams.icao = icaoInput.value;
        }

        console.log("Invio richiesta di lavoro al backend:", jobParams);
        fetch('/api/start-job', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(jobParams) });
    });

    btnConnect.addEventListener('click', () => {
        if (isConnected) handleDisconnect();
        else handleConnect();
    });

    const opacitySlider = document.getElementById('opacity-slider');
    opacitySlider.addEventListener('input', () => {
        currentOpacity = parseFloat(opacitySlider.value);
        coverageLayer.eachLayer(layer => {
            layer.setStyle({ fillOpacity: currentOpacity, opacity: currentOpacity });
        });
    });


    btnRefresh.addEventListener('click', mainUpdateLoop);

    btnStop.addEventListener('click', () => {
        if (confirm("Sei sicuro di voler terminare il server Julia?")) {
            fetch('/api/shutdown', { method: 'POST' });
            handleDisconnect();
        }
    });

    // =========================================================================
    // AZIONI INIZIALI
    // =========================================================================
    showIcaoMode();
    populateSdwnDropdown();
    setInterval(mainUpdateLoop, 5000); // Avvia il ciclo di aggiornamento automatico
});
