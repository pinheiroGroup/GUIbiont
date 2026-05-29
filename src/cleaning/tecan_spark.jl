# Tecan Spark .xlsx adapter.
# Structure (observed on a 48-well run):
#   • "Result sheet" sheet.
#   • Header / metadata block at the top.
#   • For each measured channel: a row whose column A is the channel label
#     (e.g. "OD600", "sfGFP"), immediately followed by a header row
#     "Cycle Nr. | Time [s] | Temp. [°C] | A1 | A2 | … | <last well>",
#     then data rows until a blank column-A row.
#
# Interrupted runs (filename suffix `_interrupted`) still emit a single block
# per channel; if a future run produces multiple segments per channel they
# will be concatenated in encounter order with no time offset adjustment —
# add that here if/when we see one in the wild.

using XLSX

const _TECAN_HEADER_MARKER = "Cycle Nr."
const _TECAN_TIME_DIVISOR  = 3600.0   # seconds → hours

function _row_iter(ws)
    # Return rows as Vector{Any} (one per worksheet row), 1-indexed.
    data = XLSX.getdata(ws)
    nrows = size(data, 1)
    return [collect(data[r, :]) for r in 1:nrows]
end

_is_blank(x) = ismissing(x) || (x isa AbstractString && isempty(strip(x))) || x === nothing

function _find_channel_blocks(rows::Vector)
    # Locate (channel_name_row_index, header_row_index) pairs by looking for a
    # non-blank column A whose next row's column A starts with "Cycle Nr.".
    blocks = Tuple{Int, Int}[]
    for i in 1:length(rows) - 1
        a_here = rows[i][1]
        a_next = rows[i + 1][1]
        _is_blank(a_here) && continue
        _is_blank(a_next) && continue
        if a_next isa AbstractString && startswith(strip(a_next), _TECAN_HEADER_MARKER)
            push!(blocks, (i, i + 1))
        end
    end
    return blocks
end

function _channel_name(rows, name_row::Int)
    raw = rows[name_row][1]
    s   = strip(string(raw))
    # Sanitize for filenames: keep alphanumerics and underscores.
    return replace(s, r"[^A-Za-z0-9_]" => "_")
end

function _parse_float(x)::Union{Float64, Missing}
    x === missing && return missing
    x === nothing && return missing
    if x isa Number
        return Float64(x)
    end
    s = strip(string(x))
    isempty(s) && return missing
    # Tecan typically uses '.' as decimal; tolerate ',' just in case.
    s = replace(s, "," => ".")
    v = tryparse(Float64, s)
    return v === nothing ? missing : v
end

function _extract_tecan_block(rows::Vector, name_row::Int, header_row::Int, end_row::Int)
    header = rows[header_row]
    # Find data columns: skip "Cycle Nr.", "Time [s]", "Temp. [°C]"; keep wells.
    time_col = findfirst(h -> h isa AbstractString && occursin("Time", h), header)
    time_col === nothing && error("Tecan block at row $header_row has no Time column")

    well_cols = Int[]
    well_names = String[]
    for (i, h) in enumerate(header)
        h isa AbstractString || continue
        s = strip(h)
        # Wells look like A1..H12 — letter(s) + digits.
        if occursin(r"^[A-H][0-9]+$", s)
            push!(well_cols, i)
            push!(well_names, s)
        end
    end
    isempty(well_cols) && error("Tecan block at row $header_row has no well columns")

    times = Float64[]
    cols  = [Float64[] for _ in well_cols]

    for r in (header_row + 1):end_row
        row = rows[r]
        _is_blank(row[1]) && break   # end of this channel's data
        t = _parse_float(row[time_col])
        t === missing && continue
        push!(times, t / _TECAN_TIME_DIVISOR)
        for (k, c) in enumerate(well_cols)
            v = _parse_float(row[c])
            push!(cols[k], v === missing ? NaN : v)
        end
    end

    isempty(times) && error("Tecan block at row $header_row produced no data rows")

    df = DataFrame(Time = times)
    for (k, w) in enumerate(well_names)
        df[!, Symbol(w)] = cols[k]
    end
    return df
end

function clean(::TecanSparkXLSX, src_path::String, out_dir::String)
    mkpath(out_dir)
    XLSX.openxlsx(src_path) do xf
        # Prefer "Result sheet"; fall back to the first sheet.
        ws = if XLSX.hassheet(xf, "Result sheet")
            xf["Result sheet"]
        else
            xf[1]
        end
        rows = _row_iter(ws)
        blocks = _find_channel_blocks(rows)
        isempty(blocks) && error("No channel data blocks found in $src_path")

        # Pair each block with its end row (one past the last data row).
        endpoints = vcat([b[1] for b in blocks[2:end]], length(rows) + 1)

        for (i, (name_row, header_row)) in enumerate(blocks)
            end_row = endpoints[i] - 1
            df      = _extract_tecan_block(rows, name_row, header_row, end_row)
            channel_label = _channel_name(rows, name_row)
            # Write canonical name AND a labelled copy so downstream code that
            # keys off `data_channel_1.csv` still works while users can also
            # find files by channel name.
            CSV.write(joinpath(out_dir, "data_channel_$(i).csv"), df)
            CSV.write(joinpath(out_dir, "data_channel_$(i)_$(channel_label).csv"), df)
        end
    end
end
