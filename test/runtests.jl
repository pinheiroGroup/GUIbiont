using Test
using CSV
using DataFrames

# Load the functions under test
include(joinpath(@__DIR__, "..", "function_clean_synergy.jl"))

# ---------------------------------------------------------------------------
# Paths to real fixtures (raw input) and golden outputs (Clean_data)
# ---------------------------------------------------------------------------

const RAW_LG281     = joinpath(@__DIR__, "..", "raw_data", "LG281")
const GOLDEN_LG281  = joinpath(@__DIR__, "..", "Clean_data", "LG281")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Read a CSV as a plain matrix of strings (no type inference, no headers)
function read_csv_strings(path)
    CSV.read(path, DataFrame, header=false, stringtype=String, silencewarnings=true)
end

# Read a CSV with the first row as column names
function read_csv_with_header(path)
    CSV.read(path, DataFrame, header=1, stringtype=String, silencewarnings=true)
end

# ---------------------------------------------------------------------------
# detect_csv_separator
# ---------------------------------------------------------------------------

@testset "detect_csv_separator" begin
    mktempdir() do dir
        comma_file = joinpath(dir, "comma.csv")
        semi_file  = joinpath(dir, "semi.csv")
        write(comma_file, "a,b,c\n1,2,3\n4,5,6\n")
        write(semi_file,  "a;b;c\n1;2;3\n4;5;6\n")

        @test detect_csv_separator(comma_file) == ','
        @test detect_csv_separator(semi_file)  == ';'
    end

    # Real LG281 data file uses semicolons
    @test detect_csv_separator(joinpath(RAW_LG281, "data.csv"))  == ';'
    @test detect_csv_separator(joinpath(RAW_LG281, "plate.csv")) == ';'
end

# ---------------------------------------------------------------------------
# cleaning_data_synergy — run against LG281 and compare to golden output
# ---------------------------------------------------------------------------

@testset "cleaning_data_synergy" begin
    mktempdir() do out_dir
        out_path = out_dir * "/"
        cleaning_data_synergy(joinpath(RAW_LG281, "data.csv"), out_path)

        @testset "produces correct channel files" begin
            for ch in 1:3
                fname = joinpath(out_dir, "data_channel_$(ch).csv")
                @test isfile(fname)
            end
            # No data_channel_4 expected for LG281 (3 channels)
            @test !isfile(joinpath(out_dir, "data_channel_4.csv"))
        end

        for ch in 1:3
            golden = read_csv_with_header(joinpath(GOLDEN_LG281, "data_channel_$(ch).csv"))
            result = read_csv_with_header(joinpath(out_dir, "data_channel_$(ch).csv"))

            @testset "channel $ch structure" begin
                @test names(result) == names(golden)
                @test nrow(result)  == nrow(golden)
                @test ncol(result)  == ncol(golden)
            end

            @testset "channel $ch first column is Time" begin
                @test names(result)[1] == "Time"
            end

            @testset "channel $ch well columns" begin
                well_cols = names(result)[2:end]
                @test length(well_cols) == 48      # 48-well plate
                @test well_cols[1]  == "A1"
                @test well_cols[end] == "F8"
            end

            @testset "channel $ch time values are numeric and increasing" begin
                times = Float64.(result[!, "Time"])
                @test all(isfinite, times)
                @test all(diff(times) .> 0)
            end

            @testset "channel $ch OD values are numeric" begin
                @test result[1, "A1"] isa Number
                @test isfinite(Float64(result[1, "A1"]))
            end

            @testset "channel $ch first row matches golden" begin
                @test result[1, :] == golden[1, :]
            end

            @testset "channel $ch last row matches golden" begin
                @test result[end, :] == golden[end, :]
            end

            @testset "channel $ch full content matches golden" begin
                @test result == golden
            end
        end
    end
end

# ---------------------------------------------------------------------------
# read_labguru_annotation — run against LG281 and compare to golden output
# ---------------------------------------------------------------------------

@testset "read_labguru_annotation" begin
    mktempdir() do out_dir
        out_path = out_dir * "/"
        read_labguru_annotation(joinpath(RAW_LG281, "plate.csv"), out_path, 48)

        @testset "produces annotation_clean.csv" begin
            @test isfile(joinpath(out_dir, "annotation_clean.csv"))
        end

        @testset "produces per-channel per-media annotation files" begin
            @test isfile(joinpath(out_dir, "annotation_channel_1_media_M9+glucose.csv"))
            @test isfile(joinpath(out_dir, "annotation_channel_2_media_M9+glucose.csv"))
            # Channel 3 has no wells assigned in LG281 plate layout
            @test !isfile(joinpath(out_dir, "annotation_channel_3_media_M9+glucose.csv"))
        end

        @testset "annotation_clean.csv structure" begin
            golden = read_csv_strings(joinpath(GOLDEN_LG281, "annotation_clean.csv"))
            result = read_csv_strings(joinpath(out_dir,       "annotation_clean.csv"))
            @test nrow(result) == nrow(golden)
            @test ncol(result) == ncol(golden)
        end

        @testset "annotation_clean.csv content matches golden" begin
            golden = read_csv_strings(joinpath(GOLDEN_LG281, "annotation_clean.csv"))
            result = read_csv_strings(joinpath(out_dir,       "annotation_clean.csv"))
            @test isequal(result, golden)
        end

        for ch in 1:2
            fname = "annotation_channel_$(ch)_media_M9+glucose.csv"
            @testset "$(fname) content matches golden" begin
                golden = read_csv_strings(joinpath(GOLDEN_LG281, fname))
                result = read_csv_strings(joinpath(out_dir,       fname))
                @test nrow(result) == nrow(golden)
                @test ncol(result) == ncol(golden)
                @test result == golden
            end
        end

        @testset "annotation_clean.csv well column is complete" begin
            result = read_csv_strings(joinpath(out_dir, "annotation_clean.csv"))
            wells  = result[!, 1]
            # 48-well plate: A1-F8
            expected_wells = [r * string(c) for r in ["A","B","C","D","E","F"] for c in 1:8]
            @test Vector{String}(wells) == expected_wells
        end

        @testset "per-channel annotation marks non-channel wells as X" begin
            result = read_csv_strings(joinpath(out_dir, "annotation_channel_1_media_M9+glucose.csv"))
            # Column 2 should be either a condition string or "b" (blank) — never missing
            @test all(!ismissing, result[!, 2])
            # Blank wells (column 8 in each row group: A8, B8, ...) should be "b"
            blank_rows = filter(row -> row[2] == "b", eachrow(result))
            @test length(blank_rows) > 0
        end
    end
end
