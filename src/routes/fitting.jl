const BATCH_JOBS      = Dict{String, Dict{String, Any}}()
const BATCH_JOBS_LOCK = ReentrantLock()

function _resolve_parametric_smoothing(body)
    raw_method = lowercase(strip(string(body.smooth_method)))
    method = isempty(raw_method) ? (body.smooth ? :boxcar : :none) : Symbol(raw_method)
    valid = (:none, :rolling_avg, :lowess, :gaussian, :boxcar)
    error = method in valid ? nothing : "Unknown smoothing method: $(raw_method)"
    window = body.smooth_window
    pt_avg = clamp(body.smooth_pt_avg, 3, 99)
    lowess_frac = clamp(body.lowess_frac, 0.01, 1.0)
    gaussian_h_mult = clamp(body.gaussian_h_mult, 0.1, 20.0)
    if error === nothing && method == :boxcar && (window < 3 || iseven(window))
        error = "Smoothing window must be an odd integer greater than or equal to 3"
    end
    return (
        method=method,
        enabled=method != :none,
        window=window,
        pt_avg=pt_avg,
        lowess_frac=lowess_frac,
        gaussian_h_mult=gaussian_h_mult,
        error=error,
    )
end

@post "/api/fit-curve" function(req::HTTP.Request, body::Json{FitCurveRequest})
    body = body.payload
    experiment     = string(body.experiment)
    well           = string(body.well)
    subtract_blank = body.blank_subtraction
    blank_method   = string(body.blank_method)
    override_blank_wells = String[string(w) for w in body.override_blank_wells]
    model_name     = string(body.model_name)
    model_names    = String[string(m) for m in body.model_names]
    optimizer      = string(body.optimizer)
    det_opts       = String[string(o) for o in body.deterministic_optimizers]
    sto_opts       = String[string(o) for o in body.stochastic_optimizers]
    sto_runs       = max(1, body.stochastic_runs)
    maxiters       = clamp(body.maxiters > 0 ? body.maxiters : DEFAULT_FIT_MAXITERS, 1, MAX_FIT_MAXITERS)
    abstol         = body.abstol > 0.0 ? body.abstol : 0.0
    smoothing      = _resolve_parametric_smoothing(body)
    compute_loglin = body.compute_loglin
    ll_smoothing   = string(body.loglin_type_of_smoothing)
    ll_pt_avg      = max(1, body.loglin_pt_avg)
    ll_pt_deriv    = max(2, body.loglin_pt_smoothing_derivative)
    ll_pt_min_win  = max(3, body.loglin_pt_min_size_of_win)
    ll_win_type    = string(body.loglin_type_of_win)
    ll_thr_exp     = clamp(body.loglin_threshold_of_exp, 0.0, 1.0)
    ll_start_thr   = max(0.0, body.loglin_start_exp_win_thr)
    ll_thr_lowess  = body.loglin_thr_lowess
    ll_gaussian    = clamp(body.loglin_gaussian_h_mult, 0.1, 20.0)

    if smoothing.error !== nothing
        return json(Dict("error" => smoothing.error); status=400)
    end

    data_file        = joinpath(CLEAN_DATA_PATH, experiment, "data_channel_1.csv")
    annotation_file  = joinpath(CLEAN_DATA_PATH, experiment, "annotation_clean.csv")
    calibration_file = get_calibration_file(experiment; override=string(body.calibration_file))

    if isempty(model_names)
        if !haskey(MODEL_REGISTRY, model_name)
            return json(Dict("error" => "Unknown model: $model_name"); status=400)
        end
    else
        unknown = filter(m -> !haskey(MODEL_REGISTRY, m), model_names)
        if !isempty(unknown)
            return json(Dict("error" => "Unknown models: $(join(unknown, ", "))"); status=400)
        end
    end

    if !isfile(data_file) || !isfile(annotation_file)
        return json(Dict("error" => "Data files not found"); status=404)
    end

    try
        growth_data      = CSV.read(data_file, DataFrame, header=1, silencewarnings=true)
        annotations      = read_annotation_file(annotation_file)
        excluded_wells   = get_blank_wells(annotations)   # "b" + "X"
        column_names_str = string.(names(growth_data))
        blank_well_names = resolve_blank_wells(growth_data, annotations, override_blank_wells)

        if !(well in column_names_str)
            return json(Dict("error" => "Well '$well' not found"); status=404)
        end
        if well in excluded_wells
            return json(Dict("error" => "Well '$well' is a blank well"); status=400)
        end

        time_numeric     = parse_time_column(growth_data)
        od_raw           = parse_od_column(growth_data, Symbol(well))
        blank_value      = compute_blank_value(growth_data, blank_well_names)
        blank_timeseries = (subtract_blank && blank_method == "pointbypoint") ?
            compute_blank_timeseries(growth_data, blank_well_names) : Float64[]

        valid_indices = findall(.!isnan.(od_raw))
        if length(valid_indices) < 10
            return json(Dict("error" => "Not enough valid data points for fitting"); status=400)
        end

        # Align blank timeseries to valid indices if computed
        blank_ts_valid = isempty(blank_timeseries) ? Float64[] : blank_timeseries[valid_indices]

        return fit_well_data(
            time_numeric[valid_indices], od_raw[valid_indices],
            blank_value, calibration_file, well, experiment;
            subtract_blank                  = subtract_blank,
            blank_method                    = blank_method,
            blank_timeseries                = blank_ts_valid,
            blank_well_names                = blank_well_names,
            model_name                      = model_name,
            model_names                     = model_names,
            optimizer                       = optimizer,
            deterministic_optimizers        = det_opts,
            stochastic_optimizers           = sto_opts,
            stochastic_runs                 = sto_runs,
            maxiters                        = maxiters,
            abstol                          = abstol,
            smooth                          = smoothing.enabled,
            smooth_window                   = smoothing.window,
            smooth_method                   = smoothing.method,
            smooth_pt_avg                   = smoothing.pt_avg,
            lowess_frac                     = smoothing.lowess_frac,
            gaussian_h_mult                 = smoothing.gaussian_h_mult,
            compute_loglin                  = compute_loglin,
            loglin_type_of_smoothing         = ll_smoothing,
            loglin_pt_avg                   = ll_pt_avg,
            loglin_pt_smoothing_derivative  = ll_pt_deriv,
            loglin_pt_min_size_of_win       = ll_pt_min_win,
            loglin_type_of_win               = ll_win_type,
            loglin_threshold_of_exp         = ll_thr_exp,
            loglin_start_exp_win_thr         = ll_start_thr,
            loglin_thr_lowess                = ll_thr_lowess,
            loglin_gaussian_h_mult           = ll_gaussian,
        )
    catch e
                return json(Dict("error" => "Curve fitting failed: $e"); status=500)
    end
