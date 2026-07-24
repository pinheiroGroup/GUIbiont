# Growth curve fitting using the KinBiont.jl API
# ---------------------------------------------------------------------------
# Shared growth curve fitting using the KinBiont.jl new API
# ---------------------------------------------------------------------------
using OptimizationBBO: BBO_adaptive_de_rand_1_bin_radiuslimited
using OptimizationNLopt: NLopt

const DEFAULT_FIT_MAXITERS = 100000
const MAX_FIT_MAXITERS     = 200_000
const DEFAULT_OPTIMIZER_SEED = 42

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

# Stochastic optimizers — different seeds give different fits, so multi-run
# best-of-N is useful. Deterministic optimizers (everything else in OPTIMIZER_MAP)
# return the same result every run; one attempt suffices.
const STOCHASTIC_OPTIMIZERS = Set{String}([
    "GN_ISRES",
    "BBO_adaptive_de_rand_1_bin_radiuslimited",
])

function is_stochastic_optimizer(name::String)
    name in STOCHASTIC_OPTIMIZERS
end

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
    elseif compact in ("lag", "tl", "tlag", "lagtime") ||
           startswith(compact, "tlag") || occursin("lambda", compact) ||
           occursin("delay", compact) || occursin("lag", compact)
        return features[:lag_time]
    elseif occursin("mu", compact) || compact in ("r", "gr") ||
           occursin("growth", compact) || occursin("rate", compact) ||
           occursin("gr", compact)
        return features[:growth_rate]
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

# Per-model initial-value functions. Each takes the features dict and returns
# a vector matching the model's param_names. Encodes dimensional knowledge the
# name-pattern heuristic can't reliably infer — most notably that
# `exit_lag_rate` in HPM/aHPM is a RATE (~1/lag_time), not a TIME. The
# heuristic would return the lag time itself because of "lag" in the name,
# which is off by 1-2 orders of magnitude and pushes BOBYQA into a bad basin.
const MODEL_INIT = Dict{String, Function}(
    # HPM family — exit_lag_rate is a RATE (1/lag_time), not a time
    "aHPM"                      => f -> [f[:growth_rate], 1.0/max(f[:lag_time], 0.1), f[:plateau], 1.0],
    "HPM"                       => f -> [f[:growth_rate], 1.0/max(f[:lag_time], 0.1), f[:plateau]],
    "HPM_exp"                   => f -> [f[:growth_rate], 1.0/max(f[:lag_time], 0.1)],
    "HPM_3_death"               => f -> [f[:growth_rate], 1.0/max(f[:lag_time], 0.1), 0.05*f[:growth_rate], 0.05*f[:growth_rate]],
    "HPM_3_inhibition"          => f -> [f[:growth_rate], 1.0/max(f[:lag_time], 0.1), 0.05*f[:growth_rate]],
    "HPM_inhibition"            => f -> [f[:growth_rate], 0.05*f[:growth_rate], 0.5*f[:growth_rate], f[:plateau]],
    "aHPM_3_death_resistance"   => f -> [f[:growth_rate], 1.0/max(f[:lag_time], 0.1), 0.05*f[:growth_rate], 0.05*f[:growth_rate], 1.0, 1.0],
    "aHPM_inhibition"           => f -> [f[:growth_rate], 0.05*f[:growth_rate], 0.5*f[:growth_rate], f[:plateau], 1.0],

    # Basic single-population growth (ODE)
    "logistic"                  => f -> [f[:growth_rate], f[:plateau]],
    "gompertz"                  => f -> [f[:growth_rate], f[:plateau]],
    "exponential"               => f -> [f[:growth_rate]],
    "alogistic"                 => f -> [f[:growth_rate], f[:plateau], 1.0],
    "hyper_gompertz"            => f -> [f[:growth_rate], f[:plateau], 1.0],
    "hyper_logistic"            => f -> [f[:doubling_time], f[:growth_rate], f[:plateau], 1.0],
    "bertalanffy_richards"      => f -> [f[:growth_rate], f[:plateau], 1.0],

    # Baranyi family — lag_time is a TIME here (correct interpretation)
    "baranyi_exp"               => f -> [f[:growth_rate], f[:lag_time], 1.0],
    "baranyi_richards"          => f -> [f[:growth_rate], f[:plateau], f[:lag_time], 1.0],
    "baranyi_roberts"           => f -> [f[:growth_rate], f[:plateau], f[:lag_time], 1.0, 1.0],

    # NL (nonlinear, non-ODE) variants — param order varies per model
    "NL_exponential"            => f -> [f[:baseline], f[:growth_rate]],
    "NL_logistic"               => f -> [f[:plateau], f[:growth_rate], f[:lag_time]],
    "NL_Gompertz"               => f -> [f[:plateau], f[:growth_rate], f[:lag_time]],
    "NL_Richards"               => f -> [f[:plateau], 1.0, f[:growth_rate], f[:lag_time]],
    "NL_Weibull"                => f -> [f[:plateau], f[:baseline], f[:growth_rate], 1.0],
    "NL_Bertalanffy"            => f -> [f[:baseline], f[:plateau], f[:growth_rate], 1.0],
)

