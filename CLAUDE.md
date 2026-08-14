# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is GUIbiont, a Julia web platform for large-scale microbial growth curve analysis built on Kinbiont.jl. The application processes microplate reader data, visualizes growth curves, and fits mathematical models to microbial growth data.

## Architecture

**Frontend**: Single-page HTML application (`web_interface.html`) with Plotly.js for interactive visualization
**Backend**: Julia HTTP server (`web_server.jl`) with CORS support for API endpoints
**Core Functions**:
- `src/cleaning/synergy.jl` - Data cleaning for Synergy microplate reader files
- `function_for_fitting.jl` - Growth curve fitting using Kinbiont.jl package
**Main Entry Point**: `launch_web_app.jl` - Handles dependency installation and server startup

## Development Commands

### Starting the Application
```bash
julia launch_web_app.jl
```
This automatically installs dependencies on first run and starts the server on port 8080.

### Manual Dependency Management
```bash
# Install/update dependencies
julia --project=. -e "import Pkg; Pkg.instantiate()"

# Update packages to latest compatible versions
julia --project=. -e "import Pkg; Pkg.update()"

# Clean installation (if corrupted)
rm Manifest.toml
julia --project=. -e "import Pkg; Pkg.instantiate()"
```

### Port Configuration
```bash
export PORT=3000
julia launch_web_app.jl
```

### Data Path Configuration
```bash
export CLEAN_DATA_PATH="/path/to/clean/data"
export RAW_DATA_PATH="/path/to/raw/data"
julia launch_web_app.jl
```

## Data Structure Requirements

**Raw Data** (in `raw_data/experiment_name/`):
- `data.csv` - Time series OD measurements from microplate reader
- `plate.csv` - Well annotations and experimental conditions

**Processed Data** (in `Clean_data/experiment_name/`):
- `data_channel_1.csv` - Cleaned time series data
- `annotation_clean.csv` - Processed well annotations

## Key Dependencies

- **Kinbiont.jl** - Core package for growth curve analysis and model fitting
- **HTTP.jl** - Web server functionality
- **Plots.jl** - Plotting backend (integrates with frontend Plotly.js)
- **CSV.jl/DataFrames.jl** - Data processing pipeline
- **JSON3.jl** - API serialization

## Web API Endpoints

The server provides REST endpoints for:
- `/experiments` - List available cleaned experiments
- `/experiment-info/{name}` - Get experiment metadata and well information
- `/plot-data` - Get time series data for plotting selected wells
- `/fit-curve` - Perform growth model fitting for individual wells
- `/clean-data` - Process raw Synergy microplate reader files

## Important Notes

- First-time setup requires 5-15 minutes for Julia package compilation
- Requires Julia 1.12+ (specified in Project.toml)
- Application expects specific CSV format from BioTek Synergy microplate readers
- Model fitting uses the Kinbiont.jl ecosystem for bacterial growth analysis
- Frontend uses Plotly.js for interactive visualization, no build step required
