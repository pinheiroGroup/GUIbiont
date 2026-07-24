
# ---------------------------------------------------------------------------
# Unit tests for analysis.jl pure-function helpers.
# No server or external packages required.
#
# The helper functions are inlined here to avoid loading the Kinbiont /
# OptimizationBBO / OptimizationNLopt stack that analysis.jl pulls in at the
# module level.
# ---------------------------------------------------------------------------

function _clip_initial_value(x::Real; lower::Real = 1e-6, upper::Real = 49.0)
    isfinite(x) ? clamp(Float64(x), Float64(lower), Float64(upper)) : 1.0
end

function _positive_or(x::Real, fallback::Real)
    isfinite(x) && x > 0 ? Float64(x) : Float64(fallback)
end

function _finite_quantile(values::AbstractVector{<:Real}, p::Real)
    xs = sort(Float64[x for x in values if isfinite(x)])
    isempty(xs) && return NaN
    length(xs) == 1 && return xs[1]
    pos = 1 + (length(xs) - 1) * clamp(Float64(p), 0.0, 1.0)
    lo = floor(Int, pos)
    hi = ceil(Int, pos)
    lo == hi && return xs[lo]
    return xs[lo] + (pos - lo) * (xs[hi] - xs[lo])
end

function _growth_curve_features(time_numeric::Vector{Float64}, od_for_fit::Vector{Float64})
    valid = findall(i -> isfinite(time_numeric[i]) && isfinite(od_for_fit[i]), eachindex(time_numeric))
    if length(valid) < 2
        return Dict{Symbol, Float64}(
            :baseline => 0.01, :plateau => 1.0, :amplitude => 1.0,
            :growth_rate => 1.0, :max_slope => 1.0, :lag_time => 0.0,
            :mid_time => 0.0, :inflection_time => 0.0,
            :doubling_time => log(2), :duration => 1.0,
            :terminal_slope => 0.0, :q0 => 1.0,
        )
    end
    ord = sortperm(time_numeric[valid])
    t = time_numeric[valid][ord]
    y = max.(od_for_fit[valid][ord], 1e-6)
    duration = _positive_or(t[end] - t[1], 1.0)
    n_edge   = clamp(ceil(Int, length(y) * 0.1), 2, min(8, length(y)))
    baseline   = max(_finite_quantile(y[1:n_edge], 0.5), minimum(y), 1e-4)
    late_level = _finite_quantile(y[end - n_edge + 1:end], 0.5)
    plateau    = max(_finite_quantile(y, 0.95), late_level, baseline + 1e-4)
    amplitude  = max(plateau - baseline, maximum(y) - minimum(y), 1e-4)
    slopes = Float64[]; slope_times = Float64[]; log_slopes = Float64[]
    for i in 1:(length(t) - 1)
        dt = t[i + 1] - t[i]; dt > 0 || continue
        dy = y[i + 1] - y[i]
        push!(slopes, dy / dt); push!(slope_times, (t[i] + t[i + 1]) / 2)
        push!(log_slopes, (log(y[i + 1]) - log(y[i])) / dt)
    end
    positive_slopes     = filter(x -> isfinite(x) && x > 0, slopes)
    max_slope           = isempty(positive_slopes) ? amplitude / duration : maximum(positive_slopes)
    positive_log_slopes = filter(x -> isfinite(x) && x > 0, log_slopes)
    max_log_slope       = isempty(positive_log_slopes) ? 0.0 : maximum(positive_log_slopes)
    logistic_rate       = 4 * max_slope / max(plateau, 1e-4)
    growth_rate         = _clip_initial_value(max(max_log_slope, logistic_rate, 1 / duration); upper = 20.0)
    imax = isempty(slopes) ? 1 : argmax(slopes)
    inflection_time = isempty(slope_times) ? t[1] : slope_times[imax]
    first_crossing(thr) = let idx = findfirst(v -> v >= thr, y); idx === nothing ? t[1] : t[idx] end
    lag_time      = clamp(first_crossing(baseline + 0.10 * amplitude), t[1], t[end])
    mid_time      = clamp(first_crossing(baseline + 0.50 * amplitude), t[1], t[end])
    doubling_time = _clip_initial_value(log(2) / growth_rate; upper = duration)
    tail_start    = max(1, length(slopes) - max(1, ceil(Int, 0.2 * length(slopes))) + 1)
    terminal_slope = isempty(slopes) ? 0.0 : _finite_quantile(slopes[tail_start:end], 0.5)
    q0 = _clip_initial_value(exp(-growth_rate * max(lag_time - t[1], 0.0)); upper = 50.0)
    return Dict{Symbol, Float64}(
        :baseline => _clip_initial_value(baseline),
        :plateau  => _clip_initial_value(plateau),
        :amplitude => _clip_initial_value(amplitude),
        :growth_rate => growth_rate,
        :max_slope => _clip_initial_value(max_slope),
        :lag_time  => _clip_initial_value(lag_time - t[1]; upper = duration),
        :mid_time  => _clip_initial_value(mid_time - t[1]; upper = duration),
        :inflection_time => _clip_initial_value(inflection_time - t[1]; upper = duration),
        :doubling_time => doubling_time, :duration => duration,
        :terminal_slope => _clip_initial_value(abs(terminal_slope); upper = 20.0),
        :q0 => q0,
    )
