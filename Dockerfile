# GUIbiont — precompiled Julia image.
# All heavy dependency precompilation (Kinbiont, NLopt, BlackBoxOptim, …) happens
# HERE, at build time, so end users never wait 5–15 min on first launch.
# Must match the Julia version the published results were produced with
# (Methods reports 1.12.6); a different minor version re-resolves the
# environment and is no longer the tested one.
FROM julia:1.12-bookworm

# GR/Plots is a dependency; force its headless backend so precompilation never
# needs an X display, even though we don't render server-side.
# OPENBLAS_NUM_THREADS=1: OpenBLAS's own thread pool is independent of Julia's
# --threads and, left unpinned, changes floating-point summation order between
# runs inside Kinbiont's k-means (Clustering.jl calls BLAS for the Lloyd-step
# distance updates). With multiple ambiguous local optima at a given k, that
# reordering silently changes which optimum k-means converges to — two
# requests with the identical seed, data and parameters can return different
# WCSS/cluster assignments. Pinning to 1 thread makes clustering runs
# bit-reproducible.
ENV GKSwstype=nul \
    JULIA_DEPOT_PATH=/opt/julia \
    JULIA_NUM_THREADS=auto \
    OPENBLAS_NUM_THREADS=1

WORKDIR /app

# --- Layer 1: dependencies only (cached until the environment changes) -------
# Copy just the environment spec first so the expensive instantiate+precompile
# layer is reused across source-only edits. The Manifest is copied too, so the
# image installs the exact resolution the results were produced with instead of
# re-resolving to whatever satisfies the compat bounds at build time.
COPY Project.toml Manifest.toml ./
# Project.toml declares GUIbiont as a package (name+uuid), so Pkg needs its
# module file present to resolve/precompile the environment. Create the trivial
# module now (the real src/ is copied below and is identical) so the dependency
# precompile in the next layer runs cleanly.
RUN mkdir -p src && printf 'module GUIbiont\nend\n' > src/GUIbiont.jl

# Instantiate + precompile, then clean up in the SAME layer so the freed space
# is not retained by an earlier layer:
#   - Pkg.gc() prunes orphaned packages/artifacts
#   - the registry clone and package docs are not needed at runtime
RUN julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.precompile(); Pkg.gc()' \
    && rm -rf "$JULIA_DEPOT_PATH"/registries/* "$JULIA_DEPOT_PATH"/logs \
    && find "$JULIA_DEPOT_PATH"/packages -type d -name docs -prune -exec rm -rf {} + 2>/dev/null || true

# --- Layer 2: application source --------------------------------------------
COPY web_server.jl web_interface.html ./
COPY src/ ./src/
COPY static/ ./static/
COPY calibration/ ./calibration/

# Mount points for user data (populated via -v at runtime; see run.sh).
RUN mkdir -p /app/Clean_data /app/raw_data

# Warm the application code paths too (methods in src/), not just packages.
# GUIBIONT_PRECOMPILE_ONLY loads every route/include but returns before serve(),
# so this compiles the app without hanging the build on a bound port.
RUN GUIBIONT_PRECOMPILE_ONLY=true julia --project=. web_server.jl

EXPOSE 8080
# Container always listens on 8080 internally; the host port is chosen by run.sh.
ENV PORT=8080
CMD ["julia", "--project=.", "--threads=auto", "web_server.jl"]
