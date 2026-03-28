using Test
using CSV
using DataFrames
using HTTP
using JSON3
using Statistics

# Load the functions under test
include(joinpath(@__DIR__, "..", "function_clean_synergy.jl"))

# Load backend modules (data helpers + experiment store)
# These mirror the include order in web_server.jl, minus HTTP/Kinbiont deps.
const CLEAN_DATA_PATH = get(ENV, "CLEAN_DATA_PATH",
    joinpath(@__DIR__, "..", "Clean_data") * "/")
include(joinpath(@__DIR__, "..", "src", "data.jl"))
include(joinpath(@__DIR__, "..", "src", "experiment_store.jl"))

include("data_helpers_test.jl")
include("experiment_store_test.jl")

# ---------------------------------------------------------------------------
# Paths to fixtures — prefer committed test/fixtures, fall back to local data
# ---------------------------------------------------------------------------

const RAW_LG281 = let p = joinpath(@__DIR__, "fixtures", "raw", "LG281")
    isdir(p) ? p : joinpath(@__DIR__, "..", "raw_data", "LG281")
end
const GOLDEN_LG281 = let p = joinpath(@__DIR__, "fixtures", "clean", "LG281")
    isdir(p) ? p : joinpath(@__DIR__, "..", "Clean_data", "LG281")
end

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Read a CSV as a plain matrix of strings (no type inference, no headers)
function read_csv_strings(path)
    CSV.read(path, DataFrame, header=false, stringtype=String, silencewarnings=true)
end

# Read a CSV with the first row as column names
function read_csv_with_header(path)
    CSV.read(path, DataFrame, header=1, stringtype=String, silencewarnings=true)
end

# ---------------------------------------------------------------------------
# detect_csv_separator
# ---------------------------------------------------------------------------

@testset "detect_csv_separator" begin
    mktempdir() do dir
        comma_file = joinpath(dir, "comma.csv")
        semi_file  = joinpath(dir, "semi.csv")
        write(comma_file, "a,b,c\n1,2,3\n4,5,6\n")
        write(semi_file,  "a;b;c\n1;2;3\n4;5;6\n")

        @test detect_csv_separator(comma_file) == ','
        @test detect_csv_separator(semi_file)  == ';'
    end

    # Real LG281 data file uses semicolons
    @test detect_csv_separator(joinpath(RAW_LG281, "data.csv"))  == ';'
    @test detect_csv_separator(joinpath(RAW_LG281, "plate.csv")) == ';'
end

# ---------------------------------------------------------------------------
# cleaning_data_synergy — run against LG281 and compare to golden output
# ---------------------------------------------------------------------------

@testset "cleaning_data_synergy" begin
    mktempdir() do out_dir
        out_path = out_dir * "/"
        cleaning_data_synergy(joinpath(RAW_LG281, "data.csv"), out_path)

        @testset "produces correct channel files" begin
            for ch in 1:3
                fname = joinpath(out_dir, "data_channel_$(ch).csv")
                @test isfile(fname)
            end
            # No data_channel_4 expected for LG281 (3 channels)
            @test !isfile(joinpath(out_dir, "data_channel_4.csv"))
        end

        for ch in 1:3
            golden = read_csv_with_header(joinpath(GOLDEN_LG281, "data_channel_$(ch).csv"))
            result = read_csv_with_header(joinpath(out_dir, "data_channel_$(ch).csv"))

            @testset "channel $ch structure" begin
                @test names(result) == names(golden)
                @test nrow(result)  == nrow(golden)
                @test ncol(result)  == ncol(golden)
            end

            @testset "channel $ch first column is Time" begin
                @test names(result)[1] == "Time"
            end

            @testset "channel $ch well columns" begin
                well_cols = names(result)[2:end]
                @test length(well_cols) == 48      # 48-well plate
                @test well_cols[1]  == "A1"
                @test well_cols[end] == "F8"
            end

            @testset "channel $ch time values are numeric and increasing" begin
                times = Float64.(result[!, "Time"])
                @test all(isfinite, times)
                @test all(diff(times) .> 0)
            end

            @testset "channel $ch OD values are numeric" begin
                @test result[1, "A1"] isa Number
                @test isfinite(Float64(result[1, "A1"]))
            end

            @testset "channel $ch first row matches golden" begin
                @test result[1, :] == golden[1, :]
            end

            @testset "channel $ch last row matches golden" begin
                @test result[end, :] == golden[end, :]
            end

            @testset "channel $ch full content matches golden" begin
                @test result == golden
            end
        end
    end
