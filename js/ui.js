// Save as: js/ui.js
/**
 * UI Management Module
 *
 * This module handles all webpage manipulation including:
 * - Map initialization and management
 * - User interface controls
 * - Visual feedback and updates
 */

// DOM elements and map references

const elements = {
    map: L.map('map').setView([45, 12], 5),
    icaoInput: document.getElementById('icao'),
    latInput: document.getElementById('lat'),
    lonInput: document.getElementById('lon'),
    sizeInput: document.getElementById('size'),
    sdwnSelect: document.getElementById('sdwn-value'),
    overSelect: document.getElementById('over-mode'),
    radiusInput: document.getElementById('radius'),
    latlonContainer: document.getElementById('latlon-container'),
    icaoContainer: document.getElementById('icao-container'),
    btnGetCoords: document.getElementById('btn-get-coords'),
    btnConnect: document.getElementById('btn-connect'),
    btnSelectFromMap: document.getElementById('btn-select-from-map'),
    controlsPanel: document.getElementById('controls'),
    resSvgContainer: document.getElementById('res-svg-container'),
    mapContainer: document.getElementById('map'),
    tilePreviewImage: document.getElementById('tilePreview'),
    downloadBtn: document.getElementById('downloadBtn'),
    opacitySlider: document.getElementById('opacity-slider'),
};

// Map layers and markers
let coverageLayer = L.layerGroup().addTo(elements.map);
let aircraftMarker = null;

/**
 * Initializes the base map with OpenStreetMap tiles
 */

/**
 * Updates map coverage display with filtered tiles
 * @param {Array} coverageData - Tile coverage information
 * @param {Set} allowedResolutions - Set of allowed resolution IDs
 * @param {number} currentOpacity - Current opacity setting
 */
function updateMapCoverage(coverageData, allowedResolutions, currentOpacity) {
    coverageLayer.clearLayers();
    coverageData.forEach(tile => {
        if (!allowedResolutions.has(tile.sizeId)) return;

        const popupHtml = `
        ID: ${tile.id}<br>
        Resolution: ${tile.sizeId}<br>
        <button class="preview-button" data-tile-id="${tile.id}" data-size-id="${tile.sizeId}">View Preview</button>
        `;

        const bounds = [[tile.bbox.latLL, tile.bbox.lonLL], [tile.bbox.latUR, tile.bbox.lonUR]];
        L.rectangle(bounds, {
            ...getStyleForSizeId(tile.sizeId),
                    fillOpacity: currentOpacity,
                    opacity: 1
        })
        .addTo(coverageLayer)
        .bindPopup(popupHtml);
    });
}

/**
 * Updates aircraft position marker on the map
 * @param {Object} data - Aircraft status data
 */
