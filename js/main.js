// Save as: js/main.js (final version)
import * as api from './api.js';
import {
    elements,
    initializeMap,
    updateMapCoverage,
    updateAircraftPosition,
    populateSdwnDropdown,
    getJobParameters,
    toggleConnectionState,
    renderSvgButtons,
    toggleMapSelectionMode,
    showIcaoMode,
    showTileInPanel,
    previewArea,
    clearPreview,
    setupInteractiveSelection
} from './ui.js';

// --- Aircraft-auto-queue settings ---
const RADIUS_AROUND_AC = 20;   // NM of each circle
const OVERLAP_FACTOR   = 2/3;  // ⅔ diameter offset

// --- Global State ---
const state = {
    isConnected: false,             // FlightGear connection status
    isMapSelectionMode: false,      // Whether map coordinate selection is active
    currentOpacity: 0.4,            // Current opacity level for map coverage
    resState: Array(7).fill(true),   // Active/inactive state for each resolution filter
    hasPreview: false,
    previewAreas: [],
    isDragging: false
};

const activeCircles = {};           // Stores active job circles on the map
let pendingCircle = null;           // Temporary Leaflet circle object

/**
 * Main update loop that runs periodically
 * - Updates aircraft position if connected
 * - Updates map coverage with current filters and opacity
 */
function mainUpdateLoop() {
    if (state.isConnected) {
        api.getFgfsStatus().then(updateAircraftPosition);
    }

    api.getCoverageData().then(coverageData => {
        const allowedResolutions = new Set(
            state.resState.map((active, i) => active ? i : -1).filter(i => i !== -1)
        );
        updateMapCoverage(coverageData, allowedResolutions, state.currentOpacity);
    });
}

/**
 * Handles resolution filter button clicks
 * @param {number} index - Index of the clicked resolution filter
 */
function handleResFilterClick(index) {
    state.resState[index] = !state.resState[index];
    renderSvgButtons(state.resState, handleResFilterClick);
    mainUpdateLoop();
}

// ------------------------------------------------------------------
// 1. Queue Badge (always shows ≥ 0)
// ------------------------------------------------------------------
function updateQueueBadge() {
    fetch('/api/queue-size')
    .then(r => r.json())
    .then(len => {
        document.getElementById('badge').textContent = len;
    });
}

// ------------------------------------------------------------------
// 2. Draw/Clear transparent green circles for jobs
// ------------------------------------------------------------------

function updateCoordinates(lat, lon) {
    elements.latInput.value = lat.toFixed(6);
    elements.lonInput.value = lon.toFixed(6);
    elements.icaoInput.value = `Coords: ${lat.toFixed(4)}, ${lon.toFixed(4)}`;
}

function updatePreview() {
    if (elements.latInput.value && elements.lonInput.value && elements.radiusInput.value) {
        previewArea(
            parseFloat(elements.latInput.value),
                    parseFloat(elements.lonInput.value),
                    parseFloat(elements.radiusInput.value)
        );
        state.hasPreview = true;

        // Centra la mappa sull'area selezionata
        elements.map.setView(
            [parseFloat(elements.latInput.value), parseFloat(elements.lonInput.value)],
                             elements.map.getZoom()
        );
    }
}

/**
 * Draws a circle on the map for a job
 * @param {string} jobId - Unique job identifier
 * @param {number} lat - Latitude coordinate
 * @param {number} lon - Longitude coordinate
 * @param {number} radiusKm - Circle radius in kilometers
 */
function drawCircle(jobId, lat, lon, radiusKm) {
    if (activeCircles[jobId]) return;

    const circle = L.circle([lat, lon], {
        radius: radiusKm * 1852,
        color: '#00cc00',
        fillColor: '#00cc00',
        fillOpacity: 0.15,
        weight: 1.5
    }).addTo(elements.map);

    activeCircles[jobId] = circle;
}

/**
 * Removes a job circle from the map
 * @param {string} jobId - Unique job identifier
 */
