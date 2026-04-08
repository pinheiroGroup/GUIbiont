using StructTypes

Base.@kwdef struct MultiExperimentInfoRequest
    experiments::Vector{String}
end

Base.@kwdef struct GlobalSearchRequest
    condition::String = ""
    antibiotic::String = ""
end

Base.@kwdef struct CleanDataRequest
    experiment::String
    well_count::Int = 48
end

Base.@kwdef struct FitCurveRequest
    experiment::String
    well::String
    blank_subtraction::Bool = false
    blank_method::String = "pointbypoint"
    calibration_file::String = ""
    model_name::String = "aHPM"
    model_names::Vector{String} = String[]
end

Base.@kwdef struct BatchFitRequest
    experiment::String
    model_name::String = "aHPM"
    model_names::Vector{String} = String[]
    blank_subtraction::Bool = false
    blank_method::String = "pointbypoint"
    calibration_file::String = ""
    wells::Vector{String} = String[]
end

Base.@kwdef struct MLDownstreamRequest
    fit_csv::String
    label_col::String
    feature_matrix::String
    params::Vector{String}
end

Base.@kwdef struct WellSelection
    experiment::String
    well::String
    channel::Int = 1
end

Base.@kwdef struct FitReplicateRequest
    well_selections::Vector{WellSelection}
    label::String = "replicate"
    experiment::String = "replicate"
    model_name::String = "aHPM"
    calibration_file::String = ""
end

Base.@kwdef struct BlankAnalysisRequest
    experiment::String
    well::String
end

Base.@kwdef struct PlotDataRequest
    well_selections::Vector{WellSelection} = WellSelection[]
    experiment::String = ""
    wells::Vector{String} = String[]
end

Base.@kwdef struct ClusterRequest
    experiments::Vector{String} = String[]
    csv::String = ""
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
end

Base.@kwdef struct ClusterSweepRequest
    experiments::Vector{String} = String[]
    csv::String = ""
    k_max::Int = 10
    smooth_method::String = "lowess"
    lowess_frac::Float64 = 0.05
    gaussian_h_mult::Float64 = 2.0
    cluster_method::String = "kmeans"
    maxiter::Int = 100
    tol::Float64 = 1e-6
    hclust_linkage::String = "ward"
end

Base.@kwdef struct ClusterCompareRequest
    assignments1::Vector{Int}
    assignments2::Vector{Int}
end

# Register all structs with StructTypes for JSON deserialization + OpenAPI schema generation
StructTypes.StructType(::Type{MultiExperimentInfoRequest}) = StructTypes.Struct()
StructTypes.StructType(::Type{GlobalSearchRequest}) = StructTypes.Struct()
StructTypes.StructType(::Type{CleanDataRequest}) = StructTypes.Struct()
StructTypes.StructType(::Type{FitCurveRequest}) = StructTypes.Struct()
StructTypes.StructType(::Type{BatchFitRequest}) = StructTypes.Struct()
StructTypes.StructType(::Type{MLDownstreamRequest}) = StructTypes.Struct()
StructTypes.StructType(::Type{WellSelection}) = StructTypes.Struct()
StructTypes.StructType(::Type{FitReplicateRequest}) = StructTypes.Struct()
StructTypes.StructType(::Type{BlankAnalysisRequest}) = StructTypes.Struct()
StructTypes.StructType(::Type{PlotDataRequest}) = StructTypes.Struct()
StructTypes.StructType(::Type{ClusterRequest}) = StructTypes.Struct()
StructTypes.StructType(::Type{ClusterSweepRequest}) = StructTypes.Struct()
StructTypes.StructType(::Type{ClusterCompareRequest}) = StructTypes.Struct()
