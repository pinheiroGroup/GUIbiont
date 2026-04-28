# Data access helpers: annotation loading, blank detection, time/OD parsing
function find_annotation_file(exp_dir::String, channel::Int)::Union{String, Nothing}
    all_files = try readdir(exp_dir) catch; String[] end

    # Look for annotation_channel_N_*.csv for this specific channel
    prefix = "annotation_channel_$(channel)_"
    candidates = filter(f -> startswith(f, prefix) && endswith(f, ".csv"), all_files)
    isempty(candidates) || return joinpath(exp_dir, first(sort(candidates)))

    # Only fall back to annotation_clean.csv when the experiment has NO
    # channel-specific annotation files at all (single-channel experiment).
    has_any_channel_ann = any(f -> occursin(r"^annotation_channel_\d+_", f), all_files)
    if !has_any_channel_ann
        fallback = joinpath(exp_dir, "annotation_clean.csv")
        isfile(fallback) && return fallback
    end

    return nothing
end

# Read an annotation CSV with graceful handling of missing/inconsistent values
function read_annotation_file(annotation_file::String)::DataFrame
    annotations = try
        CSV.read(annotation_file, DataFrame, header=false, silencewarnings=true, stringtype=String)
    catch
        raw = CSV.File(annotation_file, header=false) |> DataFrame
        DataFrame([string.(col) for col in eachcol(raw)], :auto)
    end
    # Normalise missing/empty second column to "X" (excluded)
    for i in 1:nrow(annotations)
        if ncol(annotations) >= 2 && (ismissing(annotations[i, 2]) || annotations[i, 2] in ("", "missing"))
            annotations[i, 2] = "X"
        end
    end
    return annotations
end


# Return the set of well names marked as blank ("b") or excluded ("X"/"x")
function get_blank_wells(annotations::DataFrame)
    blank_wells = Set{String}()
    for i in 1:nrow(annotations)
        if ncol(annotations) >= 2 && (annotations[i, 2] == "b" || annotations[i, 2] == "X" || annotations[i, 2] == "x")
            push!(blank_wells, string(annotations[i, 1]))
        end
    end
    return blank_wells
end

# Parse the first column of a growth data file into a Float64 time vector
function parse_time_column(growth_data::DataFrame)::Vector{Float64}
    time_raw = growth_data[!, names(growth_data)[1]]
    if eltype(time_raw) <: AbstractString
        try
            return [0.0; [parse(Float64, t) for t in time_raw[2:end]]]
        catch
            return Float64.(0:(nrow(growth_data)-1))
        end
    end
    return Float64.(time_raw)
end

# Parse an OD column into a Float64 vector, using NaN for non-numeric entries
function parse_od_column(growth_data::DataFrame, well_sym::Symbol)::Vector{Float64}
    od = Float64[]
    for val in growth_data[!, well_sym]
        try
            push!(od, parse(Float64, string(val)))
        catch
            push!(od, NaN)
        end
    end
    return od
end

# Return sorted list of well names marked as blank ("b") in the annotation file.
function get_blank_well_names(annotations::DataFrame)::Vector{String}
    names_out = String[]
    for i in 1:nrow(annotations)
        ncol(annotations) >= 2 || continue
        annotations[i, 2] == "b" || continue
        push!(names_out, string(annotations[i, 1]))
    end
    return sort(names_out)
end

# Compute the mean blank OD from wells marked as blank ("b") only.
# Excluded ("X") wells are intentionally omitted — they may have anomalous OD.
function compute_blank_value(growth_data::DataFrame, annotations::DataFrame)::Float64
    vals = Float64[]
    col_names = string.(names(growth_data))
    for i in 1:nrow(annotations)
        ncol(annotations) >= 2 || continue
        annotations[i, 2] == "b" || continue
        bw = string(annotations[i, 1])
        bw in col_names || continue
        for val in growth_data[!, Symbol(bw)]
            try push!(vals, parse(Float64, string(val))) catch _ end
        end
    end
    isempty(vals) && return 0.0
    return mean(filter(!isnan, vals))
end

# Compute the mean blank OD at each time point across all blank ("b") wells.
# Returns a vector of length nrow(growth_data). Used for point-by-point subtraction.
function compute_blank_timeseries(growth_data::DataFrame, annotations::DataFrame)::Vector{Float64}
    n = nrow(growth_data)
    col_names = string.(names(growth_data))
    columns = Vector{Float64}[]
    for i in 1:nrow(annotations)
        ncol(annotations) >= 2 || continue
        annotations[i, 2] == "b" || continue
        bw = string(annotations[i, 1])
        bw in col_names || continue
        col = Float64[]
        for val in growth_data[!, Symbol(bw)]
            try push!(col, parse(Float64, string(val))) catch _ push!(col, NaN) end
        end
        length(col) == n && push!(columns, col)
    end
    isempty(columns) && return zeros(Float64, n)
    # Mean across blank wells at each time point, ignoring NaN
    return [mean(filter(!isnan, [columns[j][t] for j in 1:length(columns)])) for t in 1:n]
end

# Overloads that take an explicit list of blank well names instead of an annotation DataFrame.
function compute_blank_value(growth_data::DataFrame, blank_wells::Vector{String})::Float64
    vals = Float64[]
    col_names = string.(names(growth_data))
    for bw in blank_wells
        bw in col_names || continue
        for val in growth_data[!, Symbol(bw)]
            try push!(vals, parse(Float64, string(val))) catch _ end
        end
    end
    isempty(vals) && return 0.0
    return mean(filter(!isnan, vals))
end

function compute_blank_timeseries(growth_data::DataFrame, blank_wells::Vector{String})::Vector{Float64}
    n = nrow(growth_data)
    col_names = string.(names(growth_data))
    columns = Vector{Float64}[]
    for bw in blank_wells
        bw in col_names || continue
        col = Float64[]
        for val in growth_data[!, Symbol(bw)]
            try push!(col, parse(Float64, string(val))) catch _ push!(col, NaN) end
        end
        length(col) == n && push!(columns, col)
    end
    isempty(columns) && return zeros(Float64, n)
    return [mean(filter(!isnan, [columns[j][t] for j in 1:length(columns)])) for t in 1:n]
end

# CORS headers for allowing frontend requests

function detect_and_save_well_count(experiment_path::String)::Int
    files = filter(f -> startswith(f, "data_channel_") && endswith(f, ".csv"),
                   readdir(experiment_path))
    isempty(files) && return 48
    data_file = joinpath(experiment_path, sort(files)[1])
    first_line = readline(data_file)
    ncols = length(split(first_line, ",")) - 1
    well_count = ncols > 60 ? 96 : 48
    open(joinpath(experiment_path, "metadata.json"), "w") do f
        write(f, JSON3.write(Dict("well_count" => well_count)))
    end
    return well_count
end

function get_calibration_file(experiment::String; override::String="")::String
    if !isempty(override) && isfile(override)
        return override
    end
    experiment_path = joinpath(CLEAN_DATA_PATH, experiment)
    metadata_file   = joinpath(experiment_path, "metadata.json")
    if isfile(metadata_file)
        meta       = JSON3.read(read(metadata_file, String))
        well_count = Int(get(meta, :well_count, 48))
    else
        well_count = isdir(experiment_path) ? detect_and_save_well_count(experiment_path) : 48
    end
    cal96 = joinpath(@__DIR__, "..", "calibration", "cal_curve_avg96.csv")
    cal48 = joinpath(@__DIR__, "..", "calibration", "cal_curve_avg.csv")
    if well_count == 96
        return isfile(cal96) ? cal96 : cal48
    end
    return cal48
end
