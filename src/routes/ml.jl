@post "/api/cluster" function(req::HTTP.Request, body::Json{ClusterRequest})
    body = body.payload
    k_input        = Int(body.k)
    normalize      = Bool(body.normalize)
    smooth_method  = Symbol(body.smooth_method)
    lowess_frac    = Float64(body.lowess_frac)
    gaussian_hmult = Float64(body.gaussian_h_mult)
    cluster_method = string(body.cluster_method)
    maxiter        = Int(body.maxiter)
    tol            = Float64(body.tol)
    dbscan_eps     = Float64(body.dbscan_eps)
    dbscan_minpts  = Int(body.dbscan_min_pts)
    hclust_linkage = Symbol(body.hclust_linkage)
    subtract_blank = Bool(body.subtract_blank)
    blank_method   = string(body.blank_method)
    blank_range_thr = Float64(body.blank_range_thr)
    blank_od_pct   = Float64(body.blank_od_percentile)

    times_all        = Vector{Vector{Float64}}()
    curves_all       = Vector{Vector{Float64}}()
    labels_all       = Vector{String}()
    # For experiment mode: store blank curves separately for subtraction
    blank_curves_all  = Vector{Vector{Float64}}()
    blank_labels_used = Vector{String}()
    blank_source      = "none"   # "annotated" | "auto" | "none"

    if !isempty(body.csv) || !isempty(body.csv_path)
        df = if !isempty(body.csv_path)
            p = body.csv_path
            isfile(p) || return json(Dict("error" => "File not found: $p"); status=400)
            CSV.read(p, DataFrame)
        else
            CSV.read(IOBuffer(body.csv), DataFrame)
        end
        csv_time = Float64.(coalesce.(df[!, names(df)[1]], NaN))
        for s in names(df)[2:end]
            push!(times_all,  csv_time)
            push!(curves_all, Float64.(coalesce.(df[!, s], NaN)))
            push!(labels_all, String(s))
        end
    else
        for exp_name in body.experiments
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
                @warn "Error loading $exp_name for clustering: $e"
            end
        end
    end

    isempty(curves_all) && return json(Dict("error" => "No data loaded"); status=400)

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
                blank_curves_all  = [curves[i, :] for i in blank_idxs]
                blank_labels_used = labels_all[blank_idxs]
                blank_source      = "auto"
                # Remove detected blanks from the data to be clustered
                keep       = setdiff(1:n_series, blank_idxs)
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
        gd_smooth   = GrowthData(curves, times, labels_all)
        smooth_opts = FitOptions(
            smooth          = true,
            smooth_method   = smooth_method,
            lowess_frac     = lowess_frac,
            gaussian_h_mult = gaussian_hmult,
            cluster         = false,
        )
        gd_proc = preprocess(gd_smooth, smooth_opts)
        # After smoothing times may change (gaussian can resample); use
        # smoothed data but keep original times for display alignment.
        sm_curves = gd_proc.curves   # n_series × n_times matrix
        sm_times  = gd_proc.times
        # Trim both to same length in case of mismatch
        tlen               = min(size(sm_curves, 2), length(times))
        curves_for_cluster = sm_curves[:, 1:tlen]
        times              = sm_times[1:tlen]
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
        return json(Dict("error" => "Unknown cluster_method: $cluster_method"); status=400)
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
    quality["silhouettes"]   = sil_per_series
    quality["series_labels"] = labels_all

    return Dict(
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
    )
end

