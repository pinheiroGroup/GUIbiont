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
    experiment = body.experiment
    well_count = body.well_count

    # Validate inputs
    if isempty(experiment)
        return json(Dict("error" => "Experiment name is required"); status=400)
    end

    if !(well_count in [6, 48, 96])
        return json(Dict("error" => "Well count must be 6, 48, or 96"); status=400)
    end

    # Check if raw data exists
    raw_experiment_path = joinpath(RAW_DATA_PATH, experiment)
    data_file  = joinpath(raw_experiment_path, "data.csv")
    plate_file = joinpath(raw_experiment_path, "plate.csv")

    if !isfile(data_file) || !isfile(plate_file)
        return json(Dict("error" => "Required files (data.csv and plate.csv) not found in raw experiment folder"); status=404)
    end

    try
        # Create output directory
        output_path = joinpath(CLEAN_DATA_PATH, experiment) * "/"

        # Clean the annotation file first
        read_labguru_annotation(plate_file, output_path, well_count)

        # Clean the data file
        cleaning_data_synergy(data_file, output_path)

        # Check what files were created
        created_files = isdir(output_path) ? readdir(output_path) : String[]

        return Dict(
            "success"       => true,
            "experiment"    => experiment,
            "output_path"   => output_path,
            "well_count"    => well_count,
            "created_files" => created_files,
            "message"       => "Data cleaning completed successfully"
        )
    catch e
        return json(Dict("error" => "Data cleaning failed: $e"); status=500)
    end
end
