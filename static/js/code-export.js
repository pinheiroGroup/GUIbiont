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

// JavaScript serialises an integral Number such as 2.0 as "2". That is not
// interchangeable with Float64 for type-annotated Julia keyword arguments.
function juliaFloat(value, fallback = 0.0) {
    const parsed = Number(value);
    const n = Number.isFinite(parsed) ? parsed : Number(fallback);
    if (!Number.isFinite(n)) throw new Error(`Cannot export non-finite Julia Float64: ${value}`);
    return Number.isInteger(n) ? `${n}.0` : String(n);
}

function juliaString(value) {
    return JSON.stringify(String(value));
}

function juliaStringArray(values) {
    const items = Array.isArray(values) ? values : [];
    return `String[${items.map(juliaString).join(', ')}]`;
}

function juliaKeywordLines(entries) {
    return entries
        .filter(([, literal]) => literal !== null && literal !== undefined)
        .map(([name, literal]) => `    ${name}=${literal},`)
        .join('\n');
}

function acceptedBlankWells(req) {
    const requested = Array.isArray(req.override_blank_wells) ? req.override_blank_wells : [];
    return [...new Set(requested.map(String).filter(Boolean))].sort();
}

// Reproduce GUIbiont's explicit blank-well override from the original source
// data. Unknown/stale labels are ignored, exactly as they are by the API; when
// none remain, the loader's annotation-derived blank summary is retained.
function blankExportContext(req, blankSub, blankMethod) {
    const wells = acceptedBlankWells(req);
    const useOverride = !!blankSub && wells.length > 0;
    const value = useOverride ? 'override_blank_value' : 'source.blank_value';
    const timeseries = useOverride ? 'override_blank_timeseries' : 'source.blank_timeseries';
    const setup = useOverride ? `
# Recompute the accepted blank-well override exactly as GUIbiont does.
const BLANK_WELLS = ${juliaStringArray(wells)}
blank_indices = Int[]
for blank_well in BLANK_WELLS
    idx = findfirst(==(blank_well), source.data.labels)
    idx === nothing || push!(blank_indices, idx)
end
override_blank_value = source.blank_value
override_blank_timeseries = source.blank_timeseries
if !isempty(blank_indices)
    blank_curves = [vec(source.data.curves[idx, :]) for idx in blank_indices]
    blank_values = filter(isfinite, reduce(vcat, blank_curves))
    override_blank_value = isempty(blank_values) ? 0.0 : mean(blank_values)
    override_blank_timeseries = [
        begin
            at_time = filter(isfinite, [curve[j] for curve in blank_curves])
            isempty(at_time) ? NaN : mean(at_time)
        end for j in eachindex(source.data.times)
    ]
    valid_blank_timeseries = filter(isfinite, override_blank_timeseries)
    blank_fallback = isempty(valid_blank_timeseries) ? 0.0 : mean(valid_blank_timeseries)
    replace!(override_blank_timeseries, NaN => blank_fallback)
end
` : '';
    const keywords = blankSub
        ? [
            ['blank_subtraction', 'true'],
            ['blank_method', juliaString(blankMethod)],
            ['blank_value', value],
            ['blank_timeseries', blankMethod === 'pointbypoint' ? timeseries : null],
        ]
        : [];
    return { wells, setup, keywords };
}

// ---------------------------------------------------------------------------
// Dynamic Log-Lin settings used by Fit and Batch Fit exports
// ---------------------------------------------------------------------------

function companionLogLinSettings(req) {
    return {
        smoothing: req.loglin_type_of_smoothing || 'rolling_avg',
        ptAvg: req.loglin_pt_avg ?? 7,
        ptDeriv: req.loglin_pt_smoothing_derivative ?? 7,
        ptMinWin: req.loglin_pt_min_size_of_win ?? 7,
        winType: req.loglin_type_of_win || 'maximum',
        threshold: req.loglin_threshold_of_exp ?? 0.9,
        startThreshold: req.loglin_start_exp_win_thr ?? 0.05,
        lowessThreshold: req.loglin_thr_lowess ?? 0.05,
        gaussianHMult: req.loglin_gaussian_h_mult ?? 2.0,
    };
}

