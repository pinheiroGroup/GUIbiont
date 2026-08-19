# GUIbiont

A web platform for large-scale microbial growth curve analysis, built on Kinbiont.jl.

📄 **Preprint:** [No-code microbial growth phenotyping with GUIbiont](https://www.biorxiv.org/content/10.64898/2026.08.17.745250v1) — bioRxiv, [10.64898/2026.08.17.745250](https://doi.org/10.64898/2026.08.17.745250)

## Features

- **Data Cleaning**: Process raw Synergy microplate reader data
- **Growth Visualization**: Interactive plotting of microbial growth curves
- **Curve Fitting**: Growth model fitting for individual wells
- **Multi-experiment Support**: Compare data across multiple experiments
- **Export Capabilities**: Export plots as PNG/SVG

## Easy Install (recommended for most users)

No Julia, no dependencies, no compilation wait — just Docker. The image ships
with everything precompiled, so it starts in seconds.

1. **Install [Docker Desktop](https://www.docker.com/products/docker-desktop/)** (Windows, macOS, or Linux) and start it.
2. **Download the launcher** for your system from this repository:
   - macOS / Linux → `run.sh`
   - Windows → `run.ps1`
3. **Run it:**

   **macOS / Linux**
   ```bash
   chmod +x run.sh
   ./run.sh
   ```

   **Windows** (right-click `run.ps1` → *Run with PowerShell*, or in a terminal):
   ```powershell
   .\run.ps1
   ```

The launcher automatically:

- **asks (on first run) where to store your data**, then remembers your choice,
- picks a free port (starting at 8080, skips it if busy),
- creates your data folders and mounts them into the app,
- pulls the latest version, and
- opens GUIbiont in your browser once it's ready.

### Choosing where your data lives

On the **first run** you'll be asked for a data folder; press Enter to accept
the default (`~/GUIbiont-data`, or `%USERPROFILE%\GUIbiont-data` on Windows) or
type any path. Your answer is remembered, so later runs don't ask again.

- **Change it later:** `./run.sh config` (or `.\run.ps1 config`) forgets the
  saved folder, so the next run asks again.
- **Set it non-interactively / scripted:** the `GUIBIONT_DATA` environment
  variable always wins and is not persisted, e.g.
  `GUIBIONT_DATA=/data/lab ./run.sh`.

Whatever folder you pick gets `raw_data/` and `Clean_data/` subfolders. Because
it lives outside the app, it is never touched by updates.

**To update:** just run the launcher again — it pulls the newest image.

**To stop:** `./run.sh stop` (or `.\run.ps1 stop`).

> Other environment overrides: `GUIBIONT_PORT` (starting port),
> `GUIBIONT_IMAGE` (image to run).

---

## Developer Setup (run from source with Julia)

1. **Install Julia** (version 1.12 or higher)

2. **Navigate to this directory**:
   ```bash
   cd GUIbiont
   ```

3. **Install dependencies** (choose one method):

   **Option A: Automatic (Recommended)**
   ```bash
   julia --project=. --threads=auto web_server.jl
   ```
   Dependencies will be installed automatically on first run.

   **Option B: Manual Installation**
   ```bash
   julia --project=. -e "import Pkg; Pkg.instantiate()"
   ```

   **Option C: Interactive Installation**
   ```bash
   julia --project=.
   ```
   Then in Julia REPL:
   ```julia
   import Pkg
   Pkg.instantiate()
   exit()
   ```

4. **Start the web application** (if not already started):
   ```bash
   julia --project=. --threads=auto web_server.jl
   ```

5. **Open your browser** to: http://localhost:8080

### Installation Notes

- **First-time setup**: Initial dependency installation may take 5-15 minutes
- **Internet required**: Packages are downloaded from Julia registry
- **Disk space**: Full dependency tree requires ~500MB-1GB
- **Julia version**: Requires Julia 1.12 or higher

### Running the Tests

Unit tests need no running server:

```bash
julia --project=. -e "using Pkg; Pkg.test()"
```

The integration/API tests are additionally exercised only when a GUIbiont
server is reachable — they are skipped automatically otherwise. To run them,
start the server first and then run the suite:

```bash
# terminal 1
julia --project=. --threads=auto web_server.jl

# terminal 2
julia --project=. -e "using Pkg; Pkg.test()"
```

The suite reads the server address from the `SERVER_URL` environment variable,
which defaults to `http://localhost:8080` (the server's own default port). Set
it if you started the server elsewhere, e.g.
`SERVER_URL=http://localhost:3000`.

## Project Structure

```
GUIbiont/
├── web_interface.html          # Frontend interface
├── web_server.jl              # Backend Julia server
├── launch_web_app.jl          # Application launcher
├── function_for_fitting.jl    # Growth curve fitting functions
├── src/cleaning/synergy.jl      # Data cleaning functions
├── Project.toml               # Julia dependencies
├── README.md                  # This file
├── Clean_data/                # Processed experiment data (created on first use)
└── raw_data/                  # Raw microplate reader files (user provided)
```

## Data Organization

### For Raw Data Processing
Place your raw Synergy microplate reader files in the `raw_data/` directory:
```
raw_data/
├── experiment1/
│   ├── data.csv              # Time series OD data
│   └── plate.csv             # Well annotations
└── experiment2/
    ├── data.csv
    └── plate.csv
```

### For Growth Analysis
After cleaning, processed data will be in `Clean_data/`:
```
Clean_data/
├── experiment1/
│   ├── data_channel_1.csv    # Cleaned time series data
│   └── annotation_clean.csv  # Processed annotations
└── experiment2/
    ├── data_channel_1.csv
    └── annotation_clean.csv
```

## Configuration

Environment variables can be used to customize paths:

- `CLEAN_DATA_PATH`: Path to cleaned data directory (default: `./Clean_data/`)
- `RAW_DATA_PATH`: Path to raw data directory (default: `./raw_data/`)
- `PORT`: Server port (default: `8080`)

Example:
```bash
export CLEAN_DATA_PATH="/path/to/your/clean/data"
export RAW_DATA_PATH="/path/to/your/raw/data"
export PORT=3000
julia --project=. --threads=auto web_server.jl
```

## Dependencies

The application uses the following Julia packages (automatically installed):

### Core Packages
- **HTTP.jl** - Web server functionality
- **JSON3.jl** - JSON data handling
- **CSV.jl** - Reading/writing CSV files
- **DataFrames.jl** - Data manipulation
- **Kinbiont.jl** - Growth curve analysis (core package)
- **Statistics.jl** - Statistical functions
- **Plots.jl** - Plotting functionality
- **StatsBase.jl** - Statistical utilities
- **Tables.jl** - Table interface

### Installation Commands
If you need to reinstall or update dependencies:

```bash
# Reinstall all packages
julia --project=. -e "import Pkg; Pkg.instantiate()"

# Update to latest compatible versions
julia --project=. -e "import Pkg; Pkg.update()"

# Add a missing package (if needed)
julia --project=. -e "import Pkg; Pkg.add(\"PackageName\")"
```

See `Project.toml` for complete dependency list and version constraints.

## Usage

### 1. Clean Data Tab
- Select raw experiment from dropdown
- Choose number of wells (6, 48, or 96)
- Click "Clean Data" to process

### 2. Plot Growth Tab
- Select experiments using checkboxes
- Search and filter wells by condition/antibiotic
- Select specific wells to plot
- View interactive growth curves and statistics

### 3. Fit Curve Tab
- Select one experiment and one well
- Fit growth model to data
- View fitted parameters and curve overlay

## Troubleshooting

### Common Issues

**Port already in use**
```bash
export PORT=3000
julia --project=. --threads=auto web_server.jl
```

**Missing data files**
Ensure raw data follows the expected structure (see Data Organization section).

**Package installation issues**
```bash
# Try manual installation
julia --project=. -e "import Pkg; Pkg.instantiate()"

# Clear and reinstall if corrupted
julia --project=. -e "import Pkg; Pkg.instantiate()"

# Check Julia version (requires 1.12+)
julia --version
```

**Memory issues during installation**
```bash
# Increase Julia heap size
julia --heap-size-hint=4G --project=. -e "import Pkg; Pkg.instantiate()"
```

**Internet/proxy issues**
If behind a corporate firewall, you may need to configure Julia's package manager:
```julia
# In Julia REPL
import Pkg
Pkg.Registry.add(RegistrySpec(url="https://github.com/JuliaRegistries/General.git"))
```

**Clean installation** (if dependencies are corrupted)
```bash
# Remove Manifest.toml and reinstall
rm Manifest.toml
julia --project=. -e "import Pkg; Pkg.instantiate()"
```

## Citation

If GUIbiont contributes to work you publish, please cite the manuscript and the software release:

**Manuscript**

> Alvarenga E.Z., Oltolini E., Pinheiro F. *No-code microbial growth phenotyping with GUIbiont.*
> bioRxiv (2026). doi: [10.64898/2026.08.17.745250](https://doi.org/10.64898/2026.08.17.745250)

```bibtex
@article{alvarenga2026guibiont,
  title   = {No-code microbial growth phenotyping with GUIbiont},
  author  = {Zanella Alvarenga, Edgar and Oltolini, Edoardo and Pinheiro, Fernanda},
  journal = {bioRxiv},
  year    = {2026},
  doi     = {10.64898/2026.08.17.745250},
  url     = {https://www.biorxiv.org/content/10.64898/2026.08.17.745250v1}
}
```

**Software**

> GUIbiont v1.1.1, archived at [10.5281/zenodo.21930894](https://doi.org/10.5281/zenodo.21930894).

Machine-readable metadata for both is in [`CITATION.cff`](CITATION.cff). Please also cite
[Kinbiont.jl](https://github.com/pinheiroGroup/Kinbiont.jl) for the underlying methods.

## Related Projects

GUIbiont is built on [Kinbiont.jl](https://github.com/pinheiroGroup/Kinbiont.jl), a Julia library for microbial growth curve analysis.
