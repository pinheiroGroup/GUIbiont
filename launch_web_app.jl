#!/usr/bin/env julia

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
println("🚀 Starting server on port 8080...")
start_server(8080)