# Clustering helper functions
# Pairwise Euclidean, z-score normalisation, k-means utilities, blank detection

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
