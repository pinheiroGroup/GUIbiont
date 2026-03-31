using HTTP, JSON3, CSV, DataFrames, Statistics
using Kinbiont
using Distributions: Normal, cdf
using StatsBase: corspearman
using DecisionTree: build_forest, impurity_importance, apply_forest
import Clustering

# Configuration - adjust paths for standalone deployment
const CLEAN_DATA_PATH = haskey(ENV, "CLEAN_DATA_PATH") ? ENV["CLEAN_DATA_PATH"] : "./Clean_data/"
const RAW_DATA_PATH   = haskey(ENV, "RAW_DATA_PATH")   ? ENV["RAW_DATA_PATH"]   : "./raw_data/"
const PORT            = haskey(ENV, "PORT") ? parse(Int, ENV["PORT"]) : 8080

include("function_clean_synergy.jl")
include("src/clustering.jl")
include("src/data.jl")
include("src/http.jl")
include("src/analysis.jl")
include("src/ml_downstream.jl")
include("src/routes.jl")

# Start the server
function start_server(port=PORT)
    println("Starting Growth Curve Web Server...")
    println("Clean data path: $CLEAN_DATA_PATH")
    println("Server will run at: http://localhost:$port")
    println("Available experiments: $(length(get_experiments()))")
    println("\nPress Ctrl+C to stop the server")

    try
        HTTP.serve(router, "0.0.0.0", port)
    catch e
        if isa(e, InterruptException)
            println("\nServer stopped")
        else
            println("Error: $e")
        end
    end
end

# Run the server if this file is executed directly
if abspath(PROGRAM_FILE) == @__FILE__
    start_server()
end
