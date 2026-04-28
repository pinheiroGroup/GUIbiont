# Growth curve fitting using the KinBiont.jl API
# ---------------------------------------------------------------------------
# Shared growth curve fitting using the KinBiont.jl new API
# ---------------------------------------------------------------------------

# Replace non-finite floats with nothing so JSON3 can serialise the result.
_finite(x::Float64) = isfinite(x) ? x : nothing
_finite(x::AbstractFloat) = isfinite(x) ? x : nothing
_finite(x::AbstractVector) = [_finite(v) for v in x]
_finite(x) = x

function sanitize_for_json(d::Dict)
    Dict(k => _finite(v) for (k, v) in d)
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
        spec = ModelSpec(
            models,
            [fill(1.0, length(m.param_names)) for m in models];
            lower = [fill(0.0, length(m.param_names)) for m in models],
            upper = [fill(50.0, length(m.param_names)) for m in models],
        )
    else
        model = MODEL_REGISTRY[model_name]
        n_params = length(model.param_names)
        p0 = fill(1.0, n_params)
        spec = ModelSpec(
            [model],
            [p0];
            lower = [fill(0.0, n_params)],
            upper = [fill(50.0, n_params)],
        )
    end

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