end

@post "/api/fit-replicate" function(req::HTTP.Request, body::Json{FitReplicateRequest})
    body = body.payload
    well_selections  = body.well_selections
    label            = string(body.label)
    experiment_name  = string(body.experiment)
    model_name       = string(body.model_name)
    optimizer        = string(body.optimizer)
    det_opts         = String[string(o) for o in body.deterministic_optimizers]
    sto_opts         = String[string(o) for o in body.stochastic_optimizers]
    sto_runs         = max(1, body.stochastic_runs)
    maxiters         = clamp(body.maxiters > 0 ? body.maxiters : DEFAULT_FIT_MAXITERS, 1, MAX_FIT_MAXITERS)
    abstol           = body.abstol > 0.0 ? body.abstol : 0.0
    smoothing        = _resolve_parametric_smoothing(body)
    calibration_file = "./cal_curve_avg.csv"

    if smoothing.error !== nothing
        return json(Dict("error" => smoothing.error); status=400)
    end

    if !haskey(MODEL_REGISTRY, model_name)
        return json(Dict("error" => "Unknown model: $model_name"); status=400)
    end

    try
        all_od_data   = Vector{Vector{Float64}}()
        all_time_data = Vector{Vector{Float64}}()

        for sel in well_selections
            exp     = string(sel.experiment)
            well    = string(sel.well)
            channel = Int(sel.channel)

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
            return json(Dict("error" => "No valid well data found"); status=400)
        end

        # Average across wells (align by minimum length)
        min_len  = minimum(length.(all_od_data))
        avg_time = all_time_data[1][1:min_len]
        avg_od   = sum(od[1:min_len] for od in all_od_data) ./ length(all_od_data)

        valid_indices = findall(.!isnan.(avg_od))
        if length(valid_indices) < 10
            return json(Dict("error" => "Not enough valid data points for fitting"); status=400)
        end

        return fit_well_data(
            avg_time[valid_indices], avg_od[valid_indices],
            0.0, calibration_file, label, experiment_name;
            model_name               = model_name,
            optimizer                = optimizer,
            deterministic_optimizers = det_opts,
            stochastic_optimizers    = sto_opts,
            stochastic_runs          = sto_runs,
            maxiters                 = maxiters,
            abstol                   = abstol,
            smooth                   = smoothing.enabled,
            smooth_window            = smoothing.window,
            smooth_method            = smoothing.method,
            smooth_pt_avg            = smoothing.pt_avg,
            lowess_frac              = smoothing.lowess_frac,
            gaussian_h_mult          = smoothing.gaussian_h_mult,
        )
    catch e
                return json(Dict("error" => "Replicate fitting failed: $e"); status=500)
    end
end

