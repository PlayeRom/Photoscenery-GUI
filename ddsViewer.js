// ddsViewer.js
// Lightweight DDS → PNG viewer for browser pop-ups
// MIT © KIMI 2025

export async function openTileViewer(ddsUrl, maxPx = 512) {
    // 1. Fetch DDS as Blob
    const blob = await fetch(ddsUrl).then(r => r.ok ? r.blob() : Promise.reject());

    // 2. DDS → Canvas via DDSParser (tiny WASM, 25 kB)
    const { DDSParser } = await import('https://cdn.jsdelivr.net/npm/ddsparser@1.1.0/+esm');
    const canvas = await DDSParser(blob, { maxWidth: maxPx, maxHeight: maxPx });

    // 3. Canvas → PNG Blob
    canvas.toBlob(pngBlob => {
        const url = URL.createObjectURL(pngBlob);
        // 4. Open Leaflet popup
        const img = document.createElement('img');
        img.src = url;
        img.style.maxWidth = '100%';
        img.style.height = 'auto';
        L.popup({ maxWidth: maxPx + 60 })
          .setLatLng(/* caller supplies */)
          .setContent(img)
          .openOn(window.map);   // global map instance
    });
}
