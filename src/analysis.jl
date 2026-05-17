# Growth curve fitting using the KinBiont.jl API
# ---------------------------------------------------------------------------
# Shared growth curve fitting using the KinBiont.jl new API
# ---------------------------------------------------------------------------
using OptimizationBBO: BBO_adaptive_de_rand_1_bin_radiuslimited
using OptimizationNLopt: NLopt

const DEFAULT_FIT_MAXITERS = 20000
const MAX_FIT_MAXITERS     = 100_000

# Map of optimizer name strings to actual Optimization.jl algorithm instances.
# Only optimizers that support box constraints (lb/ub) are included.
# NLopt algorithms are enum values; calling them with () is a no-op identity (see OptimizationNLopt.jl:7).
const OPTIMIZER_MAP = Dict{String, Any}(
    "LN_BOBYQA"                                 => NLopt.LN_BOBYQA,
    "LN_COBYLA"                                 => NLopt.LN_COBYLA,
    "GN_ISRES"                                  => NLopt.GN_ISRES,
    "GN_DIRECT_L"                               => NLopt.GN_DIRECT_L,
    "BBO_adaptive_de_rand_1_bin_radiuslimited"  => BBO_adaptive_de_rand_1_bin_radiuslimited(),
)

function resolve_optimizer(name::String)
    get(OPTIMIZER_MAP, name, NLopt.LN_BOBYQA)
end

# Replace non-finite floats with nothing so JSON3 can serialise the result.
_finite(x::Float64) = isfinite(x) ? x : nothing
_finite(x::AbstractFloat) = isfinite(x) ? x : nothing
_finite(x::AbstractVector) = [_finite(v) for v in x]
_finite(x::AbstractDict) = Dict(k => _finite(v) for (k, v) in x)
_finite(x) = x

function sanitize_for_json(d::Dict)
    Dict(k => _finite(v) for (k, v) in d)
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

function _positive_or(x::Real, fallback::Real)
    isfinite(x) && x > 0 ? Float64(x) : Float64(fallback)
end

function _clip_initial_value(x::Real; lower::Real = 1e-6, upper::Real = 49.0)
    isfinite(x) ? clamp(Float64(x), Float64(lower), Float64(upper)) : 1.0
end

function _growth_curve_features(time_numeric::Vector{Float64}, od_for_fit::Vector{Float64})
    valid = findall(i -> isfinite(time_numeric[i]) && isfinite(od_for_fit[i]), eachindex(time_numeric))
    if length(valid) < 2
        return Dict{Symbol, Float64}(
            :baseline => 0.01,
            :plateau => 1.0,
            :amplitude => 1.0,
            :growth_rate => 1.0,
            :max_slope => 1.0,
            :lag_time => 0.0,
            :mid_time => 0.0,
            :inflection_time => 0.0,
            :doubling_time => log(2),
            :duration => 1.0,
            :terminal_slope => 0.0,
            :q0 => 1.0,
        )
    end

    ord = sortperm(time_numeric[valid])
    t = time_numeric[valid][ord]
    y = max.(od_for_fit[valid][ord], 1e-6)
    duration = _positive_or(t[end] - t[1], 1.0)

    n_edge = clamp(ceil(Int, length(y) * 0.1), 2, min(8, length(y)))
    baseline = max(_finite_quantile(y[1:n_edge], 0.5), minimum(y), 1e-4)
    late_level = _finite_quantile(y[end - n_edge + 1:end], 0.5)
    plateau = max(_finite_quantile(y, 0.95), late_level, baseline + 1e-4)
    amplitude = max(plateau - baseline, maximum(y) - minimum(y), 1e-4)

    slopes = Float64[]
    slope_times = Float64[]
    log_slopes = Float64[]
    for i in 1:(length(t) - 1)
        dt = t[i + 1] - t[i]
        dt > 0 || continue
        dy = y[i + 1] - y[i]
        push!(slopes, dy / dt)
        push!(slope_times, (t[i] + t[i + 1]) / 2)
        push!(log_slopes, (log(y[i + 1]) - log(y[i])) / dt)
    end

    positive_slopes = filter(x -> isfinite(x) && x > 0, slopes)
    max_slope = isempty(positive_slopes) ? amplitude / duration : maximum(positive_slopes)

    positive_log_slopes = filter(x -> isfinite(x) && x > 0, log_slopes)
    max_log_slope = isempty(positive_log_slopes) ? 0.0 : maximum(positive_log_slopes)
    logistic_rate = 4 * max_slope / max(plateau, 1e-4)
    growth_rate = _clip_initial_value(max(max_log_slope, logistic_rate, 1 / duration); upper = 20.0)

    imax = isempty(slopes) ? 1 : argmax(slopes)
    inflection_time = isempty(slope_times) ? t[1] : slope_times[imax]

    function first_crossing(threshold)
        idx = findfirst(v -> v >= threshold, y)
        idx === nothing ? t[1] : t[idx]
    end

    lag_time = clamp(first_crossing(baseline + 0.10 * amplitude), t[1], t[end])
    mid_time = clamp(first_crossing(baseline + 0.50 * amplitude), t[1], t[end])
    doubling_time = _clip_initial_value(log(2) / growth_rate; upper = duration)

    tail_start = max(1, length(slopes) - max(1, ceil(Int, 0.2 * length(slopes))) + 1)
    terminal_slope = isempty(slopes) ? 0.0 : _finite_quantile(slopes[tail_start:end], 0.5)
    q0 = _clip_initial_value(exp(-growth_rate * max(lag_time - t[1], 0.0)); upper = 50.0)

    return Dict{Symbol, Float64}(
        :baseline => _clip_initial_value(baseline),
        :plateau => _clip_initial_value(plateau),
        :amplitude => _clip_initial_value(amplitude),
        :growth_rate => growth_rate,
        :max_slope => _clip_initial_value(max_slope),
        :lag_time => _clip_initial_value(lag_time - t[1]; upper = duration),
        :mid_time => _clip_initial_value(mid_time - t[1]; upper = duration),
        :inflection_time => _clip_initial_value(inflection_time - t[1]; upper = duration),
        :doubling_time => doubling_time,
        :duration => duration,
        :terminal_slope => _clip_initial_value(abs(terminal_slope); upper = 20.0),
        :q0 => q0,
    )
