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

# Rebuild the clustering grid after blank correction has been applied to the
# original source curves. Detection can happen on an interpolated/normalised
# grid, but subtraction must precede that transformation so annotated and
# derived blanks share the same measurement-index semantics.
function _rebuild_clustering_grid(
    curves_all::Vector{Vector{Float64}},
    times_all::Vector{Vector{Float64}},
    labels::Vector{String},
    groups::Vector{String},
    target_times::Vector{Float64};
    interpolate::Bool,
    irregular::Bool,
)
    length(curves_all) == length(times_all) == length(labels) == length(groups) ||
        throw(ArgumentError("curves, times, labels, and groups must have the same length"))

    if interpolate
        curves = Kinbiont.interpolate_curves_to_grid(curves_all, times_all, target_times)
        return (
            curves=curves,
            times=target_times,
            labels=labels,
            groups=groups,
            time_normalized=false,
        )
    elseif irregular
        clean_times = Vector{Vector{Float64}}()
        clean_curves = Vector{Vector{Float64}}()
        clean_labels = String[]
        clean_groups = String[]
        for i in eachindex(curves_all)
            ct, cy = _strip_nan_tail(times_all[i], curves_all[i])
            length(ct) < 2 && continue
            push!(clean_times, ct)
            push!(clean_curves, cy)
            push!(clean_labels, labels[i])
            push!(clean_groups, groups[i])
        end
        isempty(clean_curves) && error("No valid curves after raw blank correction")
        igd = IrregularGrowthData(clean_curves, clean_times, clean_labels; step=0.01)
        return (
            curves=igd.curves,
            times=igd.times,
            labels=clean_labels,
            groups=clean_groups,
            time_normalized=true,
        )
    end

    ncols = length(target_times)
    curves = Matrix{Float64}(undef, length(curves_all), ncols)
    for i in eachindex(curves_all)
        length(curves_all[i]) >= ncols || throw(ArgumentError(
            "curve $(labels[i]) is shorter than the prepared grid"
        ))
        curves[i, :] = curves_all[i][1:ncols]
    end
    return (
        curves=curves,
        times=target_times,
        labels=labels,
        groups=groups,
        time_normalized=false,
    )
end

function _smooth_clustering_curves(
    curves::Matrix{Float64},
    times::Vector{Float64},
    labels::Vector{String};
    method::Symbol=:none,
    smooth_pt_avg::Int=7,
    lowess_frac::Float64=0.05,
    gaussian_h_mult::Float64=2.0,
)
    method == :none && return curves, times
    processed = preprocess(
        GrowthData(curves, times, labels),
        FitOptions(
            smooth=true,
            smooth_method=method,
            smooth_pt_avg=smooth_pt_avg,
            lowess_frac=lowess_frac,
            gaussian_h_mult=gaussian_h_mult,
            cluster=false,
        ),
    )
    n_time = min(size(processed.curves, 2), length(processed.times))
    return processed.curves[:, 1:n_time], processed.times[1:n_time]
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

# Auto-detect likely blank wells when no annotation is available. This is the
# exact default constant-curve pre-screen used by Kinbiont clustering: q05/q95,
# relative tolerance 0.5, plus Kinbiont's fixed negligible quantile-range
# criterion of 0.01. Detection is deliberately independent for each well so a
# missing value in one trajectory cannot alter another trajectory's decision.
function _detect_blank_wells(
    growth_data::DataFrame;
    prescreen_tol::Float64    = 0.5,
    prescreen_q_low::Float64  = 0.05,
    prescreen_q_high::Float64 = 0.95,
)::Vector{String}
    well_cols = names(growth_data)[2:end]
    candidates = String[]
    for w in well_cols
        od = parse_od_column(growth_data, Symbol(w))
        y = od[isfinite.(od)]
        length(y) >= 3 || continue
        detected = Kinbiont.detect_non_growing_indices(
            reshape(y, 1, :), collect(1.0:length(y));
            prescreen_constant=true,
            trend_test=false,
            prescreen_tol=prescreen_tol,
            prescreen_q_low=prescreen_q_low,
            prescreen_q_high=prescreen_q_high,
        )
        !isempty(detected) && push!(candidates, string(w))
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