@post "/api/blank-analysis" function(req::HTTP.Request)
    request_data = JSON3.read(String(req.body))
    experiment = string(request_data.experiment)
    well       = string(request_data.well)

    data_file       = joinpath(CLEAN_DATA_PATH, experiment, "data_channel_1.csv")
    annotation_file = joinpath(CLEAN_DATA_PATH, experiment, "annotation_clean.csv")

    if !isfile(data_file)
        return json(Dict("error" => "Data file not found"); status=404)
    end

    try
        growth_data = CSV.read(data_file, DataFrame, header=1, silencewarnings=true)

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
            return Dict(
                "has_blank_wells"      => false,
                "blank_wells"          => String[],
                "blank_value"          => 0.0,
                "recommendation"       => "none",
                "auto_detected_wells"  => auto_wells,
                "message"              => isempty(auto_wells)
                    ? "No blank wells found in annotation and none could be detected automatically."
                    : "No blank wells annotated. Auto-detected $(length(auto_wells)) candidate blank well(s) based on flat curve and low OD: $(join(auto_wells, ", ")).",
            )
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
                "note" => "$(round(Int, frac_below_global*100))% of points below blank — clipping to the positive floor may distort the initial phase of the fit.")
        else
            method_notes["clip"] = Dict("status" => "ok",
                "note" => "$(round(Int, frac_below_global*100))% of points below blank — clipping will set early points to the positive floor.")
        end

        # Overall recommendation
        recommendation = if frac_below_pbp < frac_below_global && frac_below_pbp < 0.3
            "pointbypoint"
        elseif frac_below_global < 0.1 && min_global > -0.02
            "shift"
        else
            "pointbypoint"
        end

        return Dict(
            "has_blank_wells"      => true,
            "blank_wells"          => blank_well_names,
            "blank_value"          => blank_value,
            "frac_below_global"    => frac_below_global,
            "frac_below_pbp"       => frac_below_pbp,
            "min_corrected_global" => min_global,
            "min_corrected_pbp"    => min_pbp,
            "recommendation"       => recommendation,
            "method_notes"         => method_notes,
        )
    catch e
                return json(Dict("error" => "Blank analysis failed: $e"); status=500)
    end
end

