using HTTP, JSON3, CSV, DataFrames, Statistics
using Kinbiont
using Distributions: Normal, cdf
import Clustering

# Pairwise Euclidean distance matrix (n × n) for a matrix with rows = observations.
function _pairwise_euclidean(X::Matrix{Float64})::Matrix{Float64}
    n = size(X, 1)
    D = Matrix{Float64}(undef, n, n)
    for i in 1:n, j in 1:n
        D[i, j] = sqrt(sum((X[i, k] - X[j, k])^2 for k in axes(X, 2)))
    end
    return D
end

# Z-score each row (curve) across time; constant rows become all-zeros.
function _zscore_rows(m::Matrix{Float64})::Matrix{Float64}
    out = similar(m)
    for i in axes(m, 1)
        row = m[i, :]
        s   = std(row)
        out[i, :] = s < 1e-12 ? zeros(length(row)) : (row .- mean(row)) ./ s
    end
    return out
end

# Compute cluster centroids (k × n_features) from assignments (1-based, no zeros).
function _cluster_centroids(X::Matrix{Float64}, ids::Vector{Int})::Matrix{Float64}
    k     = maximum(ids)
    nfeat = size(X, 2)
    C     = zeros(Float64, k, nfeat)
    for c in 1:k
        mask = ids .== c
        any(mask) && (C[c, :] = mean(X[mask, :], dims=1))
    end
    return C
end

# Auto-detect blank curve indices from a curves matrix (rows = series, cols = time).
# Returns indices of rows that are flat AND have low mean OD.
# A curve is considered flat if EITHER:
#   - slope t-test p >= flat_p_thr (statistically no trend), OR
#   - OD range (max-min) < flat_range_thr (instrument noise only — robust against
#     high n making the t-test reject even negligible slopes)
function _detect_blank_indices(
    curves::Matrix{Float64},
    times::Vector{Float64};
    flat_p_thr::Float64     = 0.05,
    flat_range_thr::Float64 = 0.005,
    od_percentile::Float64  = 0.10,
)::Vector{Int}
    n = length(times)
    n < 3 && return Int[]

    t_c = times .- mean(times)

    mean_ods   = Float64[]
    flat_flags = Bool[]

    for i in axes(curves, 1)
        y = curves[i, :]
        finite_mask = isfinite.(y)
        nf = sum(finite_mask)
        if nf < 3
            push!(mean_ods, NaN); push!(flat_flags, false); continue
        end
        yf  = y[finite_mask]
        tcf = t_c[finite_mask]
        push!(mean_ods, mean(yf))

        # Range-based flatness: always passes if OD barely changes
        od_range = maximum(yf) - minimum(yf)
        if od_range < flat_range_thr
            push!(flat_flags, true); continue
        end

        sst2 = sum(tcf .^ 2)
        if sst2 < 1e-12
            push!(flat_flags, true); continue
        end
        slope  = sum(tcf .* yf) / sst2
        yhat   = mean(yf) .+ slope .* tcf
        s2     = sum((yf .- yhat) .^ 2) / (nf - 2)
        se     = sqrt(max(s2, 0.0) / sst2)
        t_stat = se < 1e-12 ? Inf : abs(slope / se)
        p = 2 * (1 - cdf(Normal(), t_stat))
        push!(flat_flags, p >= flat_p_thr)
    end

    finite_means = filter(isfinite, mean_ods)
    isempty(finite_means) && return Int[]
    od_thr = quantile(finite_means, od_percentile)

    return [i for i in axes(curves, 1)
            if flat_flags[i] && isfinite(mean_ods[i]) && mean_ods[i] <= od_thr]
end

# Apply blank subtraction to a curves matrix using the given blank timeseries.
# method: "pointbypoint" | "shift" | "clip"
function _apply_blank_subtraction_matrix(
    curves::Matrix{Float64},
    blank_ts::Vector{Float64},
    method::String,
)::Matrix{Float64}
    out = copy(curves)
    n_tp = size(curves, 2)
    ts   = blank_ts[1:n_tp]   # guard against length mismatch

    if method == "pointbypoint"
        for i in axes(out, 1)
            out[i, :] = out[i, :] .- ts
        end
    elseif method == "shift"
        blank_mean = mean(filter(isfinite, ts))
        for i in axes(out, 1)
            corrected = out[i, :] .- blank_mean
            shift = min(0.0, minimum(filter(isfinite, corrected)))
            out[i, :] = corrected .- shift
        end
    else  # clip
        blank_mean = mean(filter(isfinite, ts))
        for i in axes(out, 1)
            out[i, :] = max.(out[i, :] .- blank_mean, 0.0)
        end
    end
    return out
end

# Auto-detect likely blank wells when no annotation is available.
# A well is a blank candidate if:
#   1. Its growth curve is statistically flat (slope t-test p >= flat_p_thr), AND
#   2. Its mean OD is in the bottom `od_percentile` fraction of all wells.
# Returns a sorted Vector{String} of candidate well names.
function _detect_blank_wells(
    growth_data::DataFrame;
    flat_p_thr::Float64     = 0.05,
    flat_range_thr::Float64 = 0.005,
    od_percentile::Float64  = 0.10,
)::Vector{String}
    time_col = names(growth_data)[1]
    well_cols = names(growth_data)[2:end]

    times = try Float64.(growth_data[!, time_col])
            catch _ Float64.(1:nrow(growth_data)) end

    n   = length(times)
    n < 3 && return String[]

    t_c  = times .- mean(times)
    ss_t = sum(t_c .^ 2)

    mean_ods   = Float64[]
    flat_flags = Bool[]

    for w in well_cols
        od = Float64[]
        for v in growth_data[!, w]
            try push!(od, parse(Float64, string(v))) catch _ push!(od, NaN) end
        end
        finite_mask = isfinite.(od)
        nf = sum(finite_mask)
        if nf < 3
            push!(mean_ods, NaN); push!(flat_flags, false); continue
        end
        y  = od[finite_mask]
        tc = t_c[finite_mask]
        sst2 = sum(tc .^ 2)
        push!(mean_ods, mean(y))

        # Range-based flatness check first
        od_range = maximum(y) - minimum(y)
        if od_range < flat_range_thr
            push!(flat_flags, true); continue
        end

        if sst2 < 1e-12
            push!(flat_flags, true); continue
        end
        slope     = sum(tc .* y) / sst2
        y_hat     = mean(y) .+ slope .* tc
        residuals = y .- y_hat
        s2        = sum(residuals .^ 2) / (nf - 2)
        se        = sqrt(max(s2, 0.0) / sst2)
        t_stat    = se < 1e-12 ? Inf : abs(slope / se)
        p = 2 * (1 - cdf(Normal(), t_stat))
        push!(flat_flags, p >= flat_p_thr)
    end

    # OD threshold: bottom od_percentile of finite mean ODs
    finite_means = filter(isfinite, mean_ods)
    isempty(finite_means) && return String[]
    od_thr = quantile(finite_means, od_percentile)

    candidates = String[]
    for (i, w) in enumerate(well_cols)
        if flat_flags[i] && isfinite(mean_ods[i]) && mean_ods[i] <= od_thr
            push!(candidates, w)
        end
    end
    return sort(candidates)
end

# Remap arbitrary integer labels to 1..k preserving order.
function _remap_ids(ids::Vector{Int})::Tuple{Vector{Int}, Vector{Int}}
    uniq  = sort(unique(ids))
    imap  = Dict(v => i for (i, v) in enumerate(uniq))
    return [imap[id] for id in ids], uniq
end

