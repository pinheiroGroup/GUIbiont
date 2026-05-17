# ExperimentStore — single source of truth for loading experiment data.
#
# Eliminates the repeated ~50-line CSV/annotation loading block that previously
# appeared in 5+ endpoints under src/routes/.
#
# Design:  WellMeta  (metadata only, cheap)
#          WellData   (metadata + time + OD vectors, loaded on demand)
#          ExperimentChannel  (one loaded (experiment, channel) pair)
#
# See GitHub issue #36 for the RFC.

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

"""
Per-well metadata derived from an annotation file.  No OD data.
"""
struct WellMeta
    well         :: String          # raw well name, e.g. "A3"
    experiment   :: String
    channel      :: Int
    condition    :: String          # joined from cols 2–4:  "WT | Glucose_0.5"
    antibiotic   :: String          # col 5, or "None"
    well_id      :: String          # unique across (exp, channel):
                                    #   single-ch: "LG166_A3"
                                    #   multi-ch:  "LG166_ch1_A3"
    display_name :: String          # human label for the UI
end

"""
A fully-loaded well: metadata + parsed time and OD vectors.
Only materialised when a caller explicitly calls `load_well_data`.
"""
struct WellData
    meta   :: WellMeta
    time   :: Vector{Float64}
    od     :: Vector{Float64}   # NaN-free (NaNs stripped)
    od_raw :: Vector{Float64}   # original, NaNs preserved
end

"""
One loaded (experiment, channel) pair.  Holds parsed annotations and the raw
growth DataFrame.  Callers use `list_wells` and `load_well_data` to extract
information rather than touching this struct's fields directly.
"""
struct ExperimentChannel
    experiment  :: String
    channel     :: Int
    n_channels  :: Int            # total channels in this experiment
    annotations :: DataFrame      # renamed: :well, :condition, :antibiotic, :col_N
    blank_wells :: Set{String}    # "b" + "X" wells (excluded from lists)
    growth_data :: DataFrame      # raw CSV; columns = Time + well names
end

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

"""
Rename annotation columns to the canonical names used throughout the codebase:
  col 1 → :well
  col 2 → :condition
  col 5 → :antibiotic
  others → :col_N
"""
function _rename_annotation_columns!(df::DataFrame)
    n = ncol(df)
    new_names = Symbol[]
    for i in 1:n
        if     i == 1; push!(new_names, :well)
        elseif i == 2; push!(new_names, :condition)
        elseif i == 5; push!(new_names, :antibiotic)
        else;          push!(new_names, Symbol("col_$i"))
        end
    end
    rename!(df, new_names)
    return df
end

"""
Build the human-readable condition string from annotation columns 2–4.
"""
function _build_condition(row, ann::DataFrame)::String
    parts = String[]
    if :condition in propertynames(row)
        push!(parts, string(row.condition))
    end
    for col in [:col_3, :col_4]
        if col in Symbol.(names(ann))
            v = getproperty(row, col)
            if !ismissing(v) && strip(string(v)) != ""
                push!(parts, string(v))
            end
        end
    end
    return join(parts, " | ")
end

"""
Extract antibiotic from column 5 of a well's annotation row.
Returns "None" when absent, missing, or empty.
"""
function _build_antibiotic(row, ann::DataFrame)::String
    :antibiotic in Symbol.(names(ann)) || return "None"
    v = row.antibiotic
    (ismissing(v) || strip(string(v)) == "") && return "None"
    return string(v)
end

# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

"""
    load_experiment_channel(exp_dir, experiment, channel, n_channels) → Union{ExperimentChannel, Nothing}

The only function that performs file I/O for experiment data.
Returns `nothing` if the annotation or growth-data file cannot be found.
"""
function load_experiment_channel(
    exp_dir    :: AbstractString,
    experiment :: AbstractString,
    channel    :: Int,
    n_channels :: Int,
) :: Union{ExperimentChannel, Nothing}

    ann_file  = find_annotation_file(exp_dir, channel)
    data_file = joinpath(exp_dir, "data_channel_$(channel).csv")

    (ann_file === nothing || !isfile(data_file)) && return nothing

    try
        annotations = read_annotation_file(ann_file)
        _rename_annotation_columns!(annotations)
        blanks      = get_blank_wells(annotations)
        growth_data = CSV.read(data_file, DataFrame, header=1, silencewarnings=true)

        return ExperimentChannel(
            string(experiment), channel, n_channels,
            annotations, blanks, growth_data,
        )
    catch e
        @warn "Failed to load channel $channel of experiment $experiment" exception=e
        return nothing
    end
end

