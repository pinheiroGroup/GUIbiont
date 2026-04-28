using HTTP, JSON3, CSV, DataFrames, Statistics
using Kinbiont
using OptimizationNLopt
using Distributions: Normal, cdf
using StatsBase: corspearman
using DecisionTree: build_forest, impurity_importance, apply_forest
import Clustering
using Oxygen, StructTypes

const CLEAN_DATA_PATH = haskey(ENV, "CLEAN_DATA_PATH") ? ENV["CLEAN_DATA_PATH"] : "./Clean_data/"
const RAW_DATA_PATH   = haskey(ENV, "RAW_DATA_PATH")   ? ENV["RAW_DATA_PATH"]   : "./raw_data/"
const PORT            = haskey(ENV, "PORT") ? parse(Int, ENV["PORT"]) : 8080

include("function_clean_synergy.jl")
include("src/data.jl")
include("src/clustering.jl")
include("src/analysis.jl")
include("src/ml_downstream.jl")
include("src/schema.jl")
include("src/routes/config.jl")
include("src/routes/experiments.jl")
include("src/routes/fitting.jl")
include("src/routes/plot.jl")
include("src/routes/ml.jl")

@get "/" function(req::HTTP.Request)
    html = read(joinpath(@__DIR__, "web_interface.html"), String)
    return HTTP.Response(200, ["Content-Type" => "text/html"], html)
end

function CORSMiddleware(handler)
    return function(req::HTTP.Request)
        if HTTP.method(req) == "OPTIONS"
            return HTTP.Response(200, [
                "Access-Control-Allow-Origin"  => "*",
                "Access-Control-Allow-Methods" => "GET, POST, OPTIONS",
                "Access-Control-Allow-Headers" => "Content-Type",
            ])
        end
        response = handler(req)
        HTTP.setheader(response, "Access-Control-Allow-Origin" => "*")
        return response
    end
end

staticfiles("static", "static")

@info "Starting GUIbiont on port $PORT"
serve(middleware=[CORSMiddleware], host="0.0.0.0", port=PORT, async=false)
