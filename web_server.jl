using HTTP, JSON3, CSV, DataFrames, Statistics
include("function_for_fitting.jl")
include("function_clean_synergy.jl")

# Configuration - adjust paths for standalone deployment
const CLEAN_DATA_PATH = haskey(ENV, "CLEAN_DATA_PATH") ? ENV["CLEAN_DATA_PATH"] : "./Clean_data/"
const RAW_DATA_PATH = haskey(ENV, "RAW_DATA_PATH") ? ENV["RAW_DATA_PATH"] : "./raw_data/"
const PORT = haskey(ENV, "PORT") ? parse(Int, ENV["PORT"]) : 8080

# Helper function to determine blank wells from annotation data
function get_blank_wells(annotations::DataFrame)
    blank_wells = Set{String}()
    for i in 1:nrow(annotations)
        if length(annotations[i, :]) >= 2 && (annotations[i, 2] == "b" || annotations[i, 2] == "X" || annotations[i, 2] == "x")
            push!(blank_wells, string(annotations[i, 1]))
        end
    end
    return blank_wells
end

# CORS headers for allowing frontend requests
function cors_headers()
    return [
        "Access-Control-Allow-Origin" => "*",
        "Access-Control-Allow-Methods" => "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers" => "Content-Type"
    ]
end

# Handle CORS preflight requests
function handle_cors(req)
    if HTTP.method(req) == "OPTIONS"
        return HTTP.Response(200, cors_headers())
    end
    return nothing