@post "/api/batch-fit" function(req::HTTP.Request, body::Json{BatchFitRequest})
    body = body.payload
    experiment      = string(body.experiment)
    model_name      = string(body.model_name)
    model_names_req = String[string(m) for m in body.model_names]
    subtract_blank  = body.blank_subtraction
    blank_method    = string(body.blank_method)
    override_blank_wells = String[string(w) for w in body.override_blank_wells]
    cal_override    = string(body.calibration_file)
    requested_wells = isempty(body.wells) ? nothing : String[string(w) for w in body.wells]
    optimizer       = string(body.optimizer)
    det_opts        = String[string(o) for o in body.deterministic_optimizers]
    sto_opts        = String[string(o) for o in body.stochastic_optimizers]
    sto_runs        = max(1, body.stochastic_runs)
    flat_thr        = max(0.0, body.skip_flat_threshold)
    maxiters        = clamp(body.maxiters > 0 ? body.maxiters : DEFAULT_FIT_MAXITERS, 1, MAX_FIT_MAXITERS)
    abstol          = body.abstol > 0.0 ? body.abstol : 0.0
    smoothing       = _resolve_parametric_smoothing(body)
    compute_loglin  = body.compute_loglin
    ll_smoothing    = string(body.loglin_type_of_smoothing)
    ll_pt_avg       = max(1, body.loglin_pt_avg)
    ll_pt_deriv     = max(2, body.loglin_pt_smoothing_derivative)
    ll_pt_min_win   = max(3, body.loglin_pt_min_size_of_win)
    ll_win_type     = string(body.loglin_type_of_win)
    ll_thr_exp      = clamp(body.loglin_threshold_of_exp, 0.0, 1.0)
    ll_start_thr    = max(0.0, body.loglin_start_exp_win_thr)
    ll_thr_lowess   = body.loglin_thr_lowess
    ll_gaussian     = clamp(body.loglin_gaussian_h_mult, 0.1, 20.0)

    if smoothing.error !== nothing
        return json(Dict("error" => smoothing.error); status=400)
    end

    if isempty(model_names_req)
        if !haskey(MODEL_REGISTRY, model_name)
            return json(Dict("error" => "Unknown model: $model_name"); status=400)
        end
    else
        unknown = filter(m -> !haskey(MODEL_REGISTRY, m), model_names_req)
        if !isempty(unknown)
            return json(Dict("error" => "Unknown models: $(join(unknown, ", "))"); status=400)
        end
    end

    try
        data_file        = joinpath(CLEAN_DATA_PATH, experiment, "data_channel_1.csv")
        annotation_file  = joinpath(CLEAN_DATA_PATH, experiment, "annotation_clean.csv")
        calibration_file = get_calibration_file(experiment; override=cal_override)

        if !isfile(data_file) || !isfile(annotation_file)
            return json(Dict("error" => "Data files not found for experiment '$experiment'"); status=404)
        end

        growth_data      = CSV.read(data_file, DataFrame, header=1, silencewarnings=true)
        annotations      = read_annotation_file(annotation_file)
        excluded_wells   = get_blank_wells(annotations)
        column_names_str = string.(names(growth_data))
        blank_well_names = resolve_blank_wells(growth_data, annotations, override_blank_wells)
        time_numeric     = parse_time_column(growth_data)
        blank_value      = compute_blank_value(growth_data, blank_well_names)
        blank_ts         = subtract_blank && blank_method == "pointbypoint" ?
            compute_blank_timeseries(growth_data, blank_well_names) : Float64[]

        wells_to_fit = requested_wells !== nothing ? requested_wells :
            filter(w -> w in column_names_str && !(w in excluded_wells), column_names_str[2:end])

        job_id = string(time_ns(), base=16)
        job = Dict{String, Any}(
            "status"       => "running",
            "experiment"   => experiment,
            "model"        => isempty(model_names_req) ? model_name : "multi",
            "model_names"  => isempty(model_names_req) ? [model_name] : model_names_req,
            "maxiters"     => maxiters,
            "abstol"       => abstol,
            "smooth"       => smoothing.enabled,
            "smooth_method" => String(smoothing.method),
            "smooth_window" => smoothing.window,
            "smooth_pt_avg" => smoothing.pt_avg,
            "lowess_frac" => smoothing.lowess_frac,
            "gaussian_h_mult" => smoothing.gaussian_h_mult,
            "blank_subtraction" => subtract_blank,
            "blank_method"      => blank_method,
            "blank_value"       => blank_value,
            "blank_timeseries"  => blank_ts,
            "total"        => length(wells_to_fit),
            "completed"    => 0,
            "current_well" => "",
            "results"      => Dict{String, Any}[],
            "errors"       => String[],
            "skipped"      => Dict{String, Any}[],
        )
        lock(BATCH_JOBS_LOCK) do
            BATCH_JOBS[job_id] = job
        end

        Threads.@spawn begin
            results    = Dict{String, Any}[]
            errors     = String[]
            skipped    = Dict{String, Any}[]
            local_lock = ReentrantLock()

            # One task per well so the scheduler can interleave fitting with
            # HTTP progress-poll requests (Threads.@threads would saturate all
            # threads and starve the HTTP server until the loop finished).
            tasks = map(wells_to_fit) do well
                Threads.@spawn begin
                    lock(BATCH_JOBS_LOCK) do
                        job["current_well"] = well
                    end
                    if !(well in column_names_str)
                        lock(local_lock) do; push!(errors, "Well '$well' not found"); end
                    elseif well in excluded_wells
                        lock(local_lock) do; push!(errors, "Well '$well' is blank/excluded"); end
                    else
                        try
                            od_raw        = parse_od_column(growth_data, Symbol(well))
                            valid_indices = findall(.!isnan.(od_raw))
                            if length(valid_indices) < 10
                                lock(local_lock) do; push!(errors, "Well '$well': insufficient data points"); end
                            else
                                od_valid = od_raw[valid_indices]
                                # Flat-curve pre-screen: amplitude below threshold means no
                                # growth signal to fit (blank, dead culture, instrument noise).
                                # Mark as skipped (distinct from a fit failure) and move on.
                                amplitude = maximum(od_valid) - minimum(od_valid)
                                if flat_thr > 0.0 && amplitude < flat_thr
                                    lock(local_lock) do
                                        push!(skipped, Dict{String, Any}(
                                            "well"      => well,
                                            "amplitude" => amplitude,
                                            "reason"    => "flat curve (amplitude $(round(amplitude, digits=4)) < threshold $(flat_thr))",
                                        ))
                                    end
                                else
                                    blank_ts_valid = isempty(blank_ts) ? Float64[] : blank_ts[valid_indices]
                                    fit_result = fit_well_data(
                                        time_numeric[valid_indices], od_valid,
                                        blank_value, calibration_file, well, experiment;
                                        subtract_blank                  = subtract_blank,
                                        blank_method                    = blank_method,
                                        blank_timeseries                = blank_ts_valid,
                                        blank_well_names                = blank_well_names,
                                        model_name                      = model_name,
                                        model_names                     = model_names_req,
                                        optimizer                       = optimizer,
                                        deterministic_optimizers        = det_opts,
                                        stochastic_optimizers           = sto_opts,
                                        stochastic_runs                 = sto_runs,
                                        maxiters                        = maxiters,
                                        abstol                          = abstol,
                                        smooth                          = smoothing.enabled,
                                        smooth_window                   = smoothing.window,
                                        smooth_method                   = smoothing.method,
                                        smooth_pt_avg                   = smoothing.pt_avg,
                                        lowess_frac                     = smoothing.lowess_frac,
                                        gaussian_h_mult                 = smoothing.gaussian_h_mult,
                                        compute_loglin                  = compute_loglin,
                                        loglin_type_of_smoothing         = ll_smoothing,
                                        loglin_pt_avg                   = ll_pt_avg,
                                        loglin_pt_smoothing_derivative  = ll_pt_deriv,
                                        loglin_pt_min_size_of_win       = ll_pt_min_win,
                                        loglin_type_of_win               = ll_win_type,
                                        loglin_threshold_of_exp         = ll_thr_exp,
                                        loglin_start_exp_win_thr         = ll_start_thr,
                                        loglin_thr_lowess                = ll_thr_lowess,
                                        loglin_gaussian_h_mult           = ll_gaussian,
                                    )
                                    lock(local_lock) do; push!(results, fit_result); end
                                end
                            end
                        catch e
                            lock(local_lock) do; push!(errors, "Well '$well': $(string(e))"); end
                        end
                    end
                    lock(BATCH_JOBS_LOCK) do
                        job["completed"] += 1
                    end
                end
            end

            foreach(fetch, tasks)

            lock(BATCH_JOBS_LOCK) do
                job["status"]   = "done"
                job["results"]  = results
                job["errors"]   = errors
                job["skipped"]  = skipped
                job["summary"]  = Dict(
                    "total"   => length(wells_to_fit),
                    "success" => length(results),
                    "failed"  => length(errors),
                    "skipped" => length(skipped),
                    "errors"  => errors,
                )
                job["current_well"] = ""
            end
        end

        return json(Dict("job_id" => job_id, "total" => length(wells_to_fit)))
    catch e
        return json(Dict("error" => "Batch fitting failed: $e"); status=500)
    end
