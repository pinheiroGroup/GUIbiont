# Clustering helper functions
# Pairwise Euclidean, z-score normalisation, k-means utilities, blank detection

# Load curves from a DataFrame, auto-detecting an unnamed sequential-integer index column.
# Returns (times_all, curves_all, labels_all).
# If column 1 is an integer 0..n-1 sequence (e.g. an unnamed pandas/CSV row index),
# it is skipped and column 2 is used as the time axis.
function _load_csv_curves(df::DataFrame)
    col_names = names(df)
    ncols = length(col_names)
    ncols < 2 && error("CSV must have at least 2 columns (time + one data series)")

    # Detect unnamed row-index column.
    # CSV.jl names an empty header field "Column1"; pandas exports row indices as
    # an unnamed first column.  We skip it and use column 2 as the time axis when:
    #   • the first column is named "Column1" or starts with "Unnamed:" (pandas), AND
    #   • its element type is numeric (integer or float — a time column would be Float)
    time_col_idx = 1
    if ncols >= 2
        fn = col_names[1]
        et = nonmissingtype(eltype(df[!, fn]))
        if (fn == "Column1" || startswith(fn, "Unnamed:")) && et <: Number
            time_col_idx = 2
        end
    end

    csv_time = Float64.(coalesce.(df[!, col_names[time_col_idx]], NaN))
    # If time column has NaN (e.g. missing values), fall back to row indices so
    # downstream smoothing (which requires finite time) does not fail.
    if any(isnan, csv_time)
        csv_time = Float64.(0:(nrow(df) - 1))
    end
    times_all  = Vector{Vector{Float64}}()
    curves_all = Vector{Vector{Float64}}()
    labels_all = Vector{String}()
    for s in col_names[(time_col_idx + 1):end]
        push!(times_all,  csv_time)
        push!(curves_all, Float64.(coalesce.(df[!, s], NaN)))
        push!(labels_all, String(s))
    end
    return times_all, curves_all, labels_all
end

# Strip NaN tail from a (times, values) pair: drop all points from the last
# non-NaN value onward, so IrregularGrowthData receives clean vectors.
function _strip_nan_tail(t::Vector{Float64}, y::Vector{Float64})
    last_valid = findlast(!isnan, y)
    last_valid === nothing && return t[1:min(2,end)], fill(0.0, min(2,length(y)))
    last_valid = max(last_valid, 2)   # IrregularGrowthData requires ≥ 2 points
    return t[1:last_valid], y[1:last_valid]
end

# Pairwise Euclidean distance matrix (n × n) for a matrix with rows = observations.
function _pairwise_euclidean(X::Matrix{Float64})::Matrix{Float64}
    n = size(X, 1)
    D = Matrix{Float64}(undef, n, n)
    for i in 1:n, j in 1:n
        D[i, j] = sqrt(sum((X[i, k] - X[j, k])^2 for k in axes(X, 2)))
    end
    return D
end

# Z-score each row (curve) across time; constant rows and all-NaN rows become all-zeros.
# NaN values in a row are set to 0 (mean) after z-scoring so they don't pollute distances.
function _zscore_rows(m::Matrix{Float64})::Matrix{Float64}
    out = zeros(size(m))
    for i in axes(m, 1)
        row    = m[i, :]
        finite = filter(isfinite, row)
        length(finite) < 2 && continue
        μ = mean(finite)
        s = std(finite)
        s < 1e-12 && continue
        for j in axes(m, 2)
            out[i, j] = isfinite(m[i, j]) ? (m[i, j] - μ) / s : 0.0
        end
    end
    return out
end

# Replace NaN/Inf in each column with the column finite mean (or 0 if all non-finite).
# Used to sanitise a curves matrix before passing it to external libraries.
function _fill_nan_colmean(m::Matrix{Float64})::Matrix{Float64}
    out = copy(m)
    for j in axes(m, 2)
        col     = m[:, j]
        finite  = filter(isfinite, col)
        fill_v  = isempty(finite) ? 0.0 : mean(finite)
        for i in axes(m, 1)
            isfinite(out[i, j]) || (out[i, j] = fill_v)
        end
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

