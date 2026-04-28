const BATCH_JOBS      = Dict{String, Dict{String, Any}}()
const BATCH_JOBS_LOCK = ReentrantLock()

@post "/api/fit-curve" function(req::HTTP.Request, body::Json{FitCurveRequest})
    body = body.payload
    experiment     = string(body.experiment)
    well           = string(body.well)
    subtract_blank = body.blank_subtraction
    blank_method   = string(body.blank_method)
    model_name     = string(body.model_name)
    model_names    = String[string(m) for m in body.model_names]

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
        blank_well_names = get_blank_well_names(annotations)  # "b" only
        column_names_str = string.(names(growth_data))

        if !(well in column_names_str)
            return json(Dict("error" => "Well '$well' not found"); status=404)
        end
        if well in excluded_wells
            return json(Dict("error" => "Well '$well' is a blank well"); status=400)
        end

        time_numeric     = parse_time_column(growth_data)
        od_raw           = parse_od_column(growth_data, Symbol(well))
        blank_value      = compute_blank_value(growth_data, annotations)
        blank_timeseries = (subtract_blank && blank_method == "pointbypoint") ?
            compute_blank_timeseries(growth_data, annotations) : Float64[]

        valid_indices = findall(.!isnan.(od_raw))
        if length(valid_indices) < 10
            return json(Dict("error" => "Not enough valid data points for fitting"); status=400)
        end

        # Align blank timeseries to valid indices if computed
        blank_ts_valid = isempty(blank_timeseries) ? Float64[] : blank_timeseries[valid_indices]

        return fit_well_data(
            time_numeric[valid_indices], od_raw[valid_indices],
            blank_value, calibration_file, well, experiment;
            subtract_blank   = subtract_blank,
            blank_method     = blank_method,
            blank_timeseries = blank_ts_valid,
            blank_well_names = blank_well_names,
            model_name       = model_name,
            model_names      = model_names,
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
    calibration_file = "./cal_curve_avg.csv"

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
            model_name = model_name,
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
    cal_override    = string(body.calibration_file)
    requested_wells = isempty(body.wells) ? nothing : String[string(w) for w in body.wells]

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
        blank_well_names = get_blank_well_names(annotations)
        column_names_str = string.(names(growth_data))
        time_numeric     = parse_time_column(growth_data)
        blank_value      = compute_blank_value(growth_data, annotations)
        blank_ts         = subtract_blank && blank_method == "pointbypoint" ?
            compute_blank_timeseries(growth_data, annotations) : Float64[]

        wells_to_fit = requested_wells !== nothing ? requested_wells :
            filter(w -> w in column_names_str && !(w in excluded_wells), column_names_str[2:end])

        job_id = string(time_ns(), base=16)
        job = Dict{String, Any}(
            "status"       => "running",
            "experiment"   => experiment,
            "model"        => isempty(model_names_req) ? model_name : "multi",
            "model_names"  => isempty(model_names_req) ? [model_name] : model_names_req,
            "total"        => length(wells_to_fit),
            "completed"    => 0,
            "current_well" => "",
            "results"      => Dict{String, Any}[],
            "errors"       => String[],
        )
        lock(BATCH_JOBS_LOCK) do
            BATCH_JOBS[job_id] = job
        end

        Threads.@spawn begin
            results    = Dict{String, Any}[]
            errors     = String[]
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
                        lock(local_lock) do push!(errors, "Well '$well' not found") end
                    elseif well in excluded_wells
                        lock(local_lock) do push!(errors, "Well '$well' is blank/excluded") end
                    else
                        try
                            od_raw        = parse_od_column(growth_data, Symbol(well))
                            valid_indices = findall(.!isnan.(od_raw))
                            if length(valid_indices) < 10
                                lock(local_lock) do push!(errors, "Well '$well': insufficient data points") end
                            else
                                blank_ts_valid = isempty(blank_ts) ? Float64[] : blank_ts[valid_indices]
                                fit_result = fit_well_data(
                                    time_numeric[valid_indices], od_raw[valid_indices],
                                    blank_value, calibration_file, well, experiment;
                                    subtract_blank   = subtract_blank,
                                    blank_method     = blank_method,
                                    blank_timeseries = blank_ts_valid,
                                    blank_well_names = blank_well_names,
                                    model_name       = model_name,
                                    model_names      = model_names_req,
                                )
                                lock(local_lock) do push!(results, fit_result) end
                            end
                        catch e
                            lock(local_lock) do push!(errors, "Well '$well': $(string(e))") end
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
                job["summary"]  = Dict(
                    "total"   => length(wells_to_fit),
                    "success" => length(results),
                    "failed"  => length(errors),
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
            resp["experiment"]  = job["experiment"]
            resp["model"]       = job["model"]
            resp["model_names"] = job["model_names"]
            resp["results"]     = job["results"]
            resp["summary"]     = job["summary"]
            delete!(BATCH_JOBS, job_id)
        end
        return json(resp)
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

    group_labels = Vector{String}(undef, ncols - 1)
    data_start   = 1

    if has_meta_row
        # Row 1 is group labels
        for (j, c) in enumerate(col_names[2:end])
            group_labels[j] = string(df[1, c])
        end
        data_start = 2
    else
        # No metadata row — use column names as group labels
        for (j, c) in enumerate(col_names[2:end])
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
    n_ser  = ncols - 1
    od_mat = Matrix{Float64}(undef, n_tp, n_ser)
    for (j, c) in enumerate(col_names[2:end])
        for (i, v) in enumerate(data_df[!, c])
            p = tryparse(Float64, string(v))
            od_mat[i, j] = p === nothing ? NaN : p
        end
    end

    # Group series indices by label
    groups = Dict{String, Vector{Int}}()
    for (j, lbl) in enumerate(group_labels)
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
