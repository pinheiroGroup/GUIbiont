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
end

Base.@kwdef mutable struct BatchFitRequest
    experiment::String = ""
    model_name::String = "aHPM"
    model_names::Vector{String} = String[]
    blank_subtraction::Bool = false
    blank_method::String = "pointbypoint"
    calibration_file::String = ""
    wells::Vector{String} = String[]
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
end

Base.@kwdef mutable struct BlankAnalysisRequest
    experiment::String = ""
    well::String = ""
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
    tol::Float64 = 1e-6
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
    tol::Float64 = 1e-6
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
