import { state } from './state.js';

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

function stripComments(code) {
    return code.split('\n')
        .filter(line => !line.trimStart().startsWith('#'))
        .join('\n')
        .replace(/\n{3,}/g, '\n\n')
        .trim();
}

// ---------------------------------------------------------------------------
// CodeMirror instance — created lazily on first modal open
// ---------------------------------------------------------------------------

let _editor = null;
let _currentGenerator = null;

function _waitForCodeMirror(cb) {
    if (typeof CodeMirror !== 'undefined') { cb(); }
    else { setTimeout(() => _waitForCodeMirror(cb), 50); }
}

function _initEditor() {
    if (_editor) return;
    const container = document.getElementById('code-export-editor');
    _editor = CodeMirror(container, {
        mode:           'julia',
        lineNumbers:    true,
        lineWrapping:   false,
        tabSize:        4,
        indentWithTabs: false,
        autofocus:      true,
    });
    _editor.setSize('100%', '500px');
}

// ---------------------------------------------------------------------------
// Modal open / close
// ---------------------------------------------------------------------------

export function openCodeExportModal(title, generator) {
    _currentGenerator = generator;
    document.getElementById('code-export-title').textContent = title;
    document.getElementById('code-export-comments').checked = false;
    document.getElementById('code-export-modal').style.display = 'flex';

    _waitForCodeMirror(() => {
        _initEditor();
        _editor.setValue(generator(false));
        _editor.refresh();
        setTimeout(() => _editor.refresh(), 50);
    });
}

export function closeCodeExportModal() {
    document.getElementById('code-export-modal').style.display = 'none';
}

export function toggleCodeComments() {
    if (!_currentGenerator || !_editor) return;
    const withComments = document.getElementById('code-export-comments').checked;
    _editor.setValue(_currentGenerator(withComments));
}

export function downloadExportedCode() {
    const code = _editor ? _editor.getValue() : '';
    const blob = new Blob([code], { type: 'text/plain' });
    const url  = URL.createObjectURL(blob);
    const a    = document.createElement('a');
    a.href     = url;
    a.download = 'kinbiont_analysis.jl';
    a.click();
    URL.revokeObjectURL(url);
}

// ---------------------------------------------------------------------------
// Per-tab openers (called from HTML onclick / app.js)
// ---------------------------------------------------------------------------

export function openFitCodeExport() {
    if (!state.lastFitData) return;
    openCodeExportModal(
        'Export Julia code — Fit Curve',
        (withComments) => generateFitCode(state.lastFitData, withComments),
    );
}

export function openBatchCodeExport() {
    if (!state.lastBatchFitData) return;
    const isLoglin = state.lastBatchFitData.model === 'log_lin';
    const title = isLoglin
        ? 'Export Julia code — Batch Fit (log-linear)'
        : 'Export Julia code — Batch Fit';
    const generator = isLoglin ? generateBatchLogLinCode : generateBatchCode;
    openCodeExportModal(
        title,
        (withComments) => generator(state.lastBatchFitData, withComments),
    );
}

export function openClusterCodeExport() {
    if (!state._lastClusterData) return;
    openCodeExportModal(
        'Export Julia code — Clustering',
        (withComments) => generateClusterCode(state._lastClusterData, withComments),
    );
}

// ---------------------------------------------------------------------------
// Code generators
// ---------------------------------------------------------------------------

