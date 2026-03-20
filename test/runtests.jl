"""
Integration tests for web_server.jl endpoints.

Requires the server to be running. Set SERVER_URL env variable to override
the default (http://localhost:9090).

Usage:
    julia --project=. test/runtests.jl
"""

using Test
using HTTP
using JSON3

const BASE_URL = get(ENV, "SERVER_URL", "http://localhost:9090")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Fixtures — experiments that must exist in Clean_data
# ---------------------------------------------------------------------------
const SINGLE_CH_EXP  = "LG166"   # one channel
const SINGLE_CH_WELL = "A3"
const MULTI_CH_EXP   = "LG298"   # three channels
const MULTI_CH_WELLS = Dict(1 => "A1", 2 => "C1", 3 => "E1")

# ---------------------------------------------------------------------------
@testset "web_server.jl API" begin

    # -----------------------------------------------------------------------
    @testset "GET /api/experiments" begin
        status, body = get_json("/api/experiments")
        @test status == 200
        # Response is a plain JSON array of experiment name strings
        @test body isa AbstractVector
        @test !isempty(body)
        @test SINGLE_CH_EXP in body
        @test MULTI_CH_EXP  in body
    end

    # -----------------------------------------------------------------------
    @testset "POST /api/multi-experiment-info — single channel" begin
        status, body = post_json("/api/multi-experiment-info",
                                 Dict("experiments" => [SINGLE_CH_EXP]))
        @test status == 200
        @test haskey(body, :wells)
        wells = body[:wells]
        @test !isempty(wells)

        w = first(wells)
        @test haskey(w, :well_id)
        @test haskey(w, :well)
        @test haskey(w, :experiment)
        @test haskey(w, :channel)
        @test haskey(w, :condition)
        @test w[:experiment] == SINGLE_CH_EXP

        # Single-channel experiments use simple well_id (no ch prefix)
        @test !occursin("_ch", string(w[:well_id]))
    end

    @testset "POST /api/multi-experiment-info — multi channel" begin
        status, body = post_json("/api/multi-experiment-info",
                                 Dict("experiments" => [MULTI_CH_EXP]))
        @test status == 200
        wells = body[:wells]
        @test !isempty(wells)

        channels = sort(unique(Int(w[:channel]) for w in wells))
        @test channels == [1, 2, 3]

        # Multi-channel experiments encode channel in well_id
        @test any(occursin("_ch", string(w[:well_id])) for w in wells)

        # n_channels field must be present and correct
        @test all(Int(w[:n_channels]) == 3 for w in wells)
    end

    @testset "POST /api/multi-experiment-info — unknown experiment returns empty wells" begin
        status, body = post_json("/api/multi-experiment-info",
                                 Dict("experiments" => ["DOES_NOT_EXIST_XYZ"]))
        @test status == 200
        @test isempty(body[:wells])
    end

    # -----------------------------------------------------------------------
    @testset "POST /api/plot-data — single channel" begin
        sel = [Dict("experiment" => SINGLE_CH_EXP, "well" => SINGLE_CH_WELL, "channel" => 1)]
        status, body = post_json("/api/plot-data", Dict("well_selections" => sel))
        @test status == 200
        @test haskey(body, :traces)
        traces = body[:traces]
        @test length(traces) == 1

        t = first(traces)
        @test haskey(t, :x) && !isempty(t[:x])
        @test haskey(t, :y) && !isempty(t[:y])
        @test length(t[:x]) == length(t[:y])
        @test Int(t[:channel]) == 1
        @test haskey(t, :well_name)
        @test haskey(t, :condition)
    end

    @testset "POST /api/plot-data — multi channel returns one trace per channel" begin
        sel = [Dict("experiment" => MULTI_CH_EXP, "well" => MULTI_CH_WELLS[ch], "channel" => ch)
               for ch in 1:3]
        status, body = post_json("/api/plot-data", Dict("well_selections" => sel))
        @test status == 200
        traces = body[:traces]
        @test length(traces) == 3

        returned_channels = sort([Int(t[:channel]) for t in traces])
        @test returned_channels == [1, 2, 3]

        # All traces must have the same number of time points
        lengths = [length(t[:x]) for t in traces]
        @test all(==(first(lengths)), lengths)
    end

    @testset "POST /api/plot-data — blank well returns no trace" begin
        # A8 is a blank well in LG298 channel 1
        sel = [Dict("experiment" => MULTI_CH_EXP, "well" => "A8", "channel" => 1)]
        status, body = post_json("/api/plot-data", Dict("well_selections" => sel))
        @test status == 200
        @test isempty(body[:traces])
    end

    # -----------------------------------------------------------------------
    @testset "POST /api/blank-analysis" begin
        status, body = post_json("/api/blank-analysis",
                                 Dict("experiment" => SINGLE_CH_EXP, "well" => SINGLE_CH_WELL))
        @test status == 200
        # Response includes recommendation and blank well info
        @test haskey(body, :has_blank_wells) || haskey(body, :error)
    end

    # -----------------------------------------------------------------------
    @testset "GET / serves HTML" begin
        r = HTTP.get("$BASE_URL/"; status_exception=false)
        @test r.status == 200
        html = String(r.body)
        @test occursin("<html", lowercase(html))
    end

end
