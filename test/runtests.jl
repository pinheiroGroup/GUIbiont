using Test
using CSV
using DataFrames
using HTTP
using JSON3
using Statistics

# Load the functions under test. The cleaning code was split into per-vendor
# adapters under src/cleaning/; load the interface and the two adapters that
# the tests below exercise (Synergy + LabGuru annotation parser).
using Tables
include(joinpath(@__DIR__, "..", "src", "cleaning", "PlateReader.jl"))
include(joinpath(@__DIR__, "..", "src", "cleaning", "synergy.jl"))
include(joinpath(@__DIR__, "..", "src", "cleaning", "labguru.jl"))

# Load backend modules (data helpers + experiment store)
# These mirror the include order in web_server.jl, minus HTTP/Kinbiont deps.
const CLEAN_DATA_PATH = get(ENV, "CLEAN_DATA_PATH",
    joinpath(@__DIR__, "..", "Clean_data") * "/")
include(joinpath(@__DIR__, "..", "src", "data.jl"))
include(joinpath(@__DIR__, "..", "src", "experiment_store.jl"))

# Load clustering helpers (needs Statistics only — no Kinbiont/HTTP)
using Distributions: Normal, cdf
import Clustering
include(joinpath(@__DIR__, "..", "src", "clustering.jl"))

include("data_helpers_test.jl")
include("experiment_store_test.jl")
include("clustering_helpers_test.jl")
include("analysis_helpers_test.jl")

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

    if isdir(RAW_LG281)
        # Real LG281 data file uses semicolons
        @test detect_csv_separator(joinpath(RAW_LG281, "data.csv"))  == ';'
        @test detect_csv_separator(joinpath(RAW_LG281, "plate.csv")) == ';'
    else
        @info "Skipping LG281 real-data checks for detect_csv_separator — fixture not found at $RAW_LG281"
    end
end

# ---------------------------------------------------------------------------
# cleaning_data_synergy — run against LG281 and compare to golden output
# ---------------------------------------------------------------------------

if !isdir(RAW_LG281) || !isdir(GOLDEN_LG281)
    @info "Skipping cleaning_data_synergy tests — LG281 fixture not found (raw: $RAW_LG281, golden: $GOLDEN_LG281)"
else
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
end # isdir(RAW_LG281)

# ---------------------------------------------------------------------------
# read_labguru_annotation — run against LG281 and compare to golden output
# ---------------------------------------------------------------------------

if !isdir(RAW_LG281) || !isdir(GOLDEN_LG281)
    @info "Skipping read_labguru_annotation tests — LG281 fixture not found"
else
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
end # isdir(RAW_LG281)

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

