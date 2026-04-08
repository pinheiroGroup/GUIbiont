@post "/api/plot-data" function(req::HTTP.Request)
    request_data = JSON3.read(String(req.body))

    # Handle both single and multi-experiment requests
    if haskey(request_data, "well_selections")
        # Multi-experiment format: [{"experiment": "LG166", "well": "A1"}, ...]
        well_selections = request_data.well_selections
        traces = []
        stats  = []

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
                        time_col  = names(growth_data)[1]
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
                            col_names_ann = names(annotations)
                            if length(col_names_ann) >= 3 && !ismissing(row[col_names_ann[3]]) && string(row[col_names_ann[3]]) != ""
                                push!(condition_parts, string(row[col_names_ann[3]]))
                            end
                            if length(col_names_ann) >= 4 && !ismissing(row[col_names_ann[4]]) && string(row[col_names_ann[4]]) != ""
                                push!(condition_parts, string(row[col_names_ann[4]]))
                            end

                            # Add antibiotic from column 5 (only present in 7-column annotation_clean.csv)
                            if "antibiotic" in names(annotations) && !ismissing(row.antibiotic) && string(row.antibiotic) != ""
                                antibiotic = string(row.antibiotic)
                            end
                        end

                        condition = join(condition_parts, " | ")

                        # Calculate statistics
                        valid_od = filter(!isnan, od_data)
                        max_od   = isempty(valid_od) ? 0.0 : maximum(valid_od)
                        final_od = isempty(valid_od) ? 0.0 : last(valid_od)

                        # Calculate AUC
                        auc = 0.0
                        valid_indices = findall(!isnan, od_data)
                        if length(valid_indices) > 1
                            for i in 2:length(valid_indices)
                                dt     = time_numeric[valid_indices[i]] - time_numeric[valid_indices[i-1]]
                                avg_od = (od_data[valid_indices[i]] + od_data[valid_indices[i-1]]) / 2
                                auc   += dt * avg_od
                            end
                        end

                        push!(traces, Dict(
                            "well"       => "$(experiment)_$(well)",
                            "well_name"  => well,
                            "experiment" => experiment,
                            "channel"    => channel,
                            "condition"  => condition,
                            "antibiotic" => antibiotic,
                            "x"          => time_numeric,
                            "y"          => od_data
                        ))

                        push!(stats, Dict(
                            "well"       => "$(experiment)_$(well)",
                            "experiment" => experiment,
                            "condition"  => condition,
                            "antibiotic" => antibiotic,
                            "max_od"     => round(max_od,   digits=3),
                            "final_od"   => round(final_od, digits=3),
                            "auc"        => round(auc,      digits=2)
                        ))
                    end
                catch e
                    @warn "Error processing $experiment/$well: $e"
                end
            end
        end

        return Dict("traces" => traces, "stats" => stats)
    else
        # Original single-experiment format
        experiment = request_data.experiment
        wells      = request_data.wells

        data_file       = joinpath(CLEAN_DATA_PATH, experiment, "data_channel_1.csv")
        annotation_file = joinpath(CLEAN_DATA_PATH, experiment, "annotation_clean.csv")

        if !isfile(data_file) || !isfile(annotation_file)
            return json(Dict("error" => "Data not found"); status=404)
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

            time_col  = names(growth_data)[1]
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
            stats  = []

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
                    max_od   = isempty(valid_od) ? 0.0 : maximum(valid_od)
                    final_od = isempty(valid_od) ? 0.0 : last(valid_od)

                    # Calculate AUC using trapezoidal rule
                    auc = 0.0
                    valid_indices = findall(!isnan, od_data)
                    if length(valid_indices) > 1
                        for i in 2:length(valid_indices)
                            dt     = time_numeric[valid_indices[i]] - time_numeric[valid_indices[i-1]]
                            avg_od = (od_data[valid_indices[i]] + od_data[valid_indices[i-1]]) / 2
                            auc   += dt * avg_od
                        end
                    end

                    push!(traces, Dict(
                        "well"       => well,
                        "condition"  => condition,
                        "antibiotic" => antibiotic,
                        "x"          => time_numeric,
                        "y"          => od_data
                    ))

                    push!(stats, Dict(
                        "well"       => well,
                        "condition"  => condition,
                        "antibiotic" => antibiotic,
                        "max_od"     => round(max_od,   digits=3),
                        "final_od"   => round(final_od, digits=3),
                        "auc"        => round(auc,      digits=2)
                    ))
                end
            end

            return Dict("traces" => traces, "stats" => stats)
        catch e
                        return json(Dict("error" => "Error getting plot data: $e"); status=500)
        end
    end
end