end

@get "/api/batch-fit/progress/{job_id}" function(req::HTTP.Request, job_id::String)
    job = lock(BATCH_JOBS_LOCK) do
        get(BATCH_JOBS, job_id, nothing)
    end
    if job === nothing
        return json(Dict("error" => "Job not found"); status=404)
    end
    lock(BATCH_JOBS_LOCK) do
        resp = Dict{String, Any}(
            "status"       => job["status"],
            "total"        => job["total"],
            "completed"    => job["completed"],
            "current_well" => job["current_well"],
        )
        if job["status"] == "done"
            # Log-linear jobs do not populate every parametric-fit metadata key
            # (e.g. `smooth`, `smooth_window`, optimizer tolerances, blank
            # fields), so read optional metadata with defaults rather than
            # bracket access, which would raise a KeyError and 500 the endpoint.
            resp["experiment"]  = job["experiment"]
            resp["model"]       = job["model"]
            resp["model_names"] = job["model_names"]
            resp["maxiters"]    = get(job, "maxiters", 0)
            resp["abstol"]      = get(job, "abstol", 0.0)
            resp["smooth"]      = get(job, "smooth", false)
            resp["smooth_method"] = get(job, "smooth_method", "none")
            resp["smooth_window"] = get(job, "smooth_window", 0)
            resp["smooth_pt_avg"] = get(job, "smooth_pt_avg", 7)
            resp["lowess_frac"] = get(job, "lowess_frac", 0.05)
            resp["gaussian_h_mult"] = get(job, "gaussian_h_mult", 2.0)
            resp["blank_subtraction"] = get(job, "blank_subtraction", false)
            resp["blank_method"]      = get(job, "blank_method", "")
            resp["blank_value"]       = get(job, "blank_value", 0.0)
            resp["blank_timeseries"]  = get(job, "blank_timeseries", Float64[])
            resp["results"]     = job["results"]
            resp["skipped"]     = get(job, "skipped", Any[])
            resp["summary"]     = job["summary"]
            delete!(BATCH_JOBS, job_id)
        end
        return json(resp)
    end
end

