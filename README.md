# Photoscenery-GUI

**Photoscenery-GUI** is the new graphical interface for the Photoscenery tool, designed to offer a modern web-based GUI while introducing major performance improvements in several download stages.  
Although it still has some bugs and rough edges, it is already usable for downloading large scenery areas, especially if you have a good internet connection.

> **Note:** Requires Julia **version 1.11.x or later** (currently the reference version).

---

## 📦 Installing Dependencies

This version follows the Julia package management guidelines. Missing or updated dependencies will be automatically handled.

After downloading this repository from GitHub, run the following command **inside the downloaded directory**:

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

This will download and install all required packages.  
Thanks to Julia's project management, you should not encounter unexpected issues, and packages will remain automatically up to date.

---

## 🚀 Running Photoscenery-GUI

From inside the `Photoscenery-GUI` directory, run:

```bash
julia --project=. -e 'using Photoscenary; Photoscenary.GuiMode.run(["--http=8000"])'
```

The last parameter (`--http=8000`) sets the port for the local web server.

Once launched, open your **browser** (recommended: **Firefox**, not Chrome due to slower map rendering and poorer visuals) and go to:

```
http://127.0.0.1:8000/
```

The Julia application starts a lightweight local server; the interface is then handled by the JavaScript files in the `/js` directory and `main.html`.

---

## 📂 Output Storage

The GUI accepts the same batch options as the console version.  
The most useful for now is:

```
--path, -p "path Path to store the dds images"
```

If not specified, an automatic path will be chosen.  
Use this directory as the **source for FGFS** (FlightGear Scenery).

---

## ✨ Main Improvements

1. **Modern, minimal GUI** while maintaining batch mode compatibility (to be fully tested).
2. **ICAO input** has known issues, but you can click the airplane icon next to ICAO to activate **map selection mode**:
   - Mouse pointer becomes a crosshair.
   - Click to create an **orange circle** with a radius set by the "Radius (Nm)" field.
   - Adjust the radius by dragging the **white handle** on the edge.
   - Move the circle by dragging the center.
   - Add multiple circles to create a route (partially buggy).
   - Two icons per circle:  
     - **Green** → freeze/start download  
     - **Red** → delete circle
3. **Download process** requires pressing **"Execute Job"**.
4. **Parallel chunk downloading** into `photosceneryOrthophotos-saved/tmp`, then merging into tiles.  
   Includes verification to avoid incomplete or black chunks (a known issue in the previous version).
5. **Existing DDS file management**: Can import `.dds` files from other directories or even other drives (Linux confirmed working) without re-downloading.
6. **Faster startup**: On Linux, intelligently scans only relevant directories, making startup just a few seconds even with 4–5K `.dds` files.
7. **No more ImageMagick dependency**:  
   Two new high-performance Julia modules replace it:
   - `png2ddsDXT1.jl`
   - `dds2pngDXT1.jl`  
   These modules can also be useful for aircraft or scenery object developers.  
   Achieves **50–90 MPixels/s** on a 4-core CPU — the fastest `.DDS` compressed format converter tested so far.

---

## 💡 Notes & Recommendations

- **Browser**: Firefox strongly recommended for better rendering speed and visuals.
- **Large-area downloads**: Best results with stable, high-speed internet.
- **FGFS integration**: Ensure `--path` points to the correct FGFS scenery directory.

---

## 📜 License

This project is released under the same license as the main Photoscenery project.  
See the LICENSE file for details.
