# BioTek Synergy H1 CSV adapter.

# "HH:MM:SS" → minutes (two-step → hours conversion preserves original arithmetic)
function _hhmmss_to_minutes(s::AbstractString)::Float64
    parts = split(string(s), ":")
    h   = parse(Float64, parts[1])
    m   = parse(Float64, parts[2])
    sec = parse(Float64, parts[3])
    return (h * 3600.0 + m * 60.0 + sec) / 60.0
end

function _extract_synergy_channel_block(temp_data::DataFrame, start_row::Int, end_row::Int)::DataFrame
    block = temp_data[start_row:end_row, 2:end]

    na_idx = findfirst(ismissing.(block[!, 2]))
    isnothing(na_idx) || (block = block[1:(na_idx - 1), :])

    times = block[2:end, 1]
    block[2:end, 1] = string.(_hhmmss_to_minutes.(string.(times)))

    block = select!(block, Not(propertynames(block)[2]))   # drop temperature

    block[2:end, :] = string.(tryparse.(Float64, replace.(block[2:end, :], "," => ".")))
    block[2:end, 1] = string.(tryparse.(Float64, block[2:end, 1]) ./ 60.0)

    return block
end

function clean(::SynergyCSV, src_path::String, out_dir::String)
    mkpath(out_dir)

    separator = detect_csv_separator(src_path)
    temp_data = DataFrame(CSV.File(src_path; delim=separator, normalizenames=true))

    col_names      = propertynames(temp_data)
    col2_values    = temp_data[:, col_names[2]]
    channel_starts = findall(x -> !ismissing(x) && x == "Time", col2_values)

    isempty(channel_starts) && error("No channel data found in $src_path")

    for (i, start_row) in enumerate(channel_starts)
        end_row = i < length(channel_starts) ? channel_starts[i + 1] - 1 : nrow(temp_data)
        block   = _extract_synergy_channel_block(temp_data, start_row, end_row)
        CSV.write(joinpath(out_dir, "data_channel_$(i).csv"), block, header=false)
    end
end

# Backwards-compatible name (still referenced by routes/experiments.jl)
cleaning_data_synergy(src::String, out::String) = clean(SynergyCSV(), src, out)
