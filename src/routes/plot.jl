_nan_to_null(v::Vector{Float64}) = Union{Float64,Nothing}[isnan(x) ? nothing : x for x in v]

function _plot_stationary_stats(
    time_numeric::Vector{Float64},
    od_data::Vector{Float64},
)
    n = min(length(time_numeric), length(od_data))
    valid = findall(i -> isfinite(time_numeric[i]) && isfinite(od_data[i]), 1:n)
    isempty(valid) && return (specific_growth_rate=nothing, saturation_od=nothing)

    data_mat = Matrix(transpose(hcat(time_numeric[valid], od_data[valid])))
    opts = FitOptions()

    try
        # Use Kinbiont's standard detector: its reference mu is maximum(sgr),
        # not an externally supplied log-linear estimate.
        cutoff = Kinbiont._find_stationary_cutoff(data_mat, opts)
        above_threshold = findall(data_mat[2, :] .> opts.stationary_thr_od)
        isempty(above_threshold) &&
            return (specific_growth_rate=nothing, saturation_od=nothing)

        sgr = Kinbiont.specific_gr_evaluation(
            data_mat[:, above_threshold],
            opts.stationary_pt_smooth_derivative,
        )
        sgr_values = sgr isa Real ? [Float64(sgr)] : Float64.(sgr)
        finite_sgr = filter(isfinite, sgr_values)
        isempty(finite_sgr) &&
            return (specific_growth_rate=nothing, saturation_od=nothing)

        specific_growth_rate = maximum(finite_sgr)
        saturation_od = Float64(data_mat[2, cutoff])
        return (
            specific_growth_rate=isfinite(specific_growth_rate) ? specific_growth_rate : nothing,
            saturation_od=isfinite(saturation_od) ? saturation_od : nothing,
        )
    catch e
        @debug "Unable to calculate stationary growth statistics" exception=(e, catch_backtrace())
        return (specific_growth_rate=nothing, saturation_od=nothing)
    end
end

function _rename_plot_annotations!(annotations::DataFrame)
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
    return annotations
end

_clean_cell_string(v) = ismissing(v) ? "" : strip(string(v))

function _annotation_row_metadata(row, ann_names; empty_antibiotic::String="None")
    condition_parts = String[]
    condition = _clean_cell_string(row.condition)
    push!(condition_parts, isempty(condition) ? "Unknown" : condition)

    for col in (:col_3, :col_4)
        if col in ann_names
            value = _clean_cell_string(row[col])
            isempty(value) || push!(condition_parts, value)
        end
    end

    antibiotic = empty_antibiotic
    if :antibiotic in ann_names
        value = _clean_cell_string(row.antibiotic)
        isempty(value) || (antibiotic = value)
    end

    return (condition=join(condition_parts, " | "), antibiotic=antibiotic)
end

function _annotation_metadata_map(annotations::DataFrame; empty_antibiotic::String="None")
    ann_names = propertynames(annotations)
    metadata = Dict{String,NamedTuple{(:condition, :antibiotic),Tuple{String,String}}}()

    for row in eachrow(annotations)
        metadata[string(row.well)] = _annotation_row_metadata(row, ann_names; empty_antibiotic)
    end

    return metadata
end

function _plot_annotation_files(exp_dir::String, channel::Int)
    all_files = try readdir(exp_dir) catch; String[] end
    prefix = "annotation_channel_$(channel)_"
    ann_files = [joinpath(exp_dir, f) for f in sort(filter(f -> startswith(f, prefix) && endswith(f, ".csv"), all_files))]

    if isempty(ann_files)
        ann_file = find_annotation_file(exp_dir, channel)
        ann_file !== nothing && push!(ann_files, ann_file)
    end

    return ann_files
end

function _plot_annotation_context(exp_dir::String, channel::Int; empty_antibiotic::String="None")
    metadata = Dict{String,NamedTuple{(:condition, :antibiotic),Tuple{String,String}}}()
    excluded_candidates = Set{String}()
    valid_wells = Set{String}()

    for ann_file in _plot_annotation_files(exp_dir, channel)
        annotations = _rename_plot_annotations!(read_annotation_file(ann_file))
        ann_names = propertynames(annotations)

        for row in eachrow(annotations)
            well = string(row.well)
            status = _clean_cell_string(row.condition)
            if status in ("b", "X", "x")
                push!(excluded_candidates, well)
            else
                push!(valid_wells, well)
                metadata[well] = _annotation_row_metadata(row, ann_names; empty_antibiotic)
            end
        end
    end

    return metadata, setdiff(excluded_candidates, valid_wells)
end

