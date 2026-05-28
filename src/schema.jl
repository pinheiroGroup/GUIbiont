using StructTypes

Base.@kwdef mutable struct MultiExperimentInfoRequest
    experiments::Vector{String} = String[]
end

Base.@kwdef mutable struct GlobalSearchRequest
    condition::String = ""
    antibiotic::String = ""
end

Base.@kwdef mutable struct CleanDataRequest
    experiment::String = ""
    well_count::Int = 48
end

Base.@kwdef mutable struct FitCurveRequest
    experiment::String = ""
    well::String = ""
    blank_subtraction::Bool = false
    blank_method::String = "pointbypoint"
    calibration_file::String = ""
    model_name::String = "aHPM"
    model_names::Vector{String} = String[]
    optimizer::String = "LN_BOBYQA"
    # Best-of-N: when either list is non-empty, the legacy `optimizer` field
    # is ignored. Each deterministic optimizer runs once; each stochastic
    # optimizer runs `stochastic_runs` times. Lowest RMSE wins.
    deterministic_optimizers::Vector{String} = String[]
    stochastic_optimizers::Vector{String}   = String[]
    stochastic_runs::Int                    = 3
    maxiters::Int = DEFAULT_FIT_MAXITERS
    abstol::Float64 = 1e-15
end

Base.@kwdef mutable struct BatchFitRequest
    experiment::String = ""
    model_name::String = "aHPM"
    model_names::Vector{String} = String[]
    blank_subtraction::Bool = false
    blank_method::String = "pointbypoint"
    calibration_file::String = ""
    wells::Vector{String} = String[]
    optimizer::String = "LN_BOBYQA"
    deterministic_optimizers::Vector{String} = String[]
    stochastic_optimizers::Vector{String}   = String[]
    stochastic_runs::Int                    = 3
    # Pre-screen: skip curves with amplitude (max-min OD) below this threshold.
    # Catches blanks/non-growers that can't be fit. Set to 0 to disable.
    skip_flat_threshold::Float64 = 0.05
    maxiters::Int = DEFAULT_FIT_MAXITERS
    abstol::Float64 = 1e-15
    # Optional log-linear μ_max companion fit. When `compute_loglin` is true,
    # every well also gets a sliding-window log-linear fit (slope of log OD vs
    # time in the auto-detected exponential window) reported alongside the
    # parametric model fit. Provides a physiology-bounded, model-free growth
    # rate that serves as a sanity check on parametric μ from aHPM/Baranyi etc.
    compute_loglin::Bool = false
    loglin_pt_avg::Int = 7
    loglin_pt_smoothing_derivative::Int = 7
    loglin_pt_min_size_of_win::Int = 7
    loglin_threshold_of_exp::Float64 = 0.9
end

Base.@kwdef mutable struct MLDownstreamRequest
    fit_csv::String = ""
    label_col::String = ""
    feature_matrix::String = ""
    params::Vector{String} = String[]
end

Base.@kwdef mutable struct WellSelection
    experiment::String = ""
    well::String = ""
    channel::Int = 1
end

Base.@kwdef mutable struct FitReplicateRequest
    well_selections::Vector{WellSelection} = WellSelection[]
    label::String = "replicate"
    experiment::String = "replicate"
    model_name::String = "aHPM"
    calibration_file::String = ""
    optimizer::String = "LN_BOBYQA"
    deterministic_optimizers::Vector{String} = String[]
    stochastic_optimizers::Vector{String}   = String[]
    stochastic_runs::Int                    = 3
    maxiters::Int = DEFAULT_FIT_MAXITERS
    abstol::Float64 = 1e-15
end

Base.@kwdef mutable struct BlankAnalysisRequest
    experiment::String = ""
    well::String = ""
end

Base.@kwdef mutable struct LogLinFitRequest
    experiment::String = ""
    well::String = ""
    blank_subtraction::Bool = false
    blank_method::String = "pointbypoint"
    type_of_smoothing::String = "rolling_avg"   # "NO" | "rolling_avg" | "lowess"
    pt_avg::Int = 7
    pt_smoothing_derivative::Int = 7
    pt_min_size_of_win::Int = 7
    type_of_win::String = "maximum"             # "maximum" | "global_thr" | "max_with_min_OD"
    threshold_of_exp::Float64 = 0.9
    start_exp_win_thr::Float64 = 0.05
    thr_lowess::Float64 = 0.05
end

