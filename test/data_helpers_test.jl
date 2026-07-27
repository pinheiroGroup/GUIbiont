
# ---------------------------------------------------------------------------
# Unit tests for src/data.jl helpers
#
# All tests are self-contained and use fixture files from test/fixtures/.
# No running server required.
# ---------------------------------------------------------------------------

const FIXTURES_DIR  = joinpath(@__DIR__, "fixtures")
const SINGLE_CH_DIR = joinpath(FIXTURES_DIR, "test_single")
const MULTI_CH_DIR  = joinpath(FIXTURES_DIR, "test_multi")
const LG166_DIR     = joinpath(FIXTURES_DIR, "clean", "LG166")

@testset "find_annotation_file" begin
    # Channel-specific file present: must return it
    f = find_annotation_file(SINGLE_CH_DIR, 1)
    @test f !== nothing
    @test occursin("annotation_channel_1", f)

    # Channel 2 does not exist in single_channel fixture → should NOT fall back to
    # annotation_clean.csv because single_channel DOES have a channel-specific file
    # for channel 1, so the experiment is NOT purely single-channel.
    f2 = find_annotation_file(SINGLE_CH_DIR, 2)
    @test f2 === nothing

    # Multi-channel fixture: channel 1 and 2 each have their own file
    f_mc1 = find_annotation_file(MULTI_CH_DIR, 1)
    @test f_mc1 !== nothing
    @test occursin("annotation_channel_1", f_mc1)

    f_mc2 = find_annotation_file(MULTI_CH_DIR, 2)
    @test f_mc2 !== nothing
    @test occursin("annotation_channel_2", f_mc2)

    # Missing channel in multi-channel fixture
    @test find_annotation_file(MULTI_CH_DIR, 9) === nothing

    # Non-existent directory returns nothing without throwing
    @test find_annotation_file("/tmp/does_not_exist_xyz", 1) === nothing

    # Experiment directory with ONLY annotation_clean.csv and no channel-specific
    # files → must fall back to annotation_clean.csv
    mktempdir() do dir
        clean = joinpath(dir, "annotation_clean.csv")
        write(clean, "A1,WT\nA2,b\n")
        result = find_annotation_file(dir, 1)
        @test result == clean
    end
end

@testset "read_annotation_file" begin
    ann = read_annotation_file(joinpath(SINGLE_CH_DIR, "annotation_clean.csv"))

    @test ann isa DataFrame
    @test nrow(ann) == 5   # A1, A2, B1, B2, C1

    # Rows where column 2 was originally empty must be normalised to "X"
    # (A1 is "b", A2 is "X" in the fixture — no empty cells to normalise here,
    #  but we test that existing values are preserved)
    @test ann[1, 2] == "b"
    @test ann[2, 2] == "X"
    @test ann[3, 2] == "WT"

    # Test normalisation: write a file with a blank second column
    mktempdir() do dir
        p = joinpath(dir, "ann.csv")
        write(p, "A1,\nA2,WT\n")
        df = read_annotation_file(p)
        @test df[1, 2] == "X"   # empty → normalised to "X"
        @test df[2, 2] == "WT"
    end
end

@testset "get_blank_wells" begin
    ann = read_annotation_file(joinpath(SINGLE_CH_DIR, "annotation_clean.csv"))
    blanks = get_blank_wells(ann)

    @test blanks isa Set{String}
    # A1 is "b" (blank), A2 is "X" (excluded) — both must appear
    @test "A1" in blanks
    @test "A2" in blanks
    # Non-blank wells must NOT appear
    @test !("B1" in blanks)
    @test !("B2" in blanks)
    @test !("C1" in blanks)
end

@testset "get_blank_well_names" begin
    ann = read_annotation_file(joinpath(SINGLE_CH_DIR, "annotation_clean.csv"))
    names_out = get_blank_well_names(ann)

    @test names_out isa Vector{String}
    # Only "b" wells, not "X"
    @test "A1" in names_out
    @test !("A2" in names_out)
    @test issorted(names_out)
end

@testset "parse_time_column" begin
    gd = CSV.read(joinpath(SINGLE_CH_DIR, "data_channel_1.csv"),
                  DataFrame, header=1, silencewarnings=true)

    t = parse_time_column(gd)
    @test t isa Vector{Float64}
    @test length(t) == nrow(gd)
    @test all(isfinite, t)
    @test issorted(t)
    @test t[1] ≈ 0.1

    # Test string time column: write a file where times are strings
    mktempdir() do dir
        p = joinpath(dir, "str_time.csv")
        write(p, "Time,A1\n0.5,0.1\n1.0,0.2\n1.5,0.3\n")
        df = CSV.read(p, DataFrame, header=1, stringtype=String, silencewarnings=true)
        t2 = parse_time_column(df)
        @test t2 ≈ [0.5, 1.0, 1.5]
    end

    # Unparseable string times → fallback to 0:(n-1)
    mktempdir() do dir
        p = joinpath(dir, "bad_time.csv")
        write(p, "Time,A1\nstep1,0.1\nstep2,0.2\n")
        df = CSV.read(p, DataFrame, header=1, stringtype=String, silencewarnings=true)
        t3 = parse_time_column(df)
        @test length(t3) == 2
        @test t3 == [0.0, 1.0]
    end