function batch_fit_and_wait(req; timeout=120)
    status, body = post_json("/api/batch-fit", req)
    status == 200 || return status, body
    haskey(body, :job_id) || return status, body
    job_id = string(body[:job_id])
    deadline = time() + timeout
    while time() < deadline
        s, b = get_json("/api/batch-fit/progress/$job_id")
        s == 200 && string(get(b, :status, "")) == "done" && return s, b
        sleep(1)
    end
    error("batch-fit job $job_id did not complete within $(timeout)s")
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
        stats = body[:stats]
        @test length(stats) == 1
        s = first(stats)
        @test haskey(s, :specific_growth_rate)
        @test haskey(s, :saturation_od)
        @test haskey(s, :max_od)
        @test haskey(s, :final_od)
        @test Float64(s[:specific_growth_rate]) > 0.0
        @test Float64(s[:saturation_od]) > 0.0
        @test Float64(s[:max_od]) > 0.0
        @test Float64(s[:final_od]) > 0.0
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
        @test haskey(m, :model_type)
        @test m[:param_names] isa AbstractVector
        @test !isempty(m[:param_names])
        @test string(m[:model_type]) in ("ODE", "NL")
        names_list = [string(m[:name]) for m in body]
        @test "aHPM"     in names_list
        @test "logistic" in names_list
        @test "gompertz" in names_list
        @test names_list == sort(names_list)
        # Type classification sanity checks
        type_map = Dict(string(m[:name]) => string(m[:model_type]) for m in body)
        @test type_map["aHPM"]       == "ODE"
        @test type_map["logistic"]   == "ODE"
        @test type_map["NL_logistic"] == "NL"
        @test type_map["NL_Gompertz"] == "NL"
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
        @test haskey(body, :blank_timeseries)
        @test haskey(body, :blank_applied)
        @test body[:preprocessing][:smooth] == false
        @test body[:preprocessing][:cut_stationary_phase] == true
        @test Float64(body[:stationary_phase_start]) ≈ Float64(last(body[:fit_time]))
    end

    @testset "POST /api/fit-curve — preprocessing is optimizer-independent" begin
        status, body = post_json("/api/fit-curve",
                                 Dict("experiment" => SINGLE_CH_EXP, "well" => SINGLE_CH_WELL,
                                      "model_name" => "logistic", "optimizer" => "LN_COBYLA"))
        @test status == 200
        @test string(body[:optimizer_used]) == "LN_COBYLA"
        @test body[:preprocessing][:smooth] == false
        @test body[:preprocessing][:cut_stationary_phase] == true
        @test Float64(body[:stationary_phase_start]) ≈ Float64(last(body[:fit_time]))
    end

    @testset "POST /api/fit-curve — centered smoothing" begin
        status, body = post_json("/api/fit-curve",
                                 Dict("experiment" => SINGLE_CH_EXP, "well" => SINGLE_CH_WELL,
                                      "model_name" => "logistic", "smooth" => true,
                                      "smooth_window" => 3))
        @test status == 200
        @test body[:preprocessing][:smooth] == true
        @test string(body[:preprocessing][:smooth_method]) == "boxcar"
        @test Int(body[:preprocessing][:smooth_window]) == 3
        @test length(body[:smoothed_time]) == length(body[:experimental_time])
        @test length(body[:smoothed_od]) == length(body[:experimental_od])

        bad_status, _ = post_json("/api/fit-curve",
                                  Dict("experiment" => SINGLE_CH_EXP, "well" => SINGLE_CH_WELL,
                                       "smooth" => true, "smooth_window" => 4))
        @test bad_status == 400
    end

    @testset "POST /api/fit-curve — unknown model returns 400" begin
        status, body = post_json("/api/fit-curve",
                                 Dict("experiment" => SINGLE_CH_EXP, "well" => SINGLE_CH_WELL,
                                      "model_name" => "not_a_real_model"))
        @test status == 400
        @test haskey(body, :error)
    end

    @testset "POST /api/fit-curve — oversized maxiters is clamped" begin
        status, body = post_json("/api/fit-curve",
                                 Dict("experiment" => SINGLE_CH_EXP, "well" => SINGLE_CH_WELL,
                                      "model_name" => "logistic", "maxiters" => 999_999_999))
        # Server must accept the request (not reject it) and return a valid fit
        @test status == 200
        @test haskey(body, :parameters)
        @test !isempty(body[:parameters])
    end

    @testset "POST /api/fit-curve — initial_parameters returned in response" begin
        status, body = post_json("/api/fit-curve",
                                 Dict("experiment" => SINGLE_CH_EXP, "well" => SINGLE_CH_WELL,
                                      "model_name" => "logistic"))
        @test status == 200
        @test haskey(body, :initial_parameters)
        ip = body[:initial_parameters]
        @test ip isa AbstractVector
        @test length(ip) == 1           # one model
        @test length(ip[1]) == 2        # logistic has 2 params (gr, N_max)
        @test all(isfinite, Float64.(ip[1]))
    end

    @testset "POST /api/fit-curve — RE and RMSE losses are both reported" begin
        # PR #56 introduced loss_re (Kinbiont's relative-error loss) and
        # loss_rmse (separate scoring metric) alongside the legacy loss key.
        # loss must continue to alias loss_rmse for backward compatibility.
        status, body = post_json("/api/fit-curve",
                                 Dict("experiment" => SINGLE_CH_EXP, "well" => SINGLE_CH_WELL,
                                      "model_name" => "logistic"))
        @test status == 200
        @test haskey(body, :loss)
        @test haskey(body, :loss_rmse)
        @test haskey(body, :loss_re)
        @test isfinite(Float64(body[:loss]))
        @test isfinite(Float64(body[:loss_rmse]))
        @test isfinite(Float64(body[:loss_re]))
        # The public "loss" key must remain equal to the RMSE for downstream consumers
        @test Float64(body[:loss]) ≈ Float64(body[:loss_rmse])
        # Per-attempt diagnostics carry the same triple
        @test haskey(body, :all_attempts)
        @test !isempty(body[:all_attempts])
        att = first(body[:all_attempts])
        @test haskey(att, :loss_rmse)
        @test haskey(att, :loss_re)
    end

    @testset "POST /api/batch-fit — explicit model" begin
        status, body = batch_fit_and_wait(
                           Dict("experiment" => SINGLE_CH_EXP,
                                "wells"      => [SINGLE_CH_WELL, "A4"],
                                "model_name" => "logistic"))
        @test status == 200
        @test haskey(body, :results)
        @test haskey(body, :summary)
        @test Int(body[:summary][:total]) == 2
        @test Int(body[:summary][:success]) >= 1
        r = first(body[:results])
        @test haskey(r, :well)
        @test haskey(r, :parameters)
        @test haskey(r, :param_names)
        @test haskey(r, :model)
        @test haskey(r, :stationary_phase_start)
        @test string(r[:model]) == "logistic"
    end

    @testset "POST /api/batch-fit — centered smoothing" begin
        status, body = batch_fit_and_wait(
                           Dict("experiment" => SINGLE_CH_EXP,
                                "wells" => [SINGLE_CH_WELL],
                                "model_name" => "logistic",
                                "smooth" => true,
                                "smooth_window" => 3))
        @test status == 200
        @test Int(body[:summary][:success]) == 1
        r = only(body[:results])
        @test r[:preprocessing][:smooth] == true
        @test string(r[:preprocessing][:smooth_method]) == "boxcar"
        @test Int(r[:preprocessing][:smooth_window]) == 3
        @test length(r[:smoothed_time]) == length(r[:experimental_time])
    end

    @testset "POST /api/batch-fit — all wells (no wells key)" begin
        status, body = batch_fit_and_wait(
                           Dict("experiment" => SINGLE_CH_EXP,
                                "model_name" => "logistic"))
        @test status == 200
        @test Int(body[:summary][:total]) > 2
        @test Int(body[:summary][:success]) >= 1
    end

    @testset "POST /api/batch-fit — multi-model AICc selection" begin
        status, body = batch_fit_and_wait(
                           Dict("experiment"  => SINGLE_CH_EXP,
                                "wells"       => [SINGLE_CH_WELL],
                                "model_names" => ["logistic", "gompertz"]))
        @test status == 200
        @test Int(body[:summary][:success]) >= 1
        r = first(body[:results])
        @test string(r[:model]) in ["logistic", "gompertz"]
        @test haskey(r, :aic)
        @test string(body[:model]) == "multi"
    end

    @testset "POST /api/batch-fit — per-row results carry loss_re and loss_rmse" begin
        status, body = batch_fit_and_wait(
                           Dict("experiment" => SINGLE_CH_EXP,
                                "wells"      => [SINGLE_CH_WELL, "A4"],
                                "model_name" => "logistic"))
        @test status == 200
        successes = filter(r -> haskey(r, :parameters), body[:results])
        @test !isempty(successes)
        r = first(successes)
        @test haskey(r, :loss)
        @test haskey(r, :loss_rmse)
        @test haskey(r, :loss_re)
        @test isfinite(Float64(r[:loss]))
        @test isfinite(Float64(r[:loss_rmse]))
        @test isfinite(Float64(r[:loss_re]))
        @test Float64(r[:loss]) ≈ Float64(r[:loss_rmse])
    end

    @testset "POST /api/batch-fit — unknown model returns 400" begin
        status, body = post_json("/api/batch-fit",
                                 Dict("experiment" => SINGLE_CH_EXP,
                                      "model_name" => "not_a_real_model"))
        @test status == 400
        @test haskey(body, :error)
    end

    @testset "POST /api/batch-fit — unknown experiment returns 404" begin
        status, body = post_json("/api/batch-fit",
                                 Dict("experiment" => "DOES_NOT_EXIST_XYZ"))
        @test status == 404
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

include("api_routes_test.jl")

end # if server_available()
