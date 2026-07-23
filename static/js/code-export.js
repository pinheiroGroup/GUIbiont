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
    const req = fitData._request || {};
    const experiment = req.experiment || 'experiment';
    const well = req.well || 'B2';
    const fitLabel = req.label || well;
    const model = req.model_name || 'aHPM';
    const modelNames = Array.isArray(req.model_names) ? req.model_names : [];
    const isReplicate = Array.isArray(req.well_selections);
    const blankSub = isReplicate ? false : (req.blank_subtraction ?? false);
    const blankMethod = req.blank_method ?? 'pointbypoint';
    const maxiters = req.maxiters ?? 100000;
    const abstol = req.abstol ?? 1e-15;
    const smooth = req.smooth ?? false;
    const smoothWindow = req.smooth_window ?? 3;
    const computeLoglin = !!req.compute_loglin;
    const llPtAvg = req.loglin_pt_avg ?? 7;
    const llPtDeriv = req.loglin_pt_smoothing_derivative ?? 7;
    const llPtMinWin = req.loglin_pt_min_size_of_win ?? 7;
    const llThreshold = req.loglin_threshold_of_exp ?? 0.9;
    const optimizer = req.optimizer || 'LN_COBYLA';
    const detOpts = Array.isArray(req.deterministic_optimizers) ? req.deterministic_optimizers : [];
    const stoOpts = Array.isArray(req.stochastic_optimizers) ? req.stochastic_optimizers : [];
    const stochasticRuns = req.stochastic_runs ?? 3;
    const strArray = xs => `String[${xs.map(x => JSON.stringify(String(x))).join(', ')}]`;
    const jb = value => value ? 'true' : 'false';
    const selections = isReplicate ? req.well_selections : [];
    const selectionsLiteral = `[${selections.map(sel =>
        `(experiment=${JSON.stringify(String(sel.experiment))}, ` +
        `well=${JSON.stringify(String(sel.well))}, channel=${Number(sel.channel) || 1})`
    ).join(', ')}]`;

    const dataBlock = isReplicate
        ? `# Rebuild the replicate mean from the locally stored source experiments.
const WELL_SELECTIONS = ${selectionsLiteral}
replicate_times = Vector{Vector{Float64}}()
replicate_curves = Vector{Vector{Float64}}()
for selection in WELL_SELECTIONS
    source = load_gui_experiment_data(
        CLEAN_DATA_PATH,
        selection.experiment;
        channel=selection.channel,
        channel_annotation=true,
    )
    idx = findfirst(==(selection.well), source.data.labels)
    idx === nothing && error("Well $(selection.well) not found in $(selection.experiment)")
    curve = vec(source.data.curves[idx, :])
    # GUIbiont replicate fitting subtracts each experiment's global blank
    # before truncating all selected curves to their shortest common length.
    push!(replicate_curves, max.(curve .- source.blank_value, 0.01))
    push!(replicate_times, source.data.times)
end
isempty(replicate_curves) && error("No replicate curves loaded")
min_len = minimum(length.(replicate_curves))
avg_time = replicate_times[1][1:min_len]
avg_curve = sum(curve[1:min_len] for curve in replicate_curves) ./ length(replicate_curves)
valid = findall(.!isnan.(avg_curve))
length(valid) >= 10 || error("Not enough valid replicate-average measurements")
data = GrowthData(reshape(avg_curve[valid], 1, :), avg_time[valid], [FIT_LABEL])
blank_value = 0.0
blank_timeseries = Float64[]`
        : `# Load the original experiment and recompute its annotated blank summary.
source = load_gui_experiment_data(CLEAN_DATA_PATH, EXPERIMENT)
idx = findfirst(==(WELL), source.data.labels)
idx === nothing && error("Well $(WELL) not found in $(EXPERIMENT)")
data = GrowthData(reshape(vec(source.data.curves[idx, :]), 1, :),
                  source.data.times, [WELL])
blank_value = source.blank_value
blank_timeseries = BLANK_SUBTRACTION && BLANK_METHOD == "pointbypoint" ?
    source.blank_timeseries : Float64[]`;

    const code = `\
# ================================================================
# Growth curve fitting — exported from GUIbiont
# KinBiont.jl docs: https://github.com/pinheiroGroup/Kinbiont.jl
# Reruns the workflow from local source files; no GUI input curve or
# GUI result is embedded, and result comparison is intentionally external.
# ================================================================

using Kinbiont

const CLEAN_DATA_PATH = "path/to/Clean_data"
const EXPERIMENT = ${JSON.stringify(experiment)}
const FIT_LABEL = ${JSON.stringify(fitLabel)}
const WELL = ${JSON.stringify(well)}
const BLANK_SUBTRACTION = ${jb(blankSub)}
const BLANK_METHOD = ${JSON.stringify(blankMethod)}

${dataBlock}

# With one selected label, this follows GUIbiont's smart initialisation,
# preprocessing and complete single/best-of-N optimizer workflow.
fit = kinbiont_batch_fit(
    data;
    experiment=EXPERIMENT,
    labels=[${isReplicate ? 'FIT_LABEL' : 'WELL'}],
    model_name=${JSON.stringify(model)},
    model_names=${strArray(modelNames)},
    optimizer=${JSON.stringify(optimizer)},
    deterministic_optimizers=${strArray(detOpts)},
    stochastic_optimizers=${strArray(stoOpts)},
    stochastic_runs=${stochasticRuns},
    maxiters=${maxiters},
    abstol=${abstol},
    skip_flat_threshold=0.0,
    smooth=${jb(smooth)},
    smooth_window=${smoothWindow},
    compute_loglin=${jb(computeLoglin)},
    loglin_pt_avg=${llPtAvg},
    loglin_pt_smoothing_derivative=${llPtDeriv},
    loglin_pt_min_size_of_win=${llPtMinWin},
    loglin_threshold_of_exp=${llThreshold},
    blank_subtraction=BLANK_SUBTRACTION,
    blank_method=BLANK_METHOD,
    blank_value=blank_value,
    blank_timeseries=blank_timeseries,
)

isempty(fit.results) && error("Fit failed: $(join(fit.errors, \"; \"))")
r = only(fit.results)
println("Model:       ", r["model"])
println("Param names: ", r["param_names"])
println("Parameters:  ", r["parameters"])
println("AICc:        ", r["aic"])
println("RMSE:        ", r["loss_rmse"])
println("Optimizer:   ", r["optimizer_used"])
if ${jb(computeLoglin)}
    println("Log-linear mu_max: ", r["gr_loglin"])
    println("Log-linear lag:    ", r["lag_loglin"])
    println("N_max (cutoff):    ", r["N_max_emp"])
end
`;

    return withComments ? code : stripComments(code);
}