# Returns initial parameters for a fit. Uses model-specific knowledge from
# MODEL_INIT when available (dimensionally correct for the ~24 most-used
# models); falls back to the name-pattern heuristic for anything else.
function smart_initial_params(model_name::String, param_names, time_numeric::Vector{Float64}, od_for_fit::Vector{Float64})
    features = _growth_curve_features(time_numeric, od_for_fit)
    if haskey(MODEL_INIT, model_name)
        init = MODEL_INIT[model_name](features)
        if length(init) == length(param_names)
            return [_clip_initial_value(Float64(v)) for v in init]
        else
            @warn "MODEL_INIT[$model_name] returned $(length(init)) values but model expects $(length(param_names)); falling back to heuristic"
        end
    end
    return [_clip_initial_value(_smart_initial_value(name, features)) for name in param_names]
end

# Data-aware upper/lower bounds, dispatched by parameter name. Mirrors the
# branch order of `_smart_initial_value` so each param's bounds bracket its
# seed. Prevents BBO from drifting into degenerate regions (e.g. N_max=22 on
# a curve plateauing at 0.35) when the universal [0, 50] cap is too loose.
function _smart_param_bounds(param_name, features::Dict{Symbol, Float64})
    raw     = lowercase(String(param_name))
    compact = replace(raw, r"[^a-z0-9]" => "")

    plateau   = features[:plateau]
    amplitude = features[:amplitude]
    duration  = features[:duration]

    plateau_cap = max(plateau * 3, 1.0)
    time_cap    = max(duration * 2, 10.0)

    if compact in ("nlag", "xlag", "ylag", "odlag") ||
       ((startswith(compact, "n") || startswith(compact, "x") ||
         startswith(compact, "y") || startswith(compact, "od")) && occursin("lag", compact))
        return (1e-6, max(plateau, 1.0))
    elseif occursin("death", compact) || occursin("decay", compact) ||
       occursin("decline", compact) || occursin("mort", compact)
        return (0.0, 20.0)
    elseif occursin("inhib", compact) || occursin("inactiv", compact) ||
           occursin("resist", compact)
        return (0.0, 20.0)
    elseif occursin("doubl", compact) || compact in ("dt", "td")
        return (1e-6, time_cap)
    elseif occursin("slope", compact) || occursin("linear", compact)
        return (-10.0, 10.0)
    elseif compact in ("n0", "x0", "y0", "od0") ||
           occursin("initial", compact) || occursin("inoc", compact) ||
           occursin("baseline", compact)
        return (1e-6, max(plateau, 1.0))
    elseif compact in ("lag", "tl", "tlag", "lagtime") ||
           startswith(compact, "tlag") || occursin("lambda", compact) ||
           occursin("delay", compact) || occursin("lag", compact)
        # Matches both lag-times and rate-like params (e.g. exit_lag_rate).
        # Keep wide to accommodate both interpretations.
        return (0.0, max(time_cap, 50.0))
    elseif occursin("mu", compact) || compact in ("r", "gr") ||
           occursin("growth", compact) || occursin("rate", compact) ||
           occursin("gr", compact)
        return (1e-6, 20.0)
    elseif compact == "k" || occursin("nmax", compact) || occursin("ymax", compact) ||
           occursin("xmax", compact) || occursin("maxod", compact) ||
           occursin("carrying", compact) || occursin("capacity", compact) ||
           occursin("plateau", compact) || occursin("asymptote", compact)
        return (1e-6, plateau_cap)
    elseif occursin("amplitude", compact) || compact == "amp"
        return (1e-6, max(amplitude * 5, 1.0))
    elseif compact in ("t0", "tmid", "tmax", "tinf", "tinflection") ||
           occursin("inflection", compact) || occursin("midtime", compact)
        return (0.0, time_cap)
    elseif compact in ("q0", "h0")
        return (1e-6, 50.0)
    elseif occursin("shape", compact) || compact in ("nu", "theta", "beta", "gamma", "m", "v")
        return (1e-6, 10.0)
    else
        return (0.0, 50.0)
    end