# Compute all quality indices for a single clustering.
# X: n_samples × n_features (z-scored), ids: 1-based (no zeros/noise).
# Returns a Dict with all supported indices; missing ones are stored as `nothing`.
function _cluster_quality_indices(X::Matrix{Float64}, ids::Vector{Int})::Dict{String,Any}
    q = Dict{String,Any}()
    n = length(ids)
    n_clusters = length(unique(ids))

    if n_clusters < 2 || n < 3
        for key in ("silhouette_mean","dunn","davies_bouldin","calinski_harabasz","xie_beni","silhouettes")
            q[key] = nothing
        end
        return q
    end

    dmat = _pairwise_euclidean(X)

    # Silhouettes
    sil_vals = try
        Clustering.silhouettes(ids, dmat)
    catch _
        nothing
    end
    q["silhouettes"]      = sil_vals === nothing ? nothing : collect(Float64, sil_vals)
    q["silhouette_mean"]  = sil_vals === nothing ? nothing : mean(sil_vals)

    # Dunn (no centers needed)
    q["dunn"] = try
        Float64(Clustering.clustering_quality(X', ids; quality_index = :dunn))
    catch _
        nothing
    end

    # Indices that need cluster centers
    centers = _cluster_centroids(X, ids)   # k × n_features
    centers_T = centers'                   # n_features × k (needed by clustering_quality)

    q["davies_bouldin"] = try
        Float64(Clustering.clustering_quality(X', centers_T, ids; quality_index = :davies_bouldin))
    catch _
        nothing
    end

    q["calinski_harabasz"] = try
        Float64(Clustering.clustering_quality(X', centers_T, ids; quality_index = :calinski_harabasz))
    catch _
        nothing
    end

    q["xie_beni"] = try
        Float64(Clustering.clustering_quality(X', centers_T, ids; quality_index = :xie_beni))
    catch _
        nothing
    end

    return q
end

# Compute pairwise comparison metrics between two clusterings.
function _cluster_comparison(ids1::Vector{Int}, ids2::Vector{Int})::Dict{String,Any}
    ri = try
        r = Clustering.randindex(ids1, ids2)
        Dict("rand_index" => r[1], "adjusted_rand_index" => r[2],
             "mirkin_index" => r[3], "hubert_index" => r[4])
    catch _
        Dict("rand_index" => nothing, "adjusted_rand_index" => nothing,
             "mirkin_index" => nothing, "hubert_index" => nothing)
    end

    vi  = try Float64(Clustering.varinfo(ids1, ids2))   catch _ nothing end
    mi  = try Float64(Clustering.mutualinfo(ids1, ids2)) catch _ nothing end
    vm  = try Float64(Clustering.vmeasure(ids1, ids2))  catch _ nothing end
    # Serialize as array-of-rows so JSON consumers get a 2-D structure
    ct  = try
        m = Clustering.counts(ids1, ids2)
        [[m[i, j] for j in axes(m, 2)] for i in axes(m, 1)]
    catch _
        nothing
    end

    return merge(ri, Dict(
        "varinfo"     => vi,
        "mutualinfo"  => mi,
        "vmeasure"    => vm,
        "contingency" => ct,
    ))
end
include("function_clean_synergy.jl")

# Configuration - adjust paths for standalone deployment
const CLEAN_DATA_PATH = haskey(ENV, "CLEAN_DATA_PATH") ? ENV["CLEAN_DATA_PATH"] : "./Clean_data/"
const RAW_DATA_PATH = haskey(ENV, "RAW_DATA_PATH") ? ENV["RAW_DATA_PATH"] : "./raw_data/"
const PORT = haskey(ENV, "PORT") ? parse(Int, ENV["PORT"]) : 8080

# Find the annotation file for a given channel in an experiment directory.
# Priority: annotation_channel_N_*.csv  >  annotation_clean.csv (only when no
#           channel-specific files exist at all, i.e. single-channel experiment)
function find_annotation_file(exp_dir::String, channel::Int)::Union{String, Nothing}
    all_files = try readdir(exp_dir) catch; String[] end

    # Look for annotation_channel_N_*.csv for this specific channel
    prefix = "annotation_channel_$(channel)_"
    candidates = filter(f -> startswith(f, prefix) && endswith(f, ".csv"), all_files)
    isempty(candidates) || return joinpath(exp_dir, first(sort(candidates)))

    # Only fall back to annotation_clean.csv when the experiment has NO
    # channel-specific annotation files at all (single-channel experiment).
    has_any_channel_ann = any(f -> occursin(r"^annotation_channel_\d+_", f), all_files)
    if !has_any_channel_ann
        fallback = joinpath(exp_dir, "annotation_clean.csv")
        isfile(fallback) && return fallback
    end

    return nothing
end

# Read an annotation CSV with graceful handling of missing/inconsistent values
function read_annotation_file(annotation_file::String)::DataFrame
    annotations = try
        CSV.read(annotation_file, DataFrame, header=false, silencewarnings=true, stringtype=String)
    catch
        raw = CSV.File(annotation_file, header=false) |> DataFrame
        DataFrame([string.(col) for col in eachcol(raw)], :auto)
    end
    # Normalise missing/empty second column to "X" (excluded)
    for i in 1:nrow(annotations)
        if ncol(annotations) >= 2 && (ismissing(annotations[i, 2]) || annotations[i, 2] in ("", "missing"))
            annotations[i, 2] = "X"
        end
    end
    return annotations
end

function find_annotation_file(exp_dir::String, channel::Int)::Union{String, Nothing}
    all_files = try readdir(exp_dir) catch; String[] end

    # Look for annotation_channel_N_*.csv for this specific channel
    prefix = "annotation_channel_$(channel)_"
    candidates = filter(f -> startswith(f, prefix) && endswith(f, ".csv"), all_files)
    isempty(candidates) || return joinpath(exp_dir, first(sort(candidates)))

    # Only fall back to annotation_clean.csv when the experiment has NO
    # channel-specific annotation files at all (single-channel experiment).
    has_any_channel_ann = any(f -> occursin(r"^annotation_channel_\d+_", f), all_files)
    if !has_any_channel_ann
        fallback = joinpath(exp_dir, "annotation_clean.csv")
        isfile(fallback) && return fallback
    end

    return nothing
end

# Return the set of well names marked as blank ("b") or excluded ("X"/"x")
function get_blank_wells(annotations::DataFrame)
    blank_wells = Set{String}()
    for i in 1:nrow(annotations)
        if ncol(annotations) >= 2 && (annotations[i, 2] == "b" || annotations[i, 2] == "X" || annotations[i, 2] == "x")
            push!(blank_wells, string(annotations[i, 1]))
        end
    end
    return blank_wells
end

# Parse the first column of a growth data file into a Float64 time vector
function parse_time_column(growth_data::DataFrame)::Vector{Float64}
    time_raw = growth_data[!, names(growth_data)[1]]
    if eltype(time_raw) <: AbstractString
        try
            return [0.0; [parse(Float64, t) for t in time_raw[2:end]]]
        catch
            return Float64.(0:(nrow(growth_data)-1))
        end
    end
    return Float64.(time_raw)
end

# Parse an OD column into a Float64 vector, using NaN for non-numeric entries
function parse_od_column(growth_data::DataFrame, well_sym::Symbol)::Vector{Float64}
    od = Float64[]
    for val in growth_data[!, well_sym]
        try
            push!(od, parse(Float64, string(val)))
        catch
            push!(od, NaN)
        end
    end
    return od
end

# Return sorted list of well names marked as blank ("b") in the annotation file.
function get_blank_well_names(annotations::DataFrame)::Vector{String}
    names_out = String[]
    for i in 1:nrow(annotations)
        ncol(annotations) >= 2 || continue
        annotations[i, 2] == "b" || continue
        push!(names_out, string(annotations[i, 1]))
    end
    return sort(names_out)
end

# Compute the mean blank OD from wells marked as blank ("b") only.
# Excluded ("X") wells are intentionally omitted — they may have anomalous OD.
function compute_blank_value(growth_data::DataFrame, annotations::DataFrame)::Float64
    vals = Float64[]
    col_names = string.(names(growth_data))
    for i in 1:nrow(annotations)
        ncol(annotations) >= 2 || continue
        annotations[i, 2] == "b" || continue
        bw = string(annotations[i, 1])
        bw in col_names || continue
        for val in growth_data[!, Symbol(bw)]
            try push!(vals, parse(Float64, string(val))) catch _ end
        end
    end
    isempty(vals) && return 0.0
    return mean(filter(!isnan, vals))
end

# Compute the mean blank OD at each time point across all blank ("b") wells.
# Returns a vector of length nrow(growth_data). Used for point-by-point subtraction.
function compute_blank_timeseries(growth_data::DataFrame, annotations::DataFrame)::Vector{Float64}
    n = nrow(growth_data)
    col_names = string.(names(growth_data))
    columns = Vector{Float64}[]
    for i in 1:nrow(annotations)
        ncol(annotations) >= 2 || continue
        annotations[i, 2] == "b" || continue
        bw = string(annotations[i, 1])
        bw in col_names || continue
        col = Float64[]
        for val in growth_data[!, Symbol(bw)]
            try push!(col, parse(Float64, string(val))) catch _ push!(col, NaN) end
        end
        length(col) == n && push!(columns, col)
    end
    isempty(columns) && return zeros(Float64, n)
    # Mean across blank wells at each time point, ignoring NaN
    return [mean(filter(!isnan, [columns[j][t] for j in 1:length(columns)])) for t in 1:n]
end

# Overloads that take an explicit list of blank well names instead of an annotation DataFrame.
function compute_blank_value(growth_data::DataFrame, blank_wells::Vector{String})::Float64
    vals = Float64[]
    col_names = string.(names(growth_data))
    for bw in blank_wells
        bw in col_names || continue
        for val in growth_data[!, Symbol(bw)]
            try push!(vals, parse(Float64, string(val))) catch _ end
        end
    end
    isempty(vals) && return 0.0
    return mean(filter(!isnan, vals))
end

function compute_blank_timeseries(growth_data::DataFrame, blank_wells::Vector{String})::Vector{Float64}
    n = nrow(growth_data)
    col_names = string.(names(growth_data))
    columns = Vector{Float64}[]
    for bw in blank_wells
        bw in col_names || continue
        col = Float64[]
        for val in growth_data[!, Symbol(bw)]
            try push!(col, parse(Float64, string(val))) catch _ push!(col, NaN) end
        end
        length(col) == n && push!(columns, col)
    end
    isempty(columns) && return zeros(Float64, n)
    return [mean(filter(!isnan, [columns[j][t] for j in 1:length(columns)])) for t in 1:n]
end

# CORS headers for allowing frontend requests
function cors_headers()
    return [
        "Access-Control-Allow-Origin" => "*",
        "Access-Control-Allow-Methods" => "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers" => "Content-Type"
    ]
end

# Handle CORS preflight requests
function handle_cors(req)
    if HTTP.method(req) == "OPTIONS"
        return HTTP.Response(200, cors_headers())
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Shared growth curve fitting using the KinBiont.jl new API
# ---------------------------------------------------------------------------
# Accepts already-validated, NaN-filtered time and raw OD vectors plus the
# computed blank value. Returns a Dict ready to serialise as JSON.
function fit_well_data(
    time_numeric::Vector{Float64},
    od_raw::Vector{Float64},
    blank_value::Float64,
    calibration_file::String,
    label::String,
    experiment::String;
    subtract_blank::Bool = false,
    blank_method::String = "pointbypoint",  # "shift" | "pointbypoint" | "clip"
    blank_timeseries::Vector{Float64} = Float64[],
    blank_well_names::Vector{String} = String[],
)
    if subtract_blank && blank_value > 0.0
        if blank_method == "pointbypoint" && length(blank_timeseries) == length(od_raw)
            od_corrected = od_raw .- blank_timeseries
        else
            od_corrected = od_raw .- blank_value
        end
        od_subtracted_display = max.(od_corrected, 0.0)
        anchor = od_subtracted_display[1]

        if blank_method == "clip"
            # Clip negatives to a small positive floor — simple, no shift needed.
            od_for_fit = max.(od_corrected, 1e-4)
            shift = 0.0
        else
            # Shift the entire series up so the minimum is just above zero.
            # Preserves the growth curve shape; fit is shifted back after.
            shift = max(-minimum(od_corrected), 0.0) + 1e-4
            od_for_fit = od_corrected .+ shift
        end
    else
        od_subtracted_display = nothing
        od_for_fit = max.(od_raw, 0.01)
        anchor = od_raw[1]
        shift = 0.0
    end

    data = GrowthData(reshape(od_for_fit, 1, :), time_numeric, [label])

    p0 = [0.2, 0.2, 0.80, 1.0]
    spec = ModelSpec(
        [MODEL_REGISTRY["aHPM"]],
        [p0];
        lower = [[0.0, 0.0, 0.0, 0.0]],
        upper = [p0 .* 10],
    )

    opts = FitOptions(
        scattering_correction           = false,
        smooth                          = true,
        smooth_method                   = :rolling_avg,
        smooth_pt_avg                   = 14,
        cut_stationary_phase            = true,
        stationary_percentile_thr       = 0.05,
        stationary_pt_smooth_derivative = 10,
        stationary_win_size             = 5,
        loss                            = "RE",
    )

    fit_results = kinbiont_fit(data, spec, opts)
    r = fit_results[1]

    # If blank subtraction was applied, shift the fitted curve back to
    # blank-subtracted display space (undo the positive-shift applied for fitting).
    fit_od_curve = subtract_blank && blank_value > 0.0 ?
        r.fitted_curve .- shift :
        r.fitted_curve

    # The rolling-average smoother drops the first (pt_avg-1) time points, so
    # r.times[1] > time_numeric[1].  Prepend a flat segment anchored to the
    # first experimental OD so the fit line starts at the same time as the data.
    fit_start_idx = argmin(abs.(time_numeric .- r.times[1]))
    if fit_start_idx > 1
        pre_times    = time_numeric[1:fit_start_idx - 1]
        pre_fit_od   = fill(anchor, length(pre_times))
        fit_time_out = vcat(pre_times, r.times)
        fit_od_out   = vcat(pre_fit_od, fit_od_curve)
    else
        fit_time_out = r.times
        fit_od_out   = fit_od_curve
    end

    result = Dict{String, Any}(
        "experiment"             => experiment,
        "well"                   => label,
        "experimental_time"      => time_numeric,
        "experimental_od"        => od_raw,
        "fit_time"               => fit_time_out,
        "fit_od"                 => fit_od_out,
        "parameters"             => r.best_params,
        "model"                  => r.best_model.name,
        "blank_value"            => blank_value,
        "blank_subtraction"      => subtract_blank,
        "blank_method"           => blank_method,
        "blank_wells"            => blank_well_names,
        "stationary_phase_start" => r.times[end],
    )

    if od_subtracted_display !== nothing
        result["experimental_od_subtracted"] = od_subtracted_display
    end

    return result
end

# Get list of available experiments
function get_experiments()
    if !isdir(CLEAN_DATA_PATH)
        return String[]
    end
    
    experiments = filter(x -> isdir(joinpath(CLEAN_DATA_PATH, x)) && 
                             !startswith(x, "."), 
                        readdir(CLEAN_DATA_PATH))
    return sort(experiments)
end

# Get experiment metadata (wells, time points, etc.)
function get_experiment_info(experiment::String)
    data_file = joinpath(CLEAN_DATA_PATH, experiment, "data_channel_1.csv")
    annotation_file = joinpath(CLEAN_DATA_PATH, experiment, "annotation_clean.csv")
    
    if !isfile(data_file) || !isfile(annotation_file)
        return nothing
    end
    
    try
        growth_data = CSV.read(data_file, DataFrame, header=1)
        annotations = CSV.read(annotation_file, DataFrame, header=false)
        rename!(annotations, [:well, :condition])
        
        time_col = names(growth_data)[1]
        well_columns = names(growth_data)[2:end]
        
        # Create well info with conditions
        well_info = []
        for well in well_columns
            condition = "Unknown"
            well_annotation = filter(row -> row.well == well, annotations)
            if nrow(well_annotation) > 0
                condition = string(well_annotation[1, :condition])
            end
            push!(well_info, Dict("well" => well, "condition" => condition))
        end
        
        return Dict(
            "experiment" => experiment,
            "wells" => well_info,
            "time_points" => nrow(growth_data),
            "time_column" => time_col
        )
    catch e
        println("Error loading experiment $experiment: $e")
        return nothing
    end
end

# Get growth data for specific wells
function get_plot_data(experiment::String, wells::Vector{String})
    data_file = joinpath(CLEAN_DATA_PATH, experiment, "data_channel_1.csv")
    annotation_file = joinpath(CLEAN_DATA_PATH, experiment, "annotation_clean.csv")
    
    if !isfile(data_file) || !isfile(annotation_file)
        return nothing
    end
    
    try
        growth_data = CSV.read(data_file, DataFrame, header=1)
        annotations = CSV.read(annotation_file, DataFrame, header=false)
        rename!(annotations, [:well, :condition])
        
        time_col = names(growth_data)[1]
        time_data = growth_data[!, time_col]
        
        # Parse time data
        if eltype(time_data) <: AbstractString
            try
                time_numeric = [parse(Float64, t) for t in time_data[2:end]]
                time_numeric = [0.0; time_numeric]
            catch
                time_numeric = Float64.(0:(nrow(growth_data)-1))
            end
        else
            time_numeric = Float64.(time_data)
        end
        
        # Prepare data for each well
        traces = []
        stats = []
        
        for well in wells
            if well in names(growth_data)
                well_data = growth_data[!, well]
                
                # Convert to numeric
                od_data = Float64[]
                for val in well_data
                    try
                        push!(od_data, parse(Float64, string(val)))
                    catch
                        push!(od_data, NaN)
                    end
                end
                
                # Get condition
                well_annotation = filter(row -> row.well == well, annotations)
                condition = if nrow(well_annotation) > 0
                    string(well_annotation[1, :condition])
                else
                    "Unknown"
                end
                
                # Calculate statistics
                valid_od = filter(!isnan, od_data)
                max_od = isempty(valid_od) ? 0.0 : maximum(valid_od)
                final_od = isempty(valid_od) ? 0.0 : last(valid_od)
                
                # Calculate AUC using trapezoidal rule
                auc = 0.0
                valid_indices = findall(!isnan, od_data)
                if length(valid_indices) > 1
                    for i in 2:length(valid_indices)
                        dt = time_numeric[valid_indices[i]] - time_numeric[valid_indices[i-1]]
                        avg_od = (od_data[valid_indices[i]] + od_data[valid_indices[i-1]]) / 2
                        auc += dt * avg_od
                    end
                end
                
                push!(traces, Dict(
                    "well" => well,
                    "condition" => condition,
                    "x" => time_numeric,
                    "y" => od_data
                ))
                
                push!(stats, Dict(
                    "well" => well,
                    "condition" => condition,
                    "max_od" => round(max_od, digits=3),
                    "final_od" => round(final_od, digits=3),
                    "auc" => round(auc, digits=2)
                ))
            end
        end
        
        return Dict("traces" => traces, "stats" => stats)
    catch e
        println("Error getting plot data: $e")
        return nothing
    end
end

# API Routes
function router(req)
    # Handle CORS preflight
    cors_response = handle_cors(req)
    if cors_response !== nothing
        return cors_response
    end
    
    uri = HTTP.URI(req.target)
    path = uri.path
    
    headers = [
        "Access-Control-Allow-Origin" => "*",
        "Access-Control-Allow-Methods" => "GET, POST, OPTIONS", 
        "Access-Control-Allow-Headers" => "Content-Type",
        "Content-Type" => "application/json"
    ]
    
    try
        if path == "/api/config"
            # GET /api/config - Return server configuration
            config_path = joinpath(@__DIR__, "config.json")
            if isfile(config_path)
                config = JSON3.read(read(config_path, String))
                return HTTP.Response(200, headers, JSON3.write(config))
            else
                return HTTP.Response(200, headers, JSON3.write(Dict("enable_clean_data_tab" => true)))
            end

        elseif path == "/api/experiments"
            # GET /api/experiments - List all experiments
            experiments = get_experiments()
            return HTTP.Response(200, headers, JSON3.write(experiments))
            
        elseif startswith(path, "/api/experiment/") && endswith(path, "/info")
            # GET /api/experiment/{name}/info - Get experiment metadata
            path_parts = split(path, "/")
            println("Debug - path: $path, parts: $path_parts")
            if length(path_parts) >= 4
                experiment = path_parts[4]  # Extract experiment name
                println("Debug - experiment: $experiment")
                # Call function directly inline to avoid scoping issues
                data_file = joinpath(CLEAN_DATA_PATH, experiment, "data_channel_1.csv")
                annotation_file = joinpath(CLEAN_DATA_PATH, experiment, "annotation_clean.csv")
                
                if !isfile(data_file) || !isfile(annotation_file)
                    info = nothing
                else
                    try
                        # Read with more flexible options
                        println("Debug - Reading file: $data_file")
                        growth_data = CSV.read(data_file, DataFrame, header=1, silencewarnings=true)
                        println("Debug - Growth data loaded. Columns: $(ncol(growth_data)), Rows: $(nrow(growth_data))")
                        println("Debug - Column names: $(names(growth_data))")
                        
                        annotations = CSV.read(annotation_file, DataFrame, header=false, silencewarnings=true, stringtype=String)
                        println("Debug - Annotations loaded. Columns: $(ncol(annotations)), Rows: $(nrow(annotations))")
                        println("Debug - First few rows:")
                        for i in 1:min(3, nrow(annotations))
                            println("Debug - Row $i: $(annotations[i, :])")
                        end
                        
                        # Rename columns - 5th column (index 5) should be antibiotic
                        col_names = names(annotations)
                        new_names = Symbol[]
                        for i in 1:length(col_names)
                            if i == 1
                                push!(new_names, :well)
                            elseif i == 2
                                push!(new_names, :condition)
                            elseif i == 5
                                push!(new_names, :antibiotic)
                            else
                                push!(new_names, Symbol("col_$i"))
                            end
                        end
                        rename!(annotations, new_names)
                        println("Debug - Column names after renaming: $(names(annotations))")
                        
                        time_col = names(growth_data)[1]
                        all_well_columns = names(growth_data)[2:end]
                        
                        # Filter out blank wells based on annotation file (more precise than regex)
                        blank_wells = get_blank_wells(annotations)
                        well_columns = filter(well -> !(string(well) in blank_wells), all_well_columns)
                        println("Debug - All wells: $all_well_columns")
                        println("Debug - Filtered wells: $well_columns")
                        println("Debug - Filtered out: $(length(all_well_columns) - length(well_columns)) wells")
                        
                        # Create well info with conditions including columns 3, 4, and antibiotic
                        well_info = []
                        for well in well_columns
                            condition_parts = ["Unknown"]
                            antibiotic = "Unknown"
                            well_annotation = filter(row -> row.well == well, annotations)
                            if nrow(well_annotation) > 0
                                row = well_annotation[1, :]
                                condition_parts = [string(row.condition)]
                                
                                # Add columns 3 and 4 if they exist and have values
                                if "col_3" in names(annotations) && !ismissing(row.col_3) && string(row.col_3) != ""
                                    push!(condition_parts, string(row.col_3))
                                end
                                if "col_4" in names(annotations) && !ismissing(row.col_4) && string(row.col_4) != ""
                                    push!(condition_parts, string(row.col_4))
                                end
                                
                                # Add antibiotic from column 5
                                if "antibiotic" in names(annotations)
                                    antibiotic_value = row.antibiotic
                                    println("Debug - Well $well: antibiotic raw value = '$antibiotic_value', missing? $(ismissing(antibiotic_value))")
                                    if !ismissing(antibiotic_value) && string(antibiotic_value) != ""
                                        antibiotic = string(antibiotic_value)
                                        println("Debug - Well $well: antibiotic set to '$antibiotic'")
                                    else
                                        antibiotic = "None"
                                        println("Debug - Well $well: antibiotic set to 'None' (empty or missing)")
                                    end
                                else
                                    antibiotic = "None"
                                    println("Debug - Well $well: no antibiotic column found")
                                end
                            end
                            
                            condition = join(condition_parts, " | ")
                            push!(well_info, Dict("well" => well, "condition" => condition, "antibiotic" => antibiotic))
                            if antibiotic != "None"
                                println("Debug - Found well with antibiotic: $well -> $antibiotic")
                            end
                        end
                        
                        println("Debug - Total wells in result: $(length(well_info))")
                        antibiotic_wells = filter(w -> w["antibiotic"] != "None", well_info)
                        println("Debug - Wells with antibiotics: $(length(antibiotic_wells))")
                        for w in antibiotic_wells
                            println("Debug - Antibiotic well: $(w["well"]) -> $(w["antibiotic"])")
                        end
                        
                        info = Dict(
                            "experiment" => experiment,
                            "wells" => well_info,
                            "time_points" => nrow(growth_data),
                            "time_column" => time_col
                        )
                    catch e
                        println("Error loading experiment $experiment: $e")
                        info = nothing
                    end
                end
            else
                println("Error - Invalid path structure: $path")
                return HTTP.Response(400, headers, JSON3.write(Dict("error" => "Invalid path")))
            end
            if info !== nothing
                return HTTP.Response(200, headers, JSON3.write(info))
            else
                return HTTP.Response(404, headers, JSON3.write(Dict("error" => "Experiment not found")))
            end
            
        elseif path == "/api/multi-experiment-info" && HTTP.method(req) == "POST"
            # POST /api/multi-experiment-info - Get combined info for multiple experiments
            body = String(req.body)
            request_data = JSON3.read(body)
            experiments = request_data.experiments

            combined_wells = []
            combined_info = Dict("experiments" => experiments, "wells" => combined_wells)

            for experiment in experiments
                exp_dir = joinpath(CLEAN_DATA_PATH, experiment)

                # Discover all channel files (data_channel_1.csv, data_channel_2.csv, ...)
                channel_files = sort(filter(
                    f -> occursin(r"^data_channel_\d+\.csv$", basename(f)) && isfile(f),
                    [joinpath(exp_dir, "data_channel_$(ch).csv") for ch in 1:10]
                ))
                isempty(channel_files) && continue

                n_channels = length(channel_files)

                try
                    for (ch_idx, ch_file) in enumerate(channel_files)
                        ch_num = ch_idx   # 1-based channel number

                        # Per-channel annotation (annotation_channel_N_*.csv) with fallback
                        ann_file = find_annotation_file(exp_dir, ch_num)
                        ann_file === nothing && continue   # skip channel if no annotation at all

                        try
                            annotations = CSV.read(ann_file, DataFrame, header=false, silencewarnings=true, stringtype=String)
                            col_names = names(annotations)
                            new_names = Symbol[]
                            for i in 1:length(col_names)
                                if i == 1;     push!(new_names, :well)
                                elseif i == 2; push!(new_names, :condition)
                                elseif i == 5; push!(new_names, :antibiotic)
                                else;          push!(new_names, Symbol("col_$i"))
                                end
                            end
                            rename!(annotations, new_names)
                            blank_wells = get_blank_wells(annotations)

                            growth_data  = CSV.read(ch_file, DataFrame, header=1, silencewarnings=true)
                            well_columns = filter(well -> !(string(well) in blank_wells),
                                                  names(growth_data)[2:end])

                            for well in well_columns
                                condition_parts = ["Unknown"]
                                antibiotic = "Unknown"
                                well_annotation = filter(row -> row.well == well, annotations)
                                if nrow(well_annotation) > 0
                                    row = well_annotation[1, :]
                                    condition_parts = [string(row.condition)]
                                    if "col_3" in names(annotations) && !ismissing(row.col_3) && string(row.col_3) != ""
                                        push!(condition_parts, string(row.col_3))
                                    end
                                    if "col_4" in names(annotations) && !ismissing(row.col_4) && string(row.col_4) != ""
                                        push!(condition_parts, string(row.col_4))
                                    end
                                    if "antibiotic" in names(annotations) && !ismissing(row.antibiotic) && string(row.antibiotic) != ""
                                        antibiotic = string(row.antibiotic)
                                    else
                                        antibiotic = "None"
                                    end
                                end
                                condition = join(condition_parts, " | ")
                                # well_id encodes channel so same well from different channels
                                # can both be selected simultaneously
                                well_id = n_channels > 1 ?
                                    "$(experiment)_ch$(ch_num)_$(well)" :
                                    "$(experiment)_$(well)"

                                push!(combined_wells, Dict(
                                    "experiment"  => experiment,
                                    "well"        => well,
                                    "channel"     => ch_num,
                                    "n_channels"  => n_channels,
                                    "well_id"     => well_id,
                                    "condition"   => condition,
                                    "antibiotic"  => antibiotic,
                                    "display_name" => n_channels > 1 ?
                                        "$(experiment): $(well) Ch$(ch_num) ($(condition)) [$(antibiotic)]" :
                                        "$(experiment): $(well) ($(condition)) [$(antibiotic)]"
                                ))
                            end
                        catch e
                            println("Error loading channel $ch_num of $experiment: $e")
                        end
                    end
                catch e
                    println("Error loading experiment $experiment for multi-select: $e")
                end
            end

            return HTTP.Response(200, headers, JSON3.write(combined_info))
            
        elseif path == "/api/global-search" && HTTP.method(req) == "POST"
            # POST /api/global-search - Search across all experiments for conditions/antibiotics
            body = String(req.body)
            request_data = JSON3.read(body)
            
            condition_query = get(request_data, :condition, "")
            antibiotic_query = get(request_data, :antibiotic, "")
            
            search_results = []
            experiments = get_experiments()
            
            for experiment in experiments
                data_file = joinpath(CLEAN_DATA_PATH, experiment, "data_channel_1.csv")
                annotation_file = joinpath(CLEAN_DATA_PATH, experiment, "annotation_clean.csv")
                
                if isfile(data_file) && isfile(annotation_file)
                    try
                        growth_data = CSV.read(data_file, DataFrame, header=1, silencewarnings=true)
                        annotations = CSV.read(annotation_file, DataFrame, header=false, silencewarnings=true, stringtype=String)
                        
                        # Rename columns
                        col_names = names(annotations)
                        new_names = Symbol[]
                        for i in 1:length(col_names)
                            if i == 1
                                push!(new_names, :well)
                            elseif i == 2
                                push!(new_names, :condition)
                            elseif i == 5
                                push!(new_names, :antibiotic)
                            else
                                push!(new_names, Symbol("col_$i"))
                            end
                        end
                        rename!(annotations, new_names)
                        
                        # Filter valid wells
                        all_well_columns = names(growth_data)[2:end]
                        blank_wells = get_blank_wells(annotations)
                        well_columns = filter(well -> !(string(well) in blank_wells), all_well_columns)
                        
                        matching_wells = []
                        found_conditions = Set{String}()
                        found_antibiotics = Set{String}()
                        
                        for well in well_columns
                            well_annotation = filter(row -> row.well == well, annotations)
                            if nrow(well_annotation) > 0
                                row = well_annotation[1, :]
                                
                                # Build full condition string
                                condition_parts = [string(row.condition)]
                                if "col_3" in names(annotations) && !ismissing(row.col_3) && string(row.col_3) != ""
                                    push!(condition_parts, string(row.col_3))
                                end
                                if "col_4" in names(annotations) && !ismissing(row.col_4) && string(row.col_4) != ""
                                    push!(condition_parts, string(row.col_4))
                                end
                                full_condition = join(condition_parts, " | ")
                                
                                # Get antibiotic
                                antibiotic = "None"
                                if "antibiotic" in names(annotations) && !ismissing(row.antibiotic) && string(row.antibiotic) != ""
                                    antibiotic = string(row.antibiotic)
                                end
                                
                                # Check if matches search criteria
                                condition_match = isempty(condition_query) || occursin(lowercase(condition_query), lowercase(full_condition))
                                antibiotic_match = isempty(antibiotic_query) || occursin(lowercase(antibiotic_query), lowercase(antibiotic))
                                
                                if condition_match && antibiotic_match
                                    push!(matching_wells, well)
                                    push!(found_conditions, full_condition)
                                    push!(found_antibiotics, antibiotic)
                                end
                            end
                        end
                        
                        # Add to results if matches found
                        if !isempty(matching_wells)
                            push!(search_results, Dict(
                                "experiment" => experiment,
                                "matching_wells" => matching_wells,
                                "conditions" => collect(found_conditions),
                                "antibiotics" => collect(found_antibiotics)
                            ))
                        end
                        
                    catch e
                        println("Error searching experiment $experiment: $e")
                    end
                end
            end
            
            return HTTP.Response(200, headers, JSON3.write(search_results))
            
        elseif path == "/api/raw-experiments" && HTTP.method(req) == "GET"
            # GET /api/raw-experiments - List all raw experiments
            try
                if !isdir(RAW_DATA_PATH)
                    return HTTP.Response(200, headers, JSON3.write(String[]))
                end
                
                raw_experiments = filter(x -> isdir(joinpath(RAW_DATA_PATH, x)) && 
                                             !startswith(x, "."), 
                                        readdir(RAW_DATA_PATH))
                return HTTP.Response(200, headers, JSON3.write(sort(raw_experiments)))
            catch e
                println("Error listing raw experiments: ", e)
                return HTTP.Response(500, headers, JSON3.write(Dict("error" => "Failed to list raw experiments")))
            end
            
        elseif path == "/api/clean-data" && HTTP.method(req) == "POST"
            # POST /api/clean-data - Clean raw experiment data
            body = String(req.body)
            request_data = JSON3.read(body)
            
            experiment = request_data.experiment
            well_count = get(request_data, :well_count, 48)
            
            try
                # Validate inputs
                if isempty(experiment)
                    return HTTP.Response(400, headers, JSON3.write(Dict("error" => "Experiment name is required")))
                end
                
                if !(well_count in [6, 48, 96])
                    return HTTP.Response(400, headers, JSON3.write(Dict("error" => "Well count must be 6, 48, or 96")))
                end
                
                # Check if raw data exists
                raw_experiment_path = joinpath(RAW_DATA_PATH, experiment)
                data_file = joinpath(raw_experiment_path, "data.csv")
                plate_file = joinpath(raw_experiment_path, "plate.csv")
                
                if !isfile(data_file) || !isfile(plate_file)
                    return HTTP.Response(404, headers, JSON3.write(Dict("error" => "Required files (data.csv and plate.csv) not found in raw experiment folder")))
                end
                
                # Create output directory
                output_path = joinpath(CLEAN_DATA_PATH, experiment) * "/"
                
                # Load cleaning functions
                println("Starting data cleaning for experiment: $experiment")
                println("Input path: $raw_experiment_path")
                println("Output path: $output_path")
                
                # Clean the annotation file first
                read_labguru_annotation(plate_file, output_path, well_count)
                println("Annotation cleaning completed")
                
                # Clean the data file
                cleaning_data_synergy(data_file, output_path)
                println("Data cleaning completed")
                
                # Check what files were created
                created_files = []
                if isdir(output_path)
                    created_files = readdir(output_path)
                end
                
                response_data = Dict(
                    "success" => true,
                    "experiment" => experiment,
                    "output_path" => output_path,
                    "well_count" => well_count,
                    "created_files" => created_files,
                    "message" => "Data cleaning completed successfully"
                )
                
                return HTTP.Response(200, headers, JSON3.write(response_data))
                
            catch e
                println("Error cleaning data: ", e)
                return HTTP.Response(500, headers, JSON3.write(Dict("error" => "Data cleaning failed: $e")))
            end
            
        elseif path == "/api/fit-curve" && HTTP.method(req) == "POST"
            # POST /api/fit-curve - Fit growth curve for a single well
            body = String(req.body)
            request_data = JSON3.read(body)

            experiment      = string(request_data.experiment)
            well            = string(request_data.well)
            subtract_blank  = Bool(get(request_data, :blank_subtraction, false))
            blank_method    = string(get(request_data, :blank_method, "pointbypoint"))

            try
                data_file        = joinpath(CLEAN_DATA_PATH, experiment, "data_channel_1.csv")
                annotation_file  = joinpath(CLEAN_DATA_PATH, experiment, "annotation_clean.csv")
                calibration_file = "./cal_curve_avg.csv"

                if !isfile(data_file) || !isfile(annotation_file)
                    return HTTP.Response(404, headers, JSON3.write(Dict("error" => "Data files not found")))
                end

                growth_data      = CSV.read(data_file, DataFrame, header=1, silencewarnings=true)
                annotations      = read_annotation_file(annotation_file)
                excluded_wells   = get_blank_wells(annotations)   # "b" + "X"
                blank_well_names = get_blank_well_names(annotations)  # "b" only
                column_names_str = string.(names(growth_data))

                if !(well in column_names_str)
                    return HTTP.Response(404, headers, JSON3.write(Dict("error" => "Well '$well' not found")))
                end
                if well in excluded_wells
                    return HTTP.Response(400, headers, JSON3.write(Dict("error" => "Well '$well' is a blank well")))
                end

                time_numeric     = parse_time_column(growth_data)
                od_raw           = parse_od_column(growth_data, Symbol(well))
                blank_value      = compute_blank_value(growth_data, annotations)
                blank_timeseries = (subtract_blank && blank_method == "pointbypoint") ?
                    compute_blank_timeseries(growth_data, annotations) : Float64[]

                valid_indices = findall(.!isnan.(od_raw))
                if length(valid_indices) < 10
                    return HTTP.Response(400, headers, JSON3.write(Dict("error" => "Not enough valid data points for fitting")))
                end

                # Align blank timeseries to valid indices if computed
                blank_ts_valid = isempty(blank_timeseries) ? Float64[] : blank_timeseries[valid_indices]

                response_data = fit_well_data(
                    time_numeric[valid_indices], od_raw[valid_indices],
                    blank_value, calibration_file, well, experiment;
                    subtract_blank   = subtract_blank,
                    blank_method     = blank_method,
                    blank_timeseries = blank_ts_valid,
                    blank_well_names = blank_well_names,
                )
                return HTTP.Response(200, headers, JSON3.write(response_data))

            catch e
                println("Error in curve fitting: ", e)
                return HTTP.Response(500, headers, JSON3.write(Dict("error" => "Curve fitting failed: $e")))
            end
            
        elseif path == "/api/blank-analysis" && HTTP.method(req) == "POST"
            # POST /api/blank-analysis - Analyse a well's OD vs blank and recommend subtraction method
            body = String(req.body)
            request_data = JSON3.read(body)
            experiment = string(request_data.experiment)
            well       = string(request_data.well)

            try
                data_file       = joinpath(CLEAN_DATA_PATH, experiment, "data_channel_1.csv")
                annotation_file = joinpath(CLEAN_DATA_PATH, experiment, "annotation_clean.csv")

                if !isfile(data_file)
                    return HTTP.Response(404, headers, JSON3.write(Dict("error" => "Data file not found")))
                end

                growth_data      = CSV.read(data_file, DataFrame, header=1, silencewarnings=true)

                # Allow caller to supply blank wells directly (e.g. from auto-detection)
                override = get(request_data, :override_blank_wells, nothing)
                blank_well_names = if override !== nothing && length(override) > 0
                    String.(override)
                elseif isfile(annotation_file)
                    annotations = read_annotation_file(annotation_file)
                    get_blank_well_names(annotations)
                else
                    String[]
                end

                if isempty(blank_well_names)
                    range_thr  = Float64(get(request_data, :blank_range_thr, 0.005))
                    od_pct     = Float64(get(request_data, :blank_od_percentile, 0.10))
                    auto_wells = isfile(data_file) ? _detect_blank_wells(growth_data;
                        flat_range_thr = range_thr, od_percentile = od_pct) : String[]
                    return HTTP.Response(200, headers, JSON3.write(Dict(
                        "has_blank_wells"      => false,
                        "blank_wells"          => String[],
                        "blank_value"          => 0.0,
                        "recommendation"       => "none",
                        "auto_detected_wells"  => auto_wells,
                        "message"              => isempty(auto_wells)
                            ? "No blank wells found in annotation and none could be detected automatically."
                            : "No blank wells annotated. Auto-detected $(length(auto_wells)) candidate blank well(s) based on flat curve and low OD: $(join(auto_wells, ", ")).",
                    )))
                end

                od_raw           = parse_od_column(growth_data, Symbol(well))
                valid_od         = filter(!isnan, od_raw)
                blank_value      = compute_blank_value(growth_data, blank_well_names)
                blank_timeseries = compute_blank_timeseries(growth_data, blank_well_names)

                od_corrected_global  = valid_od .- blank_value
                od_corrected_pbp     = valid_od .- blank_timeseries[findall(.!isnan.(od_raw))]

                frac_below_global = count(od_corrected_global .< 0) / length(od_corrected_global)
                frac_below_pbp    = count(od_corrected_pbp    .< 0) / length(od_corrected_pbp)
                min_global        = minimum(od_corrected_global)
                min_pbp           = minimum(od_corrected_pbp)

                # Build per-method notes
                method_notes = Dict{String, Dict{String, String}}()

                # Point-by-point
                if frac_below_pbp < 0.05
                    method_notes["pointbypoint"] = Dict("status" => "good",
                        "note" => "$(round(Int, frac_below_pbp*100))% of points below blank after subtraction — works well.")
                elseif frac_below_pbp < 0.3
                    method_notes["pointbypoint"] = Dict("status" => "ok",
                        "note" => "$(round(Int, frac_below_pbp*100))% of points below blank — acceptable, negatives will be shown as zero.")
                else
                    method_notes["pointbypoint"] = Dict("status" => "warning",
                        "note" => "$(round(Int, frac_below_pbp*100))% of points below blank — well OD is near or below blank throughout. Results may have limited reliability.")
                end

                # Shift minimum
                if frac_below_global < 0.1 && min_global > -0.02
                    method_notes["shift"] = Dict("status" => "good",
                        "note" => "Only $(round(Int, frac_below_global*100))% of points below blank — shift is small and will not distort the fit.")
                elseif frac_below_global > 0.3 || min_global < -0.05
                    method_notes["shift"] = Dict("status" => "not_recommended",
                        "note" => "$(round(Int, frac_below_global*100))% of points below blank (min = $(round(min_global, digits=3))). Large shift will cause a visible discontinuity at the fit seam.")
                else
                    method_notes["shift"] = Dict("status" => "ok",
                        "note" => "$(round(Int, frac_below_global*100))% of points below blank — small shift, may produce minor artefact at fit start.")
                end

                # Clip
                if frac_below_global < 0.1
                    method_notes["clip"] = Dict("status" => "good",
                        "note" => "Few points below blank — clipping will have minimal effect on the fit.")
                elseif frac_below_global > 0.5
                    method_notes["clip"] = Dict("status" => "warning",
                        "note" => "$(round(Int, frac_below_global*100))% of points below blank — clipping to zero may distort the initial phase of the fit.")
                else
                    method_notes["clip"] = Dict("status" => "ok",
                        "note" => "$(round(Int, frac_below_global*100))% of points below blank — clipping will set early points to zero.")
                end

                # Overall recommendation
                recommendation = if frac_below_pbp < frac_below_global && frac_below_pbp < 0.3
                    "pointbypoint"
                elseif frac_below_global < 0.1 && min_global > -0.02
                    "shift"
                else
                    "pointbypoint"
                end

                return HTTP.Response(200, headers, JSON3.write(Dict(
                    "has_blank_wells"      => true,
                    "blank_wells"          => blank_well_names,
                    "blank_value"          => blank_value,
                    "frac_below_global"    => frac_below_global,
                    "frac_below_pbp"       => frac_below_pbp,
                    "min_corrected_global" => min_global,
                    "min_corrected_pbp"    => min_pbp,
                    "recommendation"       => recommendation,
                    "method_notes"         => method_notes,
                )))
            catch e
                println("Error in blank analysis: ", e)
                return HTTP.Response(500, headers, JSON3.write(Dict("error" => "Blank analysis failed: $e")))
            end

        elseif path == "/api/fit-replicate" && HTTP.method(req) == "POST"
            # POST /api/fit-replicate - Fit averaged replicate data
            body = String(req.body)
            request_data = JSON3.read(body)

            well_selections  = request_data.well_selections
            label            = string(get(request_data, :label, "replicate"))
            experiment_name  = string(get(request_data, :experiment, "replicate"))
            calibration_file = "./cal_curve_avg.csv"

            try
                all_od_data   = Vector{Vector{Float64}}()
                all_time_data = Vector{Vector{Float64}}()

                for sel in well_selections
                    exp     = string(sel.experiment)
                    well    = string(sel.well)
                    channel = Int(get(sel, :channel, 1))

                    data_file       = joinpath(CLEAN_DATA_PATH, exp, "data_channel_$(channel).csv")
                    annotation_file = find_annotation_file(joinpath(CLEAN_DATA_PATH, exp), channel)
                    isfile(data_file) && annotation_file !== nothing || continue

                    growth_data   = CSV.read(data_file, DataFrame, header=1, silencewarnings=true)
                    annotations   = read_annotation_file(annotation_file)
                    time_numeric  = parse_time_column(growth_data)
                    blank_value   = compute_blank_value(growth_data, annotations)
                    col_names_str = string.(names(growth_data))

                    well in col_names_str || continue
                    od = parse_od_column(growth_data, Symbol(well))
                    od = max.(od .- blank_value, 0.01)
                    push!(all_od_data, od)
                    push!(all_time_data, time_numeric)
                end

                if isempty(all_od_data)
                    return HTTP.Response(400, headers, JSON3.write(Dict("error" => "No valid well data found")))
                end

                # Average across wells (align by minimum length)
                min_len  = minimum(length.(all_od_data))
                avg_time = all_time_data[1][1:min_len]
                avg_od   = sum(od[1:min_len] for od in all_od_data) ./ length(all_od_data)

                valid_indices = findall(.!isnan.(avg_od))
                if length(valid_indices) < 10
                    return HTTP.Response(400, headers, JSON3.write(Dict("error" => "Not enough valid data points for fitting")))
                end

                response_data = fit_well_data(
                    avg_time[valid_indices], avg_od[valid_indices],
                    0.0, calibration_file, label, experiment_name,
                )
                return HTTP.Response(200, headers, JSON3.write(response_data))

            catch e
                println("Error in replicate fitting: ", e)
                return HTTP.Response(500, headers, JSON3.write(Dict("error" => "Replicate fitting failed: $e")))
            end

        elseif path == "/api/plot-data" && HTTP.method(req) == "POST"
            # POST /api/plot-data - Get plot data for specific wells (supports multi-experiment)
            body = String(req.body)
            request_data = JSON3.read(body)
            
            # Handle both single and multi-experiment requests
            if haskey(request_data, "well_selections")
                # Multi-experiment format: [{"experiment": "LG166", "well": "A1"}, ...]
                well_selections = request_data.well_selections
                traces = []
                stats = []
                
                for selection in well_selections
                    experiment = selection.experiment
                    well       = selection.well
                    channel    = Int(get(selection, :channel, 1))

                    data_file       = joinpath(CLEAN_DATA_PATH, experiment, "data_channel_$(channel).csv")
                    annotation_file = find_annotation_file(joinpath(CLEAN_DATA_PATH, experiment), channel)

                    if isfile(data_file) && annotation_file !== nothing
                        try
                            growth_data = CSV.read(data_file, DataFrame, header=1, silencewarnings=true)
                            annotations = CSV.read(annotation_file, DataFrame, header=false, silencewarnings=true, stringtype=String)
                            
                            # Rename columns
                            col_names = names(annotations)
                            new_names = [:well, :condition]
                            for i in 3:length(col_names)
                                if i == 5
                                    push!(new_names, :antibiotic)
                                else
                                    push!(new_names, Symbol(col_names[i]))
                                end
                            end
                            rename!(annotations, new_names)
                            
                            blank_wells = get_blank_wells(annotations)
                            if well in names(growth_data) && !(well in blank_wells)
                                # Process this well
                                time_col = names(growth_data)[1]
                                time_data = growth_data[!, time_col]
                                
                                # Parse time data
                                if eltype(time_data) <: AbstractString
                                    try
                                        time_numeric = [parse(Float64, t) for t in time_data[2:end]]
                                        time_numeric = [0.0; time_numeric]
                                    catch
                                        time_numeric = Float64.(0:(nrow(growth_data)-1))
                                    end
                                else
                                    time_numeric = Float64.(time_data)
                                end
                                
                                well_data = growth_data[!, well]
                                
                                # Convert to numeric
                                od_data = Float64[]
                                for val in well_data
                                    try
                                        push!(od_data, parse(Float64, string(val)))
                                    catch
                                        push!(od_data, NaN)
                                    end
                                end
                                
                                # Get condition including columns 3 and 4, and antibiotic
                                condition_parts = ["Unknown"]
                                antibiotic = "Unknown"
                                well_annotation = filter(row -> row.well == well, annotations)
                                if nrow(well_annotation) > 0
                                    row = well_annotation[1, :]
                                    condition_parts = [string(row.condition)]
                                    
                                    # Add columns 3 and 4 if they exist and have values
                                    col_names = names(annotations)
                                    if length(col_names) >= 3 && !ismissing(row[col_names[3]]) && string(row[col_names[3]]) != ""
                                        push!(condition_parts, string(row[col_names[3]]))
                                    end
                                    if length(col_names) >= 4 && !ismissing(row[col_names[4]]) && string(row[col_names[4]]) != ""
                                        push!(condition_parts, string(row[col_names[4]]))
                                    end
                                    
                                    # Add antibiotic from column 5 (only present in 7-column annotation_clean.csv)
                                    if "antibiotic" in names(annotations) && !ismissing(row.antibiotic) && string(row.antibiotic) != ""
                                        antibiotic = string(row.antibiotic)
                                    end
                                end

                                condition = join(condition_parts, " | ")

                                # Calculate statistics
                                valid_od = filter(!isnan, od_data)
                                max_od = isempty(valid_od) ? 0.0 : maximum(valid_od)
                                final_od = isempty(valid_od) ? 0.0 : last(valid_od)
                                
                                # Calculate AUC
                                auc = 0.0
                                valid_indices = findall(!isnan, od_data)
                                if length(valid_indices) > 1
                                    for i in 2:length(valid_indices)
                                        dt = time_numeric[valid_indices[i]] - time_numeric[valid_indices[i-1]]
                                        avg_od = (od_data[valid_indices[i]] + od_data[valid_indices[i-1]]) / 2
                                        auc += dt * avg_od
                                    end
                                end
                                
                                push!(traces, Dict(
                                    "well"      => "$(experiment)_$(well)",
                                    "well_name" => well,
                                    "experiment" => experiment,
                                    "channel"   => channel,
                                    "condition" => condition,
                                    "antibiotic" => antibiotic,
                                    "x" => time_numeric,
                                    "y" => od_data
                                ))
                                
                                push!(stats, Dict(
                                    "well" => "$(experiment)_$(well)",
                                    "experiment" => experiment,
                                    "condition" => condition,
                                    "antibiotic" => antibiotic,
                                    "max_od" => round(max_od, digits=3),
                                    "final_od" => round(final_od, digits=3),
                                    "auc" => round(auc, digits=2)
                                ))
                            end
                        catch e
                            println("Error processing $experiment/$well: $e")
                        end
                    end
                end
                
                plot_data = Dict("traces" => traces, "stats" => stats)
            else
                # Original single-experiment format
                experiment = request_data.experiment
                wells = request_data.wells
            
                # Inline plot data function to avoid scoping issues
            data_file = joinpath(CLEAN_DATA_PATH, experiment, "data_channel_1.csv")
            annotation_file = joinpath(CLEAN_DATA_PATH, experiment, "annotation_clean.csv")
            
            if !isfile(data_file) || !isfile(annotation_file)
                plot_data = nothing
            else
                try
                    growth_data = CSV.read(data_file, DataFrame, header=1, silencewarnings=true)
                    annotations = CSV.read(annotation_file, DataFrame, header=false, silencewarnings=true)
                    
                    # Rename columns - 5th column (index 5) should be antibiotic
                    col_names = names(annotations)
                    new_names = Symbol[]
                    for i in 1:length(col_names)
                        if i == 1
                            push!(new_names, :well)
                        elseif i == 2
                            push!(new_names, :condition)
                        elseif i == 5
                            push!(new_names, :antibiotic)
                        else
                            push!(new_names, Symbol("col_$i"))
                        end
                    end
                    rename!(annotations, new_names)
                    
                    time_col = names(growth_data)[1]
                    time_data = growth_data[!, time_col]
                    
                    # Parse time data
                    if eltype(time_data) <: AbstractString
                        try
                            time_numeric = [parse(Float64, t) for t in time_data[2:end]]
                            time_numeric = [0.0; time_numeric]
                        catch
                            time_numeric = Float64.(0:(nrow(growth_data)-1))
                        end
                    else
                        time_numeric = Float64.(time_data)
                    end
                    
                    # Prepare data for each well
                    traces = []
                    stats = []
                    
                    blank_wells = get_blank_wells(annotations)
                    for well in wells
                        # Only process wells that aren't blank wells and exist in the data
                        if well in names(growth_data) && !(well in blank_wells)
                            well_data = growth_data[!, well]
                            
                            # Convert to numeric
                            od_data = Float64[]
                            for val in well_data
                                try
                                    push!(od_data, parse(Float64, string(val)))
                                catch
                                    push!(od_data, NaN)
                                end
                            end
                            
                            # Get condition including columns 3 and 4, and antibiotic
                            condition_parts = ["Unknown"]
                            antibiotic = "Unknown"
                            well_annotation = filter(row -> row.well == well, annotations)
                            if nrow(well_annotation) > 0
                                row = well_annotation[1, :]
                                condition_parts = [string(row.condition)]
                                
                                # Add columns 3 and 4 if they exist and have values
                                if "col_3" in names(annotations) && !ismissing(row.col_3) && string(row.col_3) != ""
                                    push!(condition_parts, string(row.col_3))
                                end
                                if "col_4" in names(annotations) && !ismissing(row.col_4) && string(row.col_4) != ""
                                    push!(condition_parts, string(row.col_4))
                                end
                                
                                # Add antibiotic from column 5
                                if :antibiotic in names(row) && !ismissing(row.antibiotic) && string(row.antibiotic) != ""
                                    antibiotic = string(row.antibiotic)
                                else
                                    antibiotic = "None"
                                end
                            end
                            
                            condition = join(condition_parts, " | ")
                            
                            # Calculate statistics
                            valid_od = filter(!isnan, od_data)
                            max_od = isempty(valid_od) ? 0.0 : maximum(valid_od)
                            final_od = isempty(valid_od) ? 0.0 : last(valid_od)
                            
                            # Calculate AUC using trapezoidal rule
                            auc = 0.0
                            valid_indices = findall(!isnan, od_data)
                            if length(valid_indices) > 1
                                for i in 2:length(valid_indices)
                                    dt = time_numeric[valid_indices[i]] - time_numeric[valid_indices[i-1]]
                                    avg_od = (od_data[valid_indices[i]] + od_data[valid_indices[i-1]]) / 2
                                    auc += dt * avg_od
                                end
                            end
                            
                            push!(traces, Dict(
                                "well" => well,
                                "condition" => condition,
                                "antibiotic" => antibiotic,
                                "x" => time_numeric,
                                "y" => od_data
                            ))
                            
                            push!(stats, Dict(
                                "well" => well,
                                "condition" => condition,
                                "antibiotic" => antibiotic,
                                "max_od" => round(max_od, digits=3),
                                "final_od" => round(final_od, digits=3),
                                "auc" => round(auc, digits=2)
                            ))
                        end
                    end
                    
                    plot_data = Dict("traces" => traces, "stats" => stats)
                catch e
                    println("Error getting plot data: $e")
                    plot_data = nothing
                end
            end  # End of else block for single experiment
            end  # End of if haskey(request_data, "well_selections")
            
            if plot_data !== nothing
                return HTTP.Response(200, headers, JSON3.write(plot_data))
            else
                return HTTP.Response(404, headers, JSON3.write(Dict("error" => "Data not found")))
            end
            
        elseif path == "/api/cluster" && HTTP.method(req) == "POST"
            request_data = JSON3.read(String(req.body))
            k_input        = Int(get(request_data, :k, 3))
            normalize      = Bool(get(request_data, :normalize, false))
            smooth_method  = Symbol(get(request_data, :smooth_method, "lowess"))
            lowess_frac    = Float64(get(request_data, :lowess_frac, 0.05))
            gaussian_hmult = Float64(get(request_data, :gaussian_h_mult, 2.0))
            cluster_method = string(get(request_data, :cluster_method, "kmeans"))
            maxiter        = Int(get(request_data, :maxiter, 100))
            tol            = Float64(get(request_data, :tol, 1e-6))
            dbscan_eps     = Float64(get(request_data, :dbscan_eps, 1.0))
            dbscan_minpts  = Int(get(request_data, :dbscan_min_pts, 3))
            hclust_linkage = Symbol(get(request_data, :hclust_linkage, "ward"))
            subtract_blank    = Bool(get(request_data, :subtract_blank, false))
            blank_method      = string(get(request_data, :blank_method, "pointbypoint"))
            blank_range_thr   = Float64(get(request_data, :blank_range_thr, 0.005))
            blank_od_pct      = Float64(get(request_data, :blank_od_percentile, 0.10))

            times_all       = Vector{Vector{Float64}}()
            curves_all      = Vector{Vector{Float64}}()
            labels_all      = Vector{String}()
            # For experiment mode: store blank curves separately for subtraction
            blank_curves_all = Vector{Vector{Float64}}()
            blank_labels_used = Vector{String}()
            blank_source      = "none"   # "annotated" | "auto" | "none"

            if haskey(request_data, :csv)
                df       = CSV.read(IOBuffer(String(request_data[:csv])), DataFrame)
                csv_time = Float64.(df[!, names(df)[1]])
                for s in names(df)[2:end]
                    push!(times_all,  csv_time)
                    push!(curves_all, Float64.(df[!, s]))
                    push!(labels_all, String(s))
                end
            else
                for exp_name in String.(request_data[:experiments])
                    data_file       = joinpath(CLEAN_DATA_PATH, exp_name, "data_channel_1.csv")
                    annotation_file = joinpath(CLEAN_DATA_PATH, exp_name, "annotation_clean.csv")
                    isfile(data_file) || continue
                    try
                        gd_raw      = CSV.read(data_file, DataFrame, header=1, silencewarnings=true)
                        annotated_blanks = Set{String}()
                        if isfile(annotation_file)
                            ann = CSV.read(annotation_file, DataFrame, header=false,
                                          silencewarnings=true, stringtype=String)
                            annotated_blanks = get_blank_wells(ann)
                        end
                        time_data = gd_raw[!, names(gd_raw)[1]]
                        time_numeric = if eltype(time_data) <: AbstractString
                            try [0.0; [parse(Float64, t) for t in time_data[2:end]]]
                            catch _ Float64.(0:(nrow(gd_raw)-1)) end
                        else
                            Float64.(time_data)
                        end
                        for well in names(gd_raw)[2:end]
                            od = Float64[]
                            for val in gd_raw[!, well]
                                try push!(od, parse(Float64, string(val))) catch _ push!(od, NaN) end
                            end
                            if well in annotated_blanks
                                push!(blank_curves_all, od)
                                push!(blank_labels_used, "$exp_name/$well")
                            else
                                push!(times_all,  time_numeric)
                                push!(curves_all, od)
                                push!(labels_all, "$exp_name/$well")
                            end
                        end
                        if !isempty(annotated_blanks)
                            blank_source = "annotated"
                        end
                    catch e
                        println("Error loading $exp_name for clustering: $e")
                    end
                end
            end

            isempty(curves_all) && return HTTP.Response(400, headers,
                JSON3.write(Dict("error" => "No data loaded")))

            min_len  = minimum(length.(curves_all))
            times    = times_all[1][1:min_len]
            n_series = length(curves_all)
            curves   = Matrix{Float64}(undef, n_series, min_len)
            for (i, c) in enumerate(curves_all)
                curves[i, :] = c[1:min_len]
            end

            # ------------------------------------------------------------------
            # Blank subtraction (before smoothing and clustering)
            # ------------------------------------------------------------------
            if subtract_blank
                # For CSV uploads or experiments without annotated blanks: auto-detect
                if isempty(blank_curves_all)
                    blank_idxs = _detect_blank_indices(curves, times;
                        flat_range_thr = blank_range_thr,
                        od_percentile  = blank_od_pct)
                    if !isempty(blank_idxs)
                        blank_curves_all = [curves[i, :] for i in blank_idxs]
                        blank_labels_used = labels_all[blank_idxs]
                        blank_source = "auto"
                        # Remove detected blanks from the data to be clustered
                        keep = setdiff(1:n_series, blank_idxs)
                        curves     = curves[keep, :]
                        labels_all = labels_all[keep]
                        n_series   = length(keep)
                        times_all  = times_all[keep]
                    end
                end

                if !isempty(blank_curves_all)
                    blen      = min(min_len, minimum(length.(blank_curves_all)))
                    blank_mat = Matrix{Float64}(undef, length(blank_curves_all), blen)
                    for (i, bc) in enumerate(blank_curves_all)
                        blank_mat[i, :] = bc[1:blen]
                    end
                    # Mean blank timeseries (per timepoint)
                    blank_ts = [mean(filter(isfinite, blank_mat[:, t])) for t in 1:blen]
                    # Pad/trim to match curves width
                    blank_ts_full = length(blank_ts) >= min_len ? blank_ts[1:min_len] :
                                    vcat(blank_ts, fill(blank_ts[end], min_len - length(blank_ts)))
                    curves = _apply_blank_subtraction_matrix(curves, blank_ts_full, blank_method)
                end
            end

            # ------------------------------------------------------------------
            # Smoothing via KinBiont preprocess
            # ------------------------------------------------------------------
            if smooth_method != :none
                gd_smooth = GrowthData(curves, times, labels_all)
                smooth_opts = FitOptions(
                    smooth             = true,
                    smooth_method      = smooth_method,
                    lowess_frac        = lowess_frac,
                    gaussian_h_mult    = gaussian_hmult,
                    cluster            = false,
                )
                gd_proc = preprocess(gd_smooth, smooth_opts)
                # After smoothing times may change (gaussian can resample); use
                # smoothed data but keep original times for display alignment.
                sm_curves = gd_proc.curves   # n_series × n_times matrix
                sm_times  = gd_proc.times
                # Trim both to same length in case of mismatch
                tlen = min(size(sm_curves, 2), length(times))
                curves_for_cluster = sm_curves[:, 1:tlen]
                times = sm_times[1:tlen]
            else
                curves_for_cluster = curves
            end

            # ------------------------------------------------------------------
            # Z-score for clustering (always)
            # ------------------------------------------------------------------
            zscored = _zscore_rows(curves_for_cluster)

            # ------------------------------------------------------------------
            # Clustering
            # ------------------------------------------------------------------
            k_eff = min(k_input, n_series)

            cluster_ids = if cluster_method == "kmeans"
                res = Clustering.kmeans(zscored', k_eff; maxiter, tol)
                Clustering.assignments(res)

            elseif cluster_method == "kmedoids"
                dmat = _pairwise_euclidean(zscored)
                res  = Clustering.kmedoids(dmat, k_eff; maxiter, tol)
                Clustering.assignments(res)

            elseif cluster_method == "hclust"
                dmat = _pairwise_euclidean(zscored)
                hc   = Clustering.hclust(dmat; linkage = hclust_linkage)
                Clustering.cutree(hc; k = k_eff)

            elseif cluster_method == "dbscan"
                res = Clustering.dbscan(zscored', dbscan_eps, min_neighbors = dbscan_minpts)
                raw = Clustering.assignments(res)
                raw   # 0 = noise

            else
                return HTTP.Response(400, headers,
                    JSON3.write(Dict("error" => "Unknown cluster_method: $cluster_method")))
            end

            # ------------------------------------------------------------------
            # Display curves (optionally z-scored)
            # ------------------------------------------------------------------
            display_curves = copy(curves_for_cluster)
            if normalize
                for i in 1:n_series
                    row = display_curves[i, :]
                    s   = std(row)
                    s > 1e-12 && (display_curves[i, :] = (row .- mean(row)) ./ s)
                end
            end

            # Collect unique cluster ids (DBSCAN may produce arbitrary ids incl 0)
            unique_ids = sort(unique(cluster_ids))
            clusters = []
            for c in unique_ids
                mask = findall(cluster_ids .== c)
                isempty(mask) && continue
                label = c == 0 ? "Noise" : string(c)
                push!(clusters, Dict(
                    "id"            => c,
                    "label"         => label,
                    "series_labels" => labels_all[mask],
                    "series_data"   => [display_curves[i, :] for i in mask]
                ))
            end

            # ------------------------------------------------------------------
            # Quality indices (exclude DBSCAN noise points for computation)
            # ------------------------------------------------------------------
            noise_mask   = cluster_ids .!= 0
            ids_for_qual = cluster_ids[noise_mask]
            X_for_qual   = curves_for_cluster[noise_mask, :]

            # Remap to contiguous 1..k (required by clustering_quality)
            ids_remapped, _ = _remap_ids(ids_for_qual)
            quality = _cluster_quality_indices(X_for_qual, ids_remapped)

            # Per-cluster silhouette mean (keyed by original cluster id)
            sil_per_cluster = Dict{String,Any}()
            if quality["silhouettes"] !== nothing
                sil_vals = quality["silhouettes"]
                for (orig_id, remap_id) in zip(ids_for_qual, ids_remapped)
                    mask_c = ids_for_qual .== orig_id
                    sil_per_cluster[string(orig_id)] = mean(sil_vals[mask_c])
                end
            end
            quality["silhouette_per_cluster"] = sil_per_cluster

            # Per-series silhouette (same order as labels_all, NaN for noise)
            sil_per_series = fill(NaN, n_series)
            if quality["silhouettes"] !== nothing
                sil_vals   = quality["silhouettes"]
                nonnoise_i = findall(noise_mask)
                for (j, gi) in enumerate(nonnoise_i)
                    sil_per_series[gi] = sil_vals[j]
                end
            end
            quality["silhouettes"]      = sil_per_series
            quality["series_labels"]    = labels_all

            return HTTP.Response(200, headers, JSON3.write(Dict(
                "time"             => times,
                "clusters"         => clusters,
                "cluster_method"   => cluster_method,
                "smooth_method"    => string(smooth_method),
                "quality"          => quality,
                "assignments"      => cluster_ids,
                "series_labels"    => labels_all,
                "blank_subtracted" => subtract_blank && !isempty(blank_curves_all),
                "blank_source"     => blank_source,
                "blank_wells_used" => blank_labels_used,
            )))

        # ------------------------------------------------------------------
        # /api/cluster-sweep  — run clustering for k=2..k_max and return
        # quality indices per k so the user can find the best number of clusters.
        # ------------------------------------------------------------------
        elseif path == "/api/cluster-sweep" && HTTP.method(req) == "POST"
            request_data   = JSON3.read(String(req.body))
            k_max          = Int(get(request_data, :k_max, 10))
            smooth_method  = Symbol(get(request_data, :smooth_method, "lowess"))
            lowess_frac    = Float64(get(request_data, :lowess_frac, 0.05))
            gaussian_hmult = Float64(get(request_data, :gaussian_h_mult, 2.0))
            cluster_method = string(get(request_data, :cluster_method, "kmeans"))
            maxiter        = Int(get(request_data, :maxiter, 100))
            tol            = Float64(get(request_data, :tol, 1e-6))
            hclust_linkage = Symbol(get(request_data, :hclust_linkage, "ward"))

            # Re-use the same data-loading logic as /api/cluster
            times_all  = Vector{Vector{Float64}}()
            curves_all = Vector{Vector{Float64}}()
            labels_all = Vector{String}()

            if haskey(request_data, :csv)
                df       = CSV.read(IOBuffer(String(request_data[:csv])), DataFrame)
                csv_time = Float64.(df[!, names(df)[1]])
                for s in names(df)[2:end]
                    push!(times_all,  csv_time)
                    push!(curves_all, Float64.(df[!, s]))
                    push!(labels_all, String(s))
                end
            else
                for exp_name in String.(request_data[:experiments])
                    data_file       = joinpath(CLEAN_DATA_PATH, exp_name, "data_channel_1.csv")
                    annotation_file = joinpath(CLEAN_DATA_PATH, exp_name, "annotation_clean.csv")
                    isfile(data_file) || continue
                    try
                        gd_raw      = CSV.read(data_file, DataFrame, header=1, silencewarnings=true)
                        blank_wells = Set{String}()
                        if isfile(annotation_file)
                            ann = CSV.read(annotation_file, DataFrame, header=false,
                                          silencewarnings=true, stringtype=String)
                            blank_wells = get_blank_wells(ann)
                        end
                        time_data    = gd_raw[!, names(gd_raw)[1]]
                        time_numeric = if eltype(time_data) <: AbstractString
                            try [0.0; [parse(Float64, t) for t in time_data[2:end]]]
                            catch _ Float64.(0:(nrow(gd_raw)-1)) end
                        else
                            Float64.(time_data)
                        end
                        for well in names(gd_raw)[2:end]
                            well in blank_wells && continue
                            od = Float64[]
                            for val in gd_raw[!, well]
                                try push!(od, parse(Float64, string(val))) catch _ push!(od, NaN) end
                            end
                            push!(times_all,  time_numeric)
                            push!(curves_all, od)
                            push!(labels_all, "$exp_name/$well")
                        end
                    catch e
                        println("Error loading $exp_name for sweep: $e")
                    end
                end
            end

            isempty(curves_all) && return HTTP.Response(400, headers,
                JSON3.write(Dict("error" => "No data loaded")))

            min_len  = minimum(length.(curves_all))
            times    = times_all[1][1:min_len]
            n_series = length(curves_all)
            curves   = Matrix{Float64}(undef, n_series, min_len)
            for (i, c) in enumerate(curves_all)
                curves[i, :] = c[1:min_len]
            end

            # Smooth once, then sweep over k
            if smooth_method != :none
                gd_smooth   = GrowthData(curves, times, labels_all)
                smooth_opts = FitOptions(smooth=true, smooth_method=smooth_method,
                                         lowess_frac=lowess_frac,
                                         gaussian_h_mult=gaussian_hmult, cluster=false)
                gd_proc    = preprocess(gd_smooth, smooth_opts)
                tlen       = min(size(gd_proc.curves, 2), length(times))
                curves_for = gd_proc.curves[:, 1:tlen]
            else
                curves_for = curves
            end
            zscored = _zscore_rows(curves_for)

            sweep_results = []
            for k in 2:min(k_max, n_series)
                ids = try
                    if cluster_method == "kmeans"
                        Clustering.assignments(Clustering.kmeans(zscored', k; maxiter, tol))
                    elseif cluster_method == "kmedoids"
                        dmat = _pairwise_euclidean(zscored)
                        Clustering.assignments(Clustering.kmedoids(dmat, k; maxiter, tol))
                    elseif cluster_method == "hclust"
                        dmat = _pairwise_euclidean(zscored)
                        Clustering.cutree(Clustering.hclust(dmat; linkage=hclust_linkage); k)
                    else
                        Clustering.assignments(Clustering.kmeans(zscored', k; maxiter, tol))
                    end
                catch e
                    println("Sweep k=$k error: $e")
                    continue
                end

                ids_r, _ = _remap_ids(ids)
                q = _cluster_quality_indices(zscored, ids_r)
                push!(sweep_results, Dict(
                    "k"                 => k,
                    "silhouette_mean"   => q["silhouette_mean"],
                    "dunn"              => q["dunn"],
                    "davies_bouldin"    => q["davies_bouldin"],
                    "calinski_harabasz" => q["calinski_harabasz"],
                    "xie_beni"          => q["xie_beni"],
                ))
            end

            return HTTP.Response(200, headers, JSON3.write(Dict("sweep" => sweep_results)))

        # ------------------------------------------------------------------
        # /api/cluster-compare  — compare two saved clusterings
        # ------------------------------------------------------------------
        elseif path == "/api/cluster-compare" && HTTP.method(req) == "POST"
            request_data = JSON3.read(String(req.body))
            ids1 = Int.(request_data[:assignments1])
            ids2 = Int.(request_data[:assignments2])

            length(ids1) == length(ids2) || return HTTP.Response(400, headers,
                JSON3.write(Dict("error" => "assignments must have the same length")))

            result = _cluster_comparison(ids1, ids2)
            return HTTP.Response(200, headers, JSON3.write(result))

        elseif path == "/"
            # Serve the main HTML page
            html_content = read("web_interface.html", String)
            html_headers = cors_headers()
            push!(html_headers, "Content-Type" => "text/html")
            return HTTP.Response(200, html_headers, html_content)

        else
            return HTTP.Response(404, headers, JSON3.write(Dict("error" => "Not found")))
        end
        
    catch e
        println("Error in router: $e")
        return HTTP.Response(500, headers, JSON3.write(Dict("error" => "Internal server error")))
    end
end

# Start the server
function start_server(port=PORT)
    println("🚀 Starting Growth Curve Web Server...")
    println("📊 Clean data path: $CLEAN_DATA_PATH")
    println("🌐 Server will run at: http://localhost:$port")
    println("📋 Available experiments: $(length(get_experiments()))")
    println("\nPress Ctrl+C to stop the server")
    
    try
        HTTP.serve(router, "0.0.0.0", port)
    catch e
        if isa(e, InterruptException)
            println("\n👋 Server stopped")
        else
            println("❌ Error: $e")
        end
    end
end

# Run the server if this file is executed directly
if abspath(PROGRAM_FILE) == @__FILE__
    start_server()
end