function clearCircle(jobId) {
    const layer = activeCircles[jobId];
    if (layer) {
        elements.map.removeLayer(layer);      // remove from map
        delete activeCircles[jobId];          // remove from registry
    }
}

/**
 * Checks for and clears circles of completed jobs
 */
function checkCompletedJobs() {
    api.getCompletedJobs().then(ids => {
        if (ids.length) {
            ids.forEach(id => clearCircle(id));        // remove green circle
            processQueueSequentially();                // start next preview → green
        }
    });
}

// ------------------------------------------------------------------
// 3. Event Handling
// ------------------------------------------------------------------
elements.controlsPanel.addEventListener('click', (e) => {
    const t = e.target.closest('button');
    if (!t) return;

    switch (t.id) {

        case 'btn-run':
            clearPreview();          // elimina preview temporanee globali

            const params = getJobParameters();

            /* 1. cerchio arancione da promuovere? */
            const preview = state.previewAreas.find(a => !a.isFixed);

            api.startJob(params)
            .then(data => {
                updateQueueBadge();

                if (preview) {
                    /* promuovi il cerchio esistente */
                    const c = preview.circle;
                    c.pm.disable();
                    c.setStyle({
                        color: '#00cc00',
                        fillColor: '#00cc00',
                        fillOpacity: 0.15,
                        dashArray: null
                    });
                    activeCircles[data.jobId] = c;   // registra per rimozione futura

                    const idx = state.previewAreas.indexOf(preview);
                    if (idx > -1) state.previewAreas.splice(idx, 1);
                } else {
                    /* NESSUN cerchio arancione → crea il verde ex-novo */
                    const circle = L.circle([data.lat, data.lon], {
                        radius: data.radius * 1852,
                        color: '#00cc00',
                        fillColor: '#00cc00',
                        fillOpacity: 0.15,
                        weight: 1.5
                    }).addTo(elements.map);
                    activeCircles[data.jobId] = circle;
                }
            })
            .catch(err => alert(`Error: ${err.message}`));
            break;

        case 'btn-download-around-aircraft':
            if (!state.isConnected) {
                alert('Connect to FlightGear first');
                break;
            }
            api.getFgfsStatus().then(data => {
                if (!data.active) {
                    alert('Aircraft position not available');
                    return;
                }
                buildOverlappingCircles(data.lat, data.lon);
            });
            break;

        case 'btn-connect':
            state.isConnected = !state.isConnected;
            toggleConnectionState(state.isConnected);
            state.isConnected ? api.connectToFgfs(parseInt(document.getElementById('fgfs-port').value, 10))
            : api.disconnectFromFgfs();
            break;

        case 'btn-stop':
            if (confirm("Stop the server?")) api.shutdownServer();
            break;

        case 'btn-get-coords':
            if (state.isConnected) {
                api.getFgfsStatus().then(data => {
                    if (data.active) {
                        elements.latInput.value = data.lat.toFixed(6);
                        elements.lonInput.value = data.lon.toFixed(6);
                        elements.icaoInput.value = `Coords: ${data.lat.toFixed(4)}, ${data.lon.toFixed(4)}`;
                    }
                });
            }
            break;
        case 'btn-select-from-map':
            state.isMapSelectionMode = !state.isMapSelectionMode;
            toggleMapSelectionMode(state.isMapSelectionMode);
            if (state.isMapSelectionMode) {
                // Mostra gli input lat/lon se non sono visibili
                elements.latlonContainer.style.display = 'block';
                // Se ci sono coordinate già inserite, mostra la preview
                if (elements.latInput.value && elements.lonInput.value) {
                    updatePreview();
                }
            }
            break;
    }
});

// Event listeners
elements.sizeInput.addEventListener('input', populateSdwnDropdown);
elements.opacitySlider.addEventListener('input', (e) => {
    state.currentOpacity = parseFloat(e.target.value);
    mainUpdateLoop();
});