end

function smart_param_bounds(param_names, time_numeric::Vector{Float64}, od_for_fit::Vector{Float64})
    features = _growth_curve_features(time_numeric, od_for_fit)
    pairs    = [_smart_param_bounds(name, features) for name in param_names]
    lower    = Float64[p[1] for p in pairs]
    upper    = Float64[p[2] for p in pairs]
    return lower, upper
end
# Linear interpolation of (xs, ys) at point x. Outside the grid, clamps to
# the nearest endpoint — fine for our use (fit curves are dense over their window).
function _linear_interp(x::Float64, xs::AbstractVector{<:Real}, ys::AbstractVector{<:Real})
    isempty(xs) && return NaN
    x <= first(xs) && return Float64(ys[1])
    x >= last(xs)  && return Float64(ys[end])
    for i in 1:length(xs)-1
        if xs[i] <= x <= xs[i+1]
            dx = xs[i+1] - xs[i]
            dx == 0 && return Float64(ys[i])
            return Float64(ys[i] + (x - xs[i]) / dx * (ys[i+1] - ys[i]))
        end
    end
    return Float64(ys[end])
end

# RMSE between a candidate fit and the experimental OD through the stationary
# cutoff. Every optimizer receives the same input and is scored on that window.
function _fit_loss_rmse(
    time_exp::Vector{Float64},
    od_for_fit::Vector{Float64},
    fit_time::Vector{Float64},
    fit_od_in_for_fit_space::Vector{Float64},
    score_end::Float64,
)
    isempty(fit_time) && return Inf
    t_min = max(first(fit_time), time_exp[1])
    t_max = min(score_end, last(fit_time))
    ss = 0.0
    n  = 0
    for (i, t) in enumerate(time_exp)
        (t < t_min || t > t_max) && continue
        y_pred = _linear_interp(t, fit_time, fit_od_in_for_fit_space)
        isfinite(y_pred) || continue
        ss += (od_for_fit[i] - y_pred)^2
        n  += 1
    end
    n == 0 ? Inf : sqrt(ss / n)
end

# Run ONE optimizer attempt: conditioning, spec, fit, curve post-processing.
# Returns a NamedTuple with the fit outputs + RMSE loss, or rethrows on failure.
function _run_fit_attempt(
    optimizer::String,
    time_numeric::Vector{Float64},
    od_for_fit::Vector{Float64},
    shift::Float64,
    subtract_blank::Bool,
    blank_value::Float64,
    label::String,
    model_name::String,
    model_names::Vector{String},
    maxiters::Int,
    abstol::Float64,
    smooth_method::Symbol,
    smooth_pt_avg::Int,
    lowess_frac::Float64,
    gaussian_h_mult::Float64,
    smooth_window::Int,
    optimizer_seed::Int,
)
    # All optimizers receive the same complete curve and preprocessing options.
    # Kinbiont smooths when requested, then applies the stationary-phase cutoff.
    time_fit = time_numeric
    od_fit   = od_for_fit

    data = GrowthData(reshape(od_fit, 1, :), time_fit, [label])

    if !isempty(model_names)
        models = [MODEL_REGISTRY[m] for m in model_names if haskey(MODEL_REGISTRY, m)]
        model_keys = [m for m in model_names if haskey(MODEL_REGISTRY, m)]
        initial_params = [smart_initial_params(model_keys[i], models[i].param_names, time_fit, od_fit) for i in eachindex(models)]
        bounds_pairs   = [smart_param_bounds(models[i].param_names, time_fit, od_fit) for i in eachindex(models)]
        param_lower    = [b[1] for b in bounds_pairs]
        param_upper    = [b[2] for b in bounds_pairs]
        spec = ModelSpec(
            models,
            initial_params;
            lower = param_lower,
            upper = param_upper,
        )
    else
        model = MODEL_REGISTRY[model_name]
        p0    = smart_initial_params(model_name, model.param_names, time_fit, od_fit)
        lo, up = smart_param_bounds(model.param_names, time_fit, od_fit)
        initial_params = [p0]
        param_lower    = [lo]
        param_upper    = [up]
        spec = ModelSpec(
            [model],
            [p0];
            lower = param_lower,
            upper = param_upper,
        )
    end

    opt_params = abstol > 0.0 ? (maxiters = maxiters, abstol = abstol) : (maxiters = maxiters,)

    opts = FitOptions(
        scattering_correction           = false,
        smooth                          = smooth_method != :none,
        smooth_method                   = smooth_method,
        smooth_pt_avg                   = smooth_pt_avg,
        lowess_frac                     = lowess_frac,
        gaussian_h_mult                 = gaussian_h_mult,
        boxcar_window                   = smooth_window,
        cut_stationary_phase            = true,
        stationary_percentile_thr       = 0.05,
        stationary_pt_smooth_derivative = 10,
        stationary_win_size             = 5,
        loss                            = "RE",
        optimizer                       = resolve_optimizer(optimizer),
        optimizer_seed                  = optimizer_seed,
        opt_params                      = opt_params,
    )

    fit_results = kinbiont_fit(data, spec, opts)
    r = fit_results[1]
    preprocessed_time = Float64.(fit_results.data.times)
    preprocessed_od = Float64.(vec(fit_results.data.curves[1, :]))

    # Keep the fitted curve in the exact numerical space used by the optimizer.
    fit_od_curve = r.fitted_curve

    fit_time_out = collect(r.times)
    fit_od_out = collect(fit_od_curve)

    # Kinbiont returns the actual time grid retained by stationary-phase cutting.
    stationary_phase_start = Float64(last(r.times))

    # Compare attempts on the exact preprocessed observations fitted by every
    # optimizer, including optional centered smoothing.
    loss_rmse = _fit_loss_rmse(
        preprocessed_time,
        preprocessed_od,
        Float64.(r.times),
        Float64.(r.fitted_curve),
        stationary_phase_start,
    )
    loss_re   = r.loss

    preprocessed_od_out = preprocessed_od

    return (
        best_params        = r.best_params,
        param_names        = r.best_model.param_names,
        model_name         = r.best_model.name,
        initial_parameters = initial_params,
        param_lower        = param_lower,
        param_upper        = param_upper,
        fit_time_out       = fit_time_out,
        fit_od_out         = fit_od_out,
        preprocessed_time  = preprocessed_time,
        preprocessed_od    = preprocessed_od_out,
        stationary_phase_start = stationary_phase_start,
        aic                = r.best_aic,
        loss               = loss_rmse,
        loss_rmse          = loss_rmse,
        loss_re            = loss_re,
    )