function companionLogLinKeywordPairs(settings) {
    const smoothingKeywords = settings.smoothing === 'rolling_avg'
        ? [
            ['type_of_smoothing', juliaString(settings.smoothing)],
            ['pt_avg', String(settings.ptAvg)],
        ]
        : settings.smoothing === 'lowess'
        ? [
            ['type_of_smoothing', juliaString(settings.smoothing)],
            ['thr_lowess', juliaFloat(settings.lowessThreshold, 0.05)],
        ]
        : settings.smoothing === 'gaussian'
        ? [
            ['type_of_smoothing', juliaString(settings.smoothing)],
            ['gaussian_h_mult', juliaFloat(settings.gaussianHMult, 2.0)],
        ]
        : [['type_of_smoothing', juliaString(settings.smoothing)]];
    return [
        ...smoothingKeywords,
        ['pt_smoothing_derivative', String(settings.ptDeriv)],
        ['pt_min_size_of_win', String(settings.ptMinWin)],
        ['type_of_win', juliaString(settings.winType)],
        ['threshold_of_exp', juliaFloat(settings.threshold, 0.9)],
        ['start_exp_win_thr',
            settings.winType === 'global_thr' || settings.winType === 'max_with_min_OD'
                ? juliaFloat(settings.startThreshold, 0.05) : null],
    ];
}

function parametricSmoothingKeywordPairs(req) {
    const method = req.smooth_method || (req.smooth ? 'boxcar' : 'none');
    if (method === 'rolling_avg') {
        return [
            ['smooth', 'true'],
            ['smooth_method', ':rolling_avg'],
            ['smooth_pt_avg', String(req.smooth_pt_avg ?? 7)],
        ];
    }
    if (method === 'lowess') {
        return [
            ['smooth', 'true'],
            ['smooth_method', ':lowess'],
            ['lowess_frac', juliaFloat(req.lowess_frac, 0.05)],
        ];
    }
    if (method === 'gaussian') {
        return [
            ['smooth', 'true'],
            ['smooth_method', ':gaussian'],
            ['gaussian_h_mult', juliaFloat(req.gaussian_h_mult, 2.0)],
        ];
    }
    if (method === 'boxcar') {
        return [
            ['smooth', 'true'],
            ['smooth_window', String(req.smooth_window ?? 3)],
        ];
    }
    return [];
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
    a.download = 'guibiont_analysis.jl';
    a.click();
    URL.revokeObjectURL(url);
}

// ---------------------------------------------------------------------------
// Per-tab openers (called from HTML onclick / app.js)
// ---------------------------------------------------------------------------

