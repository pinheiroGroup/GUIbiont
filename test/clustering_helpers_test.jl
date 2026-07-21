
# ---------------------------------------------------------------------------
# Unit tests for clustering helper functions (src/clustering.jl)
# No server required.
# ---------------------------------------------------------------------------

using Statistics

@testset "_centroid_with_sd — basic" begin
    curves = [1.0 2.0 3.0;
              3.0 4.0 5.0;
              5.0 6.0 7.0]
    mask   = [1, 2, 3]
    c, s   = _centroid_with_sd(curves, mask)
    @test length(c) == 3
    @test length(s) == 3
    @test c ≈ [3.0, 4.0, 5.0]
    @test s ≈ [std([1.0,3.0,5.0]), std([2.0,4.0,6.0]), std([3.0,5.0,7.0])] atol=1e-10
end

@testset "_centroid_with_sd — single series gives sd=0" begin
    curves = [1.0 2.0; 9.0 9.0]
    c, s   = _centroid_with_sd(curves, [1])
    @test c == [1.0, 2.0]
    @test s == [0.0, 0.0]
end

@testset "_centroid_with_sd — subset mask" begin
    curves = [1.0 2.0;
              3.0 4.0;
              5.0 6.0]
    c, s = _centroid_with_sd(curves, [1, 3])
    @test c ≈ [3.0, 4.0]
    @test s ≈ [std([1.0, 5.0]), std([2.0, 6.0])] atol=1e-10
end

@testset "_interpolate_to_grid — exact grid points" begin
    times  = [[0.0, 1.0, 2.0]]
    curves = [[0.0, 1.0, 2.0]]
    grid   = [0.0, 0.5, 1.0, 1.5, 2.0]
    out    = _interpolate_to_grid(curves, times, grid)
    @test size(out) == (1, 5)
    @test out[1, :] ≈ [0.0, 0.5, 1.0, 1.5, 2.0] atol=1e-10
end

@testset "_interpolate_to_grid — clamped extrapolation" begin
    times  = [[1.0, 2.0]]
    curves = [[10.0, 20.0]]
    grid   = [0.0, 1.0, 2.0, 3.0]
    out    = _interpolate_to_grid(curves, times, grid)
    @test out[1, 1] == 10.0   # below range → clamp to first value
    @test out[1, 4] == 20.0   # above range → clamp to last value
end

@testset "_interpolate_to_grid — multiple series" begin
    times  = [[0.0, 2.0], [0.0, 4.0]]
    curves = [[0.0, 4.0], [0.0, 8.0]]
    grid   = [0.0, 1.0, 2.0]
    out    = _interpolate_to_grid(curves, times, grid)
    @test out[1, :] ≈ [0.0, 2.0, 4.0] atol=1e-10
    @test out[2, :] ≈ [0.0, 2.0, 4.0] atol=1e-10
end

@testset "_build_interp_grid — quantile endpoints" begin
    # Three series with different end times: 9, 10, 100
    times = [[0.0, 9.0], [0.0, 10.0], [0.0, 100.0]]
    grid  = _build_interp_grid(times, 11, 0.0, 0.95)
    @test length(grid) == 11
    @test grid[1] ≈ 0.0 atol=1e-10
    # t_end quantile(0.95) of [9,10,100] should be well below 100
    @test grid[end] < 100.0
end

@testset "_build_interp_grid — uniform spacing" begin
    times = [[0.0, 10.0], [0.0, 10.0]]
    grid  = _build_interp_grid(times, 6, 0.0, 1.0)
    @test length(grid) == 6
    @test grid ≈ collect(range(0.0, 10.0; length=6)) atol=1e-10
end

@testset "_experiment_key — csv vs experiment mode" begin
    @test _experiment_key("LG166/A1", false) == "LG166"
    @test _experiment_key("A1", false)       == "A1"        # no '/' → whole label
    @test _experiment_key("LG166/A1", true)  == "__all__"   # csv mode → single group
end

@testset "_subtract_blanks_per_experiment — each experiment uses its own blank" begin
    # exp1 well corrected by exp1 blank (0.5); exp2 well by exp2 blank (0.1).
    # A pooled mean blank (0.3) would give 0.7 / 1.7 instead — this checks that
    # correction is done separately within each experiment.
    curves       = [1.0 1.0 1.0; 2.0 2.0 2.0]
    labels       = ["exp1/A", "exp2/A"]
    blank_curves = [[0.5, 0.5, 0.5], [0.1, 0.1, 0.1]]
    blank_labels = ["exp1/b", "exp2/b"]
    out = _subtract_blanks_per_experiment(curves, labels, blank_curves, blank_labels,
                                          "pointbypoint", false)
    @test out[1, :] ≈ [0.5, 0.5, 0.5] atol=1e-10
    @test out[2, :] ≈ [1.9, 1.9, 1.9] atol=1e-10
end

@testset "_subtract_blanks_per_experiment — experiment without blanks is unchanged" begin
    curves       = [1.0 1.0; 2.0 2.0; 5.0 5.0]
    labels       = ["exp1/A", "exp2/A", "exp3/A"]   # exp3 has no blank
    blank_curves = [[0.5, 0.5], [0.1, 0.1]]
    blank_labels = ["exp1/b", "exp2/b"]
    out = _subtract_blanks_per_experiment(curves, labels, blank_curves, blank_labels,
                                          "pointbypoint", false)
    @test out[1, :] ≈ [0.5, 0.5] atol=1e-10
    @test out[2, :] ≈ [1.9, 1.9] atol=1e-10
    @test out[3, :] ≈ [5.0, 5.0] atol=1e-10        # untouched
end

@testset "_subtract_blanks_per_experiment — csv mode pools all blanks" begin
    # csv_mode=true → every series is one group, so blanks pool (mean of 0.2, 0.4 = 0.3).
    curves       = [1.0 1.0; 2.0 2.0]
    labels       = ["A", "B"]
    blank_curves = [[0.2, 0.2], [0.4, 0.4]]
    blank_labels = ["b1", "b2"]
    out = _subtract_blanks_per_experiment(curves, labels, blank_curves, blank_labels,
                                          "pointbypoint", true)
    @test out[1, :] ≈ [0.7, 0.7] atol=1e-10
    @test out[2, :] ≈ [1.7, 1.7] atol=1e-10
end