export function generateFitCode(fitData, withComments) {
    const req        = fitData._request || {};
    const well       = req.well        || fitData.well  || 'B2';
    const model      = req.model_name  || fitData.model || 'aHPM';
    const blankSub   = req.blank_subtraction || false;
    const blankMethod= req.blank_method      || 'pointbypoint';
    const blankValue = typeof fitData.blank_value === 'number' ? fitData.blank_value : 0.0;
    // Same defaults the form uses (see fitting.js buildFitOptionsPayload).
    // Without these the optimizer falls back to Kinbiont's defaults which
    // terminate earlier than the GUI does and land on a worse minimum.
    const maxiters = req.maxiters ?? fitData.maxiters ?? 100000;
    const abstol   = req.abstol   ?? fitData.abstol   ?? 1e-15;
    const optParams = abstol > 0
        ? `(maxiters = ${maxiters}, abstol = ${abstol})`
        : `(maxiters = ${maxiters},)`;
    const blankLines = blankSub
        ? `    blank_subtraction               = true,
    # blank_value is the mean OD of blank wells in this experiment
    blank_value                     = ${blankValue.toFixed(6)},  # method: "${blankMethod}"`
        : `    blank_subtraction               = false,`;

    const p0        = fitData.initial_parameters?.[0];
    // Bare list — the surrounding spec block wraps it in [...] so the
    // ModelSpec params argument ends up as a 2-D structure (one row per
    // model). Double-wrapping here produced [[[ ... ]]] which Kinbiont
    // rejects with a Vector{Vector{Vector{Float64}}} mismatch.
    const initParam = p0 && p0.length > 0
        ? `${JSON.stringify(p0)}`
        : `fill(1.0, n_params)`;

    // Optimizer the GUI actually used (e.g. "LN_BOBYQA",
    // "BBO_adaptive_de_rand_1_bin_radiuslimited"). Surface it explicitly
    // in the exported script — Kinbiont's FitOptions default is the DE
    // optimizer, which lands on a different minimum than the GUI's
    // BOBYQA default for non-convex models like aHPM.
    const optimizerName = fitData.optimizer_used || 'LN_BOBYQA';
    const isBBO = optimizerName.startsWith('BBO_');
    const optimizerExpr = isBBO
        ? `${optimizerName}()`
        : `NLopt.${optimizerName}`;

    const code = `\
# ================================================================
# Growth curve fitting — exported from GUIbiont
# KinBiont.jl docs: https://github.com/pinheiroGroup/Kinbiont.jl
# Install:  using Pkg; Pkg.add("Kinbiont")
# ================================================================

using Kinbiont
${isBBO
    ? 'using OptimizationBBO: ' + optimizerName
    : 'using OptimizationNLopt: NLopt'
}

# CSV format: first column = time points, remaining columns = wells.
# Column headers become the well labels used throughout.
data = GrowthData("your_data.csv")

# Select well "${well}" for fitting.
# Pass multiple labels to fit several at once: data[["A1", "B2"]]
data_well = data[["${well}"]]

# GUIbiont clips OD to a minimum floor (0.01 OD units) before fitting so
# that the relative-error loss does not blow up on near-zero baseline
# readings. Mirror that here so the script reproduces the GUI fit.
data_well = GrowthData(max.(data_well.curves, 0.01), data_well.times, data_well.labels)

# Growth model: "${model}".
# List all available models: collect(keys(MODEL_REGISTRY))
# Common choices: "aHPM", "logistic", "gompertz", "baranyi_exp", "NL_Gompertz"
model = MODEL_REGISTRY["${model}"]
n_params = length(model.param_names)

# Initial parameters computed by GUIbiont's data-driven smart initialisation.
# These match the values used for this fit — change to explore the parameter space.
spec = ModelSpec(
    [model],
    [${initParam}];
    lower = [${fitData.param_lower?.[0]
        ? JSON.stringify(fitData.param_lower[0])
        : 'fill(0.0, n_params)'}],
    upper = [${fitData.param_upper?.[0]
        ? JSON.stringify(fitData.param_upper[0])
        : 'fill(50.0, n_params)'}],
)

# Fitting options — these match exactly what GUIbiont used.
# See FitOptions docs for all available fields.
opts = FitOptions(
    # Smooth the raw curve before fitting to reduce noise
    smooth                          = true,
    smooth_method                   = :rolling_avg,
    # Rolling-average window size (number of time points)
    smooth_pt_avg                   = 14,
    # Detect and truncate stationary phase before fitting
    cut_stationary_phase            = true,
    stationary_percentile_thr       = 0.05,
    stationary_pt_smooth_derivative = 10,
    stationary_win_size             = 5,
    # Loss function: "RE" = relative error (also: "L2", "L2_derivative")
    loss                            = "RE",
    # Optimizer chosen in the GUI for this fit.
    optimizer                       = ${optimizerExpr},
    # Termination tolerances actually used by the GUI; without these the
    # optimizer falls back to Kinbiont defaults and may terminate earlier.
    opt_params                      = ${optParams},
${blankLines}
)

# Run fitting — returns a GrowthFitResults iterable (one entry per curve)
results = kinbiont_fit(data_well, spec, opts)
r = results[1]

println("Model:       ", r.best_model.name)
println("Param names: ", r.best_model.param_names)
println("Parameters:  ", r.best_params)
println("AICc:        ", r.best_aic)
`;

    return withComments ? code : stripComments(code);
}