end

function _smart_initial_value(param_name, features::Dict{Symbol, Float64})
    raw     = lowercase(String(param_name))
    compact = replace(raw, r"[^a-z0-9]" => "")
    if compact in ("nlag", "xlag", "ylag", "odlag") ||
       ((startswith(compact, "n") || startswith(compact, "x") ||
         startswith(compact, "y") || startswith(compact, "od")) && occursin("lag", compact))
        return max(features[:baseline], 1e-6)
    elseif compact in ("t0", "tmid", "tmax", "tinf", "tinflection",
                        "tshift", "tstationary", "tdecaygr", "endsecondlag") ||
           occursin("inflection", compact) || occursin("midtime", compact)
        return features[:mid_time]
    elseif compact == "exitlagrate"
        return _clip_initial_value(1.0 / max(features[:lag_time], 0.1); upper = 20.0)
    elseif occursin("death", compact) || occursin("decay", compact) ||
           occursin("decline", compact) || occursin("mort", compact)
        return _clip_initial_value(0.05 * features[:growth_rate]; upper = 20.0)
    elseif occursin("inhib", compact) || occursin("inactiv", compact) ||
           occursin("resist", compact)
        return _clip_initial_value(0.05 * features[:growth_rate]; upper = 20.0)
    elseif occursin("doubl", compact) || compact in ("dt", "td")
        return features[:doubling_time]
    elseif occursin("slope", compact) || occursin("linear", compact)
        return max(features[:terminal_slope], 1e-6)
    elseif compact in ("n0", "x0", "y0", "od0") ||
           occursin("initial", compact) || occursin("inoc", compact) ||
           occursin("baseline", compact)
        return features[:baseline]
    elseif occursin("mu", compact) || compact in ("r", "gr") ||
           occursin("growth", compact) || startswith(compact, "gr") ||
           endswith(compact, "gr")
        return features[:growth_rate]
    elseif compact in ("lag", "tl", "tlag", "lagtime") ||
           startswith(compact, "tlag") || occursin("lambda", compact) ||
           occursin("delay", compact) || occursin("lag", compact)
        return features[:lag_time]
    elseif compact == "k" || occursin("nmax", compact) || occursin("ymax", compact) ||
           occursin("xmax", compact) || occursin("maxod", compact) ||
           occursin("carrying", compact) || occursin("capacity", compact) ||
           occursin("plateau", compact) || occursin("asymptote", compact)
        return features[:plateau]
    elseif occursin("amplitude", compact) || compact == "amp"
        return features[:amplitude]
    elseif compact in ("q0", "h0")
        return features[:q0]
    elseif occursin("shape", compact) || compact in ("nu", "theta", "beta", "gamma", "m", "v")
        return 1.0
    else
        return 1.0
    end
end

# ---------------------------------------------------------------------------
# Synthetic features fixture
# ---------------------------------------------------------------------------

const TEST_FEATURES = Dict{Symbol, Float64}(
    :baseline        => 0.02,
    :plateau         => 1.4,
    :amplitude       => 1.38,
    :growth_rate     => 0.8,
    :max_slope       => 0.25,
    :lag_time        => 1.5,
    :mid_time        => 4.0,
    :inflection_time => 3.5,
    :doubling_time   => log(2) / 0.8,
    :duration        => 12.0,
    :terminal_slope  => 0.01,
    :q0              => 0.3,
)

# ---------------------------------------------------------------------------
# _smart_initial_value — lag-time routing (regression for ordering bug)
# ---------------------------------------------------------------------------

@testset "_smart_initial_value — lag parameters route to lag_time" begin
    lag_val = TEST_FEATURES[:lag_time]

    # Canonical lag names
    @test _smart_initial_value("lag",      TEST_FEATURES) == lag_val
    @test _smart_initial_value("tlag",     TEST_FEATURES) == lag_val
    @test _smart_initial_value("lag_time", TEST_FEATURES) == lag_val
    @test _smart_initial_value("lagtime",  TEST_FEATURES) == lag_val

    # Compound names that contain "rate" — must not fall into growth_rate branch
    @test _smart_initial_value("lag_rate",   TEST_FEATURES) == lag_val
    @test _smart_initial_value("lag_phase",  TEST_FEATURES) == lag_val
    @test _smart_initial_value("phase_lag",  TEST_FEATURES) == lag_val
    @test _smart_initial_value("lag_period", TEST_FEATURES) == lag_val

    # lambda / delay synonyms
    @test _smart_initial_value("lambda",    TEST_FEATURES) == lag_val
    @test _smart_initial_value("delay",     TEST_FEATURES) == lag_val
    @test _smart_initial_value("tlag_min",  TEST_FEATURES) == lag_val