end

function _prepare_fit_curve(
    time_numeric::Vector{Float64},
    od_raw::Vector{Float64},
    label::String;
    blank_value::Float64=0.0,
    subtract_blank::Bool=false,
    blank_method::String="pointbypoint",
    blank_timeseries::Vector{Float64}=Float64[],
    unblanked_floor::Float64=0.01,
)
    blank_enabled = subtract_blank && blank_value > 0.0
    pointwise = blank_method == "pointbypoint" && length(blank_timeseries) == length(od_raw)
    effective_method = pointwise ? :pointbypoint : blank_method == "clip" ? :clip : :shift
    opts = FitOptions(
        blank_subtraction=blank_enabled,
        blank_method=effective_method,
        blank_value=blank_value,
        blank_timeseries=pointwise ? blank_timeseries : nothing,
        blank_floor=1e-4,
        correct_negatives=!blank_enabled,
        negative_method=:thr_correction,
        negative_threshold=unblanked_floor,
    )
    processed = preprocess(GrowthData(reshape(od_raw, 1, :), time_numeric, [label]), opts)
    od_for_fit = vec(processed.curves[1, :])

    if !blank_enabled
        return (
            od_for_fit=od_for_fit,
            od_subtracted_display=nothing,
            anchor=od_raw[1],
            shift=0.0,
            blank_applied=false,
        )
    end

    corrected = pointwise ? od_raw .- blank_timeseries : od_raw .- blank_value
    return (
        od_for_fit=od_for_fit,
        od_subtracted_display=copy(od_for_fit),
        anchor=od_for_fit[1],
        shift=effective_method == :clip ? 0.0 : od_for_fit[1] - corrected[1],
        blank_applied=true,
    )
end

# Derive the log-linear empirical carrying capacity from Kinbiont's
# stationary-phase detector. The legacy log-linear result at params[16] is a
# q95 of the smoothed curve; GUIbiont deliberately leaves it untouched and
# uses the fitted log-linear slope (params[7]) as the detector's mu_max.
function _loglin_stationary_nmax(raw, pt_deriv::Int)::Float64
    return Kinbiont.loglin_stationary_nmax(
        raw; pt_smoothing_derivative=pt_deriv,
    )
end