export function generateBatchCode(batchData, withComments) {
    const req        = batchData._request || {};
    const wells      = req.wells       || [];
    const modelName  = req.model_name  || batchData.model || 'aHPM';
    const modelNames = req.model_names || [];
    const blankSub   = req.blank_subtraction || false;
    const blankMethod= req.blank_method      || 'pointbypoint';
    const maxiters   = req.maxiters ?? batchData.maxiters ?? 100000;
    const abstol     = req.abstol ?? batchData.abstol ?? 1e-15;
    const optParams  = abstol > 0
        ? `(maxiters = ${maxiters}, abstol = ${abstol})`
        : `(maxiters = ${maxiters},)`;
    const isMulti    = modelNames.length > 1;

    const wellSubset = wells.length > 0
        ? `\n# Subset to the wells that were fitted in GUIbiont
data_subset = data[[${wells.map(w => `"${w}"`).join(', ')}]]\n`
        : '';
    const dataVar = wells.length > 0 ? 'data_subset' : 'data';

    const specBlock = isMulti
        ? `\
# Multi-model comparison: best model per well is selected by AICc.
# Models compared: ${modelNames.join(', ')}
models = [MODEL_REGISTRY[m] for m in [
${modelNames.map(m => `    "${m}"`).join(',\n')},
]]
# GUIbiont uses data-driven smart initialisation per well; batch export uses
# uniform starting points as a reproducible baseline across all wells.
spec = ModelSpec(
    models,
    [fill(1.0, length(m.param_names)) for m in models];
    lower = [fill(0.0, length(m.param_names)) for m in models],
    upper = [fill(50.0, length(m.param_names)) for m in models],
)`
        : `\
# Growth model: "${modelName}".
# List all available models: collect(keys(MODEL_REGISTRY))
model = MODEL_REGISTRY["${modelName}"]
n_params = length(model.param_names)
# GUIbiont uses data-driven smart initialisation per well; batch export uses
# uniform starting points as a reproducible baseline across all wells.
spec = ModelSpec(
    [model],
    [fill(1.0, n_params)];
    lower = [fill(0.0, n_params)],
    upper = [fill(50.0, n_params)],
)`;

    const blankLine = blankSub
        ? `    blank_subtraction               = true,  # method: "${blankMethod}"`
        : `    blank_subtraction               = false,`;

    const code = `\
# ================================================================
# Batch growth curve fitting — exported from GUIbiont
# KinBiont.jl docs: https://github.com/pinheiroGroup/Kinbiont.jl
# Install:  using Pkg; Pkg.add("Kinbiont")
# ================================================================

using Kinbiont

# CSV format: first column = time points, remaining columns = wells.
data = GrowthData("your_data.csv")
${wellSubset}
${specBlock}

# Fitting options — these match exactly what GUIbiont used.
opts = FitOptions(
    smooth                          = true,
    smooth_method                   = :rolling_avg,
    # Rolling-average window size (number of time points)
    smooth_pt_avg                   = 14,
    # Detect and truncate stationary phase before fitting
    cut_stationary_phase            = true,
    stationary_percentile_thr       = 0.05,
    stationary_pt_smooth_derivative = 10,
    stationary_win_size             = 5,
    # Loss function: "RE" = relative error (also: "L2", "L2_derivative")
    loss                            = "RE",
    opt_params                      = ${optParams},
${blankLine}
)

# Run batch fitting — returns one CurveFitResult per well
results = kinbiont_fit(${dataVar}, spec, opts)

# Print a summary table
for r in results
    println(r.label, " → ", r.best_model.name,
            "  AICc=", round(r.best_aic; digits=2),
            "  params=", r.best_params)
end
`;

    return withComments ? code : stripComments(code);
}