// Tile preview popup handler
elements.map.on('popupopen', (e) => {
    const previewBtn = e.popup._container.querySelector('.preview-button');
    if (previewBtn) {
        previewBtn.onclick = () => {
            const tileId = previewBtn.dataset.tileId;
            const imageUrl = api.getTilePreview(tileId);
            const sizeId = previewBtn.dataset.sizeId;
            showTileInPanel(tileId, sizeId, imageUrl);
        };
    }
});

// ------------------------------------------------------------------
// --- Aircraft-auto-queue settings ---
// ------------------------------------------------------------------
function destinationPoint(lat, lon, dNm, bearingDeg) {
    const R = 6371;
    const δ = (dNm * 1.852) / R;
    const θ = bearingDeg * Math.PI / 180;
    const φ1 = lat * Math.PI / 180;
    const λ1 = lon * Math.PI / 180;

    const φ2 = Math.asin(Math.sin(φ1) * Math.cos(δ) +
    Math.cos(φ1) * Math.sin(δ) * Math.cos(θ));
    const λ2 = λ1 + Math.atan2(Math.sin(θ) * Math.sin(δ) * Math.cos(φ1),
                               Math.cos(δ) - Math.sin(φ1) * Math.sin(φ2));
    return { lat: φ2 * 180 / Math.PI, lon: λ2 * 180 / Math.PI };
}

/**
 * Crea **un solo cerchio arancione** centrato sulla posizione attuale dell’aereo
 * e lo trasforma immediatamente in job verde.
 */
function buildOverlappingCircles(lat, lon) {
    const radiusNm = RADIUS_AROUND_AC;   // usa il valore nel campo o costante
    const circle   = previewArea(lat, lon, radiusNm);
    const areaState = { lat, lon, radius: radiusNm, circle, isFixed: false };
    state.previewAreas.push(areaState);

    processQueueSequentially();   // parte subito
}

function processQueueSequentially() {
    const next = state.previewAreas.find(a => !a.isFixed);
    if (!next) return;

    const params = {
        lat   : next.lat,
        lon   : next.lon,
        radius: next.radius,
        size  : parseInt(elements.sizeInput.value) || 4,
        over  : parseInt(elements.overSelect.value)  || 1,
        sdwn  : parseInt(elements.sdwnSelect.value)  || -1
    };

    api.startJob(params)
    .then(data => {
        updateQueueBadge();

        // Promote orange → green
        const c = next.circle;
        c.pm.disable();
        c.setStyle({ color: '#00cc00', fillColor: '#00cc00', fillOpacity: 0.15, dashArray: null });
        activeCircles[data.jobId] = c;

        const idx = state.previewAreas.indexOf(next);
        if (idx > -1) state.previewAreas.splice(idx, 1);

        // Wait for Julia “completed” then start next
        const checkNext = () => {
            api.getCompletedJobs().then(ids => {
                if (ids.includes(data.jobId)) {
                    processQueueSequentially();
                } else {
                    setTimeout(checkNext, 1000);
                }
            });
        };
        checkNext();
    })
    .catch(err => alert(`Error: ${err.message}`));
}

function checkAutoFollow() {
    if (!state.isConnected) return;

    api.getFgfsStatus().then(data => {
        if (!data.active) return;

        const acPos = L.latLng(data.lat, data.lon);

        // cerco il cerchio verde attivo
        const jobId = Object.keys(activeCircles).find(j => elements.map.hasLayer(activeCircles[j]));
        if (!jobId) return;

        const circle = activeCircles[jobId];
        const center = circle.getLatLng();
        const radius = circle.getRadius();     // metres
        const dist   = acPos.distanceTo(center);

        // se l'aereo è a circa r/2 (0.5) dal centro
        if (dist < radius * 0.55 && dist > radius * 0.45) {
            const aheadNm = RADIUS_AROUND_AC / 2;               // NM
            const aheadPt = destinationPoint(data.lat, data.lon, aheadNm, data.heading);
            // evita duplicati
            if (!state.previewAreas.find(a => !a.isFixed)) {
                const c = previewArea(aheadPt.lat, aheadPt.lon, RADIUS_AROUND_AC);
                state.previewAreas.push({ ...aheadPt, radius: RADIUS_AROUND_AC, circle: c, isFixed: false });
            }
        }
    });
}