# ---------------------------------------------------------------------------
# POST /api/batch-fit-loglin
# ---------------------------------------------------------------------------
# Batch log-linear μ_max fit: same job-tracking + progress pattern as
# /api/batch-fit, but the per-well work is a sliding-window log-lin
# regression (no optimizer, no AICc, no parametric model). For users who
# only need μ_max and don't want to pay for aHPM/Baranyi optimisations.
# Progress polling uses the same /api/batch-fit/progress/{job_id} endpoint.
# ---------------------------------------------------------------------------
@post "/api/batch-fit-loglin" function(req::HTTP.Request, body::Json{BatchLogLinFitRequest})
    body = body.payload
    experiment      = string(body.experiment)
    requested_wells = isempty(body.wells) ? nothing : String[string(w) for w in body.wells]
    subtract_blank  = body.blank_subtraction
    blank_method    = string(body.blank_method)
    override_blank_wells = String[string(w) for w in body.override_blank_wells]
    smoothing       = string(body.type_of_smoothing)
    pt_avg          = max(1, body.pt_avg)
    pt_deriv        = max(2, body.pt_smoothing_derivative)
    pt_min_win      = max(3, body.pt_min_size_of_win)
    win_type        = string(body.type_of_win)
    thr_exp         = clamp(body.threshold_of_exp, 0.0, 1.0)
    start_thr       = body.start_exp_win_thr
    thr_lowess      = body.thr_lowess
    gaussian_h_mult = clamp(body.gaussian_h_mult, 0.1, 20.0)
    flat_thr        = max(0.0, body.skip_flat_threshold)

    try
        data_file        = joinpath(CLEAN_DATA_PATH, experiment, "data_channel_1.csv")
        annotation_file  = joinpath(CLEAN_DATA_PATH, experiment, "annotation_clean.csv")

        if !isfile(data_file) || !isfile(annotation_file)
            return json(Dict("error" => "Data files not found for experiment '$experiment'"); status=404)
        end

        growth_data      = CSV.read(data_file, DataFrame, header=1, silencewarnings=true)
        annotations      = read_annotation_file(annotation_file)
        excluded_wells   = get_blank_wells(annotations)
        column_names_str = string.(names(growth_data))
        blank_well_names = resolve_blank_wells(growth_data, annotations, override_blank_wells)
        time_numeric     = parse_time_column(growth_data)
        blank_value      = compute_blank_value(growth_data, blank_well_names)
        blank_ts         = subtract_blank && blank_method == "pointbypoint" ?
            compute_blank_timeseries(growth_data, blank_well_names) : Float64[]

        wells_to_fit = requested_wells !== nothing ? requested_wells :
            filter(w -> w in column_names_str && !(w in excluded_wells), column_names_str[2:end])

        job_id = string(time_ns(), base=16)
        job = Dict{String, Any}(
            "status"       => "running",
            "experiment"   => experiment,
            # The shared progress endpoint includes `model` and `model_names`
            # in its response — set them to "log_lin" so the frontend can
            # dispatch on the same field that distinguishes parametric jobs.
            "model"        => "log_lin",
            "model_names"  => ["log_lin"],
            "maxiters"     => 0,
            "abstol"       => 0.0,
            "smooth"       => false,
            "smooth_method" => "none",
            "smooth_window" => 0,
            "smooth_pt_avg" => 7,
            "lowess_frac" => 0.05,
            "gaussian_h_mult" => 2.0,
            "blank_subtraction" => subtract_blank,
            "blank_method"      => blank_method,
            "blank_value"       => blank_value,
            "blank_timeseries"  => blank_ts,
            "total"        => length(wells_to_fit),
            "completed"    => 0,
            "current_well" => "",
            "results"      => Dict{String, Any}[],
            "errors"       => String[],
            "skipped"      => Dict{String, Any}[],
        )
        lock(BATCH_JOBS_LOCK) do
            BATCH_JOBS[job_id] = job
        end

        Threads.@spawn begin
            results    = Dict{String, Any}[]
            errors     = String[]
            skipped    = Dict{String, Any}[]
            local_lock = ReentrantLock()

            tasks = map(wells_to_fit) do well
                Threads.@spawn begin
                    lock(BATCH_JOBS_LOCK) do
                        job["current_well"] = well
                    end
                    if !(well in column_names_str)
                        lock(local_lock) do; push!(errors, "Well '$well' not found"); end
                    elseif well in excluded_wells
                        lock(local_lock) do; push!(errors, "Well '$well' is blank/excluded"); end
                    else
                        try
                            od_raw        = parse_od_column(growth_data, Symbol(well))
                            valid_indices = findall(.!isnan.(od_raw))
                            min_pts       = max(10, pt_deriv + pt_min_win + 2)
                            if length(valid_indices) < min_pts
                                lock(local_lock) do; push!(errors, "Well '$well': insufficient data points"); end
                            else
                                od_valid  = od_raw[valid_indices]
                                amplitude = maximum(od_valid) - minimum(od_valid)
                                if flat_thr > 0.0 && amplitude < flat_thr
                                    lock(local_lock) do
                                        push!(skipped, Dict{String, Any}(
                                            "well"      => well,
                                            "amplitude" => amplitude,
                                            "reason"    => "flat curve (amplitude $(round(amplitude, digits=4)) < threshold $(flat_thr))",
                                        ))
                                    end
                                else
                                    blank_ts_valid = isempty(blank_ts) ? Float64[] : blank_ts[valid_indices]
                                    fit_result = fit_well_loglin(
                                        time_numeric[valid_indices], od_valid,
                                        blank_value, well, experiment;
                                        subtract_blank          = subtract_blank,
                                        blank_method            = blank_method,
                                        blank_timeseries        = blank_ts_valid,
                                        blank_well_names        = blank_well_names,
                                        type_of_smoothing       = smoothing,
                                        pt_avg                  = pt_avg,
                                        pt_smoothing_derivative = pt_deriv,
                                        pt_min_size_of_win      = pt_min_win,
                                        type_of_win             = win_type,
                                        threshold_of_exp        = thr_exp,
                                        start_exp_win_thr       = start_thr,
                                        thr_lowess              = thr_lowess,
                                        gaussian_h_mult         = gaussian_h_mult,
                                    )
                                    lock(local_lock) do; push!(results, fit_result); end
                                end
                            end
                        catch e
                            lock(local_lock) do; push!(errors, "Well '$well': $(string(e))"); end
                        end
                    end
                    lock(BATCH_JOBS_LOCK) do
                        job["completed"] += 1
                    end
                end
            end

            foreach(fetch, tasks)

            lock(BATCH_JOBS_LOCK) do
                job["status"]   = "done"
                job["results"]  = results
                job["errors"]   = errors
                job["skipped"]  = skipped
                job["summary"]  = Dict(
                    "total"   => length(wells_to_fit),
                    "success" => length(results),
                    "failed"  => length(errors),
                    "skipped" => length(skipped),
                    "errors"  => errors,
                )
                job["current_well"] = ""
            end
        end

        return json(Dict("job_id" => job_id, "total" => length(wells_to_fit)))
    catch e
        return json(Dict("error" => "Batch log-linear fitting failed: $e"); status=500)
    end
end

