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

@get "/api/experiments" function(req::HTTP.Request)
    return get_experiments()
end

@get "/api/experiment/{name}/info" function(req::HTTP.Request, name::String)
    experiment = name
    data_file = joinpath(CLEAN_DATA_PATH, experiment, "data_channel_1.csv")
    annotation_file = joinpath(CLEAN_DATA_PATH, experiment, "annotation_clean.csv")

    if !isfile(data_file) || !isfile(annotation_file)
        return json(Dict("error" => "Experiment not found"); status=404)
    end

    try
        growth_data = CSV.read(data_file, DataFrame, header=1, silencewarnings=true)
        annotations = CSV.read(annotation_file, DataFrame, header=false, silencewarnings=true, stringtype=String)

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
        all_well_columns = names(growth_data)[2:end]

        # Filter out blank wells based on annotation file
        blank_wells = get_blank_wells(annotations)
        well_columns = filter(well -> !(string(well) in blank_wells), all_well_columns)

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
                    if !ismissing(antibiotic_value) && string(antibiotic_value) != ""
                        antibiotic = string(antibiotic_value)
                    else
                        antibiotic = "None"
                    end
                else
                    antibiotic = "None"
                end
            end

            condition = join(condition_parts, " | ")
            push!(well_info, Dict("well" => well, "condition" => condition, "antibiotic" => antibiotic))
        end

        return Dict(
            "experiment" => experiment,
            "wells" => well_info,
            "time_points" => nrow(growth_data),
            "time_column" => time_col
        )
    catch e
        return json(Dict("error" => "Error loading experiment $experiment: $e"); status=500)
    end
end

@post "/api/multi-experiment-info" function(req::HTTP.Request, body::Json{MultiExperimentInfoRequest})
    body = body.payload
    experiments = body.experiments

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

                # Collect wells from ALL annotation files for this channel (one file per media condition)
                all_files = try readdir(exp_dir) catch; String[] end
                prefix = "annotation_channel_$(ch_num)_"
                ann_files = [joinpath(exp_dir, f) for f in sort(filter(f -> startswith(f, prefix) && endswith(f, ".csv"), all_files))]
                isempty(ann_files) && (ann_file = find_annotation_file(exp_dir, ch_num); ann_file !== nothing && push!(ann_files, ann_file))
                isempty(ann_files) && continue

                for ann_file in ann_files
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
                    @warn "Error loading channel $ch_num of $experiment ($ann_file): $e"
                end
                end  # for ann_file
            end
        catch e
            @warn "Error loading experiment $experiment for multi-select: $e"
        end
    end

    return combined_info
end

@post "/api/global-search" function(req::HTTP.Request, body::Json{GlobalSearchRequest})
    body = body.payload
    condition_query  = body.condition
    antibiotic_query = body.antibiotic

    search_results = []
    experiments = get_experiments()

    for experiment in experiments
        data_file       = joinpath(CLEAN_DATA_PATH, experiment, "data_channel_1.csv")
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
                        condition_match  = isempty(condition_query)  || occursin(lowercase(condition_query),  lowercase(full_condition))
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
                        "experiment"      => experiment,
                        "matching_wells"  => matching_wells,
                        "conditions"      => collect(found_conditions),
                        "antibiotics"     => collect(found_antibiotics)
                    ))
                end

            catch e
                @warn "Error searching experiment $experiment: $e"
            end
        end
    end

    return search_results
end

@get "/api/raw-experiments" function(req::HTTP.Request)
    try
        if !isdir(RAW_DATA_PATH)
            return String[]
        end
        raw_experiments = filter(x -> isdir(joinpath(RAW_DATA_PATH, x)) &&
                                     !startswith(x, "."),
                                readdir(RAW_DATA_PATH))
        return sort(raw_experiments)
    catch e
        return json(Dict("error" => "Failed to list raw experiments: $e"); status=500)
    end
end

