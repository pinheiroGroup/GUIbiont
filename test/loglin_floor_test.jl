#!/usr/bin/env julia
# Standalone floor-consistency test for the log-linear paths in src/analysis.jl.
#
# Invariant under test: the log-linear companion computed inside
# fit_well_data(..., compute_loglin=true) must return exactly what the
# standalone fit_well_loglin route returns, because the exported
# guibiont_analysis.jl script reproduces the batch CSV's companion columns
# with a kinbiont_batch_loglin call that takes the standalone path.
#
# The two paths use different unblanked positive floors on purpose:
#   • parametric fitting  — 0.01, needed by the relative-error loss
#   • log-linear fitting  — 1e-4, enough to keep log(OD) finite
# The companion is a log-linear fit, so it must use the log-linear floor.
# Sharing the parametric od_for_fit silently diverged for any unblanked curve
# dipping below 0.01 (mu_max off by ~9%, lag by ~2.7x on the probe below).
#
# NOT included in test/runtests.jl: it pulls in Kinbiont and the full
# OptimizationBBO/OptimizationNLopt stack that the unit tests avoid. Run it
# after touching blank handling, floors, or either log-linear path:
#
#   julia --project=. test/loglin_floor_test.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Test, Statistics, CSV, DataFrames, Kinbiont, OptimizationNLopt
using OptimizationBBO: BBO_adaptive_de_rand_1_bin_radiuslimited

include(joinpath(@__DIR__, "..", "src", "data.jl"))
include(joinpath(@__DIR__, "..", "src", "analysis.jl"))

const LOGLIN_KEYS = ("gr_loglin", "gr_loglin_se", "gr_max_sliding",
                     "t_exp_start_loglin", "t_exp_end_loglin",
                     "doubling_time_loglin", "R_squared_loglin",
                     "lag_loglin", "N_max_emp")

@testset "log-linear floors" begin

    @testset "companion matches standalone — unblanked curve below the 0.01 floor" begin
        t  = collect(0.0:0.25:20.0)
        od = min.(0.004 .* exp.(0.35 .* t), 0.8)   # starts at 0.004
        @test minimum(od) < 0.01                   # the probe must exercise the floor

        standalone = fit_well_loglin(t, od, 0.0, "probe", "exp")
        companion  = fit_well_data(t, od, 0.0, "", "probe", "exp"; compute_loglin=true)

        for k in LOGLIN_KEYS
            @test haskey(standalone, k)
            @test haskey(companion, k)
            @test standalone[k] ≈ companion[k] atol=1e-12
        end
        @test standalone["loglin_converged"] == companion["loglin_converged"]
    end

    @testset "companion matches standalone — unblanked curve above the floor" begin
        t  = collect(0.0:0.25:20.0)
        od = min.(0.05 .* exp.(0.3 .* t), 1.2)

        standalone = fit_well_loglin(t, od, 0.0, "probe", "exp")
        companion  = fit_well_data(t, od, 0.0, "", "probe", "exp"; compute_loglin=true)

        for k in LOGLIN_KEYS
            @test standalone[k] ≈ companion[k] atol=1e-12
        end
    end

    @testset "companion matches standalone — blanked curve" begin
        t     = collect(0.0:0.25:20.0)
        blank = 0.05
        od    = min.(blank .+ 0.004 .* exp.(0.35 .* t), 0.9)

        standalone = fit_well_loglin(t, od, blank, "probe", "exp";
                                     subtract_blank=true, blank_method="shift")
        companion  = fit_well_data(t, od, blank, "", "probe", "exp";
                                   subtract_blank=true, blank_method="shift",
                                   compute_loglin=true)

        for k in LOGLIN_KEYS
            @test standalone[k] ≈ companion[k] atol=1e-12
        end
    end

    @testset "the two routes preprocess with different unblanked floors" begin
        t  = collect(0.0:0.25:20.0)
        od = min.(0.004 .* exp.(0.35 .* t), 0.8)

        parametric = _prepare_fit_curve(t, od, "probe"; unblanked_floor=0.01).od_for_fit
        loglin     = _prepare_fit_curve(t, od, "probe"; unblanked_floor=1e-4).od_for_fit

        @test minimum(parametric) >= 0.01 - 1e-12    # relative-error loss needs this
        @test minimum(loglin)     >= 1e-4 - 1e-12
        @test minimum(loglin)      < 0.01            # log-linear keeps the low-OD signal
    end

end