# ------------------------------------------------------------------
# /api/cluster-sweep  — run clustering for k=2..k_max and return
# quality indices per k so the user can find the best number of clusters.
# ------------------------------------------------------------------
@post "/api/cluster-sweep" function(req::HTTP.Request, body::Json{ClusterSweepRequest})
    body = body.payload
    k_max          = Int(body.k_max)
    smooth_method  = Symbol(body.smooth_method)
    lowess_frac    = Float64(body.lowess_frac)
    gaussian_hmult = Float64(body.gaussian_h_mult)
    cluster_method = string(body.cluster_method)
    maxiter        = Int(body.maxiter)
    tol            = Float64(body.tol)
    hclust_linkage = Symbol(body.hclust_linkage)

    # Re-use the same data-loading logic as /api/cluster
    times_all  = Vector{Vector{Float64}}()
    curves_all = Vector{Vector{Float64}}()
    labels_all = Vector{String}()

    if !isempty(body.csv) || !isempty(body.csv_path)
        df = if !isempty(body.csv_path)
            p = body.csv_path
            isfile(p) || return json(Dict("error" => "File not found: $p"); status=400)
            CSV.read(p, DataFrame)
        else
            CSV.read(IOBuffer(body.csv), DataFrame)
        end
        csv_time = Float64.(coalesce.(df[!, names(df)[1]], NaN))
        for s in names(df)[2:end]
            push!(times_all,  csv_time)
            push!(curves_all, Float64.(coalesce.(df[!, s], NaN)))
            push!(labels_all, String(s))
        end
    else
        for exp_name in body.experiments
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
                @warn "Error loading $exp_name for sweep: $e"
            end
        end
    end

    isempty(curves_all) && return json(Dict("error" => "No data loaded"); status=400)

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

    _wcss(data, ids) = sum(sum((data[ids .== c, :] .- mean(data[ids .== c, :], dims=1)).^2) for c in unique(ids))

    sweep_results = []
    for k in 2:min(k_max, n_series)
        ids, wcss = try
            if cluster_method == "kmeans"
                km = Clustering.kmeans(zscored', k; maxiter, tol)
                Clustering.assignments(km), km.totalcost
            elseif cluster_method == "kmedoids"
                dmat = _pairwise_euclidean(zscored)
                asgn = Clustering.assignments(Clustering.kmedoids(dmat, k; maxiter, tol))
                asgn, _wcss(zscored, asgn)
            elseif cluster_method == "hclust"
                dmat = _pairwise_euclidean(zscored)
                asgn = Clustering.cutree(Clustering.hclust(dmat; linkage=hclust_linkage); k)
                asgn, _wcss(zscored, asgn)
            else
                km = Clustering.kmeans(zscored', k; maxiter, tol)
                Clustering.assignments(km), km.totalcost
            end
        catch e
            @warn "Sweep k=$k error: $e"
            continue
        end

        ids_r, _ = _remap_ids(ids)
        q = _cluster_quality_indices(zscored, ids_r)
        push!(sweep_results, Dict(
            "k"                 => k,
            "wcss"              => wcss,
            "silhouette_mean"   => q["silhouette_mean"],
            "dunn"              => q["dunn"],
            "davies_bouldin"    => q["davies_bouldin"],
            "calinski_harabasz" => q["calinski_harabasz"],
            "xie_beni"          => q["xie_beni"],
        ))
    end

    return Dict("sweep" => sweep_results)
end

# ------------------------------------------------------------------
# /api/cluster-compare  — compare two saved clusterings
# ------------------------------------------------------------------
@post "/api/cluster-compare" function(req::HTTP.Request, body::Json{ClusterCompareRequest})
    body = body.payload
    ids1 = body.assignments1
    ids2 = body.assignments2

    if length(ids1) != length(ids2)
        return json(Dict("error" => "assignments must have the same length"); status=400)
    end

    return _cluster_comparison(ids1, ids2)
end

@post "/api/ml-downstream" function(req::HTTP.Request, body::Json{MLDownstreamRequest})
    body = body.payload
    fit_csv     = string(body.fit_csv)
    label_col   = string(body.label_col)
    feat_csv    = string(body.feature_matrix)
    param_names = String.(body.params)

    try
        fit_raw       = CSV.read(IOBuffer(fit_csv), DataFrame)
        fit_col_names = String.(names(fit_raw))
        label_col in fit_col_names || return json(Dict("error" => "label column '$label_col' not found in fit CSV"); status=400)
        fit_labels = string.(fit_raw[!, Symbol(label_col)])

        all_params = filter(n -> n != label_col &&
            eltype(fit_raw[!, Symbol(n)]) <: Union{Number, Missing},
            fit_col_names)

        feat_raw      = CSV.read(IOBuffer(feat_csv), DataFrame)
        feat_labels   = string.(feat_raw[!, 1])
        feature_names = String.(names(feat_raw)[2:end])

        fit_df = DataFrame(
            :label => fit_labels,
            [Symbol(p) => Float64.(coalesce.(fit_raw[!, Symbol(p)], NaN)) for p in all_params]...,
        )
        feat_df = DataFrame(
            :label => feat_labels,
            [Symbol(n) => Float64.(coalesce.(feat_raw[!, Symbol(n)], NaN)) for n in feature_names]...,
        )
        joined = innerjoin(fit_df, feat_df; on = :label)

        isempty(joined) && return json(Dict("error" => "No matching labels between fit results and feature matrix"); status=400)

        param_mat = Matrix{Float64}(joined[!, Symbol.(all_params)])
        feat_mat  = Matrix{Float64}(joined[!, Symbol.(feature_names)])

        corr = spearman_correlations(param_mat, feat_mat, all_params, feature_names)

        importance = Dict{String,Any}()
        pdp        = Dict{String,Any}()
        for pname in param_names
            pcol = findfirst(==(pname), all_params)
            pcol === nothing && continue
            rankings, model, Xm = forest_importance(param_mat, feat_mat, pcol, feature_names)
            importance[pname] = rankings
            (isempty(rankings) || model === nothing) && continue
            top5 = [findfirst(==(r["feature"]), feature_names)
                    for r in rankings[1:min(5, length(rankings))]]
            pdp[pname] = [
                begin
                    grid, means = partial_dependence(model, Xm, idx)
                    Dict("feature" => feature_names[idx], "grid" => grid, "mean" => means)
                end
                for idx in top5 if idx !== nothing
            ]
        end

        return Dict(
            "correlations" => corr,
            "importance"   => importance,
            "pdp"          => pdp,
            "n_wells"      => nrow(joined),
        )
    catch e
                return json(Dict("error" => "ML analysis failed: $e"); status=500)
    end
end
