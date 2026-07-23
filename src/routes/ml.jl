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
    derive_non_growing_blanks = Bool(body.derive_non_growing_blanks)
    blank_method   = string(body.blank_method)

    if derive_non_growing_blanks &&
       !Bool(body.prescreen_constant) && !Bool(body.trend_test_flat)
        return json(Dict("error" =>
            "Blank derivation requires the non-growing pre-screen, the trend test, or both"); status=400)
    end

    times_all        = Vector{Vector{Float64}}()
    curves_all       = Vector{Vector{Float64}}()
    labels_all       = Vector{String}()
    sample_groups    = Vector{String}()
    # For experiment mode: store blank curves separately for subtraction
    blank_curves_all  = Vector{Vector{Float64}}()
    blank_times_all   = Vector{Vector{Float64}}()
    blank_groups_all  = Vector{String}()
    blank_labels_used = Vector{String}()
    blank_source      = "none"   # "annotated" | "auto" | "none"
    blank_subtraction_applied = false
    blank_uncorrected_groups = String[]

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
        append!(sample_groups, fill("uploaded_matrix", length(la)))
    else
        for exp_name in body.experiments
            data_file       = joinpath(CLEAN_DATA_PATH, exp_name, "data_channel_1.csv")
            annotation_file = joinpath(CLEAN_DATA_PATH, exp_name, "annotation_clean.csv")
            isfile(data_file) || continue
            try
                gd_raw      = CSV.read(data_file, DataFrame, header=1, silencewarnings=true)
                excluded_wells = Set{String}()
                annotated_blanks = Set{String}()
                if isfile(annotation_file)
                    ann = read_annotation_file(annotation_file)
                    excluded_wells = get_blank_wells(ann)
                    annotated_blanks = Set(get_blank_well_names(ann))
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
                    if well in excluded_wells
                        if well in annotated_blanks
                            push!(blank_curves_all, od)
                            push!(blank_times_all, time_numeric)
                            push!(blank_groups_all, exp_name)
                            push!(blank_labels_used, "$exp_name/$well")
                        end
                    else
                        push!(times_all,  time_numeric)
                        push!(curves_all, od)
                        push!(labels_all, "$exp_name/$well")
                        push!(sample_groups, exp_name)
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

    # Pair annotated blanks with samples from the same experiment and align the
    # blank traces to each sample's real time grid before any global resampling.
    annotated_blanks = !isempty(blank_curves_all)
    if subtract_blank && annotated_blanks && !derive_non_growing_blanks
        curves_all, corrected_mask = Kinbiont.apply_grouped_blank_subtraction(
            curves_all, times_all, sample_groups,
            blank_curves_all, blank_times_all, blank_groups_all;
            method=Symbol(blank_method),
            floor=1e-4,
        )
        blank_subtraction_applied = any(corrected_mask)
        blank_uncorrected_groups = sort(unique(sample_groups[.!corrected_mask]))
    end

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
        grid = Kinbiont.common_time_grid(times_all;
            n_grid=interp_n, q_low=q_lo, q_high=q_hi)
        if isempty(grid)
            return json(Dict("error" => "Could not build interpolation grid"); status=400)
        end
        curves_interp = Kinbiont.interpolate_curves_to_grid(curves_all, times_all, grid)
        times    = grid
        n_series = size(curves_interp, 1)
        curves   = curves_interp

    elseif has_irregular
        # Strip NaN tails, then use KinBiont IrregularGrowthData to resample
        # each curve onto a normalized [0, 1] union grid.
        clean_times  = Vector{Vector{Float64}}()
        clean_curves = Vector{Vector{Float64}}()
        valid_labels = Vector{String}()
        valid_groups = Vector{String}()
        for i in eachindex(curves_all)
            ct, cy = _strip_nan_tail(times_all[i], curves_all[i])
            length(ct) < 2 && continue
            push!(clean_times,  ct)
            push!(clean_curves, cy)
            push!(valid_labels, labels_all[i])
            push!(valid_groups, sample_groups[i])
        end
        isempty(clean_curves) &&
            return json(Dict("error" => "No valid curves after NaN removal"); status=400)
        igd          = IrregularGrowthData(clean_curves, clean_times, valid_labels; step=0.01)
        times        = igd.times
        n_series     = size(igd.curves, 1)
        curves       = igd.curves
        labels_all   = valid_labels
        sample_groups = valid_groups
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
    # Annotated blanks are excluded during loading. Optional derived blanks are
    # selected below by the same non-growing controls used by clustering.
    # ------------------------------------------------------------------
    # Replace NaN/Inf with column means before smoothing and clustering
    curves = Kinbiont.fill_nonfinite_colmean(curves)

    # Detect on the selected clustering signal, but derive and subtract each
    # experiment's blank trace from the unsmoothed aligned measurements.
    if derive_non_growing_blanks
        detector_curves, detector_times = _smooth_clustering_curves(
            curves, times, labels_all;
            method=smooth_method,
            lowess_frac=lowess_frac,
            gaussian_h_mult=gaussian_hmult,
        )
        derived = Kinbiont.derive_blank_from_non_growing(
            curves, times, labels_all, sample_groups,
            detector_curves, detector_times;
            annotated_blank_curves=blank_curves_all,
            annotated_blank_times=blank_times_all,
            annotated_blank_groups=blank_groups_all,
            annotated_blank_labels=blank_labels_used,
            prescreen_constant=Bool(body.prescreen_constant),
            trend_test=Bool(body.trend_test_flat),
            prescreen_tol=Float64(body.prescreen_tol_const),
            prescreen_q_low=prescreen_qlo,
            prescreen_q_high=prescreen_qhi,
            trend_p_threshold=Float64(body.trend_p_thr),
            blank_method=Symbol(blank_method),
            blank_floor=1e-4,
        )
        isempty(derived.derived_indices) && return json(Dict(
            "error" => "No non-growing curves were detected for blank derivation"
        ); status=400)
        isempty(derived.labels) && return json(Dict(
            "error" => "No sample curves remain after blank derivation"
        ); status=400)
        curves = Kinbiont.fill_nonfinite_colmean(derived.curves)
        labels_all = derived.labels
        sample_groups = derived.groups
        blank_labels_used = derived.blank_labels
        blank_source = annotated_blanks ? "annotated+derived" : "derived"
        blank_subtraction_applied = any(derived.corrected_mask)
        blank_uncorrected_groups = sort(unique(sample_groups[.!derived.corrected_mask]))
        n_series = size(curves, 1)
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

    # Record the same union Kinbiont uses so the response can identify the
    # non-growing cluster and offer the second-pass blank derivation action.
    non_growing_indices = derive_non_growing_blanks ? Int[] :
        Kinbiont.detect_non_growing_indices(
            curves_for_cluster, times;
            prescreen_constant=Bool(body.prescreen_constant),
            trend_test=Bool(body.trend_test_flat),
            prescreen_tol=Float64(body.prescreen_tol_const),
            prescreen_q_low=prescreen_qlo,
            prescreen_q_high=prescreen_qhi,
            trend_p_threshold=Float64(body.trend_p_thr),
        )
    non_growing_mask = falses(n_series)
    non_growing_mask[non_growing_indices] .= true
    do_prescreen = !derive_non_growing_blanks && Bool(body.prescreen_constant) &&
                   !isempty(non_growing_indices)

    # ------------------------------------------------------------------
    # Clustering — delegate entirely to KinBiont preprocess
    # ------------------------------------------------------------------
    k_eff = min(k_input, n_series)
    cluster_opts = FitOptions(
        cluster                    = true,
        n_clusters                 = k_eff,
        cluster_method             = Symbol(cluster_method),
        cluster_trend_test         = !derive_non_growing_blanks && Bool(body.trend_test_flat),
        cluster_trend_p_thr        = Float64(body.trend_p_thr),
        cluster_prescreen_constant = !derive_non_growing_blanks && Bool(body.prescreen_constant),
        cluster_tol_const          = Float64(body.prescreen_tol_const),
        cluster_q_low              = prescreen_qlo,
        cluster_q_high             = prescreen_qhi,
        cluster_hclust_linkage     = Symbol(hclust_linkage),
        cluster_dbscan_eps         = Float64(dbscan_eps),
        cluster_dbscan_minpts      = Int(dbscan_minpts),
        kmeans_seed                = 42,
        kmedoids_seed              = 42,
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
            "is_non_growing"         => !derive_non_growing_blanks && all(non_growing_mask[mask]),
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
        "wcss"             => something(gd_clustered.wcss, 0.0),
        "cost_metric"      => "wcss",
        "smooth_method"    => string(smooth_method),
        "quality"          => quality,
        "assignments"      => cluster_ids,
        "series_labels"    => labels_all,
        "prescreen_applied" => do_prescreen,
        "derived_non_growing_blanks" => derive_non_growing_blanks,
        "blank_subtracted" => blank_subtraction_applied,
        "blank_source"     => blank_source,
        "blank_wells_used" => blank_labels_used,
        "blank_uncorrected_experiments" => blank_uncorrected_groups,
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
    cluster_method == "dbscan" && return json(Dict(
        "error" => "Cluster-number sweep is unavailable for DBSCAN because DBSCAN does not use k"
    ); status=400)
    maxiter        = Int(body.maxiter)
    tol            = Float64(body.tol)
    kmeans_n_init  = clamp(Int(body.kmeans_n_init), 1, 100)
    hclust_linkage = Symbol(body.hclust_linkage)
    subtract_blank = Bool(body.subtract_blank)
    derive_non_growing_blanks = Bool(body.derive_non_growing_blanks)
    blank_method   = string(body.blank_method)
    if derive_non_growing_blanks &&
       !Bool(body.prescreen_constant) && !Bool(body.trend_test_flat)
        return json(Dict("error" =>
            "Blank derivation requires the non-growing pre-screen, the trend test, or both"); status=400)
    end

    # Re-use the same data-loading logic as /api/cluster
    times_all  = Vector{Vector{Float64}}()
    curves_all = Vector{Vector{Float64}}()
    labels_all = Vector{String}()
    sample_groups = Vector{String}()
    blank_curves_all = Vector{Vector{Float64}}()
    blank_times_all = Vector{Vector{Float64}}()
    blank_groups_all = Vector{String}()
    blank_labels_all = Vector{String}()

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
        append!(sample_groups, fill("uploaded_matrix", length(la)))
    else
        for exp_name in body.experiments
            data_file       = joinpath(CLEAN_DATA_PATH, exp_name, "data_channel_1.csv")
            annotation_file = joinpath(CLEAN_DATA_PATH, exp_name, "annotation_clean.csv")
            isfile(data_file) || continue
            try
                gd_raw      = CSV.read(data_file, DataFrame, header=1, silencewarnings=true)
                excluded_wells = Set{String}()
                blank_wells = Set{String}()
                if isfile(annotation_file)
                    ann = read_annotation_file(annotation_file)
                    excluded_wells = get_blank_wells(ann)
                    blank_wells = Set(get_blank_well_names(ann))
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
                    if well in excluded_wells
                        if well in blank_wells
                            push!(blank_curves_all, od)
                            push!(blank_times_all, time_numeric)
                            push!(blank_groups_all, exp_name)
                            push!(blank_labels_all, "$exp_name/$well")
                        end
                    else
                        push!(times_all,  time_numeric)
                        push!(curves_all, od)
                        push!(labels_all, "$exp_name/$well")
                        push!(sample_groups, exp_name)
                    end
                end
            catch e
                @warn "Error loading $exp_name for sweep: $e"
            end
        end
    end

    isempty(curves_all) && return json(Dict("error" => "No data loaded"); status=400)

    annotated_blanks = !isempty(blank_curves_all)
    if subtract_blank && annotated_blanks && !derive_non_growing_blanks
        curves_all, _ = Kinbiont.apply_grouped_blank_subtraction(
            curves_all, times_all, sample_groups,
            blank_curves_all, blank_times_all, blank_groups_all;
            method=Symbol(blank_method),
            floor=1e-4,
        )
    end

    do_interp     = Bool(body.interpolate)
    interp_n      = max(10, Int(body.interp_n))
    q_lo          = Float64(body.interp_quantile_lo)
    q_hi          = Float64(body.interp_quantile_hi)
    prescreen_qlo = Float64(body.prescreen_q_low)
    prescreen_qhi = Float64(body.prescreen_q_high)
    has_irregular = any(c -> any(isnan, c), curves_all)

    if do_interp
        grid = Kinbiont.common_time_grid(times_all;
            n_grid=interp_n, q_low=q_lo, q_high=q_hi)
        isempty(grid) && return json(Dict("error" => "Could not build interpolation grid"); status=400)
        curves   = Kinbiont.interpolate_curves_to_grid(curves_all, times_all, grid)
        times    = grid
        n_series = size(curves, 1)

    elseif has_irregular
        clean_times  = Vector{Vector{Float64}}()
        clean_curves = Vector{Vector{Float64}}()
        valid_labels = Vector{String}()
        valid_groups = Vector{String}()
        for i in eachindex(curves_all)
            ct, cy = _strip_nan_tail(times_all[i], curves_all[i])
            length(ct) < 2 && continue
            push!(clean_times,  ct)
            push!(clean_curves, cy)
            push!(valid_labels, labels_all[i])
            push!(valid_groups, sample_groups[i])
        end
        isempty(clean_curves) &&
            return json(Dict("error" => "No valid curves after NaN removal"); status=400)
        igd        = IrregularGrowthData(clean_curves, clean_times, valid_labels; step=0.01)
        times      = igd.times
        n_series   = size(igd.curves, 1)
        curves     = igd.curves
        labels_all = valid_labels
        sample_groups = valid_groups

    else
        min_len  = minimum(length.(curves_all))
        times    = times_all[1][1:min_len]
        n_series = length(curves_all)
        curves   = Matrix{Float64}(undef, n_series, min_len)
        for (i, c) in enumerate(curves_all)
            curves[i, :] = c[1:min_len]
        end
    end

    # Replace NaN/Inf with column means before smoothing — matches /api/cluster
    # (ml.jl:175). Without this, any NaN cell makes every per-k preprocess() call
    # throw inside the `try ... continue` below, and the response silently
    # collapses to {"sweep": []} with no error message.
    # Blank derivation below uses the same experiment-local policy as /api/cluster.
    curves = Kinbiont.fill_nonfinite_colmean(curves)

    if derive_non_growing_blanks
        detector_curves, detector_times = _smooth_clustering_curves(
            curves, times, labels_all;
            method=smooth_method,
            lowess_frac=lowess_frac,
            gaussian_h_mult=gaussian_hmult,
        )
        derived = Kinbiont.derive_blank_from_non_growing(
            curves, times, labels_all, sample_groups,
            detector_curves, detector_times;
            annotated_blank_curves=blank_curves_all,
            annotated_blank_times=blank_times_all,
            annotated_blank_groups=blank_groups_all,
            annotated_blank_labels=blank_labels_all,
            prescreen_constant=Bool(body.prescreen_constant),
            trend_test=Bool(body.trend_test_flat),
            prescreen_tol=Float64(body.prescreen_tol_const),
            prescreen_q_low=prescreen_qlo,
            prescreen_q_high=prescreen_qhi,
            trend_p_threshold=Float64(body.trend_p_thr),
            blank_method=Symbol(blank_method),
            blank_floor=1e-4,
        )
        isempty(derived.derived_indices) && return json(Dict(
            "error" => "No non-growing curves were detected for blank derivation"
        ); status=400)
        isempty(derived.labels) && return json(Dict(
            "error" => "No sample curves remain after blank derivation"
        ); status=400)
        curves = Kinbiont.fill_nonfinite_colmean(derived.curves)
        labels_all = derived.labels
        sample_groups = derived.groups
        n_series = size(curves, 1)
    end

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
    sweep_results = []
    for k in 1:min(k_max, n_series)
        prescreen_for_k = !derive_non_growing_blanks && k > 1 &&
                          Bool(body.prescreen_constant)
        gd_sw   = GrowthData(curves_for, times, labels_all)
        sw_opts = FitOptions(
            cluster                    = true,
            n_clusters                 = k,
            cluster_method             = Symbol(cluster_method),
            cluster_trend_test         = !derive_non_growing_blanks && Bool(body.trend_test_flat),
            cluster_trend_p_thr        = Float64(body.trend_p_thr),
            cluster_prescreen_constant = prescreen_for_k,
            cluster_tol_const          = Float64(body.prescreen_tol_const),
            cluster_q_low              = prescreen_qlo,
            cluster_q_high             = prescreen_qhi,
            cluster_hclust_linkage     = hclust_linkage,
            kmeans_seed                = 42,
            kmedoids_seed              = 42,
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
        cluster_cost = something(gd_result.wcss, 0.0)
        cost_metric = "wcss"

        # At k=1 every quality index is undefined (silhouette, Dunn, Davies-Bouldin,
        # Calinski-Harabasz and Xie-Beni all need ≥ 2 clusters). Skip the call so
        # we don't pay for the n×n pairwise-distance allocation that
        # `_cluster_quality_indices` does internally before short-circuiting.
        # The method-independent WCSS is still emitted as the k=1 baseline
        # used by the elbow diagnostic.
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
            "cost"              => cluster_cost,
            "cost_metric"       => cost_metric,
            "wcss"              => cluster_cost, # backwards-compatible key
            "silhouette_mean"   => q["silhouette_mean"],
            "dunn"              => q["dunn"],
            "davies_bouldin"    => q["davies_bouldin"],
            "calinski_harabasz" => q["calinski_harabasz"],
            "xie_beni"          => q["xie_beni"],
        ))
    end

    cost_metric = "wcss"
    return sanitize_for_json(Dict(
        "sweep" => sweep_results,
        "cost_metric" => cost_metric,
    ))
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
