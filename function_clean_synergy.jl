
# =============================================================================
# Data-cleaning helpers for BioTek Synergy microplate reader files
# and LabGuru plate annotation CSVs.
# =============================================================================

# ---------------------------------------------------------------------------
# detect_csv_separator
# ---------------------------------------------------------------------------

"""
    detect_csv_separator(file_path) -> Char

Read up to the first 5 lines of `file_path` and return the most common column
separator among `','` and `';'`.
"""
function detect_csv_separator(file_path::String)::Char
    lines = String[]
    open(file_path, "r") do f
        while length(lines) < 5 && !eof(f)
            push!(lines, readline(f))
        end
    end
    comma_count     = sum(count(',', l) for l in lines; init=0)
    semicolon_count = sum(count(';', l) for l in lines; init=0)
    return semicolon_count > comma_count ? ';' : ','
end

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

# Convert "HH:MM:SS" to decimal minutes (first step of the two-step
# seconds → minutes → hours conversion used by cleaning_data_synergy).
# The intermediate minutes value is later divided by 60 in _extract_channel_block
# to produce hours, replicating the original floating-point arithmetic.
function _hhmmss_to_minutes(s::AbstractString)::Float64
    parts = split(string(s), ":")
    h   = parse(Float64, parts[1])
    m   = parse(Float64, parts[2])
    sec = parse(Float64, parts[3])
    return (h * 3600.0 + m * 60.0 + sec) / 60.0
end

"""
    _well_names_for_plate(n_wells) -> Vector{String}

Return well names for a standard microplate in row-major order (e.g. A1, A2, …).
Raises an error for unsupported plate sizes.
"""
function _well_names_for_plate(n_wells::Int)::Vector{String}
    configs = Dict(
        96 => (["A","B","C","D","E","F","G","H"], 1:12),
        48 => (["A","B","C","D","E","F"],          1:8),
        24 => (["A","B","C","D"],                  1:6),
        12 => (["A","B","C"],                      1:4),
         6 => (["A","B"],                          1:3),
    )
    haskey(configs, n_wells) || error(
        "Unsupported plate size: $n_wells wells. " *
        "Supported sizes: $(sort(collect(keys(configs))))"
    )
    letters, numbers = configs[n_wells]
    return [l * string(n) for l in letters for n in numbers]
end

"""
    _extract_channel_block(temp_data, start_row, end_row) -> DataFrame

Slice the raw data DataFrame from `start_row` to `end_row` (inclusive),
trim at the first missing value in the second column (end of valid data),
drop the temperature column, convert HH:MM:SS times to decimal hours, and
normalise OD values to Float64 strings.
"""
function _extract_channel_block(temp_data::DataFrame, start_row::Int, end_row::Int)::DataFrame
    block = temp_data[start_row:end_row, 2:end]

    # Trim at first missing in column 2 (marks end of channel data)
    na_idx = findfirst(ismissing.(block[!, 2]))
    isnothing(na_idx) || (block = block[1:(na_idx - 1), :])

    # Convert HH:MM:SS times → minutes (stored as strings for the /60 step below)
    times = block[2:end, 1]
    block[2:end, 1] = string.(_hhmmss_to_minutes.(string.(times)))

    # Drop the temperature column (always the second column in BioTek output)
    block = select!(block, Not(propertynames(block)[2]))

    # Normalise OD values: replace European decimal comma, parse as Float64
    block[2:end, :] = string.(tryparse.(Float64, replace.(block[2:end, :], "," => ".")))

    # Convert time: minutes → hours  (second step of the two-step division)
    block[2:end, 1] = string.(tryparse.(Float64, block[2:end, 1]) ./ 60.0)

    return block
end

# ---------------------------------------------------------------------------
# cleaning_data_synergy
# ---------------------------------------------------------------------------

"""
    cleaning_data_synergy(path_to_data, path_to_save)

Read a BioTek Synergy H1 CSV at `path_to_data`, split it into per-channel
DataFrames, and write them as `data_channel_1.csv`, `data_channel_2.csv`, …
inside `path_to_save`.
"""
function cleaning_data_synergy(path_to_data::String, path_to_save::String)
    mkpath(path_to_save)

    separator = detect_csv_separator(path_to_data)
    temp_data = DataFrame(CSV.File(path_to_data; delim=separator, normalizenames=true))

    col_names       = propertynames(temp_data)
    col2_values     = temp_data[:, col_names[2]]
    channel_starts  = findall(x -> !ismissing(x) && x == "Time", col2_values)

    isempty(channel_starts) && error("No channel data found in $path_to_data")

    for (i, start_row) in enumerate(channel_starts)
        end_row = i < length(channel_starts) ? channel_starts[i + 1] - 1 : nrow(temp_data)
        block   = _extract_channel_block(temp_data, start_row, end_row)
        CSV.write(joinpath(path_to_save, "data_channel_$(i).csv"), block, writeheader=false)
    end
end

# ---------------------------------------------------------------------------
# read_labguru_annotation
# ---------------------------------------------------------------------------

