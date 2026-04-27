
# ---------------------------------------------------------------------------
# Unit tests for src/experiment_store.jl
#
# Uses fixture data from test/fixtures/.  No running server required.
# Tests are organised around the public interface:
#   load_experiment_channel, load_all_channels,
#   list_wells, load_well_data, load_all_well_data, load_blank_well_data
# ---------------------------------------------------------------------------

# Convenience: load the single-channel fixture
function _load_single()
    load_experiment_channel(joinpath(FIXTURES_DIR, "test_single"), "test_single", 1, 1)
end

# Convenience: load multi-channel channel N fixture
function _load_multi(ch)
    load_experiment_channel(joinpath(FIXTURES_DIR, "test_multi"), "test_multi", ch, 2)
end

# ---------------------------------------------------------------------------
# load_experiment_channel
# ---------------------------------------------------------------------------

@testset "load_experiment_channel — single channel" begin
    ec = _load_single()
    @test ec isa ExperimentChannel
    @test ec.experiment == "test_single"
    @test ec.channel    == 1
    @test ec.n_channels == 1
    @test ec.growth_data isa DataFrame
    @test nrow(ec.growth_data) == 5   # 5 time points in fixture
    # Annotation columns should be renamed
    @test :well      in Symbol.(names(ec.annotations))
    @test :condition in Symbol.(names(ec.annotations))
    # blank_wells must include both "b" and "X" wells
    @test "A1" in ec.blank_wells
    @test "A2" in ec.blank_wells
    @test !("B1" in ec.blank_wells)
end

@testset "load_experiment_channel — multi channel" begin
    ec1 = _load_multi(1)
    ec2 = _load_multi(2)
    @test ec1 isa ExperimentChannel
    @test ec2 isa ExperimentChannel
    @test ec1.channel == 1
    @test ec2.channel == 2
    @test ec1.n_channels == 2
    # Channel 2 OD values should differ from channel 1
    @test ec1.growth_data[1, :B1] != ec2.growth_data[1, :B1]
end

@testset "load_experiment_channel — missing files" begin
    # Non-existent directory
    @test load_experiment_channel("/tmp/no_such_exp_dir", "ghost", 1, 1) === nothing
    # Existing dir but no channel 9 data
    @test load_experiment_channel(SINGLE_CH_DIR, "test_single", 9, 1) === nothing
end

# ---------------------------------------------------------------------------
# load_all_channels
# ---------------------------------------------------------------------------

@testset "load_all_channels" begin
    channels = load_all_channels("test_single"; base_path=FIXTURES_DIR)
    @test length(channels) == 1
    @test channels[1].channel == 1

    channels_mc = load_all_channels("test_multi"; base_path=FIXTURES_DIR)
    @test length(channels_mc) == 2
    @test sort([c.channel for c in channels_mc]) == [1, 2]
    # All channels report n_channels = 2
    @test all(c.n_channels == 2 for c in channels_mc)

    # Unknown experiment returns empty
    @test isempty(load_all_channels("does_not_exist"; base_path=FIXTURES_DIR))
end

# ---------------------------------------------------------------------------
# list_wells
# ---------------------------------------------------------------------------

@testset "list_wells — single channel" begin
    ec    = _load_single()
    wells = list_wells(ec)

    @test wells isa Vector{WellMeta}
    # Fixture has 5 wells: A1(b), A2(X), B1, B2, C1
    # A1 and A2 must be excluded
    well_names = [w.well for w in wells]
    @test "A1" ∉ well_names
    @test "A2" ∉ well_names
    @test "B1" in well_names
    @test "B2" in well_names
    @test "C1" in well_names
    @test length(wells) == 3
end

@testset "list_wells — well_id encoding: single channel" begin
    ec    = _load_single()
    wells = list_wells(ec)
    for w in wells
        # Single-channel: no "_ch" in well_id
        @test !occursin("_ch", w.well_id)
        @test startswith(w.well_id, "test_single_")
    end
end

@testset "list_wells — well_id encoding: multi channel" begin
    ec    = _load_multi(1)
    wells = list_wells(ec)
    for w in wells
        # Multi-channel: must encode "_ch1_"
        @test occursin("_ch1_", w.well_id)
        @test startswith(w.well_id, "test_multi_ch1_")
    end
end