function updateAircraftPosition(data) {
    if (!data.active) {
        if (aircraftMarker) elements.map.removeLayer(aircraftMarker);
        aircraftMarker = null;
        return;
    }

    const latLng = [data.lat, data.lon];
    const tooltipContent = `
    <b>Heading:</b> ${Math.round(data.heading)}°<br>
    <b>Altitude:</b> ${Math.round(data.altitude)} ft<br>
    <b>Speed:</b> ${Math.round(data.speed)} kts
    `;

    if (!aircraftMarker) {
        const aircraftSVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="28" height="28">
        <path d="M21 16v-2l-8-5V3.5c0-.83-.67-1.5-1.5-1.5S10 2.67 10 3.5V9l-8 5v2l8-2.5V19l-2 1.5V22l3.5-1 3.5 1v-1.5L13 19v-5.5l8 2.5z"
        fill="#d9534f" stroke="black" stroke-width="1"/>
        </svg>`;

        const icon = L.divIcon({
            html: aircraftSVG,
            className: 'aircraft-icon',
            iconSize: [28, 28]
        });

        aircraftMarker = L.marker(latLng, {
            icon: icon,
            rotationAngle: data.heading
        })
        .addTo(elements.map)
        .bindTooltip(tooltipContent);
    } else {
        aircraftMarker.setLatLng(latLng);
        aircraftMarker.setRotationAngle(data.heading);
        aircraftMarker.setTooltipContent(tooltipContent);
    }
}

/**
 * Populates the downscaling dropdown based on current size selection
 */
function populateSdwnDropdown() {
    const maxSize = parseInt(elements.sizeInput.value, 10);
    const currentSdwnValue = elements.sdwnSelect.value;

    elements.sdwnSelect.innerHTML = '';
    elements.sdwnSelect.add(new Option("Disabled", "-1"));

    for (let i = 0; i <= maxSize; i++) {
        elements.sdwnSelect.add(new Option(`From ${maxSize} to ${i}`, i));
    }

    elements.sdwnSelect.value = (currentSdwnValue >= 0 && currentSdwnValue <= maxSize) ? currentSdwnValue : "-1";
}

/**
 * Updates UI elements based on FlightGear connection state
 * @param {boolean} isConnected - Current connection status
 */
function toggleConnectionState(isConnected) {
    if (isConnected) {
        elements.btnConnect.textContent = 'Disconnect from FGFS';
        elements.btnConnect.classList.add('active');
        elements.btnGetCoords.style.display = 'block';
    } else {
        elements.btnConnect.textContent = 'Connect to FGFS';
        elements.btnConnect.classList.remove('active');
        showIcaoMode();
    }
}

/**
 * Renders resolution filter buttons as SVG elements
 * @param {Array} resState - Array of resolution states (active/inactive)
 * @param {Function} clickCallback - Handler for button clicks
 */
function renderSvgButtons(resState, clickCallback) {
    elements.resSvgContainer.innerHTML = '';

    resState.forEach((isActive, index) => {
        const div = document.createElement('div');
        div.classList.add('res-svg-button');
        div.innerHTML = createSvgCircle(index, isActive);
        div.addEventListener('click', () => clickCallback(index));
        elements.resSvgContainer.appendChild(div);
    });
}

/**
 * Toggles map coordinate selection mode
 * @param {boolean} isSelectionMode - Whether selection mode should be active
 */
function toggleMapSelectionMode(isSelectionMode) {
    if (isSelectionMode) {
        elements.btnSelectFromMap.classList.add('active');
        elements.mapContainer.style.cursor = 'crosshair';
        elements.latlonContainer.style.display = 'block';
    } else {
        elements.btnSelectFromMap.classList.remove('active');
        elements.mapContainer.style.cursor = '';
    }
}

/**
 * Shows ICAO input mode and hides coordinate inputs
 */
function showIcaoMode() {
    elements.latlonContainer.style.display = 'none';
    elements.btnGetCoords.style.display = 'none';
}

/**
 * Displays tile preview in the preview panel
 * @param {string} tileId - Tile identifier
 * @param {number} sizeId - Resolution identifier
 * @param {string} imageUrl - Preview image URL
 */
function showTileInPanel(tileId, sizeId, imageUrl) {
    elements.tilePreviewImage.src = imageUrl;
    elements.tilePreviewImage.style.display = 'block';

    elements.downloadBtn.textContent = `Download (ID: ${tileId}, Res: ${sizeId})`;
    elements.downloadBtn.style.display = 'block';

    elements.downloadBtn.onclick = () => {
        const a = document.createElement('a');
        a.href = imageUrl;
        a.download = `${tileId}_preview.png`;
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
    };
}

/**
 * Creates a draggable preview circle on the map and returns it.
 * @param {number} lat - Latitude coordinate
 * @param {number} lon - Longitude coordinate
 * @param {number} radiusNm - Radius in nautical miles
 * @returns {L.Circle} The Leaflet circle object
 */
function previewArea(lat, lon, radiusNm) {
    const previewCircle = L.circle([lat, lon], {
        radius: radiusNm * 1852,
        color: '#ff7800',
        fillColor: '#ff7800',
        fillOpacity: 0.2,
        weight: 2,
        dashArray: '5,5'
    }).addTo(elements.map);

    // Abilita le funzionalità di Geoman (spostamento e modifica)
    previewCircle.pm.enable({
        allowSelfIntersection: false,
        draggable: true
    });

    return previewCircle;
}

/**
 * Removes the preview circle from the map
 */

// Internal helper functions
function getStyleForSizeId(sizeId) {
    const colors = ['#0000FF', '#2A00D5', '#5500AA', '#800080', '#AA0055', '#D5002A', '#FF0000'];
    return {
        color: colors[sizeId] || '#333',
        weight: 1,
        fillColor: colors[sizeId] || '#333'
    };
}

function createSvgCircle(index, selected) {
    const fillColor = selected ? '#0088cc' : 'white';
    const strokeColor = '#0088cc';
    const textColor = selected ? 'white' : '#0088cc';
    return `
    <svg viewBox="0 0 32 32">
    <circle cx="16" cy="16" r="14" fill="${fillColor}" stroke="${strokeColor}" stroke-width="2"/>
    <text x="16" y="21" text-anchor="middle" fill="${textColor}" font-size="16">${index}</text>
    </svg>`;
}

function initializeMap() {
    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
        attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
    }).addTo(elements.map);
}

/**
 * Collects job parameters from UI inputs
 * @returns {Object} Contains all parameters needed to start a job
 */
function getJobParameters() {
    const jobParams = {
        radius: parseFloat(elements.radiusInput.value) || 3,
        size:   parseInt(elements.sizeInput.value, 10) || 4,
        over:   parseInt(elements.overSelect.value, 10) || 1,
        sdwn:   parseInt(elements.sdwnSelect.value, 10)  // può restituire -1
    };

    // Se lat/lon non sono compilati, usa ICAO
    if (elements.latlonContainer.style.display === 'block' &&
        elements.latInput.value &&
        elements.lonInput.value) {
        jobParams.lat = parseFloat(elements.latInput.value);
    jobParams.lon = parseFloat(elements.lonInput.value);
        } else {
            jobParams.icao = elements.icaoInput.value.trim();
        }

        // Mai null/undefined
        Object.keys(jobParams).forEach(k => {
            if (jobParams[k] == null || Number.isNaN(jobParams[k])) {
                jobParams[k] = (k === 'sdwn') ? -1 : 3; // default sicuro
            }
        });

        return jobParams;
}

function clearPreview() {
    if (window.pendingCircle) {
        elements.map.removeLayer(window.pendingCircle);
        window.pendingCircle = null;
    }
}

function setupInteractiveSelection() {
    // Update preview when parameters change
    elements.radiusInput.addEventListener('input', updatePreview);
    elements.latInput.addEventListener('input', updatePreview);
    elements.lonInput.addEventListener('input', updatePreview);

    // Clear preview when switching to ICAO mode
    elements.icaoInput.addEventListener('input', () => {
        if (elements.icaoInput.value && window.pendingCircle) {
            clearPreview();
        }
    });

    function updatePreview() {
        if (elements.latInput.value && elements.lonInput.value && elements.radiusInput.value) {
            previewArea(
                parseFloat(elements.latInput.value),
                        parseFloat(elements.lonInput.value),
                        parseFloat(elements.radiusInput.value)
            );
        }
    }
}

export function linkRadiusHandleToInput(circle) {
    // Geoman fires while the radius handle is dragged
    circle.on('pm:markerdrag', e => {
        // radius in metres → nautical miles
        const nm = (circle.getRadius() / 1852).toFixed(1);
        elements.radiusInput.value = nm;
    });
}

/***
 * Export function
 * ES6 syntax short form*
 */
export {
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
};


