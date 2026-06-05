# Growth curve fitting using the KinBiont.jl API
# ---------------------------------------------------------------------------
# Shared growth curve fitting using the KinBiont.jl new API
# ---------------------------------------------------------------------------
using OptimizationBBO: BBO_adaptive_de_rand_1_bin_radiuslimited
using OptimizationNLopt: NLopt

const DEFAULT_FIT_MAXITERS = 100000
const MAX_FIT_MAXITERS     = 200_000

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

# RMSE between a candidate fit and the experimental OD over [t_min, t_peak].
# All attempts get scored on the SAME window in the SAME (od_for_fit) space so
# RMSEs are directly comparable across optimizers regardless of conditioning.
function _fit_loss_rmse(
    time_exp::Vector{Float64},
    od_for_fit::Vector{Float64},
    fit_time::Vector{Float64},
    fit_od_in_for_fit_space::Vector{Float64},
    t_peak::Float64,
)
    isempty(fit_time) && return Inf
    t_min = max(first(fit_time), time_exp[1])
    t_max = min(t_peak, last(fit_time))
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
    t_peak::Float64,
    anchor::Float64,
    shift::Float64,
    subtract_blank::Bool,
    blank_value::Float64,
    label::String,
    model_name::String,
    model_names::Vector{String},
    maxiters::Int,
    abstol::Float64,
)
    # Per-optimizer data conditioning:
    #   - BOBYQA uses a quadratic local model and gets stuck in spurious minima
    #     created by raw noise → needs smoothed full curve (KinBiont smooths and
    #     cuts stationary phase internally).
    #   - COBYLA (linear local), BBO (stochastic global), and others perform best
    #     on the pre-cut growth-only curve with no smoothing — sharper loss
    #     surface, cleaner convergence.
    needs_smoothing = uppercase(optimizer) in ("BOBYQA", "LN_BOBYQA")

    if needs_smoothing
        time_fit = time_numeric
        od_fit   = od_for_fit
    else
        cut_idx  = argmax(od_for_fit)
        time_fit = time_numeric[1:cut_idx]
        od_fit   = od_for_fit[1:cut_idx]
    end

    data = GrowthData(reshape(od_fit, 1, :), time_fit, [label])

    if !isempty(model_names)
        models = [MODEL_REGISTRY[m] for m in model_names if haskey(MODEL_REGISTRY, m)]
        model_keys = [m for m in model_names if haskey(MODEL_REGISTRY, m)]
        initial_params = [smart_initial_params(model_keys[i], models[i].param_names, time_fit, od_fit) for i in eachindex(models)]
        bounds_pairs   = [smart_param_bounds(models[i].param_names, time_fit, od_fit) for i in eachindex(models)]
        spec = ModelSpec(
            models,
            initial_params;
            lower = [b[1] for b in bounds_pairs],
            upper = [b[2] for b in bounds_pairs],
        )
    else
        model = MODEL_REGISTRY[model_name]
        p0    = smart_initial_params(model_name, model.param_names, time_fit, od_fit)
        lo, up = smart_param_bounds(model.param_names, time_fit, od_fit)
        initial_params = [p0]
        spec = ModelSpec(
            [model],
            [p0];
            lower = [lo],
            upper = [up],
        )
    end

    opt_params = abstol > 0.0 ? (maxiters = maxiters, abstol = abstol) : (maxiters = maxiters,)

    opts = needs_smoothing ?
        FitOptions(
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
        ) :
        FitOptions(
            scattering_correction           = false,
            smooth                          = false,
            cut_stationary_phase            = false,
            loss                            = "RE",
            optimizer                       = resolve_optimizer(optimizer),
            opt_params                      = opt_params,
        )

    fit_results = kinbiont_fit(data, spec, opts)
    r = fit_results[1]

    # Shift the fitted curve back to blank-subtracted display space if needed.
    fit_od_curve = subtract_blank && blank_value > 0.0 ?
        r.fitted_curve .- shift :
        r.fitted_curve

    # The rolling-average smoother drops the first (pt_avg-1) time points, so
    # r.times[1] > time_numeric[1].  Prepend a flat segment anchored to the
    # first experimental OD so the fit line starts at the same time as the data.
    fit_start_idx = argmin(abs.(time_fit .- r.times[1]))
    if fit_start_idx > 1
        pre_times    = time_fit[1:fit_start_idx - 1]
        pre_fit_od   = fill(anchor, length(pre_times))
        fit_time_out = vcat(pre_times, r.times)
        fit_od_out   = vcat(pre_fit_od, fit_od_curve)
    else
        fit_time_out = collect(r.times)
        fit_od_out   = collect(fit_od_curve)
    end

    # Crop the fit display at the OD peak — the fit may extend past the peak
    # if KinBiont's internal stationary phase detector overshoots.
    crop_idx = findlast(t -> t <= t_peak, fit_time_out)
    if crop_idx !== nothing && crop_idx < length(fit_time_out)
        fit_time_out = fit_time_out[1:crop_idx]
        fit_od_out   = fit_od_out[1:crop_idx]
    end

    # Loss is computed in od_for_fit space (what the optimizer minimised), so
    # un-shift fit_od_out back when blank subtraction shifted it down.
    fit_for_loss = subtract_blank && blank_value > 0.0 ?
        Float64.(fit_od_out) .+ shift :
        Float64.(fit_od_out)
    loss = _fit_loss_rmse(time_numeric, od_for_fit, Float64.(fit_time_out), fit_for_loss, t_peak)

    return (
        best_params        = r.best_params,
        param_names        = r.best_model.param_names,
        model_name         = r.best_model.name,
        initial_parameters = initial_params,
        fit_time_out       = fit_time_out,
        fit_od_out         = fit_od_out,
        aic                = r.best_aic,
        loss               = loss,
    )
