
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

# ---------------------------------------------------------------------------
# _prescreen_constant
# ---------------------------------------------------------------------------

@testset "_prescreen_constant — flat curve flagged" begin
    # Row 1: completely flat (q0.9 / q0.1 ≈ 1 < 1.5) → constant
    # Row 2: growing (q0.9 >> q0.1)                  → dynamic
    curves = [0.1  0.1  0.1  0.1  0.1;
              0.1  0.2  0.4  0.8  1.0]
    mask = _prescreen_constant(curves; tol_const=1.5)
    @test mask[1] == true
    @test mask[2] == false
end

@testset "_prescreen_constant — zero baseline flagged as flat" begin
    # Baseline near zero with negligible range
    curves = reshape([0.0, 1e-8, 0.0, 1e-8, 0.0], 1, 5)
    mask = _prescreen_constant(curves; tol_const=1.5)
    @test mask[1] == true
end

@testset "_prescreen_constant — tolerance controls threshold" begin
    # q0.1=0.5, q0.9=1.0 → ratio=2.0; flagged at tol=2.5, not at tol=1.5
    curves = reshape([0.5, 0.6, 0.7, 0.8, 1.0], 1, 5)
    @test _prescreen_constant(curves; tol_const=2.5)[1] == true
    @test _prescreen_constant(curves; tol_const=1.5)[1] == false
end

@testset "_prescreen_constant — all rows dynamic" begin
    curves = [0.0  0.5  1.0;
              0.0  0.4  0.9]
    mask = _prescreen_constant(curves; tol_const=1.5)
    @test all(.!mask)
end

# ---------------------------------------------------------------------------
# _apply_trend_test_flat
# ---------------------------------------------------------------------------

@testset "_apply_trend_test_flat — flat curve reassigned" begin
    times = collect(0.0:0.5:5.0)   # 11 points
    # Row 1: genuinely flat (no slope)
    # Row 2: strong positive slope
    curves = [fill(0.5, 11)';
              collect(range(0.0, 1.0; length=11))']
    ids = [1, 2]
    new_ids = _apply_trend_test_flat(curves, times, ids; p_thr=0.05)
    @test new_ids[1] == 3    # reassigned to flat sentinel
    @test new_ids[2] == 2    # growing curve unchanged
end

@testset "_apply_trend_test_flat — growing curves unchanged" begin
    times = collect(0.0:1.0:9.0)
    curves = [collect(range(0.0, 1.0; length=10))';
              collect(range(0.0, 2.0; length=10))']
    ids = [1, 1]
    new_ids = _apply_trend_test_flat(curves, times, ids; p_thr=0.05)
    @test new_ids == [1, 1]
end

@testset "_apply_trend_test_flat — sentinel label is max+1" begin
    times = collect(0.0:1.0:9.0)
    curves = [fill(0.3, 10)'; fill(0.5, 10)']
    ids = [3, 5]
    new_ids = _apply_trend_test_flat(curves, times, ids; p_thr=0.05)
    @test maximum(new_ids) == 6   # sentinel = max(3,5)+1
end
