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
            0.0, calibration_file, label, experiment_name,
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

        results = Dict{String, Any}[]
        errors  = String[]

        for well in wells_to_fit
            if !(well in column_names_str)
                push!(errors, "Well '$well' not found"); continue
            end
            if well in excluded_wells
                push!(errors, "Well '$well' is blank/excluded"); continue
            end
            try
                od_raw        = parse_od_column(growth_data, Symbol(well))
                valid_indices = findall(.!isnan.(od_raw))
                if length(valid_indices) < 10
                    push!(errors, "Well '$well': insufficient data points"); continue
                end
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
                push!(results, fit_result)
            catch e
                push!(errors, "Well '$well': $(string(e))")
            end
        end

        return Dict(
            "experiment"   => experiment,
            "model"        => isempty(model_names_req) ? model_name : "multi",
            "model_names"  => isempty(model_names_req) ? [model_name] : model_names_req,
            "results"      => results,
            "summary"      => Dict(
                "total"   => length(wells_to_fit),
                "success" => length(results),
                "failed"  => length(errors),
                "errors"  => errors,
            ),
        )
    catch e
                return json(Dict("error" => "Batch fitting failed: $e"); status=500)
    end
end