// Log-linear batch-fit code export. The parametric generateBatchCode above
// targets kinbiont_fit (ODE / NL models); log-lin runs through
// Kinbiont.fitting_one_well_Log_Lin directly with no parametric model.
export function generateBatchLogLinCode(batchData, withComments) {
    const req       = batchData._request || {};
    const wells     = req.wells || [];
    const ptAvg     = req.pt_avg ?? 7;
    const ptDeriv   = req.pt_smoothing_derivative ?? 7;
    const ptMinWin  = req.pt_min_size_of_win ?? 7;
    const thrExp    = req.threshold_of_exp ?? 0.9;
    const flatThr   = req.skip_flat_threshold ?? 0.05;

    const wellSubset = wells.length > 0
        ? `\n# Subset to the wells fitted in GUIbiont
const WELLS = String[${wells.map(w => `"${w}"`).join(', ')}]\n`
        : `\n# Use every column in the CSV as a curve.
const WELLS = String[]\n`;

    const code = `\
# ================================================================
# Batch log-linear μ_max fit — exported from GUIbiont
# KinBiont.jl docs: https://github.com/pinheiroGroup/Kinbiont.jl
# ================================================================

using Kinbiont
using CSV, DataFrames, Statistics

# CSV format: first column = time points, remaining columns = wells.
df = CSV.read("your_data.csv", DataFrame)
times = Float64.(coalesce.(df[!, 1], NaN))
${wellSubset}
const COLS = isempty(WELLS) ? String.(names(df))[2:end] : WELLS

# Mirror GUIbiont's batch-fit-loglin: smooth with rolling average, find
# the exponential window via R² ≥ ${thrExp}, report slope as μ_max plus
# the model-free lag and N_max companions Kinbiont appends.
results = NamedTuple[]
errors = String[]
for well in COLS
    od_raw = Float64.(coalesce.(df[!, Symbol(well)], NaN))
    mask = isfinite.(times) .& isfinite.(od_raw)
    if sum(mask) < ${ptDeriv + ptMinWin + 2}
        push!(errors, "Well '\$(well)': insufficient data points")
        continue
    end
    od_valid = od_raw[mask]
    # Skip flat curves the same way the GUI does (amplitude below
    # skip_flat_threshold) so converged counts match.
    if ${flatThr} > 0.0 && (maximum(od_valid) - minimum(od_valid)) < ${flatThr}
        continue
    end
    # The endpoint floors OD at 1e-4 so log() is well-defined; mirror that.
    od_fit = max.(od_valid, 1e-4)
    data_mat = Matrix(transpose(hcat(times[mask], od_fit)))
    raw = Kinbiont.fitting_one_well_Log_Lin(
        data_mat, String(well), "batch_loglin";
        type_of_smoothing       = "rolling_avg",
        pt_avg                  = ${ptAvg},
        pt_smoothing_derivative = ${ptDeriv},
        pt_min_size_of_win      = ${ptMinWin},
        type_of_win             = "maximum",
        threshold_of_exp        = ${thrExp},
    )
    p = raw[2]
    if length(p) >= 14 && p[7] !== missing
        push!(results, (
            well        = String(well),
            gr_loglin   = Float64(p[7]),
            gr_loglin_se = Float64(p[8]),
            t_start     = Float64(p[3]),
            t_end       = Float64(p[4]),
            R2          = Float64(p[14])^2,
            lag_loglin  = length(p) >= 16 && p[15] !== missing ? Float64(p[15]) : NaN,
            N_max_emp   = length(p) >= 16 && p[16] !== missing ? Float64(p[16]) : NaN,
            converged   = true,
        ))
    else
        push!(errors, "Well '\$(well)': no exponential window found")
    end
end

# Report the same summary statistics the SM reproducibility table compares.
gr   = [r.gr_loglin   for r in results]
lag  = [r.lag_loglin  for r in results]
nmax = [r.N_max_emp   for r in results]
t0   = [r.t_start     for r in results]
t1   = [r.t_end       for r in results]
r2   = [r.R2          for r in results]
println("converged_count: ", length(results))
println("median_gr_loglin:  ", median(filter(isfinite, gr)))
println("median_lag_loglin: ", median(filter(isfinite, lag)))
println("median_N_max_emp:  ", median(filter(isfinite, nmax)))
println("median_t_start: ", median(filter(isfinite, t0)))
println("median_t_end:   ", median(filter(isfinite, t1)))
println("median_R2:      ", median(filter(isfinite, r2)))
`;

    return withComments ? code : stripComments(code);
}