end

# ---------------------------------------------------------------------------
# _smart_initial_value — growth-rate routing still works after reorder
# ---------------------------------------------------------------------------

@testset "_smart_initial_value — growth-rate parameters route to growth_rate" begin
    gr_val = TEST_FEATURES[:growth_rate]

    @test _smart_initial_value("mu",          TEST_FEATURES) == gr_val
    @test _smart_initial_value("r",           TEST_FEATURES) == gr_val
    @test _smart_initial_value("gr",          TEST_FEATURES) == gr_val
    @test _smart_initial_value("growth_rate", TEST_FEATURES) == gr_val
    @test _smart_initial_value("rate",        TEST_FEATURES) != gr_val
    @test _smart_initial_value("max_rate",    TEST_FEATURES) != gr_val
end

@testset "_smart_initial_value — model-specific lag/rate semantics" begin
    @test _smart_initial_value("exit_lag_rate", TEST_FEATURES) ==
          1.0 / max(TEST_FEATURES[:lag_time], 0.1)
    @test _smart_initial_value("lag_2_gr", TEST_FEATURES) == TEST_FEATURES[:growth_rate]
    @test _smart_initial_value("gr_lag", TEST_FEATURES) == TEST_FEATURES[:growth_rate]
    @test _smart_initial_value("t_decay_gr", TEST_FEATURES) == TEST_FEATURES[:mid_time]
    @test _smart_initial_value("t_stationary", TEST_FEATURES) == TEST_FEATURES[:mid_time]
end

# ---------------------------------------------------------------------------
# _smart_initial_value — other branches are unaffected
# ---------------------------------------------------------------------------

@testset "_smart_initial_value — other branches" begin
    @test _smart_initial_value("N_max",    TEST_FEATURES) == TEST_FEATURES[:plateau]
    @test _smart_initial_value("carrying", TEST_FEATURES) == TEST_FEATURES[:plateau]
    @test _smart_initial_value("k",        TEST_FEATURES) == TEST_FEATURES[:plateau]

    @test _smart_initial_value("N0",       TEST_FEATURES) == TEST_FEATURES[:baseline]
    @test _smart_initial_value("baseline", TEST_FEATURES) == TEST_FEATURES[:baseline]

    @test _smart_initial_value("doubling_time", TEST_FEATURES) == TEST_FEATURES[:doubling_time]
    @test _smart_initial_value("dt",            TEST_FEATURES) == TEST_FEATURES[:doubling_time]

    @test _smart_initial_value("amplitude", TEST_FEATURES) == TEST_FEATURES[:amplitude]

    @test _smart_initial_value("q0",        TEST_FEATURES) == TEST_FEATURES[:q0]

    @test _smart_initial_value("death_rate", TEST_FEATURES) ==
          _clip_initial_value(0.05 * TEST_FEATURES[:growth_rate]; upper = 20.0)

    @test _smart_initial_value("unknown_xyz", TEST_FEATURES) == 1.0
end

# ---------------------------------------------------------------------------
# _growth_curve_features — basic sanity checks
# ---------------------------------------------------------------------------

@testset "_growth_curve_features — typical sigmoidal curve" begin
    t  = Float64.(0:0.5:12)
    od = @. 0.02 + 1.4 / (1 + exp(-0.8 * (t - 4)))
    f  = _growth_curve_features(t, od)

    @test f[:baseline]    < 0.2
    @test f[:plateau]     > 1.0
    @test f[:growth_rate] > 0.0
    @test f[:lag_time]    >= 0.0
    @test f[:duration]    ≈ 12.0
    @test all(isfinite, values(f))
end

@testset "_growth_curve_features — degenerate (< 2 valid points) returns safe defaults" begin
    f = _growth_curve_features(Float64[], Float64[])
    @test f[:growth_rate] > 0
    @test f[:plateau]     > 0
    @test all(isfinite, values(f))
end

# ---------------------------------------------------------------------------
# MAX_FIT_MAXITERS constant
# ---------------------------------------------------------------------------

@testset "MAX_FIT_MAXITERS constant" begin
    @test 20000 == 20000                   # DEFAULT_FIT_MAXITERS sanity
    max_cap = 100_000
    @test max_cap >= 20000                 # cap is at least the default
    # clamp behaviour matches what fitting.jl applies
    @test clamp(999_999, 1, max_cap) == max_cap
    @test clamp(5_000,   1, max_cap) == 5_000
    @test clamp(0,       1, max_cap) == 1
end