# ---------------------------------------------------------------------------
# POST /api/batch-average
# ---------------------------------------------------------------------------
# Reads a matrix CSV (time column + one series per column), groups series by
# the value in `group_col` (a column in a companion metadata header row OR a
# second header row), and returns the pointwise mean curve for each group as a
# new CSV.
#
# Expected input CSV format (two-row header):
#   Row 1: "Time", series_id_1, series_id_2, ...
#   Row 2: "Group", group_label_1, group_label_2, ...   ← optional metadata row
#   Row 3+: numeric data
#
# Alternatively, group_col can name a column in a separate metadata CSV
# supplied inline.  For simplicity we support the two-header-row format
# (matching the Keio atlas export) and the `group_col` field selects which
# row-2 label column to use.  If `group_col` is blank, row 2 is assumed to be
# the group labels.
# ---------------------------------------------------------------------------
@post "/api/batch-average" function(req::HTTP.Request, body::Json{BatchAverageRequest})
    body      = body.payload
    group_col = string(body.group_col)

    df = try
        if !isempty(body.csv_path)
            p = string(body.csv_path)
            isfile(p) || return json(Dict("error" => "File not found: $p"); status=400)
            CSV.read(p, DataFrame, header=1, silencewarnings=true)
        elseif !isempty(body.csv)
            CSV.read(IOBuffer(string(body.csv)), DataFrame, header=1, silencewarnings=true)
        else
            return json(Dict("error" => "Provide csv or csv_path"); status=400)
        end
    catch e
        return json(Dict("error" => "Could not parse CSV: $e"); status=400)
    end

    ncols = ncol(df)
    ncols < 2 && return json(Dict("error" => "CSV must have at least 2 columns"); status=400)

    col_names = names(df)
    time_col  = col_names[1]

    # Detect optional second-row metadata (non-numeric first column value)
    time_raw = df[!, time_col]
    first_val = string(time_raw[1])
    has_meta_row = tryparse(Float64, first_val) === nothing

    series_cols = col_names[2:end]
    group_labels = Vector{String}(undef, length(series_cols))
    data_start   = 1

    if has_meta_row
        # Row 1 is group labels
        raw_labels = [string(df[1, c]) for c in series_cols]
        if !isempty(raw_labels) && (isempty(raw_labels[1]) || raw_labels[1] == "missing")
            raw_labels = vcat(raw_labels[2:end], raw_labels[1])
        end
        for (j, c) in enumerate(series_cols)
            lbl = raw_labels[j]
            group_labels[j] = (isempty(lbl) || lbl == "missing") ?
                replace(string(c), r"_rep.*$" => "") :
                lbl
        end
        data_start = 2
    else
        # No metadata row — use column names as group labels
        for (j, c) in enumerate(series_cols)
            group_labels[j] = string(c)
        end
    end

    # Parse time and OD data (from data_start onward)
    data_df   = df[data_start:end, :]
    times_raw = Float64[]
    for v in data_df[!, time_col]
        p = tryparse(Float64, string(v))
        push!(times_raw, p === nothing ? NaN : p)
    end

    n_tp   = length(times_raw)
    n_ser  = length(series_cols)
    od_mat = Matrix{Float64}(undef, n_tp, n_ser)
    for (j, c) in enumerate(series_cols)
        for (i, v) in enumerate(data_df[!, c])
            p = tryparse(Float64, string(v))
            od_mat[i, j] = p === nothing ? NaN : p
        end
    end

    # Group series indices by label
    groups = Dict{String, Vector{Int}}()
    for (j, lbl) in enumerate(group_labels)
        any(isfinite, od_mat[:, j]) || continue
        push!(get!(groups, lbl, Int[]), j)
    end

    # Compute pointwise mean per group (ignore NaN)
    group_names = sort(collect(keys(groups)))
    avg_mat = Matrix{Float64}(undef, n_tp, length(group_names))
    for (g_idx, gname) in enumerate(group_names)
        idxs = groups[gname]
        for i in 1:n_tp
            vals = filter(isfinite, [od_mat[i, j] for j in idxs])
            avg_mat[i, g_idx] = isempty(vals) ? NaN : mean(vals)
        end
    end

    # Build output CSV string
    header = join(vcat("Time", group_names), ",")
    rows   = [header]
    for i in 1:n_tp
        row = join(vcat(string(times_raw[i]), [string(avg_mat[i, g]) for g in 1:length(group_names)]), ",")
        push!(rows, row)
    end
    out_csv = join(rows, "\n")

    return Dict(
        "csv"         => out_csv,
        "n_groups"    => length(group_names),
        "n_timepoints"=> n_tp,
        "group_names" => group_names,
    )
end