export function generateBatchCode(batchData, withComments) {
    const req = batchData._request || {};
    const experiment = req.experiment || 'experiment';
    const wells = req.wells || [];
    const rawModels = req.model_names && req.model_names.length > 0
        ? req.model_names
        : [req.model_name || 'aHPM'];
    const modelNames = rawModels.filter(m => m !== 'log_lin');
    const modelName = modelNames[0] || req.model_name || 'aHPM';
    const detOpts = req.deterministic_optimizers || [];
    const stoOpts = req.stochastic_optimizers || [];
    const stochasticRuns = req.stochastic_runs ?? 1;
    const singleOptimizer = req.optimizer || 'LN_COBYLA';
    const maxiters = req.maxiters ?? 100000;
    const abstol = req.abstol ?? 1e-15;
    const skipFlat = req.skip_flat_threshold ?? 0.02;
    const smooth = req.smooth ?? false;
    const smoothWindow = req.smooth_window ?? 3;
    const computeLoglin = !!req.compute_loglin || rawModels.includes('log_lin');
    const llPtAvg = req.loglin_pt_avg ?? 7;
    const llPtDeriv = req.loglin_pt_smoothing_derivative ?? 7;
    const llPtMinWin = req.loglin_pt_min_size_of_win ?? 7;
    const llThrExp = req.loglin_threshold_of_exp ?? 0.9;
    const blankSub = req.blank_subtraction ?? false;
    const blankMethod = req.blank_method || 'pointbypoint';
    const outPrefix = `${experiment}_batch_fit`;
    const strArray = xs => `String[${xs.map(x => JSON.stringify(String(x))).join(', ')}]`;
    const jb = x => x ? 'true' : 'false';

    const code = `\
# ================================================================
# Batch growth curve fitting - exported from GUIbiont
# KinBiont.jl docs: https://github.com/pinheiroGroup/Kinbiont.jl
# Reruns the workflow from local source files; no GUI result is embedded.
# ================================================================

using Kinbiont

const CLEAN_DATA_PATH = "path/to/Clean_data"
const EXPERIMENT = "${experiment}"
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
const SMOOTH = ${jb(smooth)}
const SMOOTH_WINDOW = ${smoothWindow}
const COMPUTE_LOGLIN = ${jb(computeLoglin)}
const LOGLIN_PT_AVG = ${llPtAvg}
const LOGLIN_PT_DERIV = ${llPtDeriv}
const LOGLIN_PT_MIN_WIN = ${llPtMinWin}
const LOGLIN_THR_EXP = ${llThrExp}
const BLANK_SUBTRACTION = ${jb(blankSub)}
const BLANK_METHOD = "${blankMethod}"

source = load_gui_experiment_data(CLEAN_DATA_PATH, EXPERIMENT)
data = source.data
blank_timeseries = BLANK_SUBTRACTION && BLANK_METHOD == "pointbypoint" ?
    source.blank_timeseries : Float64[]
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
    smooth=SMOOTH,
    smooth_window=SMOOTH_WINDOW,
    compute_loglin=COMPUTE_LOGLIN,
    loglin_pt_avg=LOGLIN_PT_AVG,
    loglin_pt_smoothing_derivative=LOGLIN_PT_DERIV,
    loglin_pt_min_size_of_win=LOGLIN_PT_MIN_WIN,
    loglin_threshold_of_exp=LOGLIN_THR_EXP,
    blank_subtraction=BLANK_SUBTRACTION,
    blank_method=BLANK_METHOD,
    blank_value=source.blank_value,
    blank_timeseries=blank_timeseries,
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
    const experiment = req.experiment || 'experiment';
    const wells = req.wells || [];
    const ptAvg = req.pt_avg ?? 7;
    const ptDeriv = req.pt_smoothing_derivative ?? 7;
    const ptMinWin = req.pt_min_size_of_win ?? 7;
    const thrExp = req.threshold_of_exp ?? 0.9;
    const flatThr = req.skip_flat_threshold ?? 0.02;
    const blankSub = req.blank_subtraction ?? false;
    const blankMethod = req.blank_method || 'pointbypoint';
    const smoothing = req.type_of_smoothing || 'rolling_avg';
    const winType = req.type_of_win || 'maximum';
    const startThr = req.start_exp_win_thr ?? 0.05;
    const thrLowess = req.thr_lowess ?? 0.05;
    const outPrefix = `${experiment}_batch_fit_loglin`;
    const strArray = xs => `String[${xs.map(x => JSON.stringify(String(x))).join(', ')}]`;
    const jb = x => x ? 'true' : 'false';

    const code = `\
# ================================================================
# Batch log-linear growth-rate fit - exported from GUIbiont
# KinBiont.jl docs: https://github.com/pinheiroGroup/Kinbiont.jl
# Reruns the workflow from local source files; no GUI result is embedded.
# ================================================================

using Kinbiont

const CLEAN_DATA_PATH = "path/to/Clean_data"
const EXPERIMENT = "${experiment}"
const OUT_PREFIX = "${outPrefix}"
const WELLS = ${strArray(wells)}
const BLANK_SUBTRACTION = ${jb(blankSub)}
const BLANK_METHOD = "${blankMethod}"
const TYPE_OF_SMOOTHING = "${smoothing}"
const PT_AVG = ${ptAvg}
const PT_SMOOTHING_DERIVATIVE = ${ptDeriv}
const PT_MIN_SIZE_OF_WIN = ${ptMinWin}
const TYPE_OF_WIN = "${winType}"
const THRESHOLD_OF_EXP = ${thrExp}
const START_EXP_WIN_THR = ${startThr}
const THR_LOWESS = ${thrLowess}
const SKIP_FLAT_THRESHOLD = ${flatThr}

source = load_gui_experiment_data(CLEAN_DATA_PATH, EXPERIMENT)
data = source.data
blank_timeseries = BLANK_SUBTRACTION && BLANK_METHOD == "pointbypoint" ?
    source.blank_timeseries : Float64[]
batch = kinbiont_batch_loglin(
    data;
    experiment=EXPERIMENT,
    labels=WELLS,
    blank_subtraction=BLANK_SUBTRACTION,
    blank_method=BLANK_METHOD,
    blank_value=source.blank_value,
    blank_timeseries=blank_timeseries,
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
    const deriveBlanks  = req.derive_non_growing_blanks ?? false;
    const blankMethod   = req.blank_method ?? 'pointbypoint';
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
    // Export the selected workflow, not a decision inferred from its result.
    // Re-running the detector on the source data determines whether a sentinel
    // is actually populated.
    const prescreenApplied = deriveBlanks ? false : prescreen;
    const trendApplied = deriveBlanks ? false : trendTest;
    const costLabel = 'WCSS';
    const experimentsLiteral = Array.isArray(req.experiments) && req.experiments.length
        ? JSON.stringify(req.experiments)
        : 'String[]';
    const dataPathLiteral = req.csv_path
        ? JSON.stringify(req.csv_path)
        : '"path/to/data.csv"';
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
    const autoBlankNote = deriveBlanks
        ? `# The enabled non-growing criteria identify blank curves on the selected
# smoothed signal. Kinbiont removes that group, derives blanks per experiment
# from the unsmoothed measurements, subtracts them, and returns the remaining data.
`
        : '';

    const trendNote = trendApplied
        ? `# The trend test contributes to the non-growing group. Methods with a
# predefined k separate that group before clustering; DBSCAN reassigns it post-hoc.
`
        : '';

    const dataPathBlock = isFileMode
        ? `# CSV layout: first usable column is time, following columns are curves.
# CSV files saved by pandas with an index column are handled automatically.
const DATA_PATH = ${dataPathLiteral}`
        : `# Point this at GUIbiont's Clean_data directory on this machine.
const CLEAN_DATA_PATH = "path/to/Clean_data"`;

    const dataLoadBlock = isFileMode
        ? `# prepare_clustering_data mirrors the GUIbiont clustering loader:
# CSV parsing, optional interpolation, blank handling, and non-finite cleanup.
data = prepare_clustering_data(
    csv_path             = DATA_PATH,
    interpolate          = ${jb(interpolate)},
    interp_n             = ${interpN},
    interp_quantile_lo   = ${interpQLo},
    interp_quantile_hi   = ${interpQHi},
    auto_detect_blanks   = false,
    subtract_blank       = ${jb(blankSub)},
    blank_method         = :${blankMethod},
    blank_floor          = 1e-4,
    derive_non_growing_blanks = ${jb(deriveBlanks)},
    blank_prescreen_constant  = ${jb(prescreen)},
    blank_trend_test          = ${jb(trendTest)},
    blank_prescreen_tol       = ${prescreenTol},
    blank_prescreen_q_low     = ${prescreenQLo},
    blank_prescreen_q_high    = ${prescreenQHi},
    blank_trend_p_threshold   = ${trendPThr},
    detection_smooth          = ${jb(smoothEnabled)},
    detection_smooth_method   = :${smoothMethod},
    detection_lowess_frac     = ${lowessFrac},
    detection_gaussian_h_mult = ${gaussianHmult},
)`
        : `# prepare_clustering_data reads the selected experiments from Clean_data.
# It excludes discard wells and aligns each experiment's annotated blank wells
# to that experiment's sample times before subtraction, matching GUIbiont.
data = prepare_clustering_data(
    clean_data_path      = CLEAN_DATA_PATH,
    experiments          = ${experimentsLiteral},
    interpolate          = ${jb(interpolate)},
    interp_n             = ${interpN},
    interp_quantile_lo   = ${interpQLo},
    interp_quantile_hi   = ${interpQHi},
    auto_detect_blanks   = false,
    subtract_blank       = ${jb(blankSub)},
    blank_method         = :${blankMethod},
    blank_floor          = 1e-4,
    derive_non_growing_blanks = ${jb(deriveBlanks)},
    blank_prescreen_constant  = ${jb(prescreen)},
    blank_trend_test          = ${jb(trendTest)},
    blank_prescreen_tol       = ${prescreenTol},
    blank_prescreen_q_low     = ${prescreenQLo},
    blank_prescreen_q_high    = ${prescreenQHi},
    blank_trend_p_threshold   = ${trendPThr},
    detection_smooth          = ${jb(smoothEnabled)},
    detection_smooth_method   = :${smoothMethod},
    detection_lowess_frac     = ${lowessFrac},
    detection_gaussian_h_mult = ${gaussianHmult},
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

${normalizeNote}${interpolationNote}${blankNote}${autoBlankNote}${trendNote}${dataPathBlock}
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
    # Explicitly match GUIbiont's deterministic k-means initialisation.
    kmeans_seed = 42,
    # Non-growing prescreen from GUIbiont Advanced options.
${prescreenParam}
    # Post-hoc flat/non-growing reassignment from GUIbiont Advanced options.
    cluster_trend_test = ${jb(trendApplied)},
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
                          for k in sort(unique(processed.clusters)))
assignment_rows = collect(zip(cluster_data.labels, processed.clusters))

# Optional diagnostics:
#println("Cluster assignments: ", processed.clusters)
println("Cluster counts:      ", cluster_counts_all)
println("${costLabel}: ", processed.wcss)
println("Quality summary:     ", quality_summary)
#println("Quality indices:     ", quality)
#println("Label/cluster rows:  ", assignment_rows)

# WCSS uses centroid-based squared error for every method and excludes the
# non-growing sentinel and DBSCAN noise. For methods that use k, repeat
# preprocessing over candidate k values to build an elbow plot.
`;

    return withComments ? code : stripComments(code);
}
