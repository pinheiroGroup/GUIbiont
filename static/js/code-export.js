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

function juliaFloatLiteral(value) {
    const n = Number(value);
    if (!Number.isFinite(n)) return '0.0';
    return Number.isInteger(n) ? `${n}.0` : String(n);
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
    const generator = isLoglin ? generateBatchLogLinKinbiontCode : generateBatchCode;
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
        ? `OptimizationBBO.${optimizerName}()`
        : `OptimizationNLopt.NLopt.${optimizerName}`;

    const code = `\
# ================================================================
# Growth curve fitting — exported from GUIbiont
# KinBiont.jl docs: https://github.com/pinheiroGroup/Kinbiont.jl
# Install:  using Pkg; Pkg.add("Kinbiont")
# ================================================================

using Kinbiont
import OptimizationNLopt
import OptimizationBBO

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

function generateBatchCodeLegacy(batchData, withComments) {
    const req        = batchData._request || {};
    const wells      = req.wells       || [];
    const modelName  = req.model_name  || batchData.model || 'aHPM';
    const requestedModels = req.model_names && req.model_names.length > 0 ? req.model_names : [modelName];
    const modelNames = requestedModels;
    const blankSub   = req.blank_subtraction || false;
    const blankMethod= req.blank_method      || 'pointbypoint';
    const maxiters   = req.maxiters ?? batchData.maxiters ?? 100000;
    const abstol     = req.abstol ?? batchData.abstol ?? 1e-15;
    const optParams  = abstol > 0
        ? `(maxiters = ${maxiters}, abstol = ${abstol})`
        : `(maxiters = ${maxiters},)`;
    const detOpts    = req.deterministic_optimizers || [];
    const stoOpts    = req.stochastic_optimizers || [];
    const experiment = batchData.experiment || req.experiment || 'experiment';
    const outPrefix  = `${experiment}_batch_fit`;
    const firstOptimizer = detOpts[0] || stoOpts[0] || req.optimizer || 'LN_BOBYQA';
    const optimizerExprMap = {
        'LN_BOBYQA': 'OptimizationNLopt.NLopt.LN_BOBYQA',
        'LN_COBYLA': 'OptimizationNLopt.NLopt.LN_COBYLA',
        'GN_ISRES': 'OptimizationNLopt.NLopt.GN_ISRES',
        'GN_DIRECT_L': 'OptimizationNLopt.NLopt.GN_DIRECT_L',
        'BBO_adaptive_de_rand_1_bin_radiuslimited': 'OptimizationBBO.BBO_adaptive_de_rand_1_bin_radiuslimited()',
    };
    const optimizerExpr = optimizerExprMap[firstOptimizer] || 'OptimizationNLopt.NLopt.LN_BOBYQA';
    const isMulti    = modelNames.length > 1;
    const modelExprs = modelNames.map(m =>
        m === 'log_lin' ? '    LogLinModel()' : `    MODEL_REGISTRY["${m}"]`
    ).join(',\n');

    const wellSubset = wells.length > 0
        ? `\n# Subset to the wells that were fitted in GUIbiont
data_subset = data[[${wells.map(w => `"${w}"`).join(', ')}]]\n`
        : '';
    const dataVar = wells.length > 0 ? 'data_subset' : 'data';

    const specBlock = isMulti
        ? `\
# Multi-model comparison: best model per well is selected by AICc.
# Models compared: ${modelNames.join(', ')}
models = [
${modelExprs}
]
# GUIbiont uses data-driven smart initialisation per well; batch export uses
# uniform starting points as a reproducible baseline across all wells.
spec = ModelSpec(
    models,
    [m isa LogLinModel ? Float64[] : fill(1.0, length(m.param_names)) for m in models];
    lower = Union{Nothing, Vector{Float64}}[m isa LogLinModel ? nothing : fill(0.0, length(m.param_names)) for m in models],
    upper = Union{Nothing, Vector{Float64}}[m isa LogLinModel ? nothing : fill(50.0, length(m.param_names)) for m in models],
)`
        : `\
# Growth model: "${modelName}".
# List all available models: collect(keys(MODEL_REGISTRY))
model = ${modelName === 'log_lin' ? 'LogLinModel()' : `MODEL_REGISTRY["${modelName}"]`}
n_params = model isa LogLinModel ? 0 : length(model.param_names)
# GUIbiont uses data-driven smart initialisation per well; batch export uses
# uniform starting points as a reproducible baseline across all wells.
spec = ModelSpec(
    [model],
    [model isa LogLinModel ? Float64[] : fill(1.0, n_params)];
    lower = Union{Nothing, Vector{Float64}}[model isa LogLinModel ? nothing : fill(0.0, n_params)],
    upper = Union{Nothing, Vector{Float64}}[model isa LogLinModel ? nothing : fill(50.0, n_params)],
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
import OptimizationNLopt
import OptimizationBBO

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
    optimizer                       = ${optimizerExpr},
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

# Save Kinbiont-native CSVs. Rename the summary to the same basename used by
# GUIbiont's download button: ${outPrefix}.csv
paths = save_results(results, "."; prefix = "${outPrefix}")
mv(paths.summary, "${outPrefix}.csv"; force = true)
`;

    return withComments ? code : stripComments(code);
}

export function generateBatchCode(batchData, withComments) {
    const req = batchData._request || {};
    const experiment = batchData.experiment || req.experiment || 'experiment';
    const wells = req.wells || [];
    const rawModels = req.model_names && req.model_names.length > 0
        ? req.model_names
        : [req.model_name || batchData.model || 'aHPM'];
    const modelNames = rawModels.filter(m => m !== 'log_lin');
    const modelName = modelNames[0] || req.model_name || 'aHPM';
    const detOpts = req.deterministic_optimizers || [];
    const stoOpts = req.stochastic_optimizers || [];
    const stochasticRuns = req.stochastic_runs ?? 1;
    const singleOptimizer = req.optimizer || batchData.optimizer_used || 'LN_BOBYQA';
    const maxiters = req.maxiters ?? batchData.maxiters ?? 100000;
    const abstol = req.abstol ?? batchData.abstol ?? 1e-15;
    const skipFlat = req.skip_flat_threshold ?? 0.05;
    const computeLoglin = !!req.compute_loglin || rawModels.includes('log_lin');
    const llPtAvg = req.loglin_pt_avg ?? 7;
    const llPtDeriv = req.loglin_pt_smoothing_derivative ?? 7;
    const llPtMinWin = req.loglin_pt_min_size_of_win ?? 7;
    const llThrExp = req.loglin_threshold_of_exp ?? 0.9;
    const blankSub = !!req.blank_subtraction;
    const blankMethod = req.blank_method || 'pointbypoint';
    const firstResult = Array.isArray(batchData.results) ? batchData.results.find(r => typeof r.blank_value === 'number') : null;
    const blankValue = firstResult ? firstResult.blank_value : 0.0;
    const outPrefix = `${experiment}_batch_fit`;
    const strArray = xs => `String[${xs.map(x => `"${x}"`).join(', ')}]`;
    const jb = x => x ? 'true' : 'false';

    const code = `\
# ================================================================
# Batch growth curve fitting - exported from GUIbiont
# Requires a Kinbiont version exposing kinbiont_batch_fit and
# save_gui_batch_results.
# ================================================================

using Kinbiont

const EXPERIMENT = "${experiment}"
const DATA_FILE = "your_data.csv"
const OUT_PREFIX = "${outPrefix}"
const WELLS = ${strArray(wells)}
const MODEL_NAME = "${modelName}"
const MODEL_NAMES = ${strArray(modelNames.length > 1 ? modelNames : [])}
const SINGLE_OPTIMIZER = "${singleOptimizer}"
const DETERMINISTIC_OPTIMIZERS = ${strArray(detOpts)}
const STOCHASTIC_OPTIMIZERS = ${strArray(stoOpts)}
const STOCHASTIC_RUNS = ${stochasticRuns}
const MAXITERS = ${maxiters}
const ABSTOL = ${abstol}
const SKIP_FLAT_THRESHOLD = ${skipFlat}
const COMPUTE_LOGLIN = ${jb(computeLoglin)}
const LOGLIN_PT_AVG = ${llPtAvg}
const LOGLIN_PT_DERIV = ${llPtDeriv}
const LOGLIN_PT_MIN_WIN = ${llPtMinWin}
const LOGLIN_THR_EXP = ${llThrExp}
const BLANK_SUBTRACTION = ${jb(blankSub)}
const BLANK_METHOD = "${blankMethod}"
# Generic exported CSVs do not carry annotation metadata. If reproducing a GUI
# run with blank wells, set these to the values used by GUIbiont.
const BLANK_VALUE = ${juliaFloatLiteral(blankValue)}
const BLANK_TIMESERIES = Float64[]

data = GrowthData(DATA_FILE)
batch = kinbiont_batch_fit(
    data;
    experiment=EXPERIMENT,
    labels=WELLS,
    model_name=MODEL_NAME,
    model_names=MODEL_NAMES,
    optimizer=SINGLE_OPTIMIZER,
    deterministic_optimizers=DETERMINISTIC_OPTIMIZERS,
    stochastic_optimizers=STOCHASTIC_OPTIMIZERS,
    stochastic_runs=STOCHASTIC_RUNS,
    maxiters=MAXITERS,
    abstol=ABSTOL,
    skip_flat_threshold=SKIP_FLAT_THRESHOLD,
    compute_loglin=COMPUTE_LOGLIN,
    loglin_pt_avg=LOGLIN_PT_AVG,
    loglin_pt_smoothing_derivative=LOGLIN_PT_DERIV,
    loglin_pt_min_size_of_win=LOGLIN_PT_MIN_WIN,
    loglin_threshold_of_exp=LOGLIN_THR_EXP,
    blank_subtraction=BLANK_SUBTRACTION,
    blank_method=BLANK_METHOD,
    blank_value=BLANK_VALUE,
    blank_timeseries=BLANK_TIMESERIES,
)

paths = save_gui_batch_results(batch, "."; prefix=OUT_PREFIX)
println("Saved ", paths.summary)
println("Saved ", paths.fitted_curves)
println("Fitted: ", length(batch.results), "  skipped: ", length(batch.skipped), "  failed: ", length(batch.errors))
`;

    return withComments ? code : stripComments(code);
}

function generateBatchLogLinKinbiontCode(batchData, withComments) {
    const req = batchData._request || {};
    const experiment = batchData.experiment || req.experiment || 'experiment';
    const wells = req.wells || [];
    const ptAvg = req.pt_avg ?? 7;
    const ptDeriv = req.pt_smoothing_derivative ?? 7;
    const ptMinWin = req.pt_min_size_of_win ?? 7;
    const thrExp = req.threshold_of_exp ?? 0.9;
    const flatThr = req.skip_flat_threshold ?? 0.05;
    const blankSub = !!req.blank_subtraction;
    const blankMethod = req.blank_method || 'pointbypoint';
    const smoothing = req.type_of_smoothing || 'rolling_avg';
    const winType = req.type_of_win || 'maximum';
    const startThr = req.start_exp_win_thr ?? 0.05;
    const thrLowess = req.thr_lowess ?? 0.05;
    const firstResult = Array.isArray(batchData.results) ? batchData.results.find(r => typeof r.blank_value === 'number') : null;
    const blankValue = firstResult ? firstResult.blank_value : 0.0;
    const outPrefix = `${experiment}_batch_fit_loglin`;
    const strArray = xs => `String[${xs.map(x => `"${x}"`).join(', ')}]`;
    const jb = x => x ? 'true' : 'false';

    const code = `\
# ================================================================
# Batch log-linear growth-rate fit - exported from GUIbiont
# Requires a Kinbiont version exposing kinbiont_batch_loglin and
# save_gui_batch_loglin_results.
# ================================================================

using Kinbiont

const EXPERIMENT = "${experiment}"
const DATA_FILE = "your_data.csv"
const OUT_PREFIX = "${outPrefix}"
const WELLS = ${strArray(wells)}
const BLANK_SUBTRACTION = ${jb(blankSub)}
const BLANK_METHOD = "${blankMethod}"
const BLANK_VALUE = ${juliaFloatLiteral(blankValue)}
const BLANK_TIMESERIES = Float64[]
const TYPE_OF_SMOOTHING = "${smoothing}"
const PT_AVG = ${ptAvg}
const PT_SMOOTHING_DERIVATIVE = ${ptDeriv}
const PT_MIN_SIZE_OF_WIN = ${ptMinWin}
const TYPE_OF_WIN = "${winType}"
const THRESHOLD_OF_EXP = ${thrExp}
const START_EXP_WIN_THR = ${startThr}
const THR_LOWESS = ${thrLowess}
const SKIP_FLAT_THRESHOLD = ${flatThr}

data = GrowthData(DATA_FILE)
batch = kinbiont_batch_loglin(
    data;
    experiment=EXPERIMENT,
    labels=WELLS,
    blank_subtraction=BLANK_SUBTRACTION,
    blank_method=BLANK_METHOD,
    blank_value=BLANK_VALUE,
    blank_timeseries=BLANK_TIMESERIES,
    type_of_smoothing=TYPE_OF_SMOOTHING,
    pt_avg=PT_AVG,
    pt_smoothing_derivative=PT_SMOOTHING_DERIVATIVE,
    pt_min_size_of_win=PT_MIN_SIZE_OF_WIN,
    type_of_win=TYPE_OF_WIN,
    threshold_of_exp=THRESHOLD_OF_EXP,
    start_exp_win_thr=START_EXP_WIN_THR,
    thr_lowess=THR_LOWESS,
    skip_flat_threshold=SKIP_FLAT_THRESHOLD,
)

paths = save_gui_batch_loglin_results(batch, "."; prefix=OUT_PREFIX)
println("Saved ", paths.summary)
println("Fitted: ", length(batch.results), "  skipped: ", length(batch.skipped), "  failed: ", length(batch.errors))
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
    const k             = req.k ?? 3;
    const smoothMethod  = req.smooth_method ?? 'lowess';
    const lowessFrac    = req.lowess_frac ?? 0.05;
    const gaussianHmult = req.gaussian_h_mult ?? 2.0;
    const clusterMethod = req.cluster_method ?? 'kmeans';
    const maxiter       = req.maxiter ?? 300;
    const tol           = req.tol ?? 1e-6;
    const blankSub      = req.subtract_blank ?? false;
    const blankMethod   = req.blank_method ?? 'pointbypoint';
    const blankRangeThr = req.blank_range_thr ?? 0.005;
    const blankOdPct    = req.blank_od_percentile ?? 0.10;
    const interpolate   = req.interpolate ?? false;
    const interpN       = req.interp_n ?? 100;
    const interpQLo     = req.interp_quantile_lo ?? 0.05;
    const interpQHi     = req.interp_quantile_hi ?? 0.95;
    const prescreen     = req.prescreen_constant ?? false;
    const prescreenTol  = req.prescreen_tol_const ?? 1.5;
    const prescreenQLo  = req.prescreen_q_low ?? 0.05;
    const prescreenQHi  = req.prescreen_q_high ?? 0.95;
    const trendTest     = req.trend_test_flat ?? false;
    const trendPThr     = req.trend_p_thr ?? 0.05;
    const normalize     = req.normalize ?? false;
    // Algorithm-specific parameters (used by hclust / dbscan only)
    const hclustLinkage = req.hclust_linkage ?? 'ward';
    const dbscanEps     = req.dbscan_eps     ?? 1.0;
    const dbscanMinPts  = req.dbscan_min_pts ?? 3;
    const isFileMode    = req._mode === 'file';
    const smoothEnabled = smoothMethod !== 'none';
    const prescreenApplied = clusterData.prescreen_applied ?? prescreen;
    const dynamicK      = prescreenApplied ? Math.max(1, k - 1) : k;
    // JS bool → Julia `true`/`false` literal for interpolation into source code.
    const jb = (value) => value ? 'true' : 'false';

    const smoothParam = !smoothEnabled ? '' : smoothMethod === 'lowess'
        ? `    # LOWESS bandwidth: fraction of points used for local regression
    lowess_frac   = ${lowessFrac},`
        : smoothMethod === 'gaussian'
        ? `    # Gaussian bandwidth multiplier (multiplied by median Δt)
    gaussian_h_mult = ${gaussianHmult},`
        : '';

    // kmeans_max_iters and kmeans_tol are shared between :kmeans and :kmedoids
    // in Kinbiont (preprocessing.jl reads opts.kmeans_max_iters / opts.kmeans_tol
    // for both algorithms). hclust and dbscan ignore these fields.
    const iterParam = (clusterMethod === 'kmeans' || clusterMethod === 'kmedoids')
        ? `
    kmeans_max_iters       = ${maxiter},
    kmeans_tol             = ${tol},`
        : '';

    // Algorithm-specific parameters for hclust / dbscan. These must travel with
    // the cluster_method choice or Kinbiont silently falls back to its defaults.
    const methodParam = clusterMethod === 'hclust'
        ? `
    cluster_hclust_linkage = :${hclustLinkage},`
        : clusterMethod === 'dbscan'
        ? `
    cluster_dbscan_eps     = ${dbscanEps},
    cluster_dbscan_minpts  = ${dbscanMinPts},`
        : '';

    const prescreenParam = prescreenApplied
        ? `    cluster_prescreen_constant = true,
    cluster_tol_const          = ${prescreenTol},
    cluster_q_low              = ${prescreenQLo},
    cluster_q_high             = ${prescreenQHi},`
        : `    cluster_prescreen_constant = false,`;

    // Kinbiont's preprocess() skips the constant-curve pre-screen entirely when
    // cluster_method = :dbscan (preprocessing.jl:380). If the user combined both
    // in the GUI, the exported `cluster_prescreen_constant = true` line will be
    // silently ignored at runtime — surface that explicitly so the reader isn't
    // surprised by a mismatched cluster count.
    const prescreenDbscanNote = (prescreenApplied && clusterMethod === 'dbscan')
        ? `# NOTE: Kinbiont's preprocess() ignores cluster_prescreen_constant when
#       cluster_method = :dbscan. The line below is kept for parity with the
#       GUI request but will have no effect — DBSCAN reports outliers as the
#       cluster label maximum(labels)+1 instead of using a reserved sentinel.
`       : '';

    const normalizeNote = normalize
        ? `# Note: GUIbiont normalised curves before clustering (z-score per curve).
# KinBiont.jl applies normalisation internally during clustering.
`       : '';

    const interpolationNote = interpolate
        ? `# GUIbiont interpolation was enabled before clustering:
#   interp_n = ${interpN}, interp_quantile_lo = ${interpQLo}, interp_quantile_hi = ${interpQHi}
# If the original CSV has one time vector per curve, build an IrregularGrowthData
# or apply the same interpolation before constructing GrowthData.
`
        : '';

    const blankNote = blankSub
        ? `# GUIbiont automatic blank subtraction was enabled before clustering:
#   blank_method = "${blankMethod}", blank_range_thr = ${blankRangeThr}, blank_od_percentile = ${blankOdPct}
# Kinbiont.FitOptions blank_subtraction runs after clustering; to reproduce the
# GUI result, apply equivalent blank preprocessing before preprocess(data, opts).
`
        : '';

    const trendNote = trendTest
        ? `# GUIbiont trend-test reassignment was enabled with p threshold ${trendPThr}.
# The local Kinbiont FitOptions exposes cluster_trend_test, but not a custom p threshold.
`
        : '';

    const dataNote = isFileMode
        ? `# Replace with the path to your CSV file (uploaded in GUIbiont).`
        : `# CSV format: first column = time points, remaining columns = wells.`;

    const smoothBlock = smoothEnabled
        ? `smooth_opts = FitOptions(
    smooth        = true,
    smooth_method = :${smoothMethod},
${smoothParam}
    cluster       = false,
)
smoothed = preprocess(data, smooth_opts)`
        : `smoothed = data`;

    const code = `\
# ================================================================
# Growth curve clustering — exported from GUIbiont
# KinBiont.jl docs: https://github.com/pinheiroGroup/Kinbiont.jl
# Install:  using Pkg; Pkg.add("Kinbiont")
# ================================================================

using Kinbiont

${normalizeNote}${interpolationNote}${blankNote}${trendNote}${prescreenDbscanNote}# ${dataNote}
data = GrowthData("your_data.csv")

const N_DYNAMIC_CLUSTERS = ${dynamicK}
const PRESCREEN_CONSTANT = ${jb(prescreenApplied)}
const N_CLUSTER_LABELS = N_DYNAMIC_CLUSTERS + (PRESCREEN_CONSTANT ? 1 : 0)

# Kinbiont clusters before smoothing when both are enabled in one FitOptions,
# so apply smoothing first, then cluster the smoothed data.
${smoothBlock}

cluster_opts = FitOptions(
    cluster       = true,
    n_clusters    = N_CLUSTER_LABELS,
    cluster_method = :${clusterMethod},${iterParam}${methodParam}
    # Non-growing pre-screen from GUI Advanced options
${prescreenParam}
    # Post-hoc flat/non-growing reassignment from GUI Advanced options
    cluster_trend_test = ${jb(trendTest)},
)

processed = preprocess(smoothed, cluster_opts)

cluster_counts = Dict(k => count(==(k), processed.clusters)
                      for k in sort(unique(processed.clusters)))
cluster_counts_all = Dict(k => count(==(k), processed.clusters)
                          for k in 1:N_CLUSTER_LABELS)

println("Cluster assignments: ", processed.clusters)
println("Cluster counts:      ", cluster_counts)
println("Cluster counts all:  ", cluster_counts_all)
println("WCSS:                ", processed.wcss)

# To find the optimal k, sweep over a range and plot WCSS (elbow method):
# wcss_by_k = [preprocess(data, FitOptions(cluster=true, n_clusters=k)).wcss
#              for k in 2:10]
`;

    return withComments ? code : stripComments(code);
}
