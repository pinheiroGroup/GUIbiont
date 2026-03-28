# HTTP router and legacy data accessor functions
# Note: get_experiment_info / get_plot_data below are superseded by the
# multi-channel implementations inside the router, but kept for reference.
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

# Get experiment metadata (wells, time points, etc.)
function get_experiment_info(experiment::String)
    data_file = joinpath(CLEAN_DATA_PATH, experiment, "data_channel_1.csv")
    annotation_file = joinpath(CLEAN_DATA_PATH, experiment, "annotation_clean.csv")
    
    if !isfile(data_file) || !isfile(annotation_file)
        return nothing
    end
    
    try
        growth_data = CSV.read(data_file, DataFrame, header=1)
        annotations = CSV.read(annotation_file, DataFrame, header=false)
        rename!(annotations, [:well, :condition])
        
        time_col = names(growth_data)[1]
        well_columns = names(growth_data)[2:end]
        
        # Create well info with conditions
        well_info = []
        for well in well_columns
            condition = "Unknown"
            well_annotation = filter(row -> row.well == well, annotations)
            if nrow(well_annotation) > 0
                condition = string(well_annotation[1, :condition])
            end
            push!(well_info, Dict("well" => well, "condition" => condition))
        end
        
        return Dict(
            "experiment" => experiment,
            "wells" => well_info,
            "time_points" => nrow(growth_data),
            "time_column" => time_col
        )
    catch e
        println("Error loading experiment $experiment: $e")
        return nothing
    end
end

# Get growth data for specific wells
function get_plot_data(experiment::String, wells::Vector{String})
    data_file = joinpath(CLEAN_DATA_PATH, experiment, "data_channel_1.csv")
    annotation_file = joinpath(CLEAN_DATA_PATH, experiment, "annotation_clean.csv")
    
    if !isfile(data_file) || !isfile(annotation_file)
        return nothing
    end
    
    try
        growth_data = CSV.read(data_file, DataFrame, header=1)
        annotations = CSV.read(annotation_file, DataFrame, header=false)
        rename!(annotations, [:well, :condition])
        
        time_col = names(growth_data)[1]
        time_data = growth_data[!, time_col]
        
        # Parse time data
        if eltype(time_data) <: AbstractString
            try
                time_numeric = [parse(Float64, t) for t in time_data[2:end]]
                time_numeric = [0.0; time_numeric]
            catch
                time_numeric = Float64.(0:(nrow(growth_data)-1))
            end
        else
            time_numeric = Float64.(time_data)
        end
        
        # Prepare data for each well
        traces = []
        stats = []
        
        for well in wells
            if well in names(growth_data)
                well_data = growth_data[!, well]
                
                # Convert to numeric
                od_data = Float64[]
                for val in well_data
                    try
                        push!(od_data, parse(Float64, string(val)))
                    catch
                        push!(od_data, NaN)
                    end
                end
                
                # Get condition
                well_annotation = filter(row -> row.well == well, annotations)
                condition = if nrow(well_annotation) > 0
                    string(well_annotation[1, :condition])
                else
                    "Unknown"
                end
                
                # Calculate statistics
                valid_od = filter(!isnan, od_data)
                max_od = isempty(valid_od) ? 0.0 : maximum(valid_od)
                final_od = isempty(valid_od) ? 0.0 : last(valid_od)
                
                # Calculate AUC using trapezoidal rule
                auc = 0.0
                valid_indices = findall(!isnan, od_data)
                if length(valid_indices) > 1
                    for i in 2:length(valid_indices)
                        dt = time_numeric[valid_indices[i]] - time_numeric[valid_indices[i-1]]
                        avg_od = (od_data[valid_indices[i]] + od_data[valid_indices[i-1]]) / 2
                        auc += dt * avg_od
                    end
                end
                
                push!(traces, Dict(
                    "well" => well,
                    "condition" => condition,
                    "x" => time_numeric,
                    "y" => od_data
                ))
                
                push!(stats, Dict(
                    "well" => well,
                    "condition" => condition,
                    "max_od" => round(max_od, digits=3),
                    "final_od" => round(final_od, digits=3),
                    "auc" => round(auc, digits=2)
                ))
            end
        end
        
        return Dict("traces" => traces, "stats" => stats)
    catch e
        println("Error getting plot data: $e")
        return nothing
    end
end