end

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
                data_file = joinpath(CLEAN_DATA_PATH, experiment, "data_channel_1.csv")
                annotation_file = joinpath(CLEAN_DATA_PATH, experiment, "annotation_clean.csv")
                
                if isfile(data_file) && isfile(annotation_file)
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
                        
                        # Filter wells
                        all_well_columns = names(growth_data)[2:end]
                        blank_wells = get_blank_wells(annotations)
                        well_columns = filter(well -> !(string(well) in blank_wells), all_well_columns)
                        
                        # Add wells with experiment prefix
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
                                if !ismissing(row.antibiotic) && string(row.antibiotic) != ""
                                    antibiotic = string(row.antibiotic)
                                else
                                    antibiotic = "None"
                                end
                            end
                            
                            condition = join(condition_parts, " | ")
                            
                            push!(combined_wells, Dict(
                                "experiment" => experiment,
                                "well" => well,
                                "well_id" => "$(experiment)_$(well)",
                                "condition" => condition,
                                "antibiotic" => antibiotic,
                                "display_name" => "$(experiment): $(well) ($(condition)) [$(antibiotic)]"
                            ))
                        end
                    catch e
                        println("Error loading experiment $experiment for multi-select: $e")
                    end
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
            
            experiment = request_data.experiment
            well = request_data.well
            
            try
                data_file = joinpath(CLEAN_DATA_PATH, experiment, "data_channel_1.csv")
                annotation_file = joinpath(CLEAN_DATA_PATH, experiment, "annotation_clean.csv")
                calibration_file = "./cal_curve_avg.csv"
                
                if !isfile(data_file) || !isfile(annotation_file)
                    return HTTP.Response(404, headers, JSON3.write(Dict("error" => "Data files not found")))
                end
                
                # Read data files
                growth_data = CSV.read(data_file, DataFrame, header=1, silencewarnings=true)
                
                # Read annotation file with error handling for missing values
                annotations = try
                    CSV.read(annotation_file, DataFrame, header=false, silencewarnings=true, stringtype=String)
                catch e
                    # If CSV reading fails due to missing values, preprocess the file
                    println("Warning: Issues reading annotation file. Preprocessing...")
                    raw_annotations = CSV.File(annotation_file, header=false) |> DataFrame
                    
                    # Handle missing values and inconsistent columns
                    for i in 1:nrow(raw_annotations)
                        # Handle empty second column specifically
                        if ncol(raw_annotations) >= 2 && (ismissing(raw_annotations[i, 2]) || raw_annotations[i, 2] == "")
                            raw_annotations[i, 2] = "X"  # Mark as excluded well
                        end
                        
                        # Replace all missing values with empty strings
                        for j in 1:ncol(raw_annotations)
                            if ismissing(raw_annotations[i, j])
                                raw_annotations[i, j] = ""
                            end
                        end
                    end
                    
                    # Convert to strings and return
                    DataFrame([string.(col) for col in eachcol(raw_annotations)], :auto)
                end
                
                # Additional check for missing values in second column
                for i in 1:nrow(annotations)
                    if ncol(annotations) >= 2 && (ismissing(annotations[i, 2]) || annotations[i, 2] == "" || annotations[i, 2] == "missing")
                        annotations[i, 2] = "X"  # Mark as excluded well
                    end
                end
                
                # Process annotation file to find blanks
                list_of_blank = []
                for i in 1:nrow(annotations)
                    if length(annotations[i, :]) >= 2 && (annotations[i, 2] == "b" || annotations[i, 2] == "X")
                        push!(list_of_blank, Symbol(annotations[i, 1]))
                    end
                end
                
                # Get time data
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
                
                # Filter wells (exclude blanks like in the regular API)
                all_well_columns = names(growth_data)[2:end]
                blank_wells = get_blank_wells(annotations)
                well_columns = filter(well_name -> !(string(well_name) in blank_wells), all_well_columns)
                
                # Get well data
                println("Debug - Requested well: '$well'")
                println("Debug - All wells: $all_well_columns")
                println("Debug - Filtered wells: $well_columns")
                println("Debug - Looking for Symbol: $(Symbol(well))")
                println("Debug - Growth data column names: $(names(growth_data))")
                println("Debug - Growth data column types: $(typeof.(names(growth_data)))")
                
                # Convert column names to strings for comparison
                column_names_str = string.(names(growth_data))
                println("Debug - Column names as strings: $column_names_str")
                println("Debug - Well '$well' in column names: $(well in column_names_str)")
                
                well_symbol = Symbol(well)
                if !(well in column_names_str)
                    return HTTP.Response(404, headers, JSON3.write(Dict("error" => "Well '$well' not found in data columns: $column_names_str")))
                end
                
                # Also check if the well is in the filtered list (not a blank)
                well_columns_str = string.(well_columns)
                if !(well in well_columns_str)
                    return HTTP.Response(400, headers, JSON3.write(Dict("error" => "Well '$well' appears to be a blank well. Please select a data well from: $well_columns_str")))
                end
                
                well_data = growth_data[!, well_symbol]
                od_data = Float64[]
                for val in well_data
                    try
                        push!(od_data, parse(Float64, string(val)))
                    catch
                        push!(od_data, NaN)
                    end
                end
                
                # Calculate blank value for subtraction
                blank_value = 0.0
                if !isempty(list_of_blank)
                    blank_values = []
                    for blank_well in list_of_blank
                        if blank_well in names(growth_data)
                            blank_well_data = growth_data[!, blank_well]
                            for val in blank_well_data
                                try
                                    push!(blank_values, parse(Float64, string(val)))
                                catch
                                    # Skip non-numeric values
                                end
                            end
                        end
                    end
                    if !isempty(blank_values)
                        blank_value = mean(filter(!isnan, blank_values))
                    end
                end
                
                # Subtract blank
                od_data = od_data .- blank_value
                
                # Remove negative values
                od_data = max.(od_data, 0.01)
                
                # Create data matrix for fitting (2 x n matrix: time, OD)
                valid_indices = findall(.!isnan.(od_data))
                if length(valid_indices) < 10
                    return HTTP.Response(400, headers, JSON3.write(Dict("error" => "Not enough valid data points for fitting")))
                end
                
                data_matrix = hcat(time_numeric[valid_indices], od_data[valid_indices])'
                
                # Apply multiple scattering correction if calibration file exists
                if isfile(calibration_file)
                    try
                        data_matrix = correction_OD_multiple_scattering(data_matrix, calibration_file; method="interpolation")
                    catch e
                        println("Warning: Could not apply calibration correction: ", e)
                    end
                end
                
                # Smoothing (rolling average with 14 points as in the original)
                try
                    data_matrix = Kinbiont.smoothing_data(data_matrix; method="rolling_avg", pt_avg=14)
                catch e
                    println("Warning: Could not apply smoothing: ", e)
                end
                
                # Find stationary phase
                data_cut = find_stationary_phase(data_matrix; percentile_thr=0.05, pt_smooth_derivative=10, win_size=5)
                if data_cut === nothing
                    data_cut = data_matrix
                end
                
                # Fit aHPM model
                model = "aHPM"
                param = [0.2, 0.2, 0.80, 1.0]
                
                fit_results = fitting_one_well_ODE_constrained(
                    data_cut,
                    string(well),
                    experiment,
                    model,
                    param;
                    pt_avg=3,
                    pt_smooth_derivative=10,
                    multiple_scattering_correction=false,
                    lb=[0.0, 0.0, 0.0, 0.0],
                    ub=param.*10
                )
                
                # Extract fit results
                fit_times = fit_results[4]
                fit_values = fit_results[3]
                fitted_parameters = fit_results[2]
                
                # Prepare response
                response_data = Dict(
                    "experiment" => experiment,
                    "well" => well,
                    "experimental_time" => time_numeric[valid_indices],
                    "experimental_od" => od_data[valid_indices],
                    "fit_time" => fit_times,
                    "fit_od" => fit_values,
                    "parameters" => fitted_parameters,
                    "model" => model,
                    "blank_value" => blank_value,
                    "stationary_phase_start" => data_cut[1, end]
                )
                
                return HTTP.Response(200, headers, JSON3.write(response_data))
                
            catch e
                println("Error in curve fitting: ", e)
                return HTTP.Response(500, headers, JSON3.write(Dict("error" => "Curve fitting failed: $e")))
            end
            
        elseif path == "/api/fit-replicate" && HTTP.method(req) == "POST"
            # POST /api/fit-replicate - Fit averaged replicate data
            body = String(req.body)
            request_data = JSON3.read(body)

            well_selections = request_data.well_selections
            label = string(get(request_data, :label, "replicate"))
            experiment_name = string(get(request_data, :experiment, "replicate"))

            try
                # Group selections by experiment to load each file only once
                exp_wells = Dict{String, Vector{String}}()
                for sel in well_selections
                    exp = string(sel.experiment)
                    well = string(sel.well)
                    if !haskey(exp_wells, exp)
                        exp_wells[exp] = String[]
                    end
                    push!(exp_wells[exp], well)
                end

                all_od_data = Vector{Vector{Float64}}()
                all_time_data = Vector{Vector{Float64}}()

                for (exp, wells) in exp_wells
                    data_file = joinpath(CLEAN_DATA_PATH, exp, "data_channel_1.csv")
                    annotation_file = joinpath(CLEAN_DATA_PATH, exp, "annotation_clean.csv")
                    if !isfile(data_file) || !isfile(annotation_file)
                        continue
                    end

                    growth_data = CSV.read(data_file, DataFrame, header=1, silencewarnings=true)
                    annotations = CSV.read(annotation_file, DataFrame, header=false, silencewarnings=true, stringtype=String)

                    # Identify blank wells
                    list_of_blank = []
                    for i in 1:nrow(annotations)
                        if length(annotations[i, :]) >= 2 && (annotations[i, 2] == "b" || annotations[i, 2] == "X")
                            push!(list_of_blank, Symbol(annotations[i, 1]))
                        end
                    end

                    # Parse time column
                    time_col = names(growth_data)[1]
                    time_raw = growth_data[!, time_col]
                    if eltype(time_raw) <: AbstractString
                        try
                            time_numeric = [parse(Float64, t) for t in time_raw[2:end]]
                            time_numeric = [0.0; time_numeric]
                        catch
                            time_numeric = Float64.(0:(nrow(growth_data)-1))
                        end
                    else
                        time_numeric = Float64.(time_raw)
                    end

                    # Compute blank value for this experiment
                    blank_value = 0.0
                    if !isempty(list_of_blank)
                        blank_vals = Float64[]
                        for bw in list_of_blank
                            if bw in names(growth_data)
                                for val in growth_data[!, bw]
                                    try push!(blank_vals, parse(Float64, string(val))) catch _ end
                                end
                            end
                        end
                        if !isempty(blank_vals)
                            blank_value = mean(filter(!isnan, blank_vals))
                        end
                    end

                    col_names_str = string.(names(growth_data))
                    for well in wells
                        if !(well in col_names_str)
                            continue
                        end
                        well_sym = Symbol(well)
                        od = Float64[]
                        for val in growth_data[!, well_sym]
                            try push!(od, parse(Float64, string(val))) catch _ push!(od, NaN) end
                        end
                        od = od .- blank_value
                        od = max.(od, 0.01)
                        push!(all_od_data, od)
                        push!(all_time_data, time_numeric)
                    end
                end

                if isempty(all_od_data)
                    return HTTP.Response(400, headers, JSON3.write(Dict("error" => "No valid well data found")))
                end

                # Average across wells (align by minimum length)
                min_len = minimum(length.(all_od_data))
                avg_time = all_time_data[1][1:min_len]
                avg_od = zeros(Float64, min_len)
                for od in all_od_data
                    avg_od .+= od[1:min_len]
                end
                avg_od ./= length(all_od_data)

                valid_indices = findall(.!isnan.(avg_od))
                if length(valid_indices) < 10
                    return HTTP.Response(400, headers, JSON3.write(Dict("error" => "Not enough valid data points for fitting")))
                end

                data_matrix = hcat(avg_time[valid_indices], avg_od[valid_indices])'

                try
                    data_matrix = Kinbiont.smoothing_data(data_matrix; method="rolling_avg", pt_avg=14)
                catch e
                    println("Warning: smoothing failed: ", e)
                end

                data_cut = find_stationary_phase(data_matrix; percentile_thr=0.05, pt_smooth_derivative=10, win_size=5)
                if data_cut === nothing
                    data_cut = data_matrix
                end

                model = "aHPM"
                param = [0.2, 0.2, 0.80, 1.0]
                fit_results = fitting_one_well_ODE_constrained(
                    data_cut, label, experiment_name, model, param;
                    pt_avg=3, pt_smooth_derivative=10,
                    multiple_scattering_correction=false,
                    lb=[0.0, 0.0, 0.0, 0.0], ub=param.*10
                )

                response_data = Dict(
                    "experiment" => experiment_name,
                    "well" => label,
                    "experimental_time" => avg_time[valid_indices],
                    "experimental_od" => avg_od[valid_indices],
                    "fit_time" => fit_results[4],
                    "fit_od" => fit_results[3],
                    "parameters" => fit_results[2],
                    "model" => model,
                    "blank_value" => 0.0,
                    "stationary_phase_start" => data_cut[1, end]
                )
                return HTTP.Response(200, headers, JSON3.write(response_data))

            catch e
                println("Error in replicate fitting: ", e)
                return HTTP.Response(500, headers, JSON3.write(Dict("error" => "Replicate fitting failed: $e")))
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
                    well = selection.well
                    
                    data_file = joinpath(CLEAN_DATA_PATH, experiment, "data_channel_1.csv")
                    annotation_file = joinpath(CLEAN_DATA_PATH, experiment, "annotation_clean.csv")
                    
                    if isfile(data_file) && isfile(annotation_file)
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
                                    
                                    # Add antibiotic from column 5
                                    if !ismissing(row.antibiotic) && string(row.antibiotic) != ""
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
                                    "well" => "$(experiment)_$(well)",
                                    "experiment" => experiment,
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
            k_input   = Int(request_data["k"])
            normalize = Bool(get(request_data, "normalize", false))

            times_all  = Vector{Vector{Float64}}()
            curves_all = Vector{Vector{Float64}}()
            labels_all = Vector{String}()

            if haskey(request_data, "csv")
                # From file: first column = Time, rest = series
                df       = CSV.read(IOBuffer(String(request_data["csv"])), DataFrame)
                csv_time = Float64.(df[!, names(df)[1]])
                for s in names(df)[2:end]
                    push!(times_all,  csv_time)
                    push!(curves_all, Float64.(df[!, s]))
                    push!(labels_all, String(s))
                end
            else
                # From experiments: load all non-blank wells
                for exp_name in String.(request_data["experiments"])
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
                        time_data = gd_raw[!, names(gd_raw)[1]]
                        if eltype(time_data) <: AbstractString
                            try
                                time_numeric = [0.0; [parse(Float64, t) for t in time_data[2:end]]]
                            catch _
                                time_numeric = Float64.(0:(nrow(gd_raw)-1))
                            end
                        else
                            time_numeric = Float64.(time_data)
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
                        println("Error loading $exp_name for clustering: $e")
                    end
                end
            end

            isempty(curves_all) && return HTTP.Response(400, headers,
                JSON3.write(Dict("error" => "No data loaded")))

            # Align all series to minimum length
            min_len  = minimum(length.(curves_all))
            times    = times_all[1][1:min_len]
            n_series = length(curves_all)
            curves   = Matrix{Float64}(undef, n_series, min_len)
            for (i, c) in enumerate(curves_all)
                curves[i, :] = c[1:min_len]
            end

            gd   = GrowthData(curves, times, labels_all)
            opts = FitOptions(
                cluster            = true,
                n_clusters         = min(k_input, n_series),
                cluster_trend_test = false,
            )
            processed   = preprocess(gd, opts)
            cluster_ids = processed.clusters

            # Optionally z-score curves for display
            display_curves = copy(curves)
            if normalize
                for i in 1:n_series
                    row = display_curves[i, :]
                    s   = std(row)
                    s > 1e-12 && (display_curves[i, :] = (row .- mean(row)) ./ s)
                end
            end

            clusters = []
            for c in 1:min(k_input, n_series)
                mask = findall(cluster_ids .== c)
                isempty(mask) && continue
                push!(clusters, Dict(
                    "id"            => c,
                    "series_labels" => labels_all[mask],
                    "series_data"   => [display_curves[i, :] for i in mask]
                ))
            end

            return HTTP.Response(200, headers, JSON3.write(Dict(
                "time"     => times,
                "clusters" => clusters
            )))

        elseif path == "/"
            # Serve the main HTML page
            html_content = read("web_interface.html", String)
            html_headers = cors_headers()
            push!(html_headers, "Content-Type" => "text/html")
            return HTTP.Response(200, html_headers, html_content)
            
        else
            return HTTP.Response(404, headers, JSON3.write(Dict("error" => "Not found")))
        end
        
    catch e
        println("Error in router: $e")
        return HTTP.Response(500, headers, JSON3.write(Dict("error" => "Internal server error")))
    end
end

# Start the server
function start_server(port=PORT)
    println("🚀 Starting Growth Curve Web Server...")
    println("📊 Clean data path: $CLEAN_DATA_PATH")
    println("🌐 Server will run at: http://localhost:$port")
    println("📋 Available experiments: $(length(get_experiments()))")
    println("\nPress Ctrl+C to stop the server")
    
    try
        HTTP.serve(router, "0.0.0.0", port)
    catch e
        if isa(e, InterruptException)
            println("\n👋 Server stopped")
        else
            println("❌ Error: $e")
        end
    end
end

# Run the server if this file is executed directly
if abspath(PROGRAM_FILE) == @__FILE__
    start_server()
end
