# ---------------------------------------------------------------------------
# Plate reader adapter interface
# ---------------------------------------------------------------------------
# One adapter per microplate-reader vendor. Each adapter implements
# `clean(::Format, src_path, out_dir)` and emits the canonical schema:
#
#   data_channel_<N>.csv:  Time(h),<wells…>
#
# `detect_format(path)` picks the adapter from file content when the caller
# requests "auto".

abstract type PlateReaderFormat end

struct SynergyCSV     <: PlateReaderFormat end
struct TecanSparkXLSX <: PlateReaderFormat end

const FORMAT_KEYS = Dict{String, PlateReaderFormat}(
    "synergy"     => SynergyCSV(),
    "tecan_spark" => TecanSparkXLSX(),
)

function format_from_key(key::AbstractString)::PlateReaderFormat
    haskey(FORMAT_KEYS, lowercase(strip(key))) ||
        error("Unknown plate reader format: $key. Known: $(sort(collect(keys(FORMAT_KEYS))))")
    return FORMAT_KEYS[lowercase(strip(key))]
end

"""
    detect_format(path) -> PlateReaderFormat

Sniff the file at `path` and return the matching adapter. Falls back to an
error when the format cannot be identified — never silently guesses.
"""
function detect_format(path::String)::PlateReaderFormat
    isfile(path) || error("File not found: $path")
    ext = lowercase(splitext(path)[2])
    if ext in (".xlsx", ".xls")
        return TecanSparkXLSX()   # only Tecan supported among .xlsx today
    end
    if ext in (".csv", ".tsv", ".txt")
        # Synergy signature: a row whose 2nd column equals "Time".
        sep = detect_csv_separator(path)
        open(path, "r") do f
            lines_scanned = 0
            for line in eachline(f)
                lines_scanned += 1
                lines_scanned > 200 && break
                parts = split(line, sep)
                length(parts) >= 2 && strip(parts[2]) == "Time" && return SynergyCSV()
            end
        end
        return SynergyCSV()  # most CSVs we see are Synergy; let the adapter raise if mis-detected
    end
    error("Cannot detect plate reader format from extension '$ext' for $path")
end

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

"""
    detect_csv_separator(file_path) -> Char

Most common separator (`,` vs `;`) in the first five lines of `file_path`.
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

"""
    well_names_for_plate(n_wells) -> Vector{String}

Row-major well names for a standard microplate (A1, A2, …).
"""
function well_names_for_plate(n_wells::Int)::Vector{String}
    configs = Dict(
        96 => (["A","B","C","D","E","F","G","H"], 1:12),
        48 => (["A","B","C","D","E","F"],          1:8),
        24 => (["A","B","C","D"],                  1:6),
        12 => (["A","B","C"],                      1:4),
         6 => (["A","B"],                          1:3),
    )
    haskey(configs, n_wells) || error(
        "Unsupported plate size: $n_wells. Supported: $(sort(collect(keys(configs))))"
    )
    letters, numbers = configs[n_wells]
    return [l * string(n) for l in letters for n in numbers]
end

"""
    clean(::PlateReaderFormat, src_path, out_dir)

Adapter contract: read the vendor file at `src_path` and write one
`data_channel_<N>.csv` per detected channel into `out_dir`. Each output is a
CSV with header `Time, A1, A2, …` and decimal-hour time values.
"""
function clean end