end

# ---------------------------------------------------------------------------
# read_labguru_annotation — run against LG281 and compare to golden output
# ---------------------------------------------------------------------------

@testset "read_labguru_annotation" begin
    mktempdir() do out_dir
        out_path = out_dir * "/"
        read_labguru_annotation(joinpath(RAW_LG281, "plate.csv"), out_path, 48)

        @testset "produces annotation_clean.csv" begin
            @test isfile(joinpath(out_dir, "annotation_clean.csv"))
        end

        @testset "produces per-channel per-media annotation files" begin
            @test isfile(joinpath(out_dir, "annotation_channel_1_media_M9+glucose.csv"))
            @test isfile(joinpath(out_dir, "annotation_channel_2_media_M9+glucose.csv"))
            # Channel 3 has no wells assigned in LG281 plate layout
            @test !isfile(joinpath(out_dir, "annotation_channel_3_media_M9+glucose.csv"))
        end

        @testset "annotation_clean.csv structure" begin
            golden = read_csv_strings(joinpath(GOLDEN_LG281, "annotation_clean.csv"))
            result = read_csv_strings(joinpath(out_dir,       "annotation_clean.csv"))
            @test nrow(result) == nrow(golden)
            @test ncol(result) == ncol(golden)
        end

        @testset "annotation_clean.csv content matches golden" begin
            golden = read_csv_strings(joinpath(GOLDEN_LG281, "annotation_clean.csv"))
            result = read_csv_strings(joinpath(out_dir,       "annotation_clean.csv"))
            @test isequal(result, golden)
        end

        for ch in 1:2
            fname = "annotation_channel_$(ch)_media_M9+glucose.csv"
            @testset "$(fname) content matches golden" begin
                golden = read_csv_strings(joinpath(GOLDEN_LG281, fname))
                result = read_csv_strings(joinpath(out_dir,       fname))
                @test nrow(result) == nrow(golden)
                @test ncol(result) == ncol(golden)
                @test result == golden
            end
        end

        @testset "annotation_clean.csv well column is complete" begin
            result = read_csv_strings(joinpath(out_dir, "annotation_clean.csv"))
            wells  = result[!, 1]
            # 48-well plate: A1-F8
            expected_wells = [r * string(c) for r in ["A","B","C","D","E","F"] for c in 1:8]
            @test Vector{String}(wells) == expected_wells
        end

        @testset "per-channel annotation marks non-channel wells as X" begin
            result = read_csv_strings(joinpath(out_dir, "annotation_channel_1_media_M9+glucose.csv"))
            # Column 2 should be either a condition string or "b" (blank) — never missing
            @test all(!ismissing, result[!, 2])
            # Blank wells (column 8 in each row group: A8, B8, ...) should be "b"
            blank_rows = filter(row -> row[2] == "b", eachrow(result))
            @test length(blank_rows) > 0
        end
    end
end

# ---------------------------------------------------------------------------
# web_server.jl API endpoints
#
# Requires a running server. Set SERVER_URL env variable to override the
# default (http://localhost:9090).
# ---------------------------------------------------------------------------

const BASE_URL = get(ENV, "SERVER_URL", "http://localhost:9090")

function server_available()
    try
        HTTP.get("$BASE_URL/"; connect_timeout=2, readtimeout=2, status_exception=false)
        return true
    catch
        return false
    end
