#!/usr/bin/env julia

# Re-exec with --threads=auto if Julia was started single-threaded.
if Threads.nthreads() == 1 && Sys.CPU_THREADS > 1
    cmd = `$(Base.julia_cmd()) --threads=auto --project=. $(PROGRAM_FILE) $(ARGS...)`
    run(cmd)
    exit()
end

# Simple launcher for the Growth Curve Web App
println("🧫 Growth Curve Web App Launcher")
println("=" ^ 40)

# Activate project environment and install packages if needed
import Pkg
Pkg.activate(".")

# Check if packages are installed
try
    using HTTP, JSON3, CSV, DataFrames, Statistics
    println("✅ All packages available")
catch e
    println("❌ Missing packages. Installing...")
    Pkg.instantiate()
    println("✅ Packages installed")
    using HTTP, JSON3, CSV, DataFrames, Statistics
end

# Include and start the server
println("📂 Loading web server...")
include("web_server.jl")
port = haskey(ENV, "PORT") ? parse(Int, ENV["PORT"]) : 8080
println("🚀 Starting server on port $port...")
start_server(port)