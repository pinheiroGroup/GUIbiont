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
    kmeans_n_init  = clamp(Int(body.kmeans_n_init), 1, 100)
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
        ta, ca, la = _load_csv_curves(df)
        append!(times_all, ta); append!(curves_all, ca); append!(labels_all, la)
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

    # ------------------------------------------------------------------
    # Build common time grid
    #   do_interp=true          → quantile-based real-time interpolation
    #   do_interp=false, NaN    → IrregularGrowthData (normalized [0,1])
    #   do_interp=false, no NaN → truncate to shortest curve
    # ------------------------------------------------------------------
    do_interp     = Bool(body.interpolate)
    interp_n      = max(10, Int(body.interp_n))
    q_lo          = Float64(body.interp_quantile_lo)
    q_hi          = Float64(body.interp_quantile_hi)
    prescreen_qlo = Float64(body.prescreen_q_low)
    prescreen_qhi = Float64(body.prescreen_q_high)
    has_irregular = any(c -> any(isnan, c), curves_all)
    time_normalized = false

    if do_interp
        grid = _build_interp_grid(times_all, interp_n, q_lo, q_hi)
        if isempty(grid)
            return json(Dict("error" => "Could not build interpolation grid"); status=400)
        end
        curves_interp = _interpolate_to_grid(curves_all, times_all, grid)
        times    = grid
        n_series = size(curves_interp, 1)
        curves   = curves_interp

    elseif has_irregular
        # Strip NaN tails, then use KinBiont IrregularGrowthData to resample
        # each curve onto a normalized [0, 1] union grid.
        clean_times  = Vector{Vector{Float64}}()
        clean_curves = Vector{Vector{Float64}}()
        valid_labels = Vector{String}()
        for i in eachindex(curves_all)
            ct, cy = _strip_nan_tail(times_all[i], curves_all[i])
            length(ct) < 2 && continue
            push!(clean_times,  ct)
            push!(clean_curves, cy)
            push!(valid_labels, labels_all[i])
        end
        isempty(clean_curves) &&
            return json(Dict("error" => "No valid curves after NaN removal"); status=400)
        igd          = IrregularGrowthData(clean_curves, clean_times, valid_labels; step=0.01)
        times        = igd.times
        n_series     = size(igd.curves, 1)
        curves       = igd.curves
        labels_all   = valid_labels
        blank_curves_all = Vector{Vector{Float64}}()   # blanks not supported on this path
        time_normalized  = true

    else
        min_len  = minimum(length.(curves_all))
        times    = times_all[1][1:min_len]
        n_series = length(curves_all)
        curves   = Matrix{Float64}(undef, n_series, min_len)
        for (i, c) in enumerate(curves_all)
            curves[i, :] = c[1:min_len]
        end
    end

    # ------------------------------------------------------------------
    # Blank detection and subtraction
    # Annotated blanks are always excluded from clustering (already separated
    # during data loading above).  Auto-detected blanks are also always removed
    # from the clustering matrix once found — consistent with annotated behaviour.
    # Signal subtraction only happens when subtract_blank=true.
    # ------------------------------------------------------------------
    csv_mode = !isempty(body.csv) || !isempty(body.csv_path)

    # Auto blank detection is an explicit, user-requested step (auto_detect_blanks).
    # It runs only when no annotated blanks were supplied, and — unlike before — is
    # NOT silently suppressed by prescreen/trend: if the user requests it, it runs.
    # Detected blanks are removed from the clustering matrix (they never cluster),
    # matching annotated-blank behaviour.
    if Bool(body.auto_detect_blanks) && isempty(blank_curves_all)
        curves, labels_all, blank_curves_all, blank_labels_used, found =
            _auto_detect_and_split_blanks(curves, times, labels_all;
                range_thr = blank_range_thr, od_pct = blank_od_pct)
        if found
            blank_source = "auto"
            n_series     = length(labels_all)
        end
    end

    # Blank correction is performed separately within each loaded experiment: each
    # experiment's wells are corrected using only that experiment's own blanks.
    if subtract_blank && !isempty(blank_curves_all)
        curves = _subtract_blanks_per_experiment(curves, labels_all,
            blank_curves_all, blank_labels_used, blank_method, csv_mode)
    end

    # Replace NaN/Inf with column means before smoothing and clustering
    curves = _fill_nan_colmean(curves)

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

    # Preflight: mirror Kinbiont's constant-curve detector on the curves we are
    # about to send in. Only forward `cluster_prescreen_constant=true` if at
    # least one curve actually matches — otherwise Kinbiont reserves a sentinel
    # cluster nobody fills, which (in the sweep) inflates WCSS at small k and
    # produces misleading elbows.
    prescreen_mask = Bool(body.prescreen_constant) ?
        _prescreen_constant_mask(curves_for_cluster;
            tol_const = Float64(body.prescreen_tol_const),
            q_low     = prescreen_qlo,
            q_high    = prescreen_qhi) :
        nothing
    do_prescreen = prescreen_mask !== nothing && any(prescreen_mask)

    # ------------------------------------------------------------------
    # Clustering — delegate entirely to KinBiont preprocess
    # ------------------------------------------------------------------
    k_eff = min(k_input, n_series)
    cluster_opts = FitOptions(
        cluster                    = true,
        n_clusters                 = k_eff,
        cluster_method             = Symbol(cluster_method),
        cluster_trend_test         = Bool(body.trend_test_flat),
        cluster_trend_p_thr        = Float64(body.trend_p_thr),
        cluster_prescreen_constant = do_prescreen,
        cluster_tol_const          = Float64(body.prescreen_tol_const),
        cluster_q_low              = prescreen_qlo,
        cluster_q_high             = prescreen_qhi,
        cluster_hclust_linkage     = Symbol(hclust_linkage),
        cluster_dbscan_eps         = Float64(dbscan_eps),
        cluster_dbscan_minpts      = Int(dbscan_minpts),
        kmeans_n_init              = kmeans_n_init,
        kmeans_max_iters           = maxiter,
        kmeans_tol                 = tol,
    )
    gd_for_cluster = GrowthData(curves_for_cluster, times, labels_all)
    gd_clustered   = try
        preprocess(gd_for_cluster, cluster_opts)
    catch e
        return json(Dict("error" => "Clustering failed: $e"); status=400)
    end
    cluster_ids = gd_clustered.clusters

    # ------------------------------------------------------------------
    # Display curves (optionally z-scored)
    # ------------------------------------------------------------------
    raw_curves        = copy(curves_for_cluster)
    normalized_curves = copy(curves_for_cluster)
    for i in 1:n_series
        row = normalized_curves[i, :]
        s   = std(row)
        s > 1e-12 && (normalized_curves[i, :] = (row .- mean(row)) ./ s)
    end
    display_curves = normalize ? normalized_curves : raw_curves

    # Collect unique cluster ids (DBSCAN may produce arbitrary ids incl 0)
    unique_ids = sort(unique(cluster_ids))
    clusters = []
    for c in unique_ids
        mask = findall(cluster_ids .== c)
        isempty(mask) && continue
        label = c == 0 ? "Noise" : string(c)
        centroid, centroid_sd = _centroid_with_sd(display_curves, mask)
        centroid_raw, centroid_raw_sd = _centroid_with_sd(raw_curves, mask)
        centroid_norm, centroid_norm_sd = _centroid_with_sd(normalized_curves, mask)
        push!(clusters, Dict(
            "id"                     => c,
            "label"                  => label,
            "series_labels"          => labels_all[mask],
            "series_data_raw"        => [raw_curves[i, :] for i in mask],
            "series_data_normalized" => [normalized_curves[i, :] for i in mask],
            "centroid"               => centroid,
            "centroid_sd"            => centroid_sd,
            "centroid_raw"           => centroid_raw,
            "centroid_raw_sd"        => centroid_raw_sd,
            "centroid_normalized"    => centroid_norm,
            "centroid_normalized_sd" => centroid_norm_sd,
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
    X_for_qual_z = _zscore_rows(X_for_qual)
    quality = _cluster_quality_indices(X_for_qual_z, ids_remapped)

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

    # Per-series silhouette (same order as labels_all, null for noise/skipped)
    if quality["silhouettes"] !== nothing
        sil_vals       = quality["silhouettes"]
        sil_per_series = Vector{Union{Float64,Nothing}}(nothing, n_series)
        nonnoise_i     = findall(noise_mask)
        for (j, gi) in enumerate(nonnoise_i)
            sil_per_series[gi] = sil_vals[j]
        end
        quality["silhouettes"] = sil_per_series
    end
    quality["series_labels"] = labels_all

    return Dict(
        "time"             => times,
        "time_normalized"  => time_normalized,
        "clusters"         => clusters,
        "cluster_method"   => cluster_method,
        "smooth_method"    => string(smooth_method),
        "quality"          => quality,
        "assignments"      => cluster_ids,
        "series_labels"    => labels_all,
        "prescreen_applied" => do_prescreen,
        "blank_subtracted" => subtract_blank && !isempty(blank_curves_all),
        "blank_source"     => blank_source,
        "blank_wells_used" => blank_labels_used,
    )
end

# ------------------------------------------------------------------
# /api/cluster-sweep  — run clustering for k=1..k_max and return
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
    kmeans_n_init  = clamp(Int(body.kmeans_n_init), 1, 100)
    hclust_linkage = Symbol(body.hclust_linkage)

    # The sweep varies k, but DBSCAN has no k parameter — it is unavailable here.
    cluster_method == "dbscan" && return json(
        Dict("error" => "Cluster-sweep is unavailable for DBSCAN (it has no k parameter to sweep over)."); status=400)

    subtract_blank  = Bool(body.subtract_blank)
    blank_method    = string(body.blank_method)
    blank_range_thr = Float64(body.blank_range_thr)
    blank_od_pct    = Float64(body.blank_od_percentile)

    # Re-use the same data-loading logic as /api/cluster
    times_all  = Vector{Vector{Float64}}()
    curves_all = Vector{Vector{Float64}}()
    labels_all = Vector{String}()
    # Annotated blanks are separated during loading (as in /api/cluster) so the
    # selected blank correction can be applied consistently during the sweep.
    blank_curves_all  = Vector{Vector{Float64}}()
    blank_labels_used = Vector{String}()

    if !isempty(body.csv) || !isempty(body.csv_path)
        df = if !isempty(body.csv_path)
            p = body.csv_path
            isfile(p) || return json(Dict("error" => "File not found: $p"); status=400)
            CSV.read(p, DataFrame)
        else
            CSV.read(IOBuffer(body.csv), DataFrame)
        end
        ta, ca, la = _load_csv_curves(df)
        append!(times_all, ta); append!(curves_all, ca); append!(labels_all, la)
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
                    od = Float64[]
                    for val in gd_raw[!, well]
                        try push!(od, parse(Float64, string(val))) catch _ push!(od, NaN) end
                    end
                    if well in blank_wells
                        push!(blank_curves_all,  od)
                        push!(blank_labels_used, "$exp_name/$well")
                    else
                        push!(times_all,  time_numeric)
                        push!(curves_all, od)
                        push!(labels_all, "$exp_name/$well")
                    end
                end
            catch e
                @warn "Error loading $exp_name for sweep: $e"
            end
        end
    end

    isempty(curves_all) && return json(Dict("error" => "No data loaded"); status=400)

    do_interp     = Bool(body.interpolate)
    interp_n      = max(10, Int(body.interp_n))
    q_lo          = Float64(body.interp_quantile_lo)
    q_hi          = Float64(body.interp_quantile_hi)
    prescreen_qlo = Float64(body.prescreen_q_low)
    prescreen_qhi = Float64(body.prescreen_q_high)
    has_irregular = any(c -> any(isnan, c), curves_all)

    if do_interp
        grid = _build_interp_grid(times_all, interp_n, q_lo, q_hi)
        isempty(grid) && return json(Dict("error" => "Could not build interpolation grid"); status=400)
        curves   = _interpolate_to_grid(curves_all, times_all, grid)
        times    = grid
        n_series = size(curves, 1)

    elseif has_irregular
        clean_times  = Vector{Vector{Float64}}()
        clean_curves = Vector{Vector{Float64}}()
        valid_labels = Vector{String}()
        for i in eachindex(curves_all)
            ct, cy = _strip_nan_tail(times_all[i], curves_all[i])
            length(ct) < 2 && continue
            push!(clean_times,  ct)
            push!(clean_curves, cy)
            push!(valid_labels, labels_all[i])
        end
        isempty(clean_curves) &&
            return json(Dict("error" => "No valid curves after NaN removal"); status=400)
        igd        = IrregularGrowthData(clean_curves, clean_times, valid_labels; step=0.01)
        times      = igd.times
        n_series   = size(igd.curves, 1)
        curves     = igd.curves
        labels_all = valid_labels

    else
        min_len  = minimum(length.(curves_all))
        times    = times_all[1][1:min_len]
        n_series = length(curves_all)
        curves   = Matrix{Float64}(undef, n_series, min_len)
        for (i, c) in enumerate(curves_all)
            curves[i, :] = c[1:min_len]
        end
    end

    # Blank handling — applied consistently with /api/cluster so the selected
    # correction is honoured during the sweep. Auto-detect (when requested and no
    # annotated blanks) removes blanks from the matrix; per-experiment subtraction
    # corrects each experiment's wells with that experiment's own blanks.
    csv_mode = !isempty(body.csv) || !isempty(body.csv_path)
    if Bool(body.auto_detect_blanks) && isempty(blank_curves_all)
        curves, labels_all, blank_curves_all, blank_labels_used, found =
            _auto_detect_and_split_blanks(curves, times, labels_all;
                range_thr = blank_range_thr, od_pct = blank_od_pct)
        found && (n_series = length(labels_all))
    end
    if subtract_blank && !isempty(blank_curves_all)
        curves = _subtract_blanks_per_experiment(curves, labels_all,
            blank_curves_all, blank_labels_used, blank_method, csv_mode)
    end

    # Replace NaN/Inf with column means before smoothing — matches /api/cluster.
    # Without this, any NaN cell makes every per-k preprocess() call throw inside
    # the `try ... continue` below, and the response silently collapses to
    # {"sweep": []} with no error message.
    curves = _fill_nan_colmean(curves)

    # Smooth once, then sweep over k. Match /api/cluster: when the smoother
    # shortens the series (rolling_avg drops smooth_pt_avg-1 points), update
    # `times` to match so the per-k GrowthData(curves_for, times, ...) calls
    # below don't fail on a dimension mismatch.
    if smooth_method != :none
        gd_smooth   = GrowthData(curves, times, labels_all)
        smooth_opts = FitOptions(smooth=true, smooth_method=smooth_method,
                                 lowess_frac=lowess_frac,
                                 gaussian_h_mult=gaussian_hmult, cluster=false)
        gd_proc    = preprocess(gd_smooth, smooth_opts)
        tlen       = min(size(gd_proc.curves, 2), length(times))
        curves_for = gd_proc.curves[:, 1:tlen]
        times      = gd_proc.times[1:tlen]
    else
        curves_for = curves
    end
    # Same preflight as /api/cluster: only ask Kinbiont to reserve a sentinel
    # cluster when there is actually something to put in it.
    prescreen_mask = Bool(body.prescreen_constant) ?
        _prescreen_constant_mask(curves_for;
            tol_const = Float64(body.prescreen_tol_const),
            q_low     = prescreen_qlo,
            q_high    = prescreen_qhi) :
        nothing
    do_prescreen = prescreen_mask !== nothing && any(prescreen_mask)
    sweep_results = []
    for k in 1:min(k_max, n_series)
        prescreen_for_k = k > 1 && do_prescreen
        gd_sw   = GrowthData(curves_for, times, labels_all)
        sw_opts = FitOptions(
            cluster                    = true,
            n_clusters                 = k,
            cluster_method             = Symbol(cluster_method),
            cluster_trend_test         = Bool(body.trend_test_flat),
            cluster_trend_p_thr        = Float64(body.trend_p_thr),
            cluster_prescreen_constant = prescreen_for_k,
            cluster_tol_const          = Float64(body.prescreen_tol_const),
            cluster_q_low              = prescreen_qlo,
            cluster_q_high             = prescreen_qhi,
            cluster_hclust_linkage     = hclust_linkage,
            kmeans_n_init              = kmeans_n_init,
            kmeans_max_iters           = maxiter,
            kmeans_tol                 = tol,
        )
        gd_result = try
            preprocess(gd_sw, sw_opts)
        catch e
            @warn "Sweep k=$k error: $e"
            continue
        end
        ids   = gd_result.clusters
        wcss  = something(gd_result.wcss, 0.0)

        # At k=1 every quality index is undefined (silhouette, Dunn, Davies-Bouldin,
        # Calinski-Harabasz and Xie-Beni all need ≥ 2 clusters). Skip the call so
        # we don't pay for the n×n pairwise-distance allocation that
        # `_cluster_quality_indices` does internally before short-circuiting.
        # WCSS is still emitted (computed above) — that is what the elbow uses
        # at k=1 as its baseline.
        q = if k < 2
            Dict{String,Any}(
                "silhouette_mean"   => nothing,
                "dunn"              => nothing,
                "davies_bouldin"    => nothing,
                "calinski_harabasz" => nothing,
                "xie_beni"          => nothing,
            )
        else
            ids_r, _ = _remap_ids(ids)
            zscored  = _zscore_rows(curves_for)
            _cluster_quality_indices(zscored, ids_r)
        end
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

    return sanitize_for_json(Dict("sweep" => sweep_results))
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

        importance      = Dict{String,Any}()
        perm_importance = Dict{String,Any}()
        pdp             = Dict{String,Any}()
        cv_r2           = Dict{String,Any}()
        for pname in param_names
            pcol = findfirst(==(pname), all_params)
            pcol === nothing && continue
            rankings, model, Xm = forest_importance(param_mat, feat_mat, pcol, feature_names)
            importance[pname] = rankings
            # Predictive-performance companion: 5-fold CV R² with the same
            # RF hyperparameters as the importance run.
            cv = cv_r2_score(param_mat, feat_mat, pcol)
            cv_r2[pname] = Dict{String,Any}(
                "mean"  => cv.mean,
                "std"   => cv.std,
                "folds" => cv.folds,
                "n"     => cv.n,
            )
            (isempty(rankings) || model === nothing) && continue
            # Permutation importance for the same forest, computed on the
            # training matrix already produced by forest_importance — no
            # refit. Surfaces feature-collinearity effects that the
            # impurity ranking can mask.
            ym = param_mat[:, pcol]
            mask = .!isnan.(ym) .& all(.!isnan.(feat_mat), dims=2)[:]
            ym_train = ym[mask]
            perm_importance[pname] = forest_permutation_importance(
                model, Xm, ym_train, feature_names,
            )
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

        return sanitize_for_json(Dict(
            "correlations"           => corr,
            "importance"             => importance,
            "permutation_importance" => perm_importance,
            "cv_r2"                  => cv_r2,
            "pdp"                    => pdp,
            "n_wells"                => nrow(joined),
        ))
    catch e
                return json(Dict("error" => "ML analysis failed: $e"); status=500)
    end
end