end

function _smart_initial_value(param_name, features::Dict{Symbol, Float64})
    raw = lowercase(String(param_name))
    compact = replace(raw, r"[^a-z0-9]" => "")

    if compact in ("nlag", "xlag", "ylag", "odlag") ||
       ((startswith(compact, "n") || startswith(compact, "x") ||
         startswith(compact, "y") || startswith(compact, "od")) && occursin("lag", compact))
        return max(features[:baseline], 1e-6)
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
           occursin("growth", compact) || occursin("rate", compact) ||
           occursin("gr", compact)
        return features[:growth_rate]
    elseif compact in ("lag", "tl", "tlag", "lagtime") ||
           startswith(compact, "tlag") || occursin("lambda", compact) ||
           occursin("delay", compact)
        return features[:lag_time]
    elseif compact == "k" || occursin("nmax", compact) || occursin("ymax", compact) ||
           occursin("xmax", compact) || occursin("maxod", compact) ||
           occursin("carrying", compact) || occursin("capacity", compact) ||
           occursin("plateau", compact) || occursin("asymptote", compact)
        return features[:plateau]
    elseif occursin("amplitude", compact) || compact == "amp"
        return features[:amplitude]
    elseif compact in ("t0", "tmid", "tmax", "tinf", "tinflection") ||
           occursin("inflection", compact) || occursin("midtime", compact)
        return features[:mid_time]
    elseif compact in ("q0", "h0")
        return features[:q0]
    elseif occursin("shape", compact) || compact in ("nu", "theta", "beta", "gamma", "m", "v")
        return 1.0
    else
        return 1.0
    end
end

function smart_initial_params(param_names, time_numeric::Vector{Float64}, od_for_fit::Vector{Float64})
    features = _growth_curve_features(time_numeric, od_for_fit)
    return [_clip_initial_value(_smart_initial_value(name, features)) for name in param_names]