@testset "list_wells — condition string" begin
    ec    = _load_single()
    wells = list_wells(ec)

    b1 = only(filter(w -> w.well == "B1", wells))
    # Fixture row: WT, M9+glucose, Glucose_0.5 → col2 | col3 | col4
    @test b1.condition == "WT | M9+glucose | Glucose_0.5"
end

@testset "list_wells — antibiotic field" begin
    ec    = _load_single()
    wells = list_wells(ec)

    b1 = only(filter(w -> w.well == "B1", wells))
    b2 = only(filter(w -> w.well == "B2", wells))
    c1 = only(filter(w -> w.well == "C1", wells))

    # B1 has no antibiotic in fixture → "None"
    @test b1.antibiotic == "None"
    # B2 has "AmpR_2" in col 5
    @test b2.antibiotic == "AmpR_2"
    # C1 has no antibiotic
    @test c1.antibiotic == "None"
end

@testset "list_wells — display_name" begin
    ec    = _load_single()
    wells = list_wells(ec)
    for w in wells
        @test !isempty(w.display_name)
        @test occursin(w.well, w.display_name)
        @test occursin("test_single", w.display_name)
    end
end

# ---------------------------------------------------------------------------
# load_well_data (single well)
# ---------------------------------------------------------------------------

@testset "load_well_data — single well" begin
    ec = _load_single()
    wd = load_well_data(ec, "B1")

    @test wd isa WellData
    @test wd.meta.well == "B1"
    @test length(wd.time) == length(wd.od)
    @test all(isfinite, wd.time)
    @test all(isfinite, wd.od)   # od is NaN-free
    # First OD value matches fixture: 0.090
    @test wd.od[1] ≈ 0.090
end

@testset "load_well_data — missing well returns nothing" begin
    ec = _load_single()
    @test load_well_data(ec, "Z99") === nothing
end

@testset "load_well_data — blank well returns nothing" begin
    ec = _load_single()
    # A1 is a blank well; should not be loadable via load_well_data
    @test load_well_data(ec, "A1") === nothing
end

@testset "load_well_data — correct channel data" begin
    ec1 = _load_multi(1)
    ec2 = _load_multi(2)
    wd1 = load_well_data(ec1, "B1")
    wd2 = load_well_data(ec2, "B1")
    @test wd1 !== nothing && wd2 !== nothing
    # Channel 2 has higher OD values in fixture
    @test wd2.od[1] > wd1.od[1]
end

# ---------------------------------------------------------------------------
# load_well_data (multiple wells)
# ---------------------------------------------------------------------------

@testset "load_well_data — multiple wells" begin
    ec   = _load_single()
    wds  = load_well_data(ec, ["B1", "B2", "C1"])
    @test length(wds) == 3
    @test Set([wd.meta.well for wd in wds]) == Set(["B1", "B2", "C1"])
end

@testset "load_well_data — skips invalid wells silently" begin
    ec  = _load_single()
    wds = load_well_data(ec, ["B1", "NOEXIST", "C1"])
    @test length(wds) == 2
    @test all(wd -> wd.meta.well in ["B1", "C1"], wds)
end

# ---------------------------------------------------------------------------
# load_all_well_data
# ---------------------------------------------------------------------------

@testset "load_all_well_data" begin
    ec   = _load_single()
    wds  = load_all_well_data(ec)
    # 3 non-blank wells in fixture
    @test length(wds) == 3
    @test all(wd -> wd.meta.well in ["B1", "B2", "C1"], wds)
    # All series must have the same length (5 time points, all finite)
    lengths = [length(wd.od) for wd in wds]
    @test all(==(5), lengths)
end

# ---------------------------------------------------------------------------
# load_blank_well_data
# ---------------------------------------------------------------------------

@testset "load_blank_well_data" begin
    ec     = _load_single()
    blanks = load_blank_well_data(ec)

    # Only "b" wells returned (not "X")
    @test length(blanks) == 1
    @test blanks[1].meta.well == "A1"
    @test all(isfinite, blanks[1].od)
    @test blanks[1].od[1] ≈ 0.085

    # Multi-channel: same blank well appears in each channel load
    ec2     = _load_multi(1)
    blanks2 = load_blank_well_data(ec2)
    @test length(blanks2) == 1
    @test blanks2[1].meta.well == "A1"
end