end

@testset "parse_od_column" begin
    gd = CSV.read(joinpath(SINGLE_CH_DIR, "data_channel_1.csv"),
                  DataFrame, header=1, silencewarnings=true)

    od = parse_od_column(gd, :B1)
    @test od isa Vector{Float64}
    @test length(od) == nrow(gd)
    @test all(isfinite, od)
    @test od[1] ≈ 0.090

    # Non-numeric cells → NaN
    mktempdir() do dir
        p = joinpath(dir, "od_nan.csv")
        write(p, "Time,A1\n0.1,0.085\n0.2,OVER\n0.3,0.090\n")
        df = CSV.read(p, DataFrame, header=1, stringtype=String, silencewarnings=true)
        od2 = parse_od_column(df, :A1)
        @test isfinite(od2[1])
        @test isnan(od2[2])
        @test isfinite(od2[3])
    end
end

@testset "compute_blank_value" begin
    gd  = CSV.read(joinpath(SINGLE_CH_DIR, "data_channel_1.csv"),
                   DataFrame, header=1, silencewarnings=true)
    ann = read_annotation_file(joinpath(SINGLE_CH_DIR, "annotation_clean.csv"))

    val = compute_blank_value(gd, ann)
    @test val isa Float64
    @test isfinite(val)
    # A1 is the only "b" well; its mean OD across all timepoints is ~0.085-0.086
    @test 0.08 < val < 0.09

    # Overload with explicit blank well name list
    val2 = compute_blank_value(gd, ["A1"])
    @test val ≈ val2

    # No blank wells → 0.0
    val3 = compute_blank_value(gd, String[])
    @test val3 == 0.0
end

@testset "compute_blank_timeseries" begin
    gd  = CSV.read(joinpath(SINGLE_CH_DIR, "data_channel_1.csv"),
                   DataFrame, header=1, silencewarnings=true)
    ann = read_annotation_file(joinpath(SINGLE_CH_DIR, "annotation_clean.csv"))

    ts = compute_blank_timeseries(gd, ann)
    @test ts isa Vector{Float64}
    @test length(ts) == nrow(gd)
    @test all(isfinite, ts)
    # All values should be in the plausible blank OD range
    @test all(v -> 0.08 < v < 0.09, ts)

    # Overload with explicit well names
    ts2 = compute_blank_timeseries(gd, ["A1"])
    @test ts ≈ ts2

    # No blank wells → zeros
    ts3 = compute_blank_timeseries(gd, String[])
    @test all(iszero, ts3)

    # Regression: an all-NaN row across every blank well must not error and must
    # return a finite, length-n vector (falls back to the global blank mean).
    # Mirrors the LG391 final-row plate-reader NaN that previously crashed
    # /api/blank-analysis with mean(Float64[]).
    gd_nan = copy(gd)
    gd_nan[end, :A1] = NaN
    ts_nan = compute_blank_timeseries(gd_nan, ["A1"])
    @test length(ts_nan) == nrow(gd_nan)
    @test all(isfinite, ts_nan)
end

# ---------------------------------------------------------------------------
# resolve_blank_wells — accepted auto-detected blanks must reach the fit.
#
# Regression guard: "Use these as blanks" in the Fit Curve tab used to update
# only the advisory card, because every fitting route re-derived blanks from
# the annotation file and the request schema had no override field. These
# tests pin the resolver the routes now call, and show that overriding really
# changes the blank value the fit subtracts.
# ---------------------------------------------------------------------------

@testset "resolve_blank_wells" begin
    gd  = CSV.read(joinpath(LG166_DIR, "data_channel_1.csv"), DataFrame,
                   header=1, stringtype=String, silencewarnings=true)
    ann = read_annotation_file(joinpath(LG166_DIR, "annotation_clean.csv"))

    annotated = get_blank_well_names(ann)
    @test !isempty(annotated)

    # Empty override falls back to the annotation file's "b" wells.
    @test resolve_blank_wells(gd, ann, String[]) == annotated

    # A non-empty override wins.
    override = ["A5", "A6"]
    @test resolve_blank_wells(gd, ann, override) == override

    # Names absent from the data file are dropped rather than trusted.
    @test resolve_blank_wells(gd, ann, ["A5", "NOPE_1", "ZZ99"]) == ["A5"]
    # Nothing usable in the override -> fall back rather than leave the fit blankless.
    @test resolve_blank_wells(gd, ann, ["NOPE_1"]) == annotated

    # The override must actually move the number the fit subtracts, otherwise
    # accepting candidates would still be a no-op.
    @test compute_blank_value(gd, override) != compute_blank_value(gd, annotated)
    @test length(compute_blank_timeseries(gd, override)) ==
          length(compute_blank_timeseries(gd, annotated))
end
