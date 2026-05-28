#!/usr/bin/env julia
# Standalone Kinbiont-comparison test for both new log-lin code paths in
# src/analysis.jl:
#   • fit_well_data(..., compute_loglin=true)  — companion alongside parametric
#   • fit_well_loglin(...)                      — pure log-lin (used by
#     /api/batch-fit-loglin)
#
# Verifies that gr_loglin / R² populated by each path matches a direct
# Kinbiont.fitting_one_well_Log_Lin call on the same input. This is a
# plumbing-only check — Kinbiont is the ground truth.
#
# This script is NOT included in test/runtests.jl because it pulls in
# Kinbiont (which loads the full OptimizationBBO/OptimizationNLopt stack
# the unit tests deliberately avoid). Run it manually after touching any
# of the log-lin paths:
#
#   julia --project=. test/batch_loglin_kinbiont_check.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using JSON3, CSV, DataFrames, Kinbiont

include(joinpath(@__DIR__, "..", "src", "data.jl"))
include(joinpath(@__DIR__, "..", "src", "clustering.jl"))
include(joinpath(@__DIR__, "..", "src", "analysis.jl"))

const ATLAS  = joinpath(@__DIR__, "..", "..", "ecoli-knockout-growth-atlas")
const CURVES = joinpath(ATLAS, "docs", "data", "curves_data.json")

# Parameters: keep identical to fit_well_data defaults so the comparison is
# a pure "plumbing" check rather than a comparison across preprocessing.
const KW = (
    type_of_smoothing       = "rolling_avg",
    pt_avg                  = 7,
    pt_smoothing_derivative = 7,
    pt_min_size_of_win      = 7,
    type_of_win             = "maximum",
    threshold_of_exp        = 0.9,
)

function ground_truth_log_lin(t::Vector{Float64}, od::Vector{Float64},
                              label::String, experiment::String;
                              floor::Float64 = 0.01)
    # Companion path uses parametric-fit floor (0.01).
    # Standalone fit_well_loglin uses log-lin floor (1e-4) — matches
    # /api/fit-loglin. Pass `floor` to get a comparable ground truth.
    od_for_fit = max.(od, floor)
    data_mat = Matrix(transpose(hcat(t, od_for_fit)))
    raw = Kinbiont.fitting_one_well_Log_Lin(
        data_mat, label, experiment;
        type_of_smoothing       = KW.type_of_smoothing,
        pt_avg                  = KW.pt_avg,
        pt_smoothing_derivative = KW.pt_smoothing_derivative,
        pt_min_size_of_win      = KW.pt_min_size_of_win,
        type_of_win             = KW.type_of_win,
        threshold_of_exp        = KW.threshold_of_exp,
    )
    params = raw[2]
    if length(params) < 14 || params[7] === missing
        return (gr=NaN, dt=NaN, r2=NaN, t0=NaN, t1=NaN, converged=false)
    end
    return (
        gr        = Float64(params[7]),
        dt        = Float64(params[9]),
        r2        = Float64(params[14])^2,
        t0        = Float64(params[3]),
        t1        = Float64(params[4]),
        converged = true,
    )
end