# Batch log-linear fit: same machinery as /api/batch-fit but the per-well
# work is a sliding-window log-lin regression instead of an optimizer-based
# parametric fit. Use this when you only need μ_max and don't want to pay
# for aHPM/Baranyi/Gompertz/logistic optimisations on every curve.
Base.@kwdef mutable struct BatchLogLinFitRequest
    experiment::String = ""
    wells::Vector{String} = String[]
    blank_subtraction::Bool = false
    blank_method::String = "pointbypoint"
    type_of_smoothing::String = "rolling_avg"
    pt_avg::Int = 7
    pt_smoothing_derivative::Int = 7
    pt_min_size_of_win::Int = 7
    type_of_win::String = "maximum"
    threshold_of_exp::Float64 = 0.9
    start_exp_win_thr::Float64 = 0.05
    thr_lowess::Float64 = 0.05
    skip_flat_threshold::Float64 = 0.05
end

Base.@kwdef mutable struct PlotDataRequest
    well_selections::Vector{WellSelection} = WellSelection[]
    experiment::String = ""
    wells::Vector{String} = String[]
end

Base.@kwdef mutable struct ClusterRequest
    experiments::Vector{String} = String[]
    csv::String = ""
    csv_path::String = ""
    k::Int = 3
    normalize::Bool = false
    smooth_method::String = "lowess"
    lowess_frac::Float64 = 0.05
    gaussian_h_mult::Float64 = 2.0
    cluster_method::String = "kmeans"
    maxiter::Int = 100
    tol::Float64 = 1e-15
    dbscan_eps::Float64 = 1.0
    dbscan_min_pts::Int = 3
    hclust_linkage::String = "ward"
    subtract_blank::Bool = false
    blank_method::String = "pointbypoint"
    blank_range_thr::Float64 = 0.005
    blank_od_percentile::Float64 = 0.10
    interpolate::Bool = false
    interp_n::Int = 100
    interp_quantile_lo::Float64 = 0.05
    interp_quantile_hi::Float64 = 0.95
    prescreen_constant::Bool = false
    prescreen_tol_const::Float64 = 1.5
    trend_test_flat::Bool = false
    trend_p_thr::Float64 = 0.05
end

Base.@kwdef mutable struct ClusterSweepRequest
    experiments::Vector{String} = String[]
    csv::String = ""
    csv_path::String = ""
    k_max::Int = 10
    smooth_method::String = "lowess"
    lowess_frac::Float64 = 0.05
    gaussian_h_mult::Float64 = 2.0
    cluster_method::String = "kmeans"
    maxiter::Int = 100
    tol::Float64 = 1e-15
    hclust_linkage::String = "ward"
    interpolate::Bool = false
    interp_n::Int = 100
    interp_quantile_lo::Float64 = 0.05
    interp_quantile_hi::Float64 = 0.95
    prescreen_constant::Bool = false
    prescreen_tol_const::Float64 = 1.5
    trend_test_flat::Bool = false
    trend_p_thr::Float64 = 0.05
end

Base.@kwdef mutable struct BatchAverageRequest
    csv::String = ""
    csv_path::String = ""
    group_col::String = ""
end

Base.@kwdef mutable struct ClusterCompareRequest
    assignments1::Vector{Int} = Int[]
    assignments2::Vector{Int} = Int[]
end

# Register all structs with StructTypes for JSON deserialization + OpenAPI schema generation
StructTypes.StructType(::Type{MultiExperimentInfoRequest}) = StructTypes.Mutable()
StructTypes.StructType(::Type{GlobalSearchRequest}) = StructTypes.Mutable()
StructTypes.StructType(::Type{CleanDataRequest}) = StructTypes.Mutable()
StructTypes.StructType(::Type{FitCurveRequest}) = StructTypes.Mutable()
StructTypes.StructType(::Type{BatchFitRequest}) = StructTypes.Mutable()
StructTypes.StructType(::Type{MLDownstreamRequest}) = StructTypes.Mutable()
StructTypes.StructType(::Type{WellSelection}) = StructTypes.Mutable()
StructTypes.StructType(::Type{FitReplicateRequest}) = StructTypes.Mutable()
StructTypes.StructType(::Type{BlankAnalysisRequest}) = StructTypes.Mutable()
StructTypes.StructType(::Type{PlotDataRequest}) = StructTypes.Mutable()
StructTypes.StructType(::Type{ClusterRequest}) = StructTypes.Mutable()
StructTypes.StructType(::Type{ClusterSweepRequest}) = StructTypes.Mutable()
StructTypes.StructType(::Type{ClusterCompareRequest}) = StructTypes.Mutable()
StructTypes.StructType(::Type{BatchAverageRequest})   = StructTypes.Mutable()
StructTypes.StructType(::Type{LogLinFitRequest})      = StructTypes.Mutable()
StructTypes.StructType(::Type{BatchLogLinFitRequest}) = StructTypes.Mutable()