export function generateClusterCode(clusterData, withComments) {
    const req           = clusterData._request || {};
    const k             = req.k               || 3;
    const smoothMethod  = req.smooth_method   || 'lowess';
    const lowessFrac    = req.lowess_frac      || 0.05;
    const gaussianHmult = req.gaussian_h_mult  || 2.0;
    const clusterMethod = req.cluster_method   || 'kmeans';
    const blankSub      = req.subtract_blank   || false;
    const normalize     = req.normalize        || false;
    const isFileMode    = req._mode === 'file';

    const smoothParam = smoothMethod === 'lowess'
        ? `    # LOWESS bandwidth: fraction of points used for local regression
    lowess_frac   = ${lowessFrac},`
        : smoothMethod === 'gaussian'
        ? `    # Gaussian bandwidth multiplier (multiplied by median Δt)
    gaussian_h_mult = ${gaussianHmult},`
        : '';

    const blankLine = blankSub
        ? `    # Blank subtraction applied before clustering
    blank_subtraction = true,`
        : '';

    const methodNote = clusterMethod !== 'kmeans'
        ? `# Note: GUIbiont used "${clusterMethod}" clustering.
# KinBiont.jl preprocess() uses k-means — adapt as needed.
`       : '';

    const normalizeNote = normalize
        ? `# Note: GUIbiont normalised curves before clustering (z-score per curve).
# KinBiont.jl applies normalisation internally during clustering.
`       : '';

    const dataNote = isFileMode
        ? `# Replace with the path to your CSV file (uploaded in GUIbiont).`
        : `# CSV format: first column = time points, remaining columns = wells.`;

    const code = `\
# ================================================================
# Growth curve clustering — exported from GUIbiont
# KinBiont.jl docs: https://github.com/pinheiroGroup/Kinbiont.jl
# Install:  using Pkg; Pkg.add("Kinbiont")
# ================================================================

using Kinbiont

${methodNote}${normalizeNote}# ${dataNote}
data = GrowthData("your_data.csv")

# Preprocessing + clustering options.
# See FitOptions docs for all available clustering fields.
opts = FitOptions(
    # Smooth curves before clustering to reduce measurement noise
    smooth        = true,
    smooth_method = :${smoothMethod},
${smoothParam}
    # Cluster into ${k} groups
    cluster       = true,
    n_clusters    = ${k},
    # Reserve one cluster label for flat / non-growing curves.
    # Set to false to let k-means assign all clusters freely.
    cluster_trend_test = true,
${blankLine}
)

# preprocess() applies smoothing and clustering.
# Returns a GrowthData with .clusters, .centroids, and .wcss populated.
processed = preprocess(data, opts)

println("Cluster assignments: ", processed.clusters)
println("WCSS:                ", processed.wcss)

# To find the optimal k, sweep over a range and plot WCSS (elbow method):
# wcss_by_k = [preprocess(data, FitOptions(cluster=true, n_clusters=k)).wcss
#              for k in 2:10]
`;

    return withComments ? code : stripComments(code);
}