function main()
    @info "Loading $CURVES"
    d = open(CURVES) do io; JSON3.read(io); end
    times = Float64.(d["times"])

    test_cases = NamedTuple[]
    for g in d["genes"]
        gene = String(g["gene"])
        for med in ("LB", "M63")
            haskey(g, med) || continue
            mean_od = [x === nothing ? NaN : Float64(x) for x in g[med]["mean"]]
            mask = .!isnan.(mean_od)
            sum(mask) < 20 && continue
            push!(test_cases, (
                gene = gene, medium = med,
                times = times[mask], od = mean_od[mask],
            ))
            length(test_cases) >= 10 && break
        end
        length(test_cases) >= 10 && break
    end

    @info "Testing $(length(test_cases)) (gene, medium) pairs"
    println()
    println(rpad("gene", 8), rpad("med", 5),
            rpad("gr (GUIbiont)", 16), rpad("gr (Kinbiont)", 16),
            rpad("|Δgr|", 12), rpad("|ΔR²|", 12), "converged")
    println("─" ^ 80)

    max_dgr = 0.0
    max_dr2 = 0.0
    max_dgr_standalone = 0.0
    fails = 0
    for tc in test_cases
        # Companion path uses 0.01 floor (parametric); standalone uses 1e-4.
        gt           = ground_truth_log_lin(tc.times, tc.od, tc.gene,
                                            "keio_$(lowercase(tc.medium))";
                                            floor = 0.01)
        gt_standalone = ground_truth_log_lin(tc.times, tc.od, tc.gene,
                                             "keio_$(lowercase(tc.medium))";
                                             floor = 1e-4)
        # (i) Companion path inside fit_well_data (parametric + log-lin)
        r = fit_well_data(
            tc.times, tc.od,
            0.0, "NA", tc.gene, "keio_$(lowercase(tc.medium))";
            model_name      = "logistic",
            optimizer       = "LN_BOBYQA",
            maxiters        = 5000,
            compute_loglin  = true,
            loglin_pt_avg                  = KW.pt_avg,
            loglin_pt_smoothing_derivative = KW.pt_smoothing_derivative,
            loglin_pt_min_size_of_win      = KW.pt_min_size_of_win,
            loglin_threshold_of_exp        = KW.threshold_of_exp,
        )
        # (ii) Standalone log-lin path used by /api/batch-fit-loglin
        s = fit_well_loglin(
            tc.times, tc.od, 0.0,
            tc.gene, "keio_$(lowercase(tc.medium))";
            type_of_smoothing       = KW.type_of_smoothing,
            pt_avg                  = KW.pt_avg,
            pt_smoothing_derivative = KW.pt_smoothing_derivative,
            pt_min_size_of_win      = KW.pt_min_size_of_win,
            type_of_win             = KW.type_of_win,
            threshold_of_exp        = KW.threshold_of_exp,
        )
        gr   = get(r, "gr_loglin", NaN)
        r2   = get(r, "R_squared_loglin", NaN)
        conv = get(r, "loglin_converged", false)
        gr_s = get(s, "gr_loglin", NaN)

        dgr  = isfinite(gr)   && isfinite(gt.gr)            ? abs(gr   - gt.gr)            : NaN
        dr2  = isfinite(r2)   && isfinite(gt.r2)            ? abs(r2   - gt.r2)            : NaN
        dgs  = isfinite(gr_s) && isfinite(gt_standalone.gr) ? abs(gr_s - gt_standalone.gr) : NaN

        println(
            rpad(tc.gene, 8), rpad(tc.medium, 5),
            rpad(round(gr, digits=8), 16),
            rpad(round(gt.gr, digits=8), 16),
            rpad(round(dgr, digits=10), 12),
            rpad(round(dr2, digits=10), 12),
            conv,
        )
        if isfinite(dgr); max_dgr = max(max_dgr, dgr); end
        if isfinite(dr2); max_dr2 = max(max_dr2, dr2); end
        if isfinite(dgs); max_dgr_standalone = max(max_dgr_standalone, dgs); end
        if !(conv == gt.converged); fails += 1; end
    end
    @info "Max |Δgr| (companion vs Kinbiont): $max_dgr"
    @info "Max |Δgr| (fit_well_loglin vs Kinbiont, used by /api/batch-fit-loglin): $max_dgr_standalone"
    println("─" ^ 80)
    @info "Convergence mismatches = $fails"
    if max_dgr < 1e-9 && max_dr2 < 1e-9 && max_dgr_standalone < 1e-9 && fails == 0
        @info "✅ PASS — both GUIbiont log-lin paths match direct Kinbiont call"
    else
        @warn "❌ FAIL — values diverge from direct Kinbiont call"
        exit(1)
    end
end

main()