# Accepts already-validated, NaN-filtered time and raw OD vectors plus the
# computed blank value. Returns a Dict ready to serialise as JSON.
#
# Best-of-N mode: pass non-empty `deterministic_optimizers` and/or
# `stochastic_optimizers`. Each deterministic optimizer runs once; each
# stochastic optimizer runs `stochastic_runs` times with different seeds.
# The attempt with the lowest RMSE through Kinbiont's stationary cutoff
# wins, and its parameters are returned. The legacy `optimizer` argument is
# used only when both lists are empty.
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
    deterministic_optimizers::Vector{String} = String[],
    stochastic_optimizers::Vector{String}   = String[],
    stochastic_runs::Int                    = 3,
    maxiters::Int = DEFAULT_FIT_MAXITERS,
    abstol::Float64 = 1e-15,
    smooth::Bool = false,
    smooth_window::Int = 3,
    smooth_method::Symbol = :none,
    smooth_pt_avg::Int = 7,
    lowess_frac::Float64 = 0.05,
    gaussian_h_mult::Float64 = 2.0,
    # Optional log-linear sliding-window companion fit. When `compute_loglin`
    # is true, the result dict is enriched with `gr_loglin`, `gr_loglin_se`,
    # `gr_max_sliding`, `t_exp_start_loglin`, `t_exp_end_loglin`,
    # `doubling_time_loglin`, `R_squared_loglin`, and `loglin_converged`.
    # Fit runs on the same `od_for_fit` as the parametric model so the two
    # estimates are directly comparable.
    compute_loglin::Bool = false,
    loglin_type_of_smoothing::String = "rolling_avg",
    loglin_pt_avg::Int = 7,
    loglin_pt_smoothing_derivative::Int = 7,
    loglin_pt_min_size_of_win::Int = 7,
    loglin_type_of_win::String = "maximum",
    loglin_threshold_of_exp::Float64 = 0.9,
    loglin_start_exp_win_thr::Float64 = 0.05,
    loglin_thr_lowess::Float64 = 0.05,
    loglin_gaussian_h_mult::Float64 = 2.0,
)
    resolved_smooth_method = smooth_method == :none && smooth ? :boxcar : smooth_method
    resolved_smooth_method in (:none, :rolling_avg, :lowess, :gaussian, :boxcar) ||
        throw(ArgumentError("Unknown smoothing method: $resolved_smooth_method"))
    if resolved_smooth_method == :boxcar && (smooth_window < 3 || iseven(smooth_window))
        throw(ArgumentError("smooth_window must be an odd integer greater than or equal to 3"))
    end
    3 <= smooth_pt_avg <= 99 ||
        throw(ArgumentError("smooth_pt_avg must be between 3 and 99"))
    0.01 <= lowess_frac <= 1.0 ||
        throw(ArgumentError("lowess_frac must be between 0.01 and 1.0"))
    0.1 <= gaussian_h_mult <= 20.0 ||
        throw(ArgumentError("gaussian_h_mult must be between 0.1 and 20.0"))
    smooth_enabled = resolved_smooth_method != :none

    prepared = _prepare_fit_curve(
        time_numeric, od_raw, label;
        blank_value,
        subtract_blank,
        blank_method,
        blank_timeseries,
        unblanked_floor=0.01,
    )
    od_for_fit = prepared.od_for_fit
    od_subtracted_display = prepared.od_subtracted_display
    shift = prepared.shift

    # Build the attempt list. Best-of-N mode wins if either list is populated.
    # Each entry is (optimizer_name, run_index) — run_index lets the response
    # disambiguate the N stochastic runs.
    attempts = Tuple{String, Int}[]
    if !isempty(deterministic_optimizers) || !isempty(stochastic_optimizers)
        for opt in deterministic_optimizers
            push!(attempts, (opt, 1))
        end
        runs = max(1, stochastic_runs)
        for opt in stochastic_optimizers
            for k in 1:runs
                push!(attempts, (opt, k))
            end
        end
    else
        push!(attempts, (optimizer, 1))
    end
    isempty(attempts) && error("No optimizers selected")

    # Run each attempt, collect outcomes.
    outcomes = NamedTuple[]
    for (opt, run_idx) in attempts
        attempt_seed = is_stochastic_optimizer(opt) ?
            DEFAULT_OPTIMIZER_SEED + run_idx - 1 :
            DEFAULT_OPTIMIZER_SEED
        try
            res = _run_fit_attempt(
                opt, time_numeric, od_for_fit, shift,
                subtract_blank, blank_value, label,
                model_name, model_names, maxiters, abstol,
                resolved_smooth_method, smooth_pt_avg, lowess_frac,
                gaussian_h_mult, smooth_window, attempt_seed,
            )
            push!(outcomes, (optimizer = opt, run = run_idx, status = "ok",
                              seed = attempt_seed,
                              loss = res.loss_rmse, loss_rmse = res.loss_rmse,
                              loss_re = res.loss_re, aic = res.aic, result = res))
        catch e
            push!(outcomes, (optimizer = opt, run = run_idx, status = "error: $(string(e))",
                              seed = attempt_seed,
                              loss = Inf, loss_rmse = Inf, loss_re = NaN,
                              aic = NaN, result = nothing))
        end
    end

    successful = filter(o -> o.result !== nothing && isfinite(o.loss_rmse), outcomes)
    if isempty(successful)
        # Add a flat-curve diagnostic when nothing fit — most often this is a
        # blank/non-grower with no signal, and the cryptic "all attempts
        # failed" hides the actual cause.
        amplitude = maximum(od_for_fit) - minimum(od_for_fit)
        if amplitude < 0.02
            error("Curve appears flat (amplitude $(round(amplitude, digits=4)) < 0.02) — looks like a blank or non-grower, no growth signal to fit")
        end
        # Otherwise surface the first attempt's status so the user sees a real
        # optimizer error, not just "all attempts failed".
        first_status = isempty(outcomes) ? "no attempts run" : outcomes[1].status
        error("All optimizer attempts failed (first error: $first_status)")
    end

    best_pos = argmin([o.loss_rmse for o in successful])
    best     = successful[best_pos]
    win      = best.result

    result = Dict{String, Any}(
        "experiment"             => experiment,
        "well"                   => label,
        "experimental_time"      => time_numeric,
        "experimental_od"        => od_raw,
        "fit_time"               => win.fit_time_out,
        "fit_od"                 => win.fit_od_out,
        "parameters"             => win.best_params,
        "param_names"            => win.param_names,
        "model"                  => win.model_name,
        "initial_parameters"     => win.initial_parameters,
        # Data-driven bounds from smart_param_bounds — surfaced so the
        # exported Julia script can reproduce the GUI fit without falling
        # back to a uniform [0, 50] box that pulls the optimizer toward
        # a different local minimum on non-convex models.
        "param_lower"            => win.param_lower,
        "param_upper"            => win.param_upper,
        "blank_value"            => blank_value,
        "blank_subtraction"      => subtract_blank,
        "blank_applied"          => prepared.blank_applied,
        "blank_method"           => blank_method,
        "blank_timeseries"       => blank_timeseries,
        "blank_wells"            => blank_well_names,
        "stationary_phase_start" => win.stationary_phase_start,
        "maxiters"               => maxiters,
        "abstol"                 => abstol,
        "preprocessing"          => Dict(
            "smooth"                          => smooth_enabled,
            "smooth_method"                   => String(resolved_smooth_method),
            "smooth_window"                   => smooth_window,
            "smooth_pt_avg"                   => smooth_pt_avg,
            "lowess_frac"                     => lowess_frac,
            "gaussian_h_mult"                 => gaussian_h_mult,
            "cut_stationary_phase"            => true,
            "stationary_percentile_thr"       => 0.05,
            "stationary_pt_smooth_derivative" => 10,
            "stationary_win_size"             => 5,
        ),
        "aic"                    => win.aic,
        "loss"                   => win.loss,
        "loss_rmse"              => win.loss_rmse,
        "loss_re"                => win.loss_re,
        "optimizer_used"         => best.optimizer,
        "optimizer_run"          => best.run,
        "optimizer_seed"         => best.seed,
        "all_attempts"           => [
            Dict(
                "optimizer" => o.optimizer,
                "run"       => o.run,
                "seed"      => o.seed,
                "status"    => o.status,
                "loss"      => o.loss,
                "loss_rmse" => o.loss_rmse,
                "loss_re"   => o.loss_re,
                "aic"       => o.aic,
            ) for o in outcomes
        ],
    )

    if od_subtracted_display !== nothing
        result["experimental_od_subtracted"] = od_subtracted_display
    end
    if smooth_enabled
        result["smoothed_time"] = win.preprocessed_time
        result["smoothed_od"] = win.preprocessed_od
    end

    # ────────────────────────────────────────────────────────────────────
    # Local helper: fit a single well with log-linear sliding-window only.
    # Hoisted into a separate function so that `/api/batch-fit-loglin` can
    # call it directly without going through the parametric optimizer path.
    # The companion fit inside fit_well_data (compute_loglin=true above)
    # uses the same Kinbiont call but with the already-computed od_for_fit
    # — keep these in sync if you tune blank handling here.
    # ────────────────────────────────────────────────────────────────────

    # Optional log-linear sliding-window μ_max companion fit. Runs on the same
    # blank-corrected, unsmoothed od_for_fit. Parametric smoothing happens only
    # inside _run_fit_attempt, so the companion cannot smooth the same data twice.
    # The estimates remain directly comparable. When the detector can't locate
    # a window (very short curves, noisy data, persistent lag), we mark the
    # log-lin fields as NaN with `loglin_converged = false` rather than
    # failing the whole well — the parametric model fit remains valid.
    if compute_loglin
        loglin_fields = Dict{String, Any}(
            "gr_loglin"             => NaN,
            "gr_loglin_se"          => NaN,
            "gr_max_sliding"        => NaN,
            "t_exp_start_loglin"    => NaN,
            "t_exp_end_loglin"      => NaN,
            "doubling_time_loglin"  => NaN,
            "R_squared_loglin"      => NaN,
            "lag_loglin"            => NaN,
            "N_max_emp"             => NaN,
            "loglin_converged"      => false,
        )

        # log-lin needs ≥ pt_deriv + pt_min_win + 2 points; guard so we don't
        # raise from inside Kinbiont and pollute the error channel.
        min_pts = loglin_pt_smoothing_derivative + loglin_pt_min_size_of_win + 2
        if length(od_for_fit) >= max(10, min_pts)
            try
                data_mat = Matrix(transpose(hcat(time_numeric, od_for_fit)))
                raw = Kinbiont.fitting_one_well_Log_Lin(
                    data_mat,
                    label,
                    experiment;
                    type_of_smoothing       = loglin_type_of_smoothing,
                    pt_avg                  = loglin_pt_avg,
                    pt_smoothing_derivative = loglin_pt_smoothing_derivative,
                    pt_min_size_of_win      = loglin_pt_min_size_of_win,
                    type_of_win             = loglin_type_of_win,
                    threshold_of_exp        = loglin_threshold_of_exp,
                    start_exp_win_thr       = loglin_start_exp_win_thr,
                    thr_lowess              = loglin_thr_lowess,
                    gaussian_h_mult         = loglin_gaussian_h_mult,
                )
                # raw[2] layout (see Kinbiont/src/Fit_one_well_functions.jl):
                #   [1] label_exp   [2] well        [3] t_start_exp  [4] t_end_exp
                #   [5] t_max_gr    [6] gr_max      [7] slope        [8] sigma_b
                #   [9] doubling_t  [10] dt − 2σ    [11] dt + 2σ     [12] intercept
                #   [13] sigma_a    [14] rho (Pearson R, NOT R² — squared below)
                #   [15] lag_loglin (Buchanan tangent-intercept lag)
                #   [16] legacy q95 N_max_emp (not used by GUIbiont)
                params = raw[2]
                if length(params) >= 14 && params[7] !== missing
                    loglin_fields["gr_loglin"]            = Float64(params[7])
                    loglin_fields["gr_loglin_se"]         = Float64(params[8])
                    loglin_fields["gr_max_sliding"]       = Float64(params[6])
                    loglin_fields["t_exp_start_loglin"]   = Float64(params[3])
                    loglin_fields["t_exp_end_loglin"]     = Float64(params[4])
                    loglin_fields["doubling_time_loglin"] = Float64(params[9])
                    loglin_fields["R_squared_loglin"]     = Float64(params[14])^2
                    if length(params) >= 15
                        loglin_fields["lag_loglin"]  = params[15] === missing ?
                            NaN : Float64(params[15])
                    end
                    loglin_fields["N_max_emp"] = _loglin_stationary_nmax(
                        raw, loglin_pt_smoothing_derivative,
                    )
                    loglin_fields["loglin_converged"]     = true

                    # Plottable fit segment over the detected exponential
                    # window. raw[3] is an n×2 matrix [time, log(fitted_OD)].
                    fit_matrix = raw[3]
                    if !ismissing(fit_matrix) && size(fit_matrix, 1) > 0
                        ll_time  = Vector{Float64}(fit_matrix[:, 1])
                        ll_logod = Vector{Float64}(fit_matrix[:, 2])
                        loglin_fields["loglin_fit_time"] = ll_time
                        loglin_fields["loglin_fit_od"]   = exp.(ll_logod)
                    end
                end
            catch
                # Leave NaN sentinels; the parametric fit is the primary result.
            end
        end

        merge!(result, loglin_fields)
    end

    return sanitize_for_json(result)