# ---------------------------------------------------------------------------
# Log-linear fit (exponential-phase growth rate via sliding window)
# ---------------------------------------------------------------------------
# Distinct from /api/fit-curve: instead of optimising an ODE/NL model, this
# identifies the exponential window from the smoothed specific growth rate
# and runs a closed-form linear regression of log(OD) vs time. Returns the
# regression statistics (slope = µ_max, doubling time, R², 1σ standard errors) plus the
# fitted segment for plotting.
@post "/api/fit-loglin" function(req::HTTP.Request, body::Json{LogLinFitRequest})
    body = body.payload
    experiment      = string(body.experiment)
    well            = string(body.well)
    subtract_blank  = body.blank_subtraction
    blank_method    = string(body.blank_method)
    override_blank_wells = String[string(w) for w in body.override_blank_wells]
    smoothing       = string(body.type_of_smoothing)
    pt_avg          = max(1, body.pt_avg)
    pt_deriv        = max(2, body.pt_smoothing_derivative)
    pt_min_win      = max(3, body.pt_min_size_of_win)
    win_type        = string(body.type_of_win)
    thr_exp         = clamp(body.threshold_of_exp, 0.0, 1.0)
    start_thr       = body.start_exp_win_thr
    thr_lowess      = body.thr_lowess
    gaussian_h_mult = clamp(body.gaussian_h_mult, 0.1, 20.0)

    data_file       = joinpath(CLEAN_DATA_PATH, experiment, "data_channel_1.csv")
    annotation_file = joinpath(CLEAN_DATA_PATH, experiment, "annotation_clean.csv")

    if !isfile(data_file) || !isfile(annotation_file)
        return json(Dict("error" => "Data files not found"); status=404)
    end

    try
        growth_data      = CSV.read(data_file, DataFrame, header=1, silencewarnings=true)
        annotations      = read_annotation_file(annotation_file)
        excluded_wells   = get_blank_wells(annotations)
        column_names_str = string.(names(growth_data))
        blank_well_names = resolve_blank_wells(growth_data, annotations, override_blank_wells)

        if !(well in column_names_str)
            return json(Dict("error" => "Well '$well' not found"); status=404)
        end
        if well in excluded_wells
            return json(Dict("error" => "Well '$well' is a blank well"); status=400)
        end

        time_numeric     = parse_time_column(growth_data)
        od_raw           = parse_od_column(growth_data, Symbol(well))
        blank_value      = compute_blank_value(growth_data, blank_well_names)
        blank_timeseries = (subtract_blank && blank_method == "pointbypoint") ?
            compute_blank_timeseries(growth_data, blank_well_names) : Float64[]

        valid = findall(.!isnan.(od_raw))
        if length(valid) < max(10, pt_deriv + pt_min_win + 2)
            return json(Dict("error" => "Not enough valid data points for log-linear fit"); status=400)
        end

        t = time_numeric[valid]
        od = od_raw[valid]

        blank_ts_valid = isempty(blank_timeseries) ? Float64[] : blank_timeseries[valid]
        prepared = _prepare_fit_curve(
            t, od, well;
            blank_value,
            subtract_blank,
            blank_method,
            blank_timeseries=blank_ts_valid,
            unblanked_floor=1e-4,
        )
        od_for_fit = prepared.od_for_fit
        od_subtracted_display = prepared.od_subtracted_display

        data_mat = Matrix(transpose(hcat(t, od_for_fit)))

        raw = Kinbiont.fitting_one_well_Log_Lin(
            data_mat,
            well,
            experiment;
            type_of_smoothing       = smoothing,
            pt_avg                  = pt_avg,
            pt_smoothing_derivative = pt_deriv,
            pt_min_size_of_win      = pt_min_win,
            type_of_win             = win_type,
            threshold_of_exp        = thr_exp,
            start_exp_win_thr       = start_thr,
            thr_lowess              = thr_lowess,
            gaussian_h_mult         = gaussian_h_mult,
        )

        # raw = (method, params, fit_matrix, smoothed_data, confidence_band)
        # params layout from Fit_one_well_functions.jl:
        #   [label_exp, name_well, t_start_exp, t_end_exp, t_max_gr, gr_max,
        #    slope, sigma_b, dt, dt_minus, dt_plus, intercept, sigma_a, rho]
        params       = raw[2]
        fit_matrix   = raw[3]
        smoothed     = raw[4]
        ci_band      = raw[5]
        lag_loglin   = length(params) >= 15 && params[15] !== missing ?
            Float64(params[15]) : NaN
        n_max_emp    = _loglin_stationary_nmax(raw, pt_deriv)

        # Guard against the "no exp window found" path where matrix is `missing`.
        fit_times    = ismissing(fit_matrix) ? Float64[] :
                       Vector{Float64}(fit_matrix[:, 1])
        log_fit_vals = ismissing(fit_matrix) ? Float64[] :
                       Vector{Float64}(fit_matrix[:, 2])
        fit_od_vals  = isempty(log_fit_vals) ? Float64[] : exp.(log_fit_vals)
        ci_vals      = ismissing(ci_band) ? Float64[] : Vector{Float64}(ci_band)

        param_names = [
            "label_exp", "well", "t_start_exp", "t_end_exp", "t_max_gr",
            "gr_max", "slope", "slope_se", "doubling_time",
            "doubling_time_minus_se", "doubling_time_plus_se",
            "intercept", "intercept_se", "R_squared",
        ]

        result = Dict{String, Any}(
            "experiment"            => experiment,
            "well"                  => well,
            "method"                => raw[1],
            "experimental_time"     => t,
            "experimental_od"       => od,
            "smoothed_time"         => Vector{Float64}(smoothed[1, :]),
            "smoothed_od"           => Vector{Float64}(smoothed[2, :]),
            "fit_time"              => fit_times,
            "fit_od"                => fit_od_vals,
            "fit_log_od"            => log_fit_vals,
            "confidence_band_log"   => ci_vals,
            "param_names"           => param_names,
            "parameters"            => params,
            "lag_loglin"            => lag_loglin,
            "N_max_emp"             => n_max_emp,
            "blank_value"           => blank_value,
            "blank_subtraction"     => subtract_blank,
            "blank_method"          => blank_method,
            "blank_wells"           => blank_well_names,
        )

        if od_subtracted_display !== nothing
            result["experimental_od_subtracted"] = od_subtracted_display
        end

        return sanitize_for_json(result)
    catch e
        return json(Dict("error" => "Log-linear fitting failed: $e"); status=500)
    end
end
