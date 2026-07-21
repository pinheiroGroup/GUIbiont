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
# KinBiont.jl docs: https://github.com/pinheiroGroup/Kinbiont.jl
# Install:  using Pkg; Pkg.add(Pkg.PackageSpec(name="Kinbiont", version="1.4"))
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

export function generateBatchLogLinKinbiontCode(batchData, withComments) {
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
# KinBiont.jl docs: https://github.com/pinheiroGroup/Kinbiont.jl
# Install:  using Pkg; Pkg.add(Pkg.PackageSpec(name="Kinbiont", version="1.4"))
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

export function generateClusterCode(clusterData, withComments) {
    const req           = clusterData._request || {};
    const k             = req.k ?? 3;
    const smoothMethod  = req.smooth_method ?? 'lowess';
    const lowessFrac    = req.lowess_frac ?? 0.05;
    const gaussianHmult = req.gaussian_h_mult ?? 2.0;
    const clusterMethod = req.cluster_method ?? 'kmeans';
    const maxiter       = req.maxiter ?? 300;
    const tol           = req.tol ?? 1e-6;
    const nInit         = req.kmeans_n_init ?? 3;
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
    // Auto blank detection is a user-controllable flag (default on), but pre-screen
    // and the trend test provide their own non-growing-curve handling, so it only
    // applies when neither of those is active — matching the /api/cluster route.
    const autoBlankDetection = (req.auto_detect_blanks ?? true) && !prescreen && !trendTest;
    // Algorithm-specific parameters (used by hclust / dbscan only)
    const hclustLinkage = req.hclust_linkage ?? 'ward';
    const dbscanEps     = req.dbscan_eps     ?? 1.0;
    const dbscanMinPts  = req.dbscan_min_pts ?? 3;
    const isFileMode    = req._mode === 'file';
    const smoothEnabled = smoothMethod !== 'none';
    const prescreenApplied = clusterData.prescreen_applied ?? prescreen;
    const experimentsLiteral = Array.isArray(req.experiments) && req.experiments.length
        ? JSON.stringify(req.experiments)
        : 'String[]';
    const dataPathLiteral = req.csv_path
        ? JSON.stringify(req.csv_path)
        : '"your_data.csv"';
    // JS bool → Julia `true`/`false` literal for interpolation into source code.
    const jb = (value) => value ? 'true' : 'false';

    const smoothParam = !smoothEnabled ? '' : smoothMethod === 'lowess'
        ? `    # LOWESS bandwidth: fraction of points used for local regression
    lowess_frac   = ${lowessFrac},`
        : smoothMethod === 'gaussian'
        ? `    # Gaussian bandwidth multiplier (multiplied by median Δt)
    gaussian_h_mult = ${gaussianHmult},`
        : '';

    const nInitParam = clusterMethod === 'kmeans'
        ? `    kmeans_n_init          = ${nInit},\n`
        : '';

    // kmeans_max_iters and kmeans_tol are used by :kmeans and :kmedoids.
    // kmeans_n_init is used only by :kmeans in Kinbiont._kmeans_best.
    const iterParam = (clusterMethod === 'kmeans' || clusterMethod === 'kmedoids')
        ? `
${nInitParam}    kmeans_max_iters       = ${maxiter},
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
        ? `# Display normalisation was enabled in GUIbiont. Kinbiont already
# z-scores curves internally for clustering, so the data are not transformed here.
`       : '';

    const interpolationNote = interpolate
        ? `# File-mode interpolation is part of data preparation. The quantile
# bounds trim extreme start/end times before building the common time grid.
`
        : '';

    const blankNote = blankSub
        ? `# Blank subtraction is applied before smoothing and clustering, matching
# the GUIbiont clustering route rather than FitOptions.blank_subtraction.
`
        : '';
    const autoBlankNote = autoBlankDetection
        ? `# Auto blank detection was requested: when no annotated blanks exist,
# GUIbiont removes low, flat blank candidates from the clustering matrix.
# Blank correction is applied separately within each loaded experiment.
`
        : '';

    const trendNote = trendTest
        ? `# The post-hoc trend test assigns curves without a significant OD trend
# to the reserved non-growing label after clustering.
`
        : '';

    const dataPathBlock = isFileMode
        ? `# CSV layout: first usable column is time, following columns are curves.
# CSV files saved by pandas with an index column are handled automatically.
const DATA_PATH = ${dataPathLiteral}`
        : `# Point this at GUIbiont's Clean_data directory before running elsewhere.
const CLEAN_DATA_PATH = "Clean_data"`;

    const dataLoadBlock = isFileMode
        ? `# prepare_clustering_data mirrors the GUIbiont clustering loader:
# CSV parsing, optional interpolation, blank handling, and non-finite cleanup.
data = prepare_clustering_data(
    csv_path             = DATA_PATH,
    interpolate          = ${jb(interpolate)},
    interp_n             = ${interpN},
    interp_quantile_lo   = ${interpQLo},
    interp_quantile_hi   = ${interpQHi},
    auto_detect_blanks   = ${jb(autoBlankDetection)},
    subtract_blank       = ${jb(blankSub)},
    blank_method         = :${blankMethod},
    blank_range_thr      = ${blankRangeThr},
    blank_od_percentile  = ${blankOdPct},
)`
        : `# prepare_clustering_data reads the selected experiments from Clean_data,
# excludes annotated blank/discard wells, and applies the same blank handling as GUIbiont.
data = prepare_clustering_data(
    clean_data_path      = CLEAN_DATA_PATH,
    experiments          = ${experimentsLiteral},
    interpolate          = false,
    auto_detect_blanks   = ${jb(autoBlankDetection)},
    subtract_blank       = ${jb(blankSub)},
    blank_method         = :${blankMethod},
    blank_range_thr      = ${blankRangeThr},
    blank_od_percentile  = ${blankOdPct},
)`;

    const smoothBlock = smoothEnabled
        ? `# GUIbiont smooths the prepared curves before clustering. Calling preprocess
# once for smoothing and once for clustering preserves that order in Kinbiont.
smooth_opts = FitOptions(
    smooth        = true,
    smooth_method = :${smoothMethod},
${smoothParam}
    cluster       = false,
)
smoothed = preprocess(data, smooth_opts)
tlen = min(size(smoothed.curves, 2), length(smoothed.times))
cluster_data = GrowthData(smoothed.curves[:, 1:tlen], smoothed.times[1:tlen], smoothed.labels)`
        : `# Smoothing was disabled in GUIbiont.
cluster_data = data`;

    const code = `\
# ================================================================
# Growth curve clustering — exported from GUIbiont
# KinBiont.jl docs: https://github.com/pinheiroGroup/Kinbiont.jl
# Install:  using Pkg; Pkg.add("Kinbiont")
# ================================================================

using Kinbiont

${normalizeNote}${interpolationNote}${blankNote}${autoBlankNote}${trendNote}${prescreenDbscanNote}${dataPathBlock}
${dataLoadBlock}

const N_REQUESTED_CLUSTERS = ${k}
const PRESCREEN_CONSTANT = ${jb(prescreenApplied)}

${smoothBlock}

# GUIbiont caps k to the number of series after blank removal/preparation.
const N_CLUSTER_LABELS = min(N_REQUESTED_CLUSTERS, size(cluster_data.curves, 1))

# These options are the clustering controls selected in GUIbiont. Parameters
# that do not apply to the selected algorithm are intentionally omitted.
cluster_opts = FitOptions(
    cluster       = true,
    n_clusters    = N_CLUSTER_LABELS,
    cluster_method = :${clusterMethod},${iterParam}${methodParam}
    # Non-growing prescreen from GUIbiont Advanced options.
${prescreenParam}
    # Post-hoc flat/non-growing reassignment from GUIbiont Advanced options.
    cluster_trend_test = ${jb(trendTest)},
    cluster_trend_p_thr = ${trendPThr},
)

processed = preprocess(cluster_data, cluster_opts)
# Quality indices are computed on the same data that was passed to clustering.
quality = cluster_quality_indices(cluster_data.curves, processed.clusters;
)
quality_summary = Dict(
    "silhouette_mean"   => quality["silhouette_mean"],
    "dunn"              => quality["dunn"],
    "davies_bouldin"    => quality["davies_bouldin"],
    "calinski_harabasz" => quality["calinski_harabasz"],
    "xie_beni"          => quality["xie_beni"],
)

cluster_counts_all = Dict(k => count(==(k), processed.clusters)
                          for k in 1:N_CLUSTER_LABELS)

# Optional diagnostics:
#println("Cluster assignments: ", processed.clusters)
println("Cluster counts:      ", cluster_counts_all)
println("WCSS:                ", processed.wcss)
println("Quality summary:     ", quality_summary)
#println("Quality indices:     ", quality)

# To find the optimal k, sweep over a range and plot WCSS (elbow method):
# wcss_by_k = [preprocess(data, FitOptions(cluster=true, n_clusters=k)).wcss
#              for k in 2:10]
`;

    return withComments ? code : stripComments(code);
}