function _growth_curve_summary(time_numeric::Vector{Float64}, od_data::Vector{Float64})
    max_od = 0.0
    final_od = 0.0
    auc = 0.0
    have_valid = false
    prev_idx = 0
    prev_od = 0.0

    @inbounds for i in eachindex(od_data)
        od = od_data[i]
        isfinite(od) || continue

        if have_valid
            max_od = max(max_od, od)
            dt = time_numeric[i] - time_numeric[prev_idx]
            auc += dt * (od + prev_od) / 2
        else
            max_od = od
            have_valid = true
        end

        final_od = od
        prev_idx = i
        prev_od = od
    end

    return max_od, final_od, auc
end

function _plot_trace_and_stat(
    experiment::String,
    well::String,
    channel::Int,
    time_numeric::Vector{Float64},
    od_data::Vector{Float64},
    metadata;
    multi_experiment::Bool,
)
    meta = get(metadata, well, (condition="Unknown", antibiotic="Unknown"))
    max_od, final_od, auc = _growth_curve_summary(time_numeric, od_data)
    stationary_stats = _plot_stationary_stats(time_numeric, od_data)
    well_id = multi_experiment ? "$(experiment)_$(well)" : well

    trace = Dict(
        "well"       => well_id,
        "condition"  => meta.condition,
        "antibiotic" => meta.antibiotic,
        "x"          => time_numeric,
        "y"          => _nan_to_null(od_data),
    )

    stat = Dict(
        "well"       => well_id,
        "condition"  => meta.condition,
        "antibiotic" => meta.antibiotic,
        "specific_growth_rate" => stationary_stats.specific_growth_rate === nothing ? nothing : round(stationary_stats.specific_growth_rate, digits=4),
        "saturation_od"        => stationary_stats.saturation_od === nothing ? nothing : round(stationary_stats.saturation_od, digits=3),
        "max_od"               => round(max_od, digits=3),
        "final_od"             => round(final_od, digits=3),
        "auc"                  => round(auc, digits=2),
    )

    if multi_experiment
        trace["well_name"] = well
        trace["experiment"] = experiment
        trace["channel"] = channel
        stat["experiment"] = experiment
    end

    return trace, stat
end

@post "/api/plot-data" function(req::HTTP.Request)
    request_data = JSON3.read(String(req.body))

    # Handle both single and multi-experiment requests
    if haskey(request_data, "well_selections")
        # Multi-experiment format: [{"experiment": "LG166", "well": "A1"}, ...]
        well_selections = request_data.well_selections
        traces = []
        stats  = []

        grouped = Dict{Tuple{String,Int},Vector{String}}()
        group_order = Tuple{String,Int}[]

        for selection in well_selections
            experiment = string(selection.experiment)
            well       = string(selection.well)
            channel    = Int(get(selection, :channel, 1))
            key = (experiment, channel)
            if !haskey(grouped, key)
                grouped[key] = String[]
                push!(group_order, key)
            end
            push!(grouped[key], well)
        end

        for (experiment, channel) in group_order
            exp_dir = joinpath(CLEAN_DATA_PATH, experiment)
            data_file = joinpath(exp_dir, "data_channel_$(channel).csv")

            if !isfile(data_file) || isempty(_plot_annotation_files(exp_dir, channel))
                continue
            end

            try
                growth_data = CSV.read(data_file, DataFrame, header=1, silencewarnings=true)
                metadata, excluded_wells = _plot_annotation_context(exp_dir, channel; empty_antibiotic="Unknown")
                col_names = Set(string.(names(growth_data)))
                time_numeric = parse_time_column(growth_data)

                for well in grouped[(experiment, channel)]
                    if well in col_names && !(well in excluded_wells)
                        od_data = parse_od_column(growth_data, Symbol(well))
                        trace, stat = _plot_trace_and_stat(
                            experiment, well, channel, time_numeric, od_data, metadata;
                            multi_experiment=true,
                        )
                        push!(traces, trace)
                        push!(stats, stat)
                    end
                end
            catch e
                @warn "Error processing $experiment channel $channel: $e"
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
            annotations = _rename_plot_annotations!(read_annotation_file(annotation_file))
            time_numeric = parse_time_column(growth_data)

            # Prepare data for each well
            traces = []
            stats  = []

            blank_wells = get_blank_wells(annotations)
            metadata = _annotation_metadata_map(annotations; empty_antibiotic="None")
            col_names = Set(string.(names(growth_data)))
            for well in wells
                # Only process wells that aren't blank wells and exist in the data
                well = string(well)
                if well in col_names && !(well in blank_wells)
                    od_data = parse_od_column(growth_data, Symbol(well))
                    trace, stat = _plot_trace_and_stat(
                        string(experiment), well, 1, time_numeric, od_data, metadata;
                        multi_experiment=false,
                    )
                    push!(traces, trace)
                    push!(stats, stat)
                end
            end

            return Dict("traces" => traces, "stats" => stats)
        catch e
                        return json(Dict("error" => "Error getting plot data: $e"); status=500)
        end
    end
end