end

function get_json(path)
    r = HTTP.get("$BASE_URL$path"; status_exception=false)
    return r.status, JSON3.read(String(r.body))
end

function post_json(path, body)
    r = HTTP.post(
        "$BASE_URL$path",
        ["Content-Type" => "application/json"],
        JSON3.write(body);
        status_exception=false
    )
    return r.status, JSON3.read(String(r.body))
end

const SINGLE_CH_EXP  = "LG166"
const SINGLE_CH_WELL = "A3"
const MULTI_CH_EXP   = "LG298"
const MULTI_CH_WELLS = Dict(1 => "A1", 2 => "C1", 3 => "E1")

if !server_available()
    @info "Server not reachable at $BASE_URL — skipping API tests. Start the server to run them."
else

@testset "web_server.jl API" begin

    @testset "GET /api/experiments" begin
        status, body = get_json("/api/experiments")
        @test status == 200
        @test body isa AbstractVector
        @test !isempty(body)
        @test SINGLE_CH_EXP in body
        @test MULTI_CH_EXP  in body
    end

    @testset "POST /api/multi-experiment-info — single channel" begin
        status, body = post_json("/api/multi-experiment-info",
                                 Dict("experiments" => [SINGLE_CH_EXP]))
        @test status == 200
        wells = body[:wells]
        @test !isempty(wells)
        w = first(wells)
        @test haskey(w, :well_id)
        @test haskey(w, :channel)
        @test haskey(w, :condition)
        @test w[:experiment] == SINGLE_CH_EXP
        @test !occursin("_ch", string(w[:well_id]))
    end

    @testset "POST /api/multi-experiment-info — multi channel" begin
        status, body = post_json("/api/multi-experiment-info",
                                 Dict("experiments" => [MULTI_CH_EXP]))
        @test status == 200
        wells = body[:wells]
        @test !isempty(wells)
        @test sort(unique(Int(w[:channel]) for w in wells)) == [1, 2, 3]
        @test any(occursin("_ch", string(w[:well_id])) for w in wells)
        @test all(Int(w[:n_channels]) == 3 for w in wells)
    end

    @testset "POST /api/multi-experiment-info — unknown experiment" begin
        status, body = post_json("/api/multi-experiment-info",
                                 Dict("experiments" => ["DOES_NOT_EXIST_XYZ"]))
        @test status == 200
        @test isempty(body[:wells])
    end

    @testset "POST /api/plot-data — single channel" begin
        sel = [Dict("experiment" => SINGLE_CH_EXP, "well" => SINGLE_CH_WELL, "channel" => 1)]
        status, body = post_json("/api/plot-data", Dict("well_selections" => sel))
        @test status == 200
        traces = body[:traces]
        @test length(traces) == 1
        t = first(traces)
        @test !isempty(t[:x]) && !isempty(t[:y])
        @test length(t[:x]) == length(t[:y])
        @test Int(t[:channel]) == 1
        @test haskey(t, :well_name)
    end

    @testset "POST /api/plot-data — multi channel" begin
        sel = [Dict("experiment" => MULTI_CH_EXP, "well" => MULTI_CH_WELLS[ch], "channel" => ch)
               for ch in 1:3]
        status, body = post_json("/api/plot-data", Dict("well_selections" => sel))
        @test status == 200
        traces = body[:traces]
        @test length(traces) == 3
        @test sort([Int(t[:channel]) for t in traces]) == [1, 2, 3]
        lengths = [length(t[:x]) for t in traces]
        @test all(==(first(lengths)), lengths)
    end

    @testset "POST /api/plot-data — blank well excluded" begin
        sel = [Dict("experiment" => MULTI_CH_EXP, "well" => "A8", "channel" => 1)]
        status, body = post_json("/api/plot-data", Dict("well_selections" => sel))
        @test status == 200
        @test isempty(body[:traces])
    end

    @testset "POST /api/blank-analysis" begin
        status, body = post_json("/api/blank-analysis",
                                 Dict("experiment" => SINGLE_CH_EXP, "well" => SINGLE_CH_WELL))
        @test status == 200
        @test haskey(body, :has_blank_wells) || haskey(body, :error)
    end

    @testset "GET /api/models" begin
        status, body = get_json("/api/models")
        @test status == 200
        @test body isa AbstractVector
        @test !isempty(body)
        m = first(body)
        @test haskey(m, :name)
        @test haskey(m, :param_names)
        @test m[:param_names] isa AbstractVector
        @test !isempty(m[:param_names])
        names_list = [string(m[:name]) for m in body]
        @test "aHPM"     in names_list
        @test "logistic" in names_list
        @test "gompertz" in names_list
        @test names_list == sort(names_list)
    end

    @testset "POST /api/fit-curve — default model (aHPM)" begin
        status, body = post_json("/api/fit-curve",
                                 Dict("experiment" => SINGLE_CH_EXP, "well" => SINGLE_CH_WELL))
        @test status == 200
        @test string(body[:model]) == "aHPM"
        @test haskey(body, :param_names)
        @test length(body[:param_names]) == length(body[:parameters])
    end

    @testset "POST /api/fit-curve — explicit model (logistic)" begin
        status, body = post_json("/api/fit-curve",
                                 Dict("experiment" => SINGLE_CH_EXP, "well" => SINGLE_CH_WELL,
                                      "model_name" => "logistic"))
        @test status == 200
        @test string(body[:model]) == "logistic"
        @test haskey(body, :param_names)
        @test length(body[:param_names]) == 2   # logistic has gr, N_max
        @test length(body[:parameters]) == 2
    end

    @testset "POST /api/fit-curve — unknown model returns 400" begin
        status, body = post_json("/api/fit-curve",
                                 Dict("experiment" => SINGLE_CH_EXP, "well" => SINGLE_CH_WELL,
                                      "model_name" => "not_a_real_model"))
        @test status == 400
        @test haskey(body, :error)
    end

    @testset "GET / serves HTML" begin
        r = HTTP.get("$BASE_URL/"; status_exception=false)
        @test r.status == 200
        body = String(r.body)
        @test occursin("<html", lowercase(body))
        # Must not reference CDN — Plotly is served locally
        @test !occursin("cdn.plot.ly", body)
        @test !occursin("cdn.jsdelivr", body)
        @test !occursin("unpkg.com", body)
        # Must reference the local vendor copy
        @test occursin("plotly", lowercase(body))
    end

    @testset "GET /static/vendor/plotly serves JS" begin
        r = HTTP.get("$BASE_URL/static/vendor/plotly-2.29.1.min.js"; status_exception=false)
        @test r.status == 200
        @test occursin("javascript", lowercase(string(HTTP.header(r, "Content-Type"))))
    end

    @testset "GET /static/js/app.js serves JS" begin
        r = HTTP.get("$BASE_URL/static/js/app.js"; status_exception=false)
        @test r.status == 200
        @test occursin("javascript", lowercase(string(HTTP.header(r, "Content-Type"))))
    end

    @testset "GET /static/js/state.js serves JS" begin
        r = HTTP.get("$BASE_URL/static/js/state.js"; status_exception=false)
        @test r.status == 200
    end

    @testset "GET /static/css/main.css serves CSS" begin
        r = HTTP.get("$BASE_URL/static/css/main.css"; status_exception=false)
        @test r.status == 200
        @test occursin("css", lowercase(string(HTTP.header(r, "Content-Type"))))
    end

    @testset "GET /static/nonexistent returns 404" begin
        r = HTTP.get("$BASE_URL/static/does_not_exist.js"; status_exception=false)
        @test r.status == 404
    end

end # @testset "web_server.jl API"
end # if server_available()