// ------------------------------------------------------------------
// Map click handler for coordinate selection
// ------------------------------------------------------------------

import {linkRadiusHandleToInput} from './ui.js';

elements.map.on('click', (e) => {
    if (state.isDragging) {
        return;
    }
    if (!state.isMapSelectionMode) return;

    let radiusNm = parseFloat(elements.radiusInput.value) || 3;
    if (radiusNm < 3) radiusNm = 3;
    elements.radiusInput.value = radiusNm;

    const { lat, lng } = e.latlng;
    updateCoordinates(lat, lng);

    const circle = previewArea(lat, lng, radiusNm);
    linkRadiusHandleToInput(circle);

    const areaState = { lat, lon: lng, radius: radiusNm, circle, isFixed: false };
    state.previewAreas.push(areaState);

    // Bottoni di conferma e cancellazione
    const btnGroup = L.layerGroup().addTo(elements.map);
    const rLatDeg = circle.getRadius() / 111320;

    const okBtn = L.marker([lat + rLatDeg, lng], {
        icon: L.divIcon({
            html: '<button class="mini-btn ok">✓</button>',
            className: 'mini-btn-container', iconSize: [22, 22], iconAnchor: [11, 11]
        })
    }).addTo(btnGroup);

    const delBtn = L.marker([lat - rLatDeg, lng], {
        icon: L.divIcon({
            html: '<button class="mini-btn del">🗑</button>',
            className: 'mini-btn-container', iconSize: [22, 22], iconAnchor: [11, 11]
        })
    }).addTo(btnGroup);

    circle.on('pm:dragstart', () => {
        state.isDragging = true;
    })

    circle.on('pm:dragend', () => {
        // Usiamo un piccolo timeout per resettare lo stato DOPO che l'evento di click è stato ignorato
        setTimeout(() => {
            state.isDragging = false;
        }, 0);
    });

    // --- Eventi sui bottoni ---
    okBtn.on('click', (event) => {
        L.DomEvent.stop(event);
        circle.pm.disable();
        circle.setStyle({ dashArray: null, color: '#cc6000' });
        areaState.isFixed = true;
        elements.map.removeLayer(btnGroup);
    });

    delBtn.on('click', (event) => {
        L.DomEvent.stop(event);
        elements.map.removeLayer(circle);
        elements.map.removeLayer(btnGroup);
        const idx = state.previewAreas.findIndex(a => a.circle === circle);
        if (idx !== -1) state.previewAreas.splice(idx, 1);
    });

    // --- Aggiorna posizione bottoni durante le modifiche ---
    const updateButtons = () => {
        if (areaState.isFixed) return;
        const centre = circle.getLatLng();
        /*  NEW → keep the form in sync */
        updateCoordinates(centre.lat, centre.lng);
        const rLatDeg = circle.getRadius() / 111320;
        okBtn.setLatLng([centre.lat + rLatDeg, centre.lng]);
        delBtn.setLatLng([centre.lat - rLatDeg, centre.lng]);
    };

    circle.on('drag', updateButtons);
    circle.on('pm:markerdrag', updateButtons);
});



// ------------------------------------------------------------------
// 4. Initialization
// ------------------------------------------------------------------
initializeMap();
populateSdwnDropdown();
renderSvgButtons(state.resState, handleResFilterClick);
setupInteractiveSelection();

// Set up periodic updates
setInterval(updateQueueBadge, 1000);        // Update queue every 2 seconds
setInterval(checkCompletedJobs, 3000);      // Check completed jobs every 3 seconds
setInterval(mainUpdateLoop, 5000);          // Main update every 5 seconds
setInterval(checkAutoFollow, 2000);  // run every 2 s

mainUpdateLoop();  // Initial update on startup