"""
    read_labguru_annotation(path_to_annotation, path_to_save, number_of_wells)

Parse a LabGuru plate annotation CSV, build a unified `annotation_clean.csv`,
and write per-channel per-media simplified annotation files inside `path_to_save`.
"""
function read_labguru_annotation(path_to_annotation::String,
                                 path_to_save::String,
                                 number_of_wells::Int)
    mkpath(path_to_save)

    names_of_wells_tot = _well_names_for_plate(number_of_wells)

    annotation_separator = detect_csv_separator(path_to_annotation)
    raw_annotation = CSV.read(path_to_annotation, normalizenames=true,
                               delim=annotation_separator, DataFrame)
    raw_annotation = raw_annotation[1:end, 4:end]

    names_of_columns = unique(raw_annotation[1:end, 4])[2:end]
    names_of_columns = names_of_columns[names_of_columns .!= "Bacterium"]
    names_of_columns = names_of_columns[names_of_columns .!= "Media"]
    names_of_columns = vcat(["Well", "Bacterium", "Media"], names_of_columns)
    names_of_columns = vcat(names_of_columns, "Replicate")
    names_of_columns = vcat(names_of_columns, "Channels")

    letters_of_wells   = raw_annotation[2:end, 1]
    number_of_well     = raw_annotation[2:end, 2]
    temp_list_of_wells = string.(letters_of_wells, number_of_well)
    names_of_wells     = unique(string.(letters_of_wells, number_of_well))
    raw_annotation[2:end, 1] = string.(letters_of_wells, number_of_well)

    full_annotation        = Matrix{Any}(missing, length(names_of_wells_tot), length(names_of_columns))
    full_annotation[:, 1]  = names_of_wells_tot

    # Discover "Concentration" and "Well Annotation" column positions in row 2
    row2 = [string(raw_annotation[2, i]) for i in 1:ncol(raw_annotation)]
    concentration_column   = something(findfirst(==("Concentration"),   row2), 9)
    well_annotation_column = something(findfirst(==("Well Annotation"), row2), 10)

    for kk in 1:length(names_of_wells)
        well_rows        = findall(temp_list_of_wells .== names_of_wells[kk])
        reduced_raw_data = Matrix(raw_annotation[well_rows .+ 1, :])

        for mm in 2:length(names_of_columns)
            metadata_oi = names_of_columns[mm]

            if metadata_oi == "Replicate" || metadata_oi == "Channels"
                temp_metadata        = reduced_raw_data[:, well_annotation_column]
                non_missing_metadata = filter(!ismissing, temp_metadata)
                splitted_inf = isempty(non_missing_metadata) ?
                               [["X"]] :
                               unique(split.(non_missing_metadata, "&"))

                well_idx = findall(full_annotation[:, 1] .== names_of_wells[kk])
                if splitted_inf[1][1] != "b" && splitted_inf[1][1] != "X"
                    if metadata_oi == "Channels"
                        full_annotation[well_idx, mm] .= splitted_inf[1][1]
                    elseif metadata_oi == "Replicate" && length(splitted_inf[1]) > 1
                        full_annotation[well_idx, mm] .= splitted_inf[1][2]
                    end
                else
                    full_annotation[well_idx, 2] .= splitted_inf[1][1]
                end

            else
                oi_metadata = reduced_raw_data[reduced_raw_data[:, 4] .== metadata_oi, :]
                well_idx    = findall(full_annotation[:, 1] .== names_of_wells[kk])

                if size(oi_metadata, 1) == 1
                    if ismissing(oi_metadata[:, concentration_column][1])
                        full_annotation[well_idx, mm] = oi_metadata[:, 6]
                    else
                        full_annotation[well_idx, mm] .= string(
                            oi_metadata[:, 6][1], "_",
                            replace(oi_metadata[:, concentration_column][1], "," => ".")
                        )
                    end
                elseif size(oi_metadata, 1) > 1
                    temp = join(oi_metadata[:, 6] .* "_" .* oi_metadata[:, concentration_column], "_")
                    full_annotation[well_idx, mm] .= replace(temp, "," => ".")
                end
            end
        end
    end

    # Write unified annotation
    CSV.write(joinpath(path_to_save, "annotation_clean.csv"),
              Tables.table(Matrix(full_annotation)), writeheader=false)

    # Collect unique media types and channel IDs
    list_of_media    = filter(!ismissing, unique(full_annotation[:, names_of_columns .== "Media"]))
    list_of_channels = unique(Iterators.flatten(
        split.(string.(filter(!ismissing, unique(full_annotation[:, end]))), "")
    ))

    # Replace remaining missing values with "X" in all but the last column
    for i in 1:(size(full_annotation, 2) - 1)
        if any(ismissing, full_annotation[:, i])
            full_annotation[ismissing.(full_annotation[:, i]), i] .= "X"
        end
    end

    index_of_blanks = findall(full_annotation[:, 2] .== "b")
    n_fa_cols = size(full_annotation, 2)

    for cc in 1:length(list_of_channels)
        for uu in 1:length(list_of_media)
            reduced_notation        = Matrix{Any}(missing, length(names_of_wells_tot), 2)
            reduced_notation[:, 2] .= "X"
            reduced_notation[:, 1] .= names_of_wells_tot

            temp_channel = list_of_channels[cc]
            temp_media   = list_of_media[uu]

            index_of_correct_media  = findall(
                Vector(full_annotation[:, names_of_columns .== "Media"][:, 1]) .== temp_media
            )
            index_of_correct_blanks = intersect(index_of_correct_media, index_of_blanks)
            reduced_notation[index_of_correct_blanks, 2] .= "b"
            oi_wells = setdiff(index_of_correct_media, index_of_correct_blanks)

            for ff in 1:length(oi_wells)
                row    = oi_wells[ff]
                ch_val = full_annotation[row, n_fa_cols]
                if !ismissing(ch_val)
                    if sum(split(string(ch_val), "") .== string(temp_channel)) > 0
                        reduced_notation[row, 2] =
                            join(full_annotation[row, 2:(n_fa_cols - 1)], "_")
                    end
                end
            end

            CSV.write(
                joinpath(path_to_save, "annotation_channel_$(temp_channel)_media_$(temp_media).csv"),
                Tables.table(Matrix(reduced_notation)),
                writeheader=false,
            )
        end
    end
end