end


"""
    fit_well_loglin(time, od, blank_value, label, experiment; kwargs...)
        -> Dict{String, Any}

Log-linear sliding-window growth-rate fit for a single well, no parametric
model. Powers `/api/batch-fit-loglin` and produces a result dict with the
same `gr_loglin*` field names that `fit_well_data(..., compute_loglin=true)`
emits — keeping the two log-lin code paths consistent.

Blank handling mirrors the single-curve `/api/fit-loglin` endpoint so that
batch and single-well log-lin results from the same input are identical.
"""
function fit_well_loglin(
    time_numeric::Vector{Float64},
    od_raw::Vector{Float64},
    blank_value::Float64,
    label::String,
    experiment::String;
    subtract_blank::Bool = false,
    blank_method::String = "pointbypoint",
    blank_timeseries::Vector{Float64} = Float64[],
    blank_well_names::Vector{String} = String[],
    type_of_smoothing::String = "rolling_avg",
    pt_avg::Int = 7,
    pt_smoothing_derivative::Int = 7,
    pt_min_size_of_win::Int = 7,
    type_of_win::String = "maximum",
    threshold_of_exp::Float64 = 0.9,
    start_exp_win_thr::Float64 = 0.05,
    thr_lowess::Float64 = 0.05,
    gaussian_h_mult::Float64 = 2.0,
)
    # Min points before Kinbiont so we surface a clean error.
    min_pts = pt_smoothing_derivative + pt_min_size_of_win + 2
    if length(od_raw) < max(10, min_pts)
        error("Insufficient data points for log-linear fit "
              * "($(length(od_raw)) < $(max(10, min_pts)))")
    end

    prepared = _prepare_fit_curve(
        time_numeric, od_raw, label;
        blank_value,
        subtract_blank,
        blank_method,
        blank_timeseries,
        unblanked_floor=1e-4,
    )
    od_for_fit = prepared.od_for_fit
    od_subtracted_display = prepared.od_subtracted_display

    data_mat = Matrix(transpose(hcat(time_numeric, od_for_fit)))
    raw = Kinbiont.fitting_one_well_Log_Lin(
        data_mat, label, experiment;
        type_of_smoothing       = type_of_smoothing,
        pt_avg                  = pt_avg,
        pt_smoothing_derivative = pt_smoothing_derivative,
        pt_min_size_of_win      = pt_min_size_of_win,
        type_of_win             = type_of_win,
        threshold_of_exp        = threshold_of_exp,
        start_exp_win_thr       = start_exp_win_thr,
        thr_lowess              = thr_lowess,
        gaussian_h_mult         = gaussian_h_mult,
    )
    params = raw[2]

    result = Dict{String, Any}(
        "experiment"        => experiment,
        "well"              => label,
        "method"            => "Log-lin",
        "experimental_time" => time_numeric,
        "experimental_od"   => od_raw,
        "blank_value"       => blank_value,
        "blank_subtraction" => subtract_blank,
        "blank_method"      => blank_method,
        "blank_wells"       => blank_well_names,
    )

    if length(params) >= 14 && params[7] !== missing
        result["gr_loglin"]             = Float64(params[7])
        result["gr_loglin_se"]          = Float64(params[8])
        result["gr_max_sliding"]        = Float64(params[6])
        result["t_exp_start_loglin"]    = Float64(params[3])
        result["t_exp_end_loglin"]      = Float64(params[4])
        result["doubling_time_loglin"]  = Float64(params[9])
        result["R_squared_loglin"]      = Float64(params[14])^2
        if length(params) >= 15
            result["lag_loglin"] = params[15] === missing ?
                NaN : Float64(params[15])
        else
            result["lag_loglin"] = NaN
        end
        result["N_max_emp"] = _loglin_stationary_nmax(
            raw, pt_smoothing_derivative,
        )
        result["loglin_converged"]      = true
    else
        result["gr_loglin"]             = NaN
        result["gr_loglin_se"]          = NaN
        result["gr_max_sliding"]        = NaN
        result["t_exp_start_loglin"]    = NaN
        result["t_exp_end_loglin"]      = NaN
        result["doubling_time_loglin"]  = NaN
        result["R_squared_loglin"]      = NaN
        result["lag_loglin"]            = NaN
        result["N_max_emp"]             = NaN
        result["loglin_converged"]      = false
    end

    if od_subtracted_display !== nothing
        result["experimental_od_subtracted"] = od_subtracted_display
    end

    return sanitize_for_json(result)
end