end

# Accepts already-validated, NaN-filtered time and raw OD vectors plus the
# computed blank value. Returns a Dict ready to serialise as JSON.
#
# Best-of-N mode: pass non-empty `deterministic_optimizers` and/or
# `stochastic_optimizers`. Each deterministic optimizer runs once; each
# stochastic optimizer runs `stochastic_runs` times with different seeds.
# The attempt with the lowest RMSE (against raw OD over [t_min, t_peak])
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
    # Optional log-linear sliding-window companion fit. When `compute_loglin`
    # is true, the result dict is enriched with `gr_loglin`, `gr_loglin_se`,
    # `gr_max_sliding`, `t_exp_start_loglin`, `t_exp_end_loglin`,
    # `doubling_time_loglin`, `R_squared_loglin`, and `loglin_converged`.
    # Fit runs on the same `od_for_fit` as the parametric model so the two
    # estimates are directly comparable.
    compute_loglin::Bool = false,
    loglin_pt_avg::Int = 7,
    loglin_pt_smoothing_derivative::Int = 7,
    loglin_pt_min_size_of_win::Int = 7,
    loglin_threshold_of_exp::Float64 = 0.9,
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
            od_for_fit = max.(od_corrected, 1e-4)
            shift = 0.0
        else
            shift = max(-minimum(od_corrected), 0.0) + 1e-4
            od_for_fit = od_corrected .+ shift
        end
    else
        od_subtracted_display = nothing
        od_for_fit = max.(od_raw, 0.01)
        anchor = od_raw[1]
        shift = 0.0
    end

    t_peak = time_numeric[argmax(od_for_fit)]

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
        try
            res = _run_fit_attempt(
                opt, time_numeric, od_for_fit, t_peak, anchor, shift,
                subtract_blank, blank_value, label,
                model_name, model_names, maxiters, abstol,
            )
            push!(outcomes, (optimizer = opt, run = run_idx, status = "ok",
                              loss = res.loss, aic = res.aic, result = res))
        catch e
            push!(outcomes, (optimizer = opt, run = run_idx, status = "error: $(string(e))",
                              loss = Inf, aic = NaN, result = nothing))
        end
    end

    successful = filter(o -> o.result !== nothing && isfinite(o.loss), outcomes)
    if isempty(successful)
        # Add a flat-curve diagnostic when nothing fit — most often this is a
        # blank/non-grower with no signal, and the cryptic "all attempts
        # failed" hides the actual cause.
        amplitude = maximum(od_for_fit) - minimum(od_for_fit)
        if amplitude < 0.05
            error("Curve appears flat (amplitude $(round(amplitude, digits=4)) < 0.05) — looks like a blank or non-grower, no growth signal to fit")
        end
        # Otherwise surface the first attempt's status so the user sees a real
        # optimizer error, not just "all attempts failed".
        first_status = isempty(outcomes) ? "no attempts run" : outcomes[1].status
        error("All optimizer attempts failed (first error: $first_status)")
    end

    best_pos = argmin([o.loss for o in successful])
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
        "blank_value"            => blank_value,
        "blank_subtraction"      => subtract_blank,
        "blank_method"           => blank_method,
        "blank_wells"            => blank_well_names,
        "stationary_phase_start" => t_peak,
        "aic"                    => win.aic,
        "loss"                   => win.loss,
        "optimizer_used"         => best.optimizer,
        "optimizer_run"          => best.run,
        "all_attempts"           => [
            Dict(
                "optimizer" => o.optimizer,
                "run"       => o.run,
                "status"    => o.status,
                "loss"      => o.loss,
                "aic"       => o.aic,
            ) for o in outcomes
        ],
    )

    if od_subtracted_display !== nothing
        result["experimental_od_subtracted"] = od_subtracted_display
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
    # od_for_fit data the parametric model saw, so the two estimates are
    # directly comparable. When the exponential-window detector can't locate
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
                    type_of_smoothing       = "rolling_avg",
                    pt_avg                  = loglin_pt_avg,
                    pt_smoothing_derivative = loglin_pt_smoothing_derivative,
                    pt_min_size_of_win      = loglin_pt_min_size_of_win,
                    type_of_win             = "maximum",
                    threshold_of_exp        = loglin_threshold_of_exp,
                )
                # raw[2] layout (see Kinbiont/src/Fit_one_well_functions.jl):
                #   [1] label_exp   [2] well        [3] t_start_exp  [4] t_end_exp
                #   [5] t_max_gr    [6] gr_max      [7] slope        [8] sigma_b
                #   [9] doubling_t  [10] dt − 2σ    [11] dt + 2σ     [12] intercept
                #   [13] sigma_a    [14] rho (Pearson R, NOT R² — squared below)
                #   [15] lag_loglin (Buchanan tangent-intercept lag)
                #   [16] N_max_emp  (95th-percentile carrying capacity)
                params = raw[2]
                if length(params) >= 14 && params[7] !== missing
                    loglin_fields["gr_loglin"]            = Float64(params[7])
                    loglin_fields["gr_loglin_se"]         = Float64(params[8])
                    loglin_fields["gr_max_sliding"]       = Float64(params[6])
                    loglin_fields["t_exp_start_loglin"]   = Float64(params[3])
                    loglin_fields["t_exp_end_loglin"]     = Float64(params[4])
                    loglin_fields["doubling_time_loglin"] = Float64(params[9])
                    loglin_fields["R_squared_loglin"]     = Float64(params[14])^2
                    if length(params) >= 16
                        loglin_fields["lag_loglin"]  = params[15] === missing ?
                            NaN : Float64(params[15])
                        loglin_fields["N_max_emp"]   = params[16] === missing ?
                            NaN : Float64(params[16])
                    end
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
)
    # Min points before Kinbiont so we surface a clean error.
    min_pts = pt_smoothing_derivative + pt_min_size_of_win + 2
    if length(od_raw) < max(10, min_pts)
        error("Insufficient data points for log-linear fit "
              * "($(length(od_raw)) < $(max(10, min_pts)))")
    end

    # Blank handling — log-lin needs strictly positive OD for log().
    # Mirrors the single-curve /api/fit-loglin endpoint exactly.
    od_subtracted_display = nothing
    if subtract_blank && blank_value > 0.0
        corrected = (blank_method == "pointbypoint" &&
                     length(blank_timeseries) == length(od_raw)) ?
            od_raw .- blank_timeseries : od_raw .- blank_value
        od_subtracted_display = max.(corrected, 0.0)
        if blank_method == "clip"
            od_for_fit = max.(corrected, 1e-4)
        else
            shift = max(-minimum(corrected), 0.0) + 1e-4
            od_for_fit = corrected .+ shift
        end
    else
        od_for_fit = max.(od_raw, 1e-4)
    end

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
        if length(params) >= 16
            result["lag_loglin"] = params[15] === missing ?
                NaN : Float64(params[15])
            result["N_max_emp"]  = params[16] === missing ?
                NaN : Float64(params[16])
        else
            result["lag_loglin"] = NaN
            result["N_max_emp"]  = NaN
        end
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