export function openFitCodeExport() {
    if (!state.lastFitData) return;
    const isLoglin = state.lastFitData._workflow === 'loglin';
    const generator = isLoglin ? generateFitLogLinKinbiontCode : generateFitCode;
    openCodeExportModal(
        isLoglin ? 'Export Julia code — Log-Lin Fit' : 'Export Julia code — Fit Curve',
        (withComments) => generator(state.lastFitData, withComments),
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
    const computeLoglin = !!req.compute_loglin;
    const loglinSettings = companionLogLinSettings(req);
    const optimizer = req.optimizer || 'LN_COBYLA';
    const detOpts = Array.isArray(req.deterministic_optimizers) ? req.deterministic_optimizers : [];
    const stoOpts = Array.isArray(req.stochastic_optimizers) ? req.stochastic_optimizers : [];
    const stochasticRuns = req.stochastic_runs ?? 3;
    const selections = isReplicate ? req.well_selections : [];
    const selectionsLiteral = `[${selections.map(sel =>
        `(experiment=${juliaString(sel.experiment)}, ` +
        `well=${juliaString(sel.well)}, channel=${Number(sel.channel) || 1})`
    ).join(', ')}]`;
    const targetConstant = isReplicate
        ? `const FIT_LABEL = ${juliaString(fitLabel)}`
        : `const WELL = ${juliaString(well)}`;
    const bestOfOptimizers = detOpts.length > 0 || stoOpts.length > 0;
    const modelKeywords = modelNames.length > 0
        ? [['model_names', juliaStringArray(modelNames)]]
        : [['model_name', juliaString(model)]];
    const optimizerKeywords = bestOfOptimizers
        ? [
            ['deterministic_optimizers', detOpts.length ? juliaStringArray(detOpts) : null],
            ['stochastic_optimizers', stoOpts.length ? juliaStringArray(stoOpts) : null],
            ['stochastic_runs', stoOpts.length ? String(stochasticRuns) : null],
            ['optimizer_seed', stoOpts.length ? '42' : null],
        ]
        : [
            ['optimizer', juliaString(optimizer)],
            ['optimizer_seed', optimizer === 'BBO_adaptive_de_rand_1_bin_radiuslimited' ||
                optimizer === 'GN_ISRES' ? '42' : null],
        ];
    const smoothingKeywords = parametricSmoothingKeywordPairs(req);
    const blankContext = blankExportContext(req, blankSub, blankMethod);
    const blankKeywords = blankContext.keywords;
    const fitKeywords = juliaKeywordLines([
        ...modelKeywords,
        ...optimizerKeywords,
        ['maxiters', String(maxiters)],
        ['abstol', juliaFloat(abstol, 1e-15)],
        ['skip_flat_threshold', '0.0'],
        ...smoothingKeywords,
        ...blankKeywords,
    ]);
    const companionKeywords = computeLoglin
        ? juliaKeywordLines([
            ...blankKeywords,
            // The companion is a log-linear fit, so it takes the log-linear
            // floor (1e-4), not the 0.01 the parametric relative-error loss
            // needs. src/analysis.jl preprocesses it the same way; using 0.01
            // here made the export disagree with the GUI for low-OD curves.
            ['unblanked_floor', '1e-4'],
            ...companionLogLinKeywordPairs(loglinSettings),
        ])
        : '';
    const loglinBlock = computeLoglin
        ? `# Run the Log-Lin companion with the exact advanced options selected in GUIbiont.
loglin = kinbiont_fit_loglin(
    data;
    experiment=EXPERIMENT,
    label=${isReplicate ? 'FIT_LABEL' : 'WELL'},
${companionKeywords}
)
println("Log-linear mu_max: ", loglin["gr_loglin"])
println("Log-linear lag:    ", loglin["lag_loglin"])
println("N_max (cutoff):    ", loglin["N_max_emp"])`
        : '';

    const dataBlock = isReplicate
        ? `# Rebuild the replicate mean from the locally stored source experiments.
const WELL_SELECTIONS = ${selectionsLiteral}
replicate_times = Vector{Vector{Float64}}()
replicate_curves = Vector{Vector{Float64}}()
for selection in WELL_SELECTIONS
    source = load_experiment_data(
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
data = GrowthData(reshape(avg_curve[valid], 1, :), avg_time[valid], [FIT_LABEL])`
        : `# Load the original experiment and recompute its annotated blank summary.
source = load_experiment_data(CLEAN_DATA_PATH, EXPERIMENT)
idx = findfirst(==(WELL), source.data.labels)
idx === nothing && error("Well $(WELL) not found in $(EXPERIMENT)")
data = GrowthData(reshape(vec(source.data.curves[idx, :]), 1, :),
                  source.data.times, [WELL])`;

    const code = `\
# ================================================================
# Growth curve fitting — exported from GUIbiont
# KinBiont.jl docs: https://github.com/pinheiroGroup/Kinbiont.jl
# Reruns the workflow from local source files; no GUI input curve or
# GUI result is embedded, and result comparison is intentionally external.
# ================================================================

using Kinbiont
using Statistics

const CLEAN_DATA_PATH = "path/to/Clean_data"
const EXPERIMENT = ${juliaString(experiment)}
${targetConstant}

${dataBlock}
${isReplicate ? '' : blankContext.setup}

# With one selected label, this follows GUIbiont's smart initialisation,
# preprocessing and complete single/best-of-N optimizer workflow.
fit = kinbiont_batch_fit(
    data;
    experiment=EXPERIMENT,
    labels=[${isReplicate ? 'FIT_LABEL' : 'WELL'}],
${fitKeywords}
)

isempty(fit.results) && error("Fit failed: $(join(fit.errors, \"; \"))")
r = only(fit.results)
println("Model:       ", r["model"])
println("Param names: ", r["param_names"])
println("Parameters:  ", r["parameters"])
println("AICc:        ", r["aic"])
println("RMSE:        ", r["loss_rmse"])
println("Optimizer:   ", r["optimizer_used"])
${loglinBlock}
`;

    return withComments ? code : stripComments(code);
}

export function generateFitLogLinKinbiontCode(fitData, withComments) {
    const req = fitData._request || {};
    const experiment = req.experiment || 'experiment';
    const well = req.well || 'B2';
    const blankSub = req.blank_subtraction ?? false;
    const blankMethod = req.blank_method || 'pointbypoint';
    const settings = {
        smoothing: req.type_of_smoothing || 'rolling_avg',
        ptAvg: req.pt_avg ?? 7,
        ptDeriv: req.pt_smoothing_derivative ?? 7,
        ptMinWin: req.pt_min_size_of_win ?? 7,
        winType: req.type_of_win || 'maximum',
        threshold: req.threshold_of_exp ?? 0.9,
        startThreshold: req.start_exp_win_thr ?? 0.05,
        lowessThreshold: req.thr_lowess ?? 0.05,
        gaussianHMult: req.gaussian_h_mult ?? 2.0,
    };
    const blankContext = blankExportContext(req, blankSub, blankMethod);
    const blankKeywords = blankContext.keywords;
    const loglinKeywords = juliaKeywordLines([
        ...blankKeywords,
        ...companionLogLinKeywordPairs(settings),
    ]);

    const code = `\
# ================================================================
# Single-well Log-Lin fit - exported from GUIbiont
# ================================================================

using Kinbiont
using Statistics

const CLEAN_DATA_PATH = "path/to/Clean_data"
const EXPERIMENT = ${juliaString(experiment)}
const WELL = ${juliaString(well)}

source = load_experiment_data(CLEAN_DATA_PATH, EXPERIMENT)
${blankContext.setup}
idx = findfirst(==(WELL), source.data.labels)
idx === nothing && error("Well $(WELL) not found in $(EXPERIMENT)")
data = GrowthData(reshape(vec(source.data.curves[idx, :]), 1, :),
                  source.data.times, [WELL])

result = kinbiont_fit_loglin(
    data;
    experiment=EXPERIMENT,
    label=WELL,
${loglinKeywords}
)

println("Log-linear mu_max: ", result["gr_loglin"])
println("Log-linear lag:    ", result["lag_loglin"])
println("N_max (cutoff):    ", result["N_max_emp"])
println("R-squared:         ", result["R_squared_loglin"])
`;

    return withComments ? code : stripComments(code);
}

export function generateBatchCode(batchData, withComments) {
    const req = batchData._request || {};
    const experiment = req.experiment || 'experiment';
    const acceptedBlanks = acceptedBlankWells(req);
    const wells = (req.wells || []).filter(well => !acceptedBlanks.includes(String(well)));
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
    const computeLoglin = !!req.compute_loglin || rawModels.includes('log_lin');
    const loglinSettings = companionLogLinSettings(req);
    const blankSub = req.blank_subtraction ?? false;
    const blankMethod = req.blank_method || 'pointbypoint';
    const outPrefix = `${experiment}_batch_fit`;
    const bestOfOptimizers = detOpts.length > 0 || stoOpts.length > 0;
    const modelKeywords = modelNames.length > 1
        ? [['model_names', juliaStringArray(modelNames)]]
        : [['model_name', juliaString(modelName)]];
    const optimizerKeywords = bestOfOptimizers
        ? [
            ['deterministic_optimizers', detOpts.length ? juliaStringArray(detOpts) : null],
            ['stochastic_optimizers', stoOpts.length ? juliaStringArray(stoOpts) : null],
            ['stochastic_runs', stoOpts.length ? String(stochasticRuns) : null],
            ['optimizer_seed', stoOpts.length ? '42' : null],
        ]
        : [
            ['optimizer', juliaString(singleOptimizer)],
            ['optimizer_seed', singleOptimizer === 'BBO_adaptive_de_rand_1_bin_radiuslimited' ||
                singleOptimizer === 'GN_ISRES' ? '42' : null],
        ];
    const smoothingKeywords = parametricSmoothingKeywordPairs(req);
    const blankContext = blankExportContext(req, blankSub, blankMethod);
    const blankKeywords = blankContext.keywords;
    const batchKeywords = juliaKeywordLines([
        ...modelKeywords,
        ...optimizerKeywords,
        ['maxiters', String(maxiters)],
        ['abstol', juliaFloat(abstol, 1e-15)],
        ['skip_flat_threshold', juliaFloat(skipFlat, 0.02)],
        ...smoothingKeywords,
        ...blankKeywords,
    ]);
    const companionKeywords = computeLoglin
        ? juliaKeywordLines([
            ...blankKeywords,
            ...companionLogLinKeywordPairs(loglinSettings),
            ['skip_flat_threshold', juliaFloat(skipFlat, 0.02)],
        ])
        : '';
    const loglinBlock = computeLoglin
        ? `
# Run the Log-Lin companion with the exact advanced options selected in GUIbiont.
loglin_batch = kinbiont_batch_loglin(
    data;
    experiment=EXPERIMENT,
    labels=WELLS,
${companionKeywords}
)
loglin_paths = save_batch_loglin_results(
    loglin_batch, "."; prefix=OUT_PREFIX * "_loglin",
)
println("Saved ", loglin_paths.summary)
println("Log-Lin fitted: ", length(loglin_batch.results),
        "  skipped: ", length(loglin_batch.skipped),
        "  failed: ", length(loglin_batch.errors))
`
        : '';

    const code = `\
# ================================================================
# Batch growth curve fitting - exported from GUIbiont
# KinBiont.jl docs: https://github.com/pinheiroGroup/Kinbiont.jl
# Reruns the workflow from local source files; no GUI result is embedded.
# ================================================================

using Kinbiont
using Statistics

const CLEAN_DATA_PATH = "path/to/Clean_data"
const EXPERIMENT = ${juliaString(experiment)}
const OUT_PREFIX = ${juliaString(outPrefix)}
const WELLS = ${juliaStringArray(wells)}

source = load_experiment_data(CLEAN_DATA_PATH, EXPERIMENT)
${blankContext.setup}
data = source.data
batch = kinbiont_batch_fit(
    data;
    experiment=EXPERIMENT,
    labels=WELLS,
${batchKeywords}
)

paths = save_batch_results(batch, "."; prefix=OUT_PREFIX)
println("Saved ", paths.summary)
println("Saved ", paths.fitted_curves)
println("Fitted: ", length(batch.results), "  skipped: ", length(batch.skipped), "  failed: ", length(batch.errors))
${loglinBlock}
`;

    return withComments ? code : stripComments(code);
}

export function generateBatchLogLinKinbiontCode(batchData, withComments) {
    const req = batchData._request || {};
    const experiment = req.experiment || 'experiment';
    const acceptedBlanks = acceptedBlankWells(req);
    const wells = (req.wells || []).filter(well => !acceptedBlanks.includes(String(well)));
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
    const gaussianHMult = req.gaussian_h_mult ?? 2.0;
    const outPrefix = `${experiment}_batch_fit_loglin`;
    const smoothingKeywords = smoothing === 'rolling_avg'
        ? [['type_of_smoothing', juliaString(smoothing)], ['pt_avg', String(ptAvg)]]
        : smoothing === 'lowess'
        ? [['type_of_smoothing', juliaString(smoothing)], ['thr_lowess', juliaFloat(thrLowess, 0.05)]]
        : smoothing === 'gaussian'
        ? [['type_of_smoothing', juliaString(smoothing)], ['gaussian_h_mult', juliaFloat(gaussianHMult, 2.0)]]
        : [['type_of_smoothing', juliaString(smoothing)]];
    const blankContext = blankExportContext(req, blankSub, blankMethod);
    const blankKeywords = blankContext.keywords;
    const loglinKeywords = juliaKeywordLines([
        ...blankKeywords,
        ...smoothingKeywords,
        ['pt_smoothing_derivative', String(ptDeriv)],
        ['pt_min_size_of_win', String(ptMinWin)],
        ['type_of_win', juliaString(winType)],
        ['threshold_of_exp', juliaFloat(thrExp, 0.9)],
        ['start_exp_win_thr',
            winType === 'global_thr' || winType === 'max_with_min_OD'
                ? juliaFloat(startThr, 0.05) : null],
        ['skip_flat_threshold', juliaFloat(flatThr, 0.02)],
    ]);

    const code = `\
# ================================================================
# Batch log-linear growth-rate fit - exported from GUIbiont
# KinBiont.jl docs: https://github.com/pinheiroGroup/Kinbiont.jl
# Reruns the workflow from local source files; no GUI result is embedded.
# ================================================================

using Kinbiont
using Statistics

const CLEAN_DATA_PATH = "path/to/Clean_data"
const EXPERIMENT = ${juliaString(experiment)}
const OUT_PREFIX = ${juliaString(outPrefix)}
const WELLS = ${juliaStringArray(wells)}

source = load_experiment_data(CLEAN_DATA_PATH, EXPERIMENT)
${blankContext.setup}
data = source.data
batch = kinbiont_batch_loglin(
    data;
    experiment=EXPERIMENT,
    labels=WELLS,
${loglinKeywords}
)

paths = save_batch_loglin_results(batch, "."; prefix=OUT_PREFIX)
println("Saved ", paths.summary)
println("Fitted: ", length(batch.results), "  skipped: ", length(batch.skipped), "  failed: ", length(batch.errors))
`;

    return withComments ? code : stripComments(code);
}

export function generateClusterCode(clusterData, withComments) {
    const req           = clusterData._request || {};
    const k             = req.k ?? 3;
    const smoothMethod  = req.smooth_method ?? 'lowess';
    const smoothPtAvg   = req.smooth_pt_avg ?? 7;
    const lowessFrac    = req.lowess_frac ?? 0.05;
    const gaussianHmult = req.gaussian_h_mult ?? 2.0;
    const clusterMethod = req.cluster_method ?? 'kmeans';
    const maxiter       = req.maxiter ?? 300;
    const tol           = req.tol ?? 1e-6;
    const nInit         = req.kmeans_n_init ?? 3;
    const kmedoidsNInit = req.kmedoids_n_init ?? nInit;
    const blankSub      = req.subtract_blank ?? false;
    const deriveBlanks  = req.derive_non_growing_blanks ?? false;
    const blankMethod   = req.blank_method ?? 'pointbypoint';
    const interpolate   = req.interpolate ?? false;
    const interpN       = req.interp_n ?? 100;
    const interpQLo     = req.interp_quantile_lo ?? 0.05;
    const interpQHi     = req.interp_quantile_hi ?? 0.95;
    const prescreen     = req.prescreen_constant ?? false;
    const prescreenTol  = req.prescreen_tol_const ?? 0.5;
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
    // Curves manually moved into the non-growing cluster via GUIbiont's
    // "Nearest curves" review after clustering. Only emitted when used.
    const transferredLabels  = Array.isArray(clusterData._transferredToNonGrowing)
        ? clusterData._transferredToNonGrowing : [];
    const nonGrowingClusterId = clusterData._nonGrowingClusterId;
    const hasTransfers = transferredLabels.length > 0 && Number.isFinite(nonGrowingClusterId);
    const clusterIdsExpr = hasTransfers ? 'cluster_ids' : 'processed.clusters';
    // Export the selected workflow, not a decision inferred from its result.
    // Re-running the detector on the source data determines whether a sentinel
    // is actually populated.
    const prescreenApplied = deriveBlanks ? false : prescreen;
    const trendApplied = deriveBlanks ? false : trendTest;
    const costLabel = 'WCSS';
    const experimentsLiteral = Array.isArray(req.experiments) && req.experiments.length
        ? juliaStringArray(req.experiments)
        : 'String[]';
    const dataPathLiteral = req.csv_path
        ? juliaString(req.csv_path)
        : req.csv_name
            ? juliaString(req.csv_name)
            : '"path/to/data.csv"';
    const smoothParam = !smoothEnabled ? '' : smoothMethod === 'lowess'
        ? `    # LOWESS bandwidth: fraction of points used for local regression
    lowess_frac   = ${juliaFloat(lowessFrac, 0.05)},`
        : smoothMethod === 'gaussian'
        ? `    # Gaussian bandwidth multiplier (multiplied by median Δt)
    gaussian_h_mult = ${juliaFloat(gaussianHmult, 2.0)},`
        : smoothMethod === 'rolling_avg'
        ? `    # Number of points in the rolling-average window
    smooth_pt_avg = ${smoothPtAvg},`
        : '';

    const prepareKeywords = [
        ['interpolate', interpolate ? 'true' : null],
        ['interp_n', interpolate ? String(interpN) : null],
        ['interp_quantile_lo', interpolate ? juliaFloat(interpQLo, 0.05) : null],
        ['interp_quantile_hi', interpolate ? juliaFloat(interpQHi, 0.95) : null],
        // GUIbiont never performs the legacy automatic low-OD blank removal.
        ['auto_detect_blanks', 'false'],
        ['subtract_blank', blankSub ? 'true' : null],
        ['blank_method', (blankSub || deriveBlanks) ? `:${blankMethod}` : null],
        ['blank_floor', (blankSub || deriveBlanks) ? '1e-4' : null],
        ['derive_non_growing_blanks', deriveBlanks ? 'true' : null],
        ['blank_prescreen_constant', deriveBlanks && prescreen ? 'true' : null],
        ['blank_prescreen_tol', deriveBlanks && prescreen ? juliaFloat(prescreenTol, 0.5) : null],
        ['blank_prescreen_q_low', deriveBlanks && prescreen ? juliaFloat(prescreenQLo, 0.05) : null],
        ['blank_prescreen_q_high', deriveBlanks && prescreen ? juliaFloat(prescreenQHi, 0.95) : null],
        ['blank_trend_test', deriveBlanks && trendTest ? 'true' : null],
        ['blank_trend_p_threshold', deriveBlanks && trendTest ? juliaFloat(trendPThr, 0.05) : null],
        ['detection_smooth', deriveBlanks && smoothEnabled ? 'true' : null],
        ['detection_smooth_method', deriveBlanks && smoothEnabled ? `:${smoothMethod}` : null],
        ['detection_smooth_pt_avg',
            deriveBlanks && smoothEnabled && smoothMethod === 'rolling_avg'
                ? String(smoothPtAvg) : null],
        ['detection_lowess_frac',
            deriveBlanks && smoothEnabled && smoothMethod === 'lowess'
                ? juliaFloat(lowessFrac, 0.05) : null],
        ['detection_gaussian_h_mult',
            deriveBlanks && smoothEnabled && smoothMethod === 'gaussian'
                ? juliaFloat(gaussianHmult, 2.0) : null],
    ];

    const usesK = clusterMethod !== 'dbscan';
    const clusterKeywords = [
        ['cluster', 'true'],
        ['n_clusters', usesK ? 'N_CLUSTER_LABELS' : null],
        ['cluster_method', `:${clusterMethod}`],
        ['kmeans_n_init', clusterMethod === 'kmeans' ? String(nInit) : null],
        ['kmedoids_n_init', clusterMethod === 'kmedoids' ? String(kmedoidsNInit) : null],
        ['kmeans_max_iters',
            clusterMethod === 'kmeans' || clusterMethod === 'kmedoids' ? String(maxiter) : null],
        ['kmeans_tol',
            clusterMethod === 'kmeans' || clusterMethod === 'kmedoids'
                ? juliaFloat(tol, 1e-6) : null],
        ['kmeans_seed', clusterMethod === 'kmeans' ? '42' : null],
        ['kmedoids_seed', clusterMethod === 'kmedoids' ? '42' : null],
        ['cluster_hclust_linkage', clusterMethod === 'hclust' ? `:${hclustLinkage}` : null],
        ['cluster_dbscan_eps', clusterMethod === 'dbscan' ? juliaFloat(dbscanEps, 1.0) : null],
        ['cluster_dbscan_minpts', clusterMethod === 'dbscan' ? String(dbscanMinPts) : null],
        ['cluster_prescreen_constant', prescreenApplied ? 'true' : null],
        ['cluster_tol_const', prescreenApplied ? juliaFloat(prescreenTol, 0.5) : null],
        ['cluster_q_low', prescreenApplied ? juliaFloat(prescreenQLo, 0.05) : null],
        ['cluster_q_high', prescreenApplied ? juliaFloat(prescreenQHi, 0.95) : null],
        // FitOptions defaults this to true, so false is an active override.
        ['cluster_trend_test', trendApplied ? 'true' : 'false'],
        ['cluster_trend_p_thr', trendApplied ? juliaFloat(trendPThr, 0.05) : null],
    ];

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

    const sourceKeywords = isFileMode
        ? [['csv_path', 'DATA_PATH']]
        : [
            ['clean_data_path', 'CLEAN_DATA_PATH'],
            ['experiments', experimentsLiteral],
        ];
    const dataLoadBlock = `# prepare_clustering_data mirrors GUIbiont's source loader
# and includes only the preparation stages enabled for this run.
data = prepare_clustering_data(
${juliaKeywordLines([...sourceKeywords, ...prepareKeywords])}
)`;

    const smoothBlock = smoothEnabled
        ? `# GUIbiont smooths the prepared curves before clustering. Calling preprocess
# once for smoothing and once for clustering preserves that order in Kinbiont.
smooth_opts = FitOptions(
    smooth        = true,
    smooth_method = :${smoothMethod},
${smoothParam}
)
smoothed = preprocess(data, smooth_opts)
tlen = min(size(smoothed.curves, 2), length(smoothed.times))
cluster_data = GrowthData(smoothed.curves[:, 1:tlen], smoothed.times[1:tlen], smoothed.labels)`
        : `# Smoothing was disabled in GUIbiont.
cluster_data = data`;
    const clusterCountBlock = usesK
        ? `# GUIbiont caps k to the number of series after data preparation.
const N_REQUESTED_CLUSTERS = ${k}
const N_CLUSTER_LABELS = min(N_REQUESTED_CLUSTERS, size(cluster_data.curves, 1))
`
        : '';

    const transferBlock = hasTransfers
        ? `

# Curves manually reviewed with "Nearest curves" on the non-growing cluster in
# GUIbiont and confirmed as non-growing after clustering.
TRANSFERRED_TO_NON_GROWING = ${juliaStringArray(transferredLabels)}
NON_GROWING_CLUSTER_ID = ${nonGrowingClusterId}
cluster_ids = reassign_non_growing(
    processed.clusters, cluster_data.labels, TRANSFERRED_TO_NON_GROWING, NON_GROWING_CLUSTER_ID,
)
`
        : '';

    const code = `\
# ================================================================
# Growth curve clustering — exported from GUIbiont
# KinBiont.jl docs: https://github.com/pinheiroGroup/Kinbiont.jl
# Install:  using Pkg; Pkg.add("Kinbiont")
# ================================================================

using Kinbiont

${normalizeNote}${interpolationNote}${blankNote}${autoBlankNote}${trendNote}${dataPathBlock}
${dataLoadBlock}

${smoothBlock}

${clusterCountBlock}

# These options are the clustering controls selected in GUIbiont. Parameters
# that do not apply to the selected algorithm are intentionally omitted.
cluster_opts = FitOptions(
${juliaKeywordLines(clusterKeywords)}
)

processed = preprocess(cluster_data, cluster_opts)${transferBlock}
# Quality indices are computed on the same data that was passed to clustering.
quality = cluster_quality_indices(cluster_data.curves, ${clusterIdsExpr})
quality_summary = Dict(
    "silhouette_mean"   => quality["silhouette_mean"],
    "dunn"              => quality["dunn"],
    "davies_bouldin"    => quality["davies_bouldin"],
    "calinski_harabasz" => quality["calinski_harabasz"],
    "xie_beni"          => quality["xie_beni"],
)

cluster_counts_all = Dict(k => count(==(k), ${clusterIdsExpr})
                          for k in sort(unique(${clusterIdsExpr})))

# Optional diagnostics:
#println("Cluster assignments: ", ${clusterIdsExpr})
println("Cluster counts:      ", cluster_counts_all)
println("${costLabel}: ", processed.wcss)
println("Quality summary:     ", quality_summary)
#println("Quality indices:     ", quality)

# WCSS uses centroid-based squared error for every method and excludes the
# non-growing sentinel and DBSCAN noise. For methods that use k, repeat
# preprocessing over candidate k values to build an elbow plot.
`;

    return withComments ? code : stripComments(code);
}