# API Routes
function router(req)
    # Handle CORS preflight
    cors_response = handle_cors(req)
    if cors_response !== nothing
        return cors_response
    end
    
    uri = HTTP.URI(req.target)
    path = uri.path
    
    headers = [
        "Access-Control-Allow-Origin" => "*",
        "Access-Control-Allow-Methods" => "GET, POST, OPTIONS", 
        "Access-Control-Allow-Headers" => "Content-Type",
        "Content-Type" => "application/json"
    ]
    
    try
        if path == "/api/config"
            # GET /api/config - Return server configuration
            config_path = joinpath(@__DIR__, "config.json")
            if isfile(config_path)
                config = JSON3.read(read(config_path, String))
                return HTTP.Response(200, headers, JSON3.write(config))
            else
                return HTTP.Response(200, headers, JSON3.write(Dict("enable_clean_data_tab" => true)))
            end

        elseif path == "/api/experiments"
            # GET /api/experiments - List all experiments
            experiments = get_experiments()
            return HTTP.Response(200, headers, JSON3.write(experiments))

        elseif path == "/api/models" && HTTP.method(req) == "GET"
            # GET /api/models - List available growth models from KinBiont MODEL_REGISTRY
            model_list = sort(collect(keys(MODEL_REGISTRY)))
            model_info = [Dict(
                "name"        => name,
                "param_names" => MODEL_REGISTRY[name].param_names,
                "model_type"  => occursin("NL", string(typeof(MODEL_REGISTRY[name]))) ? "NL" : "ODE",
            ) for name in model_list]
            return HTTP.Response(200, headers, JSON3.write(model_info))
            
        elseif startswith(path, "/api/experiment/") && endswith(path, "/info")
            # GET /api/experiment/{name}/info - Get experiment metadata
            path_parts = split(path, "/")
            println("Debug - path: $path, parts: $path_parts")
            if length(path_parts) >= 4
                experiment = path_parts[4]  # Extract experiment name
                println("Debug - experiment: $experiment")
                # Call function directly inline to avoid scoping issues
                data_file = joinpath(CLEAN_DATA_PATH, experiment, "data_channel_1.csv")
                annotation_file = joinpath(CLEAN_DATA_PATH, experiment, "annotation_clean.csv")
                
                if !isfile(data_file) || !isfile(annotation_file)
                    info = nothing
                else
                    try
                        # Read with more flexible options
                        println("Debug - Reading file: $data_file")
                        growth_data = CSV.read(data_file, DataFrame, header=1, silencewarnings=true)
                        println("Debug - Growth data loaded. Columns: $(ncol(growth_data)), Rows: $(nrow(growth_data))")
                        println("Debug - Column names: $(names(growth_data))")
                        
                        annotations = CSV.read(annotation_file, DataFrame, header=false, silencewarnings=true, stringtype=String)
                        println("Debug - Annotations loaded. Columns: $(ncol(annotations)), Rows: $(nrow(annotations))")
                        println("Debug - First few rows:")
                        for i in 1:min(3, nrow(annotations))
                            println("Debug - Row $i: $(annotations[i, :])")
                        end
                        
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
                        println("Debug - Column names after renaming: $(names(annotations))")
                        
                        time_col = names(growth_data)[1]
                        all_well_columns = names(growth_data)[2:end]
                        
                        # Filter out blank wells based on annotation file (more precise than regex)
                        blank_wells = get_blank_wells(annotations)
                        well_columns = filter(well -> !(string(well) in blank_wells), all_well_columns)
                        println("Debug - All wells: $all_well_columns")
                        println("Debug - Filtered wells: $well_columns")
                        println("Debug - Filtered out: $(length(all_well_columns) - length(well_columns)) wells")
                        
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
                                    println("Debug - Well $well: antibiotic raw value = '$antibiotic_value', missing? $(ismissing(antibiotic_value))")
                                    if !ismissing(antibiotic_value) && string(antibiotic_value) != ""
                                        antibiotic = string(antibiotic_value)
                                        println("Debug - Well $well: antibiotic set to '$antibiotic'")
                                    else
                                        antibiotic = "None"
                                        println("Debug - Well $well: antibiotic set to 'None' (empty or missing)")
                                    end
                                else
                                    antibiotic = "None"
                                    println("Debug - Well $well: no antibiotic column found")
                                end
                            end
                            
                            condition = join(condition_parts, " | ")
                            push!(well_info, Dict("well" => well, "condition" => condition, "antibiotic" => antibiotic))
                            if antibiotic != "None"
                                println("Debug - Found well with antibiotic: $well -> $antibiotic")
                            end
                        end
                        
                        println("Debug - Total wells in result: $(length(well_info))")
                        antibiotic_wells = filter(w -> w["antibiotic"] != "None", well_info)
                        println("Debug - Wells with antibiotics: $(length(antibiotic_wells))")
                        for w in antibiotic_wells
                            println("Debug - Antibiotic well: $(w["well"]) -> $(w["antibiotic"])")
                        end
                        
                        info = Dict(
                            "experiment" => experiment,
                            "wells" => well_info,
                            "time_points" => nrow(growth_data),
                            "time_column" => time_col
                        )
                    catch e
                        println("Error loading experiment $experiment: $e")
                        info = nothing
                    end
                end
            else
                println("Error - Invalid path structure: $path")
                return HTTP.Response(400, headers, JSON3.write(Dict("error" => "Invalid path")))
            end
            if info !== nothing
                return HTTP.Response(200, headers, JSON3.write(info))
            else
                return HTTP.Response(404, headers, JSON3.write(Dict("error" => "Experiment not found")))
            end
            
        elseif path == "/api/multi-experiment-info" && HTTP.method(req) == "POST"
            # POST /api/multi-experiment-info - Get combined info for multiple experiments
            body = String(req.body)
            request_data = JSON3.read(body)
            experiments = request_data.experiments

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

                        # Per-channel annotation (annotation_channel_N_*.csv) with fallback
                        ann_file = find_annotation_file(exp_dir, ch_num)
                        ann_file === nothing && continue   # skip channel if no annotation at all

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
                            println("Error loading channel $ch_num of $experiment: $e")
                        end
                    end
                catch e
                    println("Error loading experiment $experiment for multi-select: $e")
                end
            end

            return HTTP.Response(200, headers, JSON3.write(combined_info))
            
        elseif path == "/api/global-search" && HTTP.method(req) == "POST"
            # POST /api/global-search - Search across all experiments for conditions/antibiotics
            body = String(req.body)
            request_data = JSON3.read(body)
            
            condition_query = get(request_data, :condition, "")
            antibiotic_query = get(request_data, :antibiotic, "")
            
            search_results = []
            experiments = get_experiments()
            
            for experiment in experiments
                data_file = joinpath(CLEAN_DATA_PATH, experiment, "data_channel_1.csv")
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
                                condition_match = isempty(condition_query) || occursin(lowercase(condition_query), lowercase(full_condition))
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
                                "experiment" => experiment,
                                "matching_wells" => matching_wells,
                                "conditions" => collect(found_conditions),
                                "antibiotics" => collect(found_antibiotics)
                            ))
                        end
                        
                    catch e
                        println("Error searching experiment $experiment: $e")
                    end
                end
            end
            
            return HTTP.Response(200, headers, JSON3.write(search_results))
            
        elseif path == "/api/raw-experiments" && HTTP.method(req) == "GET"
            # GET /api/raw-experiments - List all raw experiments
            try
                if !isdir(RAW_DATA_PATH)
                    return HTTP.Response(200, headers, JSON3.write(String[]))
                end
                
                raw_experiments = filter(x -> isdir(joinpath(RAW_DATA_PATH, x)) && 
                                             !startswith(x, "."), 
                                        readdir(RAW_DATA_PATH))
                return HTTP.Response(200, headers, JSON3.write(sort(raw_experiments)))
            catch e
                println("Error listing raw experiments: ", e)
                return HTTP.Response(500, headers, JSON3.write(Dict("error" => "Failed to list raw experiments")))
            end
            
        elseif path == "/api/clean-data" && HTTP.method(req) == "POST"
            # POST /api/clean-data - Clean raw experiment data
            body = String(req.body)
            request_data = JSON3.read(body)
            
            experiment = request_data.experiment
            well_count = get(request_data, :well_count, 48)
            
            try
                # Validate inputs
                if isempty(experiment)
                    return HTTP.Response(400, headers, JSON3.write(Dict("error" => "Experiment name is required")))
                end
                
                if !(well_count in [6, 48, 96])
                    return HTTP.Response(400, headers, JSON3.write(Dict("error" => "Well count must be 6, 48, or 96")))
                end
                
                # Check if raw data exists
                raw_experiment_path = joinpath(RAW_DATA_PATH, experiment)
                data_file = joinpath(raw_experiment_path, "data.csv")
                plate_file = joinpath(raw_experiment_path, "plate.csv")
                
                if !isfile(data_file) || !isfile(plate_file)
                    return HTTP.Response(404, headers, JSON3.write(Dict("error" => "Required files (data.csv and plate.csv) not found in raw experiment folder")))
                end
                
                # Create output directory
                output_path = joinpath(CLEAN_DATA_PATH, experiment) * "/"
                
                # Load cleaning functions
                println("Starting data cleaning for experiment: $experiment")
                println("Input path: $raw_experiment_path")
                println("Output path: $output_path")
                
                # Clean the annotation file first
                read_labguru_annotation(plate_file, output_path, well_count)
                println("Annotation cleaning completed")
                
                # Clean the data file
                cleaning_data_synergy(data_file, output_path)
                println("Data cleaning completed")
                
                # Check what files were created
                created_files = []
                if isdir(output_path)
                    created_files = readdir(output_path)
                end
                
                response_data = Dict(
                    "success" => true,
                    "experiment" => experiment,
                    "output_path" => output_path,
                    "well_count" => well_count,
                    "created_files" => created_files,
                    "message" => "Data cleaning completed successfully"
                )
                
                return HTTP.Response(200, headers, JSON3.write(response_data))
                
            catch e
                println("Error cleaning data: ", e)
                return HTTP.Response(500, headers, JSON3.write(Dict("error" => "Data cleaning failed: $e")))
            end
            
        elseif path == "/api/fit-curve" && HTTP.method(req) == "POST"
            # POST /api/fit-curve - Fit growth curve for a single well
            body = String(req.body)
            request_data = JSON3.read(body)

            experiment      = string(request_data.experiment)
            well            = string(request_data.well)
            subtract_blank  = Bool(get(request_data, :blank_subtraction, false))
            blank_method    = string(get(request_data, :blank_method, "pointbypoint"))
            model_name      = string(get(request_data, :model_name, "aHPM"))
            if !haskey(MODEL_REGISTRY, model_name)
                return HTTP.Response(400, headers, JSON3.write(Dict("error" => "Unknown model: $model_name")))
            end

            try
                data_file        = joinpath(CLEAN_DATA_PATH, experiment, "data_channel_1.csv")
                annotation_file  = joinpath(CLEAN_DATA_PATH, experiment, "annotation_clean.csv")
                calibration_file = "./cal_curve_avg.csv"

                if !isfile(data_file) || !isfile(annotation_file)
                    return HTTP.Response(404, headers, JSON3.write(Dict("error" => "Data files not found")))
                end

                growth_data      = CSV.read(data_file, DataFrame, header=1, silencewarnings=true)
                annotations      = read_annotation_file(annotation_file)
                excluded_wells   = get_blank_wells(annotations)   # "b" + "X"
                blank_well_names = get_blank_well_names(annotations)  # "b" only
                column_names_str = string.(names(growth_data))

                if !(well in column_names_str)
                    return HTTP.Response(404, headers, JSON3.write(Dict("error" => "Well '$well' not found")))
                end
                if well in excluded_wells
                    return HTTP.Response(400, headers, JSON3.write(Dict("error" => "Well '$well' is a blank well")))
                end

                time_numeric     = parse_time_column(growth_data)
                od_raw           = parse_od_column(growth_data, Symbol(well))
                blank_value      = compute_blank_value(growth_data, annotations)
                blank_timeseries = (subtract_blank && blank_method == "pointbypoint") ?
                    compute_blank_timeseries(growth_data, annotations) : Float64[]

                valid_indices = findall(.!isnan.(od_raw))
                if length(valid_indices) < 10
                    return HTTP.Response(400, headers, JSON3.write(Dict("error" => "Not enough valid data points for fitting")))
                end

                # Align blank timeseries to valid indices if computed
                blank_ts_valid = isempty(blank_timeseries) ? Float64[] : blank_timeseries[valid_indices]

                response_data = fit_well_data(
                    time_numeric[valid_indices], od_raw[valid_indices],
                    blank_value, calibration_file, well, experiment;
                    subtract_blank   = subtract_blank,
                    blank_method     = blank_method,
                    blank_timeseries = blank_ts_valid,
                    blank_well_names = blank_well_names,
                    model_name       = model_name,
                )
                return HTTP.Response(200, headers, JSON3.write(response_data))

            catch e
                println("Error in curve fitting: ", e)
                return HTTP.Response(500, headers, JSON3.write(Dict("error" => "Curve fitting failed: $e")))
            end
            
        elseif path == "/api/blank-analysis" && HTTP.method(req) == "POST"
            # POST /api/blank-analysis - Analyse a well's OD vs blank and recommend subtraction method
            body = String(req.body)
            request_data = JSON3.read(body)
            experiment = string(request_data.experiment)
            well       = string(request_data.well)

            try
                data_file       = joinpath(CLEAN_DATA_PATH, experiment, "data_channel_1.csv")
                annotation_file = joinpath(CLEAN_DATA_PATH, experiment, "annotation_clean.csv")

                if !isfile(data_file)
                    return HTTP.Response(404, headers, JSON3.write(Dict("error" => "Data file not found")))
                end

                growth_data      = CSV.read(data_file, DataFrame, header=1, silencewarnings=true)

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
                    return HTTP.Response(200, headers, JSON3.write(Dict(
                        "has_blank_wells"      => false,
                        "blank_wells"          => String[],
                        "blank_value"          => 0.0,
                        "recommendation"       => "none",
                        "auto_detected_wells"  => auto_wells,
                        "message"              => isempty(auto_wells)
                            ? "No blank wells found in annotation and none could be detected automatically."
                            : "No blank wells annotated. Auto-detected $(length(auto_wells)) candidate blank well(s) based on flat curve and low OD: $(join(auto_wells, ", ")).",
                    )))
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

                return HTTP.Response(200, headers, JSON3.write(Dict(
                    "has_blank_wells"      => true,
                    "blank_wells"          => blank_well_names,
                    "blank_value"          => blank_value,
                    "frac_below_global"    => frac_below_global,
                    "frac_below_pbp"       => frac_below_pbp,
                    "min_corrected_global" => min_global,
                    "min_corrected_pbp"    => min_pbp,
                    "recommendation"       => recommendation,
                    "method_notes"         => method_notes,
                )))
            catch e
                println("Error in blank analysis: ", e)
                return HTTP.Response(500, headers, JSON3.write(Dict("error" => "Blank analysis failed: $e")))
            end

        elseif path == "/api/fit-replicate" && HTTP.method(req) == "POST"
            # POST /api/fit-replicate - Fit averaged replicate data
            body = String(req.body)
            request_data = JSON3.read(body)

            well_selections  = request_data.well_selections
            label            = string(get(request_data, :label, "replicate"))
            experiment_name  = string(get(request_data, :experiment, "replicate"))
            model_name       = string(get(request_data, :model_name, "aHPM"))
            calibration_file = "./cal_curve_avg.csv"
            if !haskey(MODEL_REGISTRY, model_name)
                return HTTP.Response(400, headers, JSON3.write(Dict("error" => "Unknown model: $model_name")))
            end

            try
                all_od_data   = Vector{Vector{Float64}}()
                all_time_data = Vector{Vector{Float64}}()

                for sel in well_selections
                    exp     = string(sel.experiment)
                    well    = string(sel.well)
                    channel = Int(get(sel, :channel, 1))

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
                    return HTTP.Response(400, headers, JSON3.write(Dict("error" => "No valid well data found")))
                end

                # Average across wells (align by minimum length)
                min_len  = minimum(length.(all_od_data))
                avg_time = all_time_data[1][1:min_len]
                avg_od   = sum(od[1:min_len] for od in all_od_data) ./ length(all_od_data)

                valid_indices = findall(.!isnan.(avg_od))
                if length(valid_indices) < 10
                    return HTTP.Response(400, headers, JSON3.write(Dict("error" => "Not enough valid data points for fitting")))
                end

                response_data = fit_well_data(
                    avg_time[valid_indices], avg_od[valid_indices],
                    0.0, calibration_file, label, experiment_name;
                    model_name = model_name,
                )
                return HTTP.Response(200, headers, JSON3.write(response_data))

            catch e
                println("Error in replicate fitting: ", e)
                return HTTP.Response(500, headers, JSON3.write(Dict("error" => "Replicate fitting failed: $e")))
            end

        elseif path == "/api/batch-fit" && HTTP.method(req) == "POST"
            # POST /api/batch-fit - Fit multiple wells from a cleaned experiment
            body = String(req.body)
            request_data = JSON3.read(body)

            experiment     = string(request_data.experiment)
            model_name     = string(get(request_data, :model_name, "aHPM"))
            subtract_blank = Bool(get(request_data, :blank_subtraction, false))
            blank_method   = string(get(request_data, :blank_method, "pointbypoint"))
            # "wells" is optional — if omitted, fit all non-blank wells
            requested_wells = haskey(request_data, :wells) ?
                String[string(w) for w in request_data.wells] : nothing

            if model_name != "auto" && !haskey(MODEL_REGISTRY, model_name)
                return HTTP.Response(400, headers, JSON3.write(Dict("error" => "Unknown model: $model_name")))
            end

            try
                data_file        = joinpath(CLEAN_DATA_PATH, experiment, "data_channel_1.csv")
                annotation_file  = joinpath(CLEAN_DATA_PATH, experiment, "annotation_clean.csv")
                calibration_file = "./cal_curve_avg.csv"

                if !isfile(data_file) || !isfile(annotation_file)
                    return HTTP.Response(404, headers, JSON3.write(Dict("error" => "Data files not found for experiment '$experiment'")))
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

                results  = Dict{String, Any}[]
                errors   = String[]

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
                        )
                        push!(results, fit_result)
                    catch e
                        push!(errors, "Well '$well': $(string(e))")
                    end
                end

                return HTTP.Response(200, headers, JSON3.write(Dict(
                    "experiment" => experiment,
                    "model"      => model_name,
                    "results"    => results,
                    "summary"    => Dict(
                        "total"   => length(wells_to_fit),
                        "success" => length(results),
                        "failed"  => length(errors),
                        "errors"  => errors,
                    ),
                )))

            catch e
                println("Error in batch fitting: ", e)
                return HTTP.Response(500, headers, JSON3.write(Dict("error" => "Batch fitting failed: $e")))
            end

        elseif path == "/api/plot-data" && HTTP.method(req) == "POST"
            # POST /api/plot-data - Get plot data for specific wells (supports multi-experiment)
            body = String(req.body)
            request_data = JSON3.read(body)
            
            # Handle both single and multi-experiment requests
            if haskey(request_data, "well_selections")
                # Multi-experiment format: [{"experiment": "LG166", "well": "A1"}, ...]
                well_selections = request_data.well_selections
                traces = []
                stats = []
                
                for selection in well_selections
                    experiment = selection.experiment
                    well       = selection.well
                    channel    = Int(get(selection, :channel, 1))

                    data_file       = joinpath(CLEAN_DATA_PATH, experiment, "data_channel_$(channel).csv")
                    annotation_file = find_annotation_file(joinpath(CLEAN_DATA_PATH, experiment), channel)

                    if isfile(data_file) && annotation_file !== nothing
                        try
                            growth_data = CSV.read(data_file, DataFrame, header=1, silencewarnings=true)
                            annotations = CSV.read(annotation_file, DataFrame, header=false, silencewarnings=true, stringtype=String)
                            
                            # Rename columns
                            col_names = names(annotations)
                            new_names = [:well, :condition]
                            for i in 3:length(col_names)
                                if i == 5
                                    push!(new_names, :antibiotic)
                                else
                                    push!(new_names, Symbol(col_names[i]))
                                end
                            end
                            rename!(annotations, new_names)
                            
                            blank_wells = get_blank_wells(annotations)
                            if well in names(growth_data) && !(well in blank_wells)
                                # Process this well
                                time_col = names(growth_data)[1]
                                time_data = growth_data[!, time_col]
                                
                                # Parse time data
                                if eltype(time_data) <: AbstractString
                                    try
                                        time_numeric = [parse(Float64, t) for t in time_data[2:end]]
                                        time_numeric = [0.0; time_numeric]
                                    catch
                                        time_numeric = Float64.(0:(nrow(growth_data)-1))
                                    end
                                else
                                    time_numeric = Float64.(time_data)
                                end
                                
                                well_data = growth_data[!, well]
                                
                                # Convert to numeric
                                od_data = Float64[]
                                for val in well_data
                                    try
                                        push!(od_data, parse(Float64, string(val)))
                                    catch
                                        push!(od_data, NaN)
                                    end
                                end
                                
                                # Get condition including columns 3 and 4, and antibiotic
                                condition_parts = ["Unknown"]
                                antibiotic = "Unknown"
                                well_annotation = filter(row -> row.well == well, annotations)
                                if nrow(well_annotation) > 0
                                    row = well_annotation[1, :]
                                    condition_parts = [string(row.condition)]
                                    
                                    # Add columns 3 and 4 if they exist and have values
                                    col_names = names(annotations)
                                    if length(col_names) >= 3 && !ismissing(row[col_names[3]]) && string(row[col_names[3]]) != ""
                                        push!(condition_parts, string(row[col_names[3]]))
                                    end
                                    if length(col_names) >= 4 && !ismissing(row[col_names[4]]) && string(row[col_names[4]]) != ""
                                        push!(condition_parts, string(row[col_names[4]]))
                                    end
                                    
                                    # Add antibiotic from column 5 (only present in 7-column annotation_clean.csv)
                                    if "antibiotic" in names(annotations) && !ismissing(row.antibiotic) && string(row.antibiotic) != ""
                                        antibiotic = string(row.antibiotic)
                                    end
                                end

                                condition = join(condition_parts, " | ")

                                # Calculate statistics
                                valid_od = filter(!isnan, od_data)
                                max_od = isempty(valid_od) ? 0.0 : maximum(valid_od)
                                final_od = isempty(valid_od) ? 0.0 : last(valid_od)
                                
                                # Calculate AUC
                                auc = 0.0
                                valid_indices = findall(!isnan, od_data)
                                if length(valid_indices) > 1
                                    for i in 2:length(valid_indices)
                                        dt = time_numeric[valid_indices[i]] - time_numeric[valid_indices[i-1]]
                                        avg_od = (od_data[valid_indices[i]] + od_data[valid_indices[i-1]]) / 2
                                        auc += dt * avg_od
                                    end
                                end
                                
                                push!(traces, Dict(
                                    "well"      => "$(experiment)_$(well)",
                                    "well_name" => well,
                                    "experiment" => experiment,
                                    "channel"   => channel,
                                    "condition" => condition,
                                    "antibiotic" => antibiotic,
                                    "x" => time_numeric,
                                    "y" => od_data
                                ))
                                
                                push!(stats, Dict(
                                    "well" => "$(experiment)_$(well)",
                                    "experiment" => experiment,
                                    "condition" => condition,
                                    "antibiotic" => antibiotic,
                                    "max_od" => round(max_od, digits=3),
                                    "final_od" => round(final_od, digits=3),
                                    "auc" => round(auc, digits=2)
                                ))
                            end
                        catch e
                            println("Error processing $experiment/$well: $e")
                        end
                    end
                end
                
                plot_data = Dict("traces" => traces, "stats" => stats)
            else
                # Original single-experiment format
                experiment = request_data.experiment
                wells = request_data.wells
            
                # Inline plot data function to avoid scoping issues
            data_file = joinpath(CLEAN_DATA_PATH, experiment, "data_channel_1.csv")
            annotation_file = joinpath(CLEAN_DATA_PATH, experiment, "annotation_clean.csv")
            
            if !isfile(data_file) || !isfile(annotation_file)
                plot_data = nothing
            else
                try
                    growth_data = CSV.read(data_file, DataFrame, header=1, silencewarnings=true)
                    annotations = CSV.read(annotation_file, DataFrame, header=false, silencewarnings=true)
                    
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
                    time_data = growth_data[!, time_col]
                    
                    # Parse time data
                    if eltype(time_data) <: AbstractString
                        try
                            time_numeric = [parse(Float64, t) for t in time_data[2:end]]
                            time_numeric = [0.0; time_numeric]
                        catch
                            time_numeric = Float64.(0:(nrow(growth_data)-1))
                        end
                    else
                        time_numeric = Float64.(time_data)
                    end
                    
                    # Prepare data for each well
                    traces = []
                    stats = []
                    
                    blank_wells = get_blank_wells(annotations)
                    for well in wells
                        # Only process wells that aren't blank wells and exist in the data
                        if well in names(growth_data) && !(well in blank_wells)
                            well_data = growth_data[!, well]
                            
                            # Convert to numeric
                            od_data = Float64[]
                            for val in well_data
                                try
                                    push!(od_data, parse(Float64, string(val)))
                                catch
                                    push!(od_data, NaN)
                                end
                            end
                            
                            # Get condition including columns 3 and 4, and antibiotic
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
                                if :antibiotic in names(row) && !ismissing(row.antibiotic) && string(row.antibiotic) != ""
                                    antibiotic = string(row.antibiotic)
                                else
                                    antibiotic = "None"
                                end
                            end
                            
                            condition = join(condition_parts, " | ")
                            
                            # Calculate statistics
                            valid_od = filter(!isnan, od_data)
                            max_od = isempty(valid_od) ? 0.0 : maximum(valid_od)
                            final_od = isempty(valid_od) ? 0.0 : last(valid_od)
                            
                            # Calculate AUC using trapezoidal rule
                            auc = 0.0
                            valid_indices = findall(!isnan, od_data)
                            if length(valid_indices) > 1
                                for i in 2:length(valid_indices)
                                    dt = time_numeric[valid_indices[i]] - time_numeric[valid_indices[i-1]]
                                    avg_od = (od_data[valid_indices[i]] + od_data[valid_indices[i-1]]) / 2
                                    auc += dt * avg_od
                                end
                            end
                            
                            push!(traces, Dict(
                                "well" => well,
                                "condition" => condition,
                                "antibiotic" => antibiotic,
                                "x" => time_numeric,
                                "y" => od_data
                            ))
                            
                            push!(stats, Dict(
                                "well" => well,
                                "condition" => condition,
                                "antibiotic" => antibiotic,
                                "max_od" => round(max_od, digits=3),
                                "final_od" => round(final_od, digits=3),
                                "auc" => round(auc, digits=2)
                            ))
                        end
                    end
                    
                    plot_data = Dict("traces" => traces, "stats" => stats)
                catch e
                    println("Error getting plot data: $e")
                    plot_data = nothing
                end
            end  # End of else block for single experiment
            end  # End of if haskey(request_data, "well_selections")
            
            if plot_data !== nothing
                return HTTP.Response(200, headers, JSON3.write(plot_data))
            else
                return HTTP.Response(404, headers, JSON3.write(Dict("error" => "Data not found")))
            end
            
        elseif path == "/api/cluster" && HTTP.method(req) == "POST"
            request_data = JSON3.read(String(req.body))
            k_input        = Int(get(request_data, :k, 3))
            normalize      = Bool(get(request_data, :normalize, false))
            smooth_method  = Symbol(get(request_data, :smooth_method, "lowess"))
            lowess_frac    = Float64(get(request_data, :lowess_frac, 0.05))
            gaussian_hmult = Float64(get(request_data, :gaussian_h_mult, 2.0))
            cluster_method = string(get(request_data, :cluster_method, "kmeans"))
            maxiter        = Int(get(request_data, :maxiter, 100))
            tol            = Float64(get(request_data, :tol, 1e-6))
            dbscan_eps     = Float64(get(request_data, :dbscan_eps, 1.0))
            dbscan_minpts  = Int(get(request_data, :dbscan_min_pts, 3))
            hclust_linkage = Symbol(get(request_data, :hclust_linkage, "ward"))
            subtract_blank    = Bool(get(request_data, :subtract_blank, false))
            blank_method      = string(get(request_data, :blank_method, "pointbypoint"))
            blank_range_thr   = Float64(get(request_data, :blank_range_thr, 0.005))
            blank_od_pct      = Float64(get(request_data, :blank_od_percentile, 0.10))

            times_all       = Vector{Vector{Float64}}()
            curves_all      = Vector{Vector{Float64}}()
            labels_all      = Vector{String}()
            # For experiment mode: store blank curves separately for subtraction
            blank_curves_all = Vector{Vector{Float64}}()
            blank_labels_used = Vector{String}()
            blank_source      = "none"   # "annotated" | "auto" | "none"

            if haskey(request_data, :csv)
                df       = CSV.read(IOBuffer(String(request_data[:csv])), DataFrame)
                csv_time = Float64.(df[!, names(df)[1]])
                for s in names(df)[2:end]
                    push!(times_all,  csv_time)
                    push!(curves_all, Float64.(df[!, s]))
                    push!(labels_all, String(s))
                end
            else
                for exp_name in String.(request_data[:experiments])
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
                        println("Error loading $exp_name for clustering: $e")
                    end
                end
            end

            isempty(curves_all) && return HTTP.Response(400, headers,
                JSON3.write(Dict("error" => "No data loaded")))

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
                        blank_curves_all = [curves[i, :] for i in blank_idxs]
                        blank_labels_used = labels_all[blank_idxs]
                        blank_source = "auto"
                        # Remove detected blanks from the data to be clustered
                        keep = setdiff(1:n_series, blank_idxs)
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
                gd_smooth = GrowthData(curves, times, labels_all)
                smooth_opts = FitOptions(
                    smooth             = true,
                    smooth_method      = smooth_method,
                    lowess_frac        = lowess_frac,
                    gaussian_h_mult    = gaussian_hmult,
                    cluster            = false,
                )
                gd_proc = preprocess(gd_smooth, smooth_opts)
                # After smoothing times may change (gaussian can resample); use
                # smoothed data but keep original times for display alignment.
                sm_curves = gd_proc.curves   # n_series × n_times matrix
                sm_times  = gd_proc.times
                # Trim both to same length in case of mismatch
                tlen = min(size(sm_curves, 2), length(times))
                curves_for_cluster = sm_curves[:, 1:tlen]
                times = sm_times[1:tlen]
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
                return HTTP.Response(400, headers,
                    JSON3.write(Dict("error" => "Unknown cluster_method: $cluster_method")))
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
            quality["silhouettes"]      = sil_per_series
            quality["series_labels"]    = labels_all

            return HTTP.Response(200, headers, JSON3.write(Dict(
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
            )))

        # ------------------------------------------------------------------
        # /api/cluster-sweep  — run clustering for k=2..k_max and return
        # quality indices per k so the user can find the best number of clusters.
        # ------------------------------------------------------------------
        elseif path == "/api/cluster-sweep" && HTTP.method(req) == "POST"
            request_data   = JSON3.read(String(req.body))
            k_max          = Int(get(request_data, :k_max, 10))
            smooth_method  = Symbol(get(request_data, :smooth_method, "lowess"))
            lowess_frac    = Float64(get(request_data, :lowess_frac, 0.05))
            gaussian_hmult = Float64(get(request_data, :gaussian_h_mult, 2.0))
            cluster_method = string(get(request_data, :cluster_method, "kmeans"))
            maxiter        = Int(get(request_data, :maxiter, 100))
            tol            = Float64(get(request_data, :tol, 1e-6))
            hclust_linkage = Symbol(get(request_data, :hclust_linkage, "ward"))

            # Re-use the same data-loading logic as /api/cluster
            times_all  = Vector{Vector{Float64}}()
            curves_all = Vector{Vector{Float64}}()
            labels_all = Vector{String}()

            if haskey(request_data, :csv)
                df       = CSV.read(IOBuffer(String(request_data[:csv])), DataFrame)
                csv_time = Float64.(df[!, names(df)[1]])
                for s in names(df)[2:end]
                    push!(times_all,  csv_time)
                    push!(curves_all, Float64.(df[!, s]))
                    push!(labels_all, String(s))
                end
            else
                for exp_name in String.(request_data[:experiments])
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
                        println("Error loading $exp_name for sweep: $e")
                    end
                end
            end

            isempty(curves_all) && return HTTP.Response(400, headers,
                JSON3.write(Dict("error" => "No data loaded")))

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

            sweep_results = []
            for k in 2:min(k_max, n_series)
                ids = try
                    if cluster_method == "kmeans"
                        Clustering.assignments(Clustering.kmeans(zscored', k; maxiter, tol))
                    elseif cluster_method == "kmedoids"
                        dmat = _pairwise_euclidean(zscored)
                        Clustering.assignments(Clustering.kmedoids(dmat, k; maxiter, tol))
                    elseif cluster_method == "hclust"
                        dmat = _pairwise_euclidean(zscored)
                        Clustering.cutree(Clustering.hclust(dmat; linkage=hclust_linkage); k)
                    else
                        Clustering.assignments(Clustering.kmeans(zscored', k; maxiter, tol))
                    end
                catch e
                    println("Sweep k=$k error: $e")
                    continue
                end

                ids_r, _ = _remap_ids(ids)
                q = _cluster_quality_indices(zscored, ids_r)
                push!(sweep_results, Dict(
                    "k"                 => k,
                    "silhouette_mean"   => q["silhouette_mean"],
                    "dunn"              => q["dunn"],
                    "davies_bouldin"    => q["davies_bouldin"],
                    "calinski_harabasz" => q["calinski_harabasz"],
                    "xie_beni"          => q["xie_beni"],
                ))
            end

            return HTTP.Response(200, headers, JSON3.write(Dict("sweep" => sweep_results)))

        # ------------------------------------------------------------------
        # /api/cluster-compare  — compare two saved clusterings
        # ------------------------------------------------------------------
        elseif path == "/api/cluster-compare" && HTTP.method(req) == "POST"
            request_data = JSON3.read(String(req.body))
            ids1 = Int.(request_data[:assignments1])
            ids2 = Int.(request_data[:assignments2])

            length(ids1) == length(ids2) || return HTTP.Response(400, headers,
                JSON3.write(Dict("error" => "assignments must have the same length")))

            result = _cluster_comparison(ids1, ids2)
            return HTTP.Response(200, headers, JSON3.write(result))

        elseif path == "/"
            # Serve the main HTML page
            html_file = joinpath(@__DIR__, "..", "web_interface.html")
            html_content = read(html_file, String)
            html_headers = cors_headers()
            push!(html_headers, "Content-Type" => "text/html")
            return HTTP.Response(200, html_headers, html_content)

        elseif startswith(path, "/static/")
            static_response = serve_static(req)
            if static_response !== nothing
                return static_response
            end
            return HTTP.Response(404, headers, JSON3.write(Dict("error" => "Not found")))

        else
            return HTTP.Response(404, headers, JSON3.write(Dict("error" => "Not found")))
        end
        
    catch e
        println("Error in router: $e")
        return HTTP.Response(500, headers, JSON3.write(Dict("error" => "Internal server error")))
    end
end