"""
    load_all_channels(experiment, base_path) → Vector{ExperimentChannel}

Discover and load every `data_channel_N.csv` present for `experiment`.
"""
function load_all_channels(
    experiment :: AbstractString;
    base_path  :: AbstractString = CLEAN_DATA_PATH,
) :: Vector{ExperimentChannel}

    exp_dir = joinpath(base_path, experiment)
    isdir(exp_dir) || return ExperimentChannel[]

    channel_files = sort(filter(
        f -> occursin(r"^data_channel_\d+\.csv$", basename(f)) && isfile(f),
        [joinpath(exp_dir, "data_channel_$(ch).csv") for ch in 1:10],
    ))
    isempty(channel_files) && return ExperimentChannel[]

    n_channels = length(channel_files)
    result = ExperimentChannel[]
    for (idx, _) in enumerate(channel_files)
        ec = load_experiment_channel(exp_dir, experiment, idx, n_channels)
        ec !== nothing && push!(result, ec)
    end
    return result
end

# ---------------------------------------------------------------------------
# Well catalogue  (80 % case — metadata only, no OD parsing)
# ---------------------------------------------------------------------------

"""
    list_wells(ec) → Vector{WellMeta}

Return metadata for all non-blank wells in `ec`.
Blank ("b") and excluded ("X") wells are omitted.
"""
function list_wells(ec::ExperimentChannel) :: Vector{WellMeta}
    result = WellMeta[]
    col_names_str = string.(names(ec.growth_data))

    for i in 1:nrow(ec.annotations)
        well = string(ec.annotations[i, :well])
        well in ec.blank_wells  && continue
        well in col_names_str   || continue   # well not in data file

        row       = ec.annotations[i, :]
        condition = _build_condition(row, ec.annotations)
        antibiotic = _build_antibiotic(row, ec.annotations)

        well_id = ec.n_channels > 1 ?
            "$(ec.experiment)_ch$(ec.channel)_$(well)" :
            "$(ec.experiment)_$(well)"

        display_name = ec.n_channels > 1 ?
            "$(ec.experiment): $(well) Ch$(ec.channel) ($(condition)) [$(antibiotic)]" :
            "$(ec.experiment): $(well) ($(condition)) [$(antibiotic)]"

        push!(result, WellMeta(
            well, ec.experiment, ec.channel,
            condition, antibiotic, well_id, display_name,
        ))
    end
    return result
end

# ---------------------------------------------------------------------------
# OD timeseries  (opt-in)
# ---------------------------------------------------------------------------

"""
    load_well_data(ec, well) → Union{WellData, Nothing}

Load OD data for a single well by name (e.g. "A3").
Returns `nothing` if the well is not found in the growth data.
"""
function load_well_data(
    ec   :: ExperimentChannel,
    well :: AbstractString,
) :: Union{WellData, Nothing}

    col_names_str = string.(names(ec.growth_data))
    well in col_names_str || return nothing

    meta_list = filter(m -> m.well == well, list_wells(ec))
    isempty(meta_list) && return nothing   # blank/excluded well

    meta    = first(meta_list)
    time    = parse_time_column(ec.growth_data)
    od_raw  = parse_od_column(ec.growth_data, Symbol(well))
    valid   = findall(!isnan, od_raw)
    od_clean = od_raw[valid]
    time_clean = time[valid]

    return WellData(meta, time_clean, od_clean, od_raw)
end

"""
    load_well_data(ec, wells) → Vector{WellData}

Load OD data for a subset of wells.  Missing or blank wells are silently skipped.
"""
function load_well_data(
    ec    :: ExperimentChannel,
    wells :: AbstractVector{<:AbstractString},
) :: Vector{WellData}

    result = WellData[]
    for w in wells
        wd = load_well_data(ec, w)
        wd !== nothing && push!(result, wd)
    end
    return result
end

"""
    load_all_well_data(ec) → Vector{WellData}

Load OD data for every non-blank well in `ec`.
"""
function load_all_well_data(ec::ExperimentChannel) :: Vector{WellData}
    return load_well_data(ec, [m.well for m in list_wells(ec)])
end

"""
    load_blank_well_data(ec) → Vector{WellData}

Load OD data for wells annotated as blank ("b" only, not "X").
Used by fitting endpoints that need the blank timeseries.
"""
function load_blank_well_data(ec::ExperimentChannel) :: Vector{WellData}
    blank_names = get_blank_well_names(ec.annotations)
    result = WellData[]
    time = parse_time_column(ec.growth_data)
    col_names_str = string.(names(ec.growth_data))
    for bw in blank_names
        bw in col_names_str || continue
        od_raw   = parse_od_column(ec.growth_data, Symbol(bw))
        valid    = findall(!isnan, od_raw)
        od_clean = od_raw[valid]
        # Blank wells don't appear in list_wells, so build a minimal WellMeta
        meta = WellMeta(bw, ec.experiment, ec.channel, "blank", "None",
                        "$(ec.experiment)_$(bw)", "$(ec.experiment): $(bw) (blank)")
        push!(result, WellData(meta, time[valid], od_clean, od_raw))
    end
    return result
end