# Mirror KinBiont's constant/non-growing pre-screen on raw OD curves.  This is
# used as a cheap preflight so we only reserve the sentinel cluster when at
# least one curve would actually be assigned to it.
function _prescreen_constant_raw_od_mask(
    curves::Matrix{Float64};
    tol_const::Float64 = 1.5,
    q_low::Float64 = 0.05,
    q_high::Float64 = 0.95,
)::BitVector
    opts = Kinbiont.FitOptions(
        cluster_tol_const = tol_const,
        cluster_q_low     = q_low,
        cluster_q_high    = q_high,
    )
    return Kinbiont._prescreen_constant(curves, opts)
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

# Compute per-cluster centroid (mean) and SD over the time axis.
function _centroid_with_sd(display_curves::Matrix{Float64}, mask::Vector{Int})
    sub  = display_curves[mask, :]
    n_tp = size(sub, 2)
    centroid = Vector{Float64}(undef, n_tp)
    sd_vec   = Vector{Float64}(undef, n_tp)
    for t in 1:n_tp
        col = filter(isfinite, sub[:, t])
        if isempty(col)
            centroid[t] = 0.0; sd_vec[t] = 0.0
        elseif length(col) == 1
            centroid[t] = col[1]; sd_vec[t] = 0.0
        else
            centroid[t] = mean(col); sd_vec[t] = std(col)
        end
    end
    return centroid, sd_vec
end

# Interpolate curves onto a common grid using piecewise-linear interpolation.
# Points outside a curve's time range are held at the nearest endpoint.
function _interpolate_to_grid(
    curves_all::Vector{Vector{Float64}},
    times_all::Vector{Vector{Float64}},
    grid::Vector{Float64},
)::Matrix{Float64}
    n      = length(curves_all)
    n_grid = length(grid)
    out    = Matrix{Float64}(undef, n, n_grid)
    for (i, (y, t)) in enumerate(zip(curves_all, times_all))
        ord = sortperm(t)
        t_s = t[ord]; y_s = y[ord]; n_t = length(t_s)
        for (j, tg) in enumerate(grid)
            if n_t == 0
                out[i, j] = NaN
            elseif tg <= t_s[1]
                out[i, j] = y_s[1]
            elseif tg >= t_s[end]
                out[i, j] = y_s[end]
            else
                k    = clamp(searchsortedlast(t_s, tg), 1, n_t - 1)
                frac = (tg - t_s[k]) / (t_s[k+1] - t_s[k])
                out[i, j] = y_s[k] + frac * (y_s[k+1] - y_s[k])
            end
        end
    end
    return out
end

# Build a uniform time grid using quantile-based endpoints to resist outlier lengths.
function _build_interp_grid(
    times_all::Vector{Vector{Float64}},
    n_grid::Int,
    q_lo::Float64,
    q_hi::Float64,
)::Vector{Float64}
    t_starts = [minimum(t) for t in times_all if !isempty(t)]
    t_ends   = [maximum(t) for t in times_all if !isempty(t)]
    isempty(t_starts) && return Float64[]
    t0 = quantile(t_starts, q_lo)
    t1 = quantile(t_ends,   q_hi)
    t0 >= t1 && (t0 = minimum(t_starts); t1 = maximum(t_ends))
    return collect(range(t0, t1; length = n_grid))
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

    # Pairwise-distance-based indices (silhouette, Dunn) require an n×n matrix.
    # Skip them when n is large to avoid OOM — centroid-based indices still run.
    if n <= 5000
        dmat = _pairwise_euclidean(X)

        sil_vals = try
            Clustering.silhouettes(ids, dmat)
        catch _
            nothing
        end
        q["silhouettes"]     = sil_vals === nothing ? nothing : collect(Float64, sil_vals)
        q["silhouette_mean"] = sil_vals === nothing ? nothing : mean(sil_vals)

        q["dunn"] = try
            Float64(Clustering.clustering_quality(X', ids; quality_index = :dunn))
        catch _
            nothing
        end
    else
        q["silhouettes"]     = nothing
        q["silhouette_mean"] = nothing
        q["dunn"]            = nothing
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