@post "/api/clean-data" function(req::HTTP.Request, body::Json{CleanDataRequest})
    body = body.payload
    experiment    = body.experiment
    well_count    = body.well_count
    machine_type  = lowercase(strip(string(body.machine_type)))
    data_override = strip(string(body.data_filename))

    if isempty(experiment)
        return json(Dict("error" => "Experiment name is required"); status=400)
    end
    if !(well_count in [6, 48, 96])
        return json(Dict("error" => "Well count must be 6, 48, or 96"); status=400)
    end

    raw_experiment_path = joinpath(RAW_DATA_PATH, experiment)
    plate_file          = joinpath(raw_experiment_path, "plate.csv")

    if !isdir(raw_experiment_path)
        return json(Dict("error" => "Raw experiment folder not found: '$experiment'"); status=404)
    end
    has_plate = isfile(plate_file)

    # Resolve the source data file. Caller may override; otherwise pick by
    # machine_type. In auto mode, prefer .xlsx (Tecan) over data.csv, since
    # users frequently leave a stale data.csv copy of plate.csv lying around.
    function _pick_data_file(dir::String, prefer::Symbol)
        files = readdir(dir)
        # Never pick the annotation file as data.
        files = filter(f -> lowercase(f) != "plate.csv", files)
        xlsx  = filter(f -> endswith(lowercase(f), ".xlsx") || endswith(lowercase(f), ".xls"), files)
        csvs  = filter(f -> endswith(lowercase(f), ".csv"), files)
        ordered = if prefer == :xlsx
            vcat(xlsx, csvs)
        elseif prefer == :csv
            vcat(csvs, xlsx)
        else
            vcat(xlsx, csvs)   # auto → xlsx wins (newer + more common request)
        end
        for f in ordered
            return joinpath(dir, f)
        end
        return joinpath(dir, prefer == :xlsx ? "data.xlsx" : "data.csv")
    end

    data_file = if !isempty(data_override)
        joinpath(raw_experiment_path, data_override)
    elseif machine_type == "tecan_spark"
        _pick_data_file(raw_experiment_path, :xlsx)
    elseif machine_type == "synergy"
        _pick_data_file(raw_experiment_path, :csv)
    else
        _pick_data_file(raw_experiment_path, :auto)
    end

    if !isfile(data_file)
        return json(Dict("error" => "Data file not found: $(basename(data_file))"); status=404)
    end

    # Resolve format: explicit > sniffed.
    fmt = try
        machine_type == "auto" ? detect_format(data_file) : format_from_key(machine_type)
    catch e
        return json(Dict("error" => "Format resolution failed: $e"); status=400)
    end

    try
        output_path = joinpath(CLEAN_DATA_PATH, experiment) * "/"
        if has_plate
            read_labguru_annotation(plate_file, output_path, well_count)
        end
        clean(fmt, data_file, output_path)

        # No plate.csv → write a stub annotation_clean.csv from the well columns
        # that the data adapter just produced. Every well gets a placeholder
        # condition so it shows up downstream as non-blank, non-excluded. The
        # user can supply a real plate.csv later and re-clean.
        if !has_plate
            mkpath(output_path)
            primary = joinpath(output_path, "data_channel_1.csv")
            wells = String[]
            if isfile(primary)
                cols = string.(names(CSV.read(primary, DataFrame, header=1, silencewarnings=true)))
                wells = filter(c -> c != "Time", cols)
            end
            stub_rows = [(w, "unknown", "unknown", "", "", "", "1") for w in wells]
            CSV.write(joinpath(output_path, "annotation_clean.csv"),
                      Tables.table(reduce(vcat, [collect(r)' for r in stub_rows]; init=Matrix{Any}(undef, 0, 7))),
                      header=false)
        end

        created_files = isdir(output_path) ? readdir(output_path) : String[]

        return Dict(
            "success"       => true,
            "experiment"    => experiment,
            "output_path"   => output_path,
            "well_count"    => well_count,
            "machine_type"  => string(typeof(fmt).name.name),
            "data_file"     => basename(data_file),
            "created_files" => created_files,
            "has_plate"     => has_plate,
            "message"       => has_plate ?
                "Data cleaning completed successfully" :
                "Data cleaning completed — no plate.csv found, generated a stub annotation. Replace it with a real LabGuru plate.csv and re-run for full metadata.",
        )
    catch e
        return json(Dict("error" => "Data cleaning failed: $e"); status=500)
    end
end