end
# Accepts already-validated, NaN-filtered time and raw OD vectors plus the
# computed blank value. Returns a Dict ready to serialise as JSON.
function fit_well_data(
    time_numeric::Vector{Float64},
    od_raw::Vector{Float64},
    blank_value::Float64,
    calibration_file::String,
    label::String,
    experiment::String;
    subtract_blank::Bool = false,
    blank_method::String = "pointbypoint",  # "shift" | "pointbypoint" | "clip"
    blank_timeseries::Vector{Float64} = Float64[],
    blank_well_names::Vector{String} = String[],
    model_name::String = "aHPM",
    model_names::Vector{String} = String[],
    optimizer::String = "BOBYQA",
    maxiters::Int = DEFAULT_FIT_MAXITERS,
    abstol::Float64 = 1e-6,
)
    if subtract_blank && blank_value > 0.0
        if blank_method == "pointbypoint" && length(blank_timeseries) == length(od_raw)
            od_corrected = od_raw .- blank_timeseries
        else
            od_corrected = od_raw .- blank_value
        end
        od_subtracted_display = max.(od_corrected, 0.0)
        anchor = od_subtracted_display[1]

        if blank_method == "clip"
            # Clip negatives to a small positive floor — simple, no shift needed.
            od_for_fit = max.(od_corrected, 1e-4)
            shift = 0.0
        else
            # Shift the entire series up so the minimum is just above zero.
            # Preserves the growth curve shape; fit is shifted back after.
            shift = max(-minimum(od_corrected), 0.0) + 1e-4
            od_for_fit = od_corrected .+ shift
        end
    else
        od_subtracted_display = nothing
        od_for_fit = max.(od_raw, 0.01)
        anchor = od_raw[1]
        shift = 0.0
    end

    data = GrowthData(reshape(od_for_fit, 1, :), time_numeric, [label])

    # Multi-model: compare a set of models and pick the best by AICc.
    if !isempty(model_names)
        models = [MODEL_REGISTRY[m] for m in model_names if haskey(MODEL_REGISTRY, m)]
        initial_params = [smart_initial_params(m.param_names, time_numeric, od_for_fit) for m in models]
        spec = ModelSpec(
            models,
            initial_params;
            lower = [fill(0.0, length(m.param_names)) for m in models],
            upper = [fill(50.0, length(m.param_names)) for m in models],
        )
    else
        model = MODEL_REGISTRY[model_name]
        n_params = length(model.param_names)
        p0 = smart_initial_params(model.param_names, time_numeric, od_for_fit)
        initial_params = [p0]
        spec = ModelSpec(
            [model],
            [p0];
            lower = [fill(0.0, n_params)],
            upper = [fill(50.0, n_params)],
        )
    end

    opt_params = abstol > 0.0 ? (maxiters = maxiters, abstol = abstol) : (maxiters = maxiters,)

    opts = FitOptions(
        scattering_correction           = false,
        smooth                          = true,
        smooth_method                   = :rolling_avg,
        smooth_pt_avg                   = 14,
        cut_stationary_phase            = true,
        stationary_percentile_thr       = 0.05,
        stationary_pt_smooth_derivative = 10,
        stationary_win_size             = 5,
        loss                            = "RE",
        optimizer                       = resolve_optimizer(optimizer),
        opt_params                      = opt_params,
    )

    fit_results = kinbiont_fit(data, spec, opts)
    r = fit_results[1]

    # If blank subtraction was applied, shift the fitted curve back to
    # blank-subtracted display space (undo the positive-shift applied for fitting).
    fit_od_curve = subtract_blank && blank_value > 0.0 ?
        r.fitted_curve .- shift :
        r.fitted_curve

    # The rolling-average smoother drops the first (pt_avg-1) time points, so
    # r.times[1] > time_numeric[1].  Prepend a flat segment anchored to the
    # first experimental OD so the fit line starts at the same time as the data.
    fit_start_idx = argmin(abs.(time_numeric .- r.times[1]))
    if fit_start_idx > 1
        pre_times    = time_numeric[1:fit_start_idx - 1]
        pre_fit_od   = fill(anchor, length(pre_times))
        fit_time_out = vcat(pre_times, r.times)
        fit_od_out   = vcat(pre_fit_od, fit_od_curve)
    else
        fit_time_out = r.times
        fit_od_out   = fit_od_curve
    end

    result = Dict{String, Any}(
        "experiment"             => experiment,
        "well"                   => label,
        "experimental_time"      => time_numeric,
        "experimental_od"        => od_raw,
        "fit_time"               => fit_time_out,
        "fit_od"                 => fit_od_out,
        "parameters"             => r.best_params,
        "param_names"            => r.best_model.param_names,
        "model"                  => r.best_model.name,
        "initial_parameters"     => initial_params,
        "blank_value"            => blank_value,
        "blank_subtraction"      => subtract_blank,
        "blank_method"           => blank_method,
        "blank_wells"            => blank_well_names,
        "stationary_phase_start" => r.times[end],
        "aic"                    => r.best_aic,
    )

    if od_subtracted_display !== nothing
        result["experimental_od_subtracted"] = od_subtracted_display
    end

    return sanitize_for_json(result)
end

