#!/usr/bin/env julia

# Simple launcher for the Growth Curve Web App
println("🧫 Growth Curve Web App Launcher")
println("=" ^ 40)

# Check if packages are installed
try
    using HTTP, JSON3, CSV, DataFrames, Statistics
    println("✅ All packages available")
catch e
    println("❌ Missing packages. Installing...")
    import Pkg
    Pkg.instantiate()
    println("✅ Packages installed")
end

# Include and start the server
println("📂 Loading web server...")
include("web_server.jl")
println("🚀 Starting server on port 8080...")
start_server(8080)