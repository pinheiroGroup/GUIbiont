import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

globalThis.localStorage = { getItem: () => null, setItem: () => {} };
globalThis.document = { getElementById: () => null, createElement: () => ({}) };

const {
    generateFitCode,
    generateFitLogLinKinbiontCode,
    generateBatchCode,
    generateBatchLogLinKinbiontCode,
    generateClusterCode,
} = await import('../static/js/code-export.js');

function includes(code, ...parts) {
    for (const part of parts) assert.ok(code.includes(part), `Expected export to include: ${part}`);
}

function excludes(code, ...parts) {
    for (const part of parts) assert.ok(!code.includes(part), `Expected export to omit: ${part}`);
}

const fitMinimal = generateFitCode({ _request: {
    experiment: 'exp', well: 'A1', model_name: 'logistic',
    optimizer: 'LN_COBYLA', maxiters: 500, abstol: 1e-15,
    smooth: false, compute_loglin: false, blank_subtraction: false,
} }, true);
includes(
    fitMinimal,
    'model_name="logistic"', 'optimizer="LN_COBYLA"', 'abstol=1e-15',
    'source = load_experiment_data(',
);
excludes(
    fitMinimal,
    'model_names=', 'deterministic_optimizers=', 'stochastic_optimizers=', 'stochastic_runs=',
    'smooth=', 'smooth_window=', 'compute_loglin=', 'loglin_pt_', 'blank_subtraction=',
    'blank_method=', 'optimizer_seed=', 'if false', 'const FIT_LABEL', 'load_gui_experiment_data',
);

const fitLoglinGaussian = generateFitLogLinKinbiontCode({ _request: {
    experiment: 'exp', well: 'A1',
    type_of_smoothing: 'gaussian', gaussian_h_mult: 1.5,
    type_of_win: 'global_thr', start_exp_win_thr: 0.08,
    blank_subtraction: true, blank_method: 'pointbypoint',
} }, true);
includes(
    fitLoglinGaussian,
    'result = kinbiont_fit_loglin(', 'type_of_smoothing="gaussian"',
    'gaussian_h_mult=1.5', 'type_of_win="global_thr"',
    'start_exp_win_thr=0.08', 'blank_timeseries=source.blank_timeseries',
);
excludes(fitLoglinGaussian, 'pt_avg=', 'thr_lowess=', 'kinbiont_batch_fit(');

const fitFull = generateFitCode({ _request: {
    experiment: 'exp', well: 'A1', model_names: ['aHPM', 'logistic'],
    deterministic_optimizers: ['LN_COBYLA'],
    stochastic_optimizers: ['BBO_adaptive_de_rand_1_bin_radiuslimited'],
    stochastic_runs: 4, maxiters: 500, abstol: 0.0,
    smooth: true, smooth_window: 5,
    compute_loglin: true, loglin_type_of_smoothing: 'lowess',
    loglin_thr_lowess: 0.2, loglin_type_of_win: 'global_thr',
    loglin_start_exp_win_thr: 0.1, loglin_pt_avg: 5,
    loglin_pt_smoothing_derivative: 6, loglin_pt_min_size_of_win: 7,
    loglin_threshold_of_exp: 1,
    blank_subtraction: true, blank_method: 'pointbypoint',
} }, true);
includes(
    fitFull,
    'model_names=String["aHPM", "logistic"]',
    'deterministic_optimizers=String["LN_COBYLA"]',
    'stochastic_optimizers=String["BBO_adaptive_de_rand_1_bin_radiuslimited"]',
    'stochastic_runs=4', 'optimizer_seed=42', 'smooth=true', 'smooth_window=5',
    'loglin = kinbiont_fit_loglin(', 'type_of_smoothing="lowess"',
    'thr_lowess=0.2', 'type_of_win="global_thr"', 'start_exp_win_thr=0.1',
    'threshold_of_exp=1.0',
    'blank_subtraction=true', 'blank_timeseries=source.blank_timeseries',
);
excludes(
    fitFull,
    '\n    optimizer=', 'compute_loglin=', 'pt_avg=', 'companionLogLinSettings',
);

const fitCompanionNone = generateFitCode({ _request: {
    experiment: 'exp', well: 'A1', model_name: 'logistic',
    compute_loglin: true, loglin_type_of_smoothing: 'NO',
    loglin_type_of_win: 'max_with_min_OD', loglin_start_exp_win_thr: 0.08,
} }, true);
includes(
    fitCompanionNone,
    'type_of_smoothing="NO"', 'type_of_win="max_with_min_OD"',
    'start_exp_win_thr=0.08',
);
excludes(fitCompanionNone, 'pt_avg=', 'thr_lowess=', 'companionLogLinSettings');

const fitCompanionGaussian = generateFitCode({ _request: {
    experiment: 'exp', well: 'A1', model_name: 'logistic',
    compute_loglin: true, loglin_type_of_smoothing: 'gaussian',
    loglin_gaussian_h_mult: 1.5,
} }, true);
includes(
    fitCompanionGaussian,
    'type_of_smoothing="gaussian"', 'gaussian_h_mult=1.5',
);
excludes(fitCompanionGaussian, 'pt_avg=', 'thr_lowess=', 'companionLogLinSettings');

const fitRolling = generateFitCode({ _request: {
    experiment: 'exp', well: 'A1', model_name: 'logistic',
    smooth: true, smooth_method: 'rolling_avg', smooth_pt_avg: 9,
} }, true);
includes(fitRolling, 'smooth=true', 'smooth_method=:rolling_avg', 'smooth_pt_avg=9');
excludes(fitRolling, 'lowess_frac=', 'gaussian_h_mult=', 'smooth_window=');

const fitLowess = generateFitCode({ _request: {
    experiment: 'exp', well: 'A1', model_name: 'logistic',
    smooth: true, smooth_method: 'lowess', lowess_frac: 0.2,
} }, true);
includes(fitLowess, 'smooth=true', 'smooth_method=:lowess', 'lowess_frac=0.2');
excludes(fitLowess, 'smooth_pt_avg=', 'gaussian_h_mult=', 'smooth_window=');

const fitGaussian = generateFitCode({ _request: {
    experiment: 'exp', well: 'A1', model_name: 'logistic',
    smooth: true, smooth_method: 'gaussian', gaussian_h_mult: 1.5,
} }, true);
includes(fitGaussian, 'smooth=true', 'smooth_method=:gaussian', 'gaussian_h_mult=1.5');
excludes(fitGaussian, 'smooth_pt_avg=', 'lowess_frac=', 'smooth_window=');

const fitBbo = generateFitCode({ _request: {
    experiment: 'exp', well: 'A1', model_name: 'logistic',
    optimizer: 'BBO_adaptive_de_rand_1_bin_radiuslimited',
} }, true);
includes(
    fitBbo,
    'optimizer="BBO_adaptive_de_rand_1_bin_radiuslimited"',
    'optimizer_seed=42',
);

const batchMinimal = generateBatchCode({ _request: {
    experiment: 'exp', wells: ['A1'], model_name: 'logistic',
    optimizer: 'LN_COBYLA', smooth: false, compute_loglin: false,
    blank_subtraction: false, skip_flat_threshold: 0,
} }, true);
includes(
    batchMinimal,
    'model_name="logistic"', 'optimizer="LN_COBYLA"', 'skip_flat_threshold=0.0',
    'source = load_experiment_data(', 'paths = save_batch_results(',
);
excludes(
    batchMinimal,
    'model_names=', 'deterministic_optimizers=', 'stochastic_optimizers=', 'stochastic_runs=',
    'smooth=', 'smooth_window=', 'compute_loglin=', 'loglin_pt_', 'blank_subtraction=',
    'blank_method=', 'optimizer_seed=', 'load_gui_experiment_data', 'save_gui_batch_results',
);

const batchBbo = generateBatchCode({ _request: {
    experiment: 'exp', wells: ['A1'], model_name: 'logistic',
    stochastic_optimizers: ['BBO_adaptive_de_rand_1_bin_radiuslimited'],
    stochastic_runs: 3,
} }, true);
includes(
    batchBbo,
    'stochastic_optimizers=String["BBO_adaptive_de_rand_1_bin_radiuslimited"]',
    'stochastic_runs=3',
    'optimizer_seed=42',
);

const batchGaussian = generateBatchCode({ _request: {
    experiment: 'exp', wells: ['A1'], model_name: 'logistic',
    smooth: true, smooth_method: 'gaussian', gaussian_h_mult: 2.5,
} }, true);
includes(batchGaussian, 'smooth=true', 'smooth_method=:gaussian', 'gaussian_h_mult=2.5');
excludes(batchGaussian, 'smooth_pt_avg=', 'lowess_frac=', 'smooth_window=');

const batchCompanionRolling = generateBatchCode({ _request: {
    experiment: 'exp', wells: ['A1'], model_name: 'logistic',
    compute_loglin: true, loglin_type_of_smoothing: 'rolling_avg',
    loglin_pt_avg: 9, loglin_type_of_win: 'maximum',
} }, true);
includes(
    batchCompanionRolling,
    'loglin_batch = kinbiont_batch_loglin(',
    'type_of_smoothing="rolling_avg"', 'pt_avg=9', 'type_of_win="maximum"',
    'save_batch_loglin_results(',
);
excludes(
    batchCompanionRolling,
    'compute_loglin=', 'thr_lowess=', 'start_exp_win_thr=', 'companionLogLinSettings',
);

const batchCompanionGaussian = generateBatchCode({ _request: {
    experiment: 'exp', wells: ['A1'], model_name: 'logistic',
    compute_loglin: true, loglin_type_of_smoothing: 'gaussian',
    loglin_gaussian_h_mult: 2.5,
} }, true);
includes(
    batchCompanionGaussian,
    'loglin_batch = kinbiont_batch_loglin(',
    'type_of_smoothing="gaussian"', 'gaussian_h_mult=2.5',
);
excludes(batchCompanionGaussian, 'pt_avg=', 'thr_lowess=', 'companionLogLinSettings');

const batchLoglinRolling = generateBatchLogLinKinbiontCode({ _request: {
    experiment: 'exp', wells: ['A1'], type_of_smoothing: 'rolling_avg',
    pt_avg: 9, blank_subtraction: false,
} }, true);
includes(
    batchLoglinRolling,
    'type_of_smoothing="rolling_avg"', 'pt_avg=9',
    'source = load_experiment_data(', 'paths = save_batch_loglin_results(',
);
excludes(
    batchLoglinRolling,
    'thr_lowess=', 'start_exp_win_thr=', 'blank_subtraction=', 'blank_method=',
    'load_gui_experiment_data', 'save_gui_batch_loglin_results',
);

const batchLoglinLowess = generateBatchLogLinKinbiontCode({ _request: {
    experiment: 'exp', wells: ['A1'], type_of_smoothing: 'lowess',
    pt_avg: 9, thr_lowess: 1, blank_subtraction: true, blank_method: 'shift',
} }, true);
includes(
    batchLoglinLowess,
    'type_of_smoothing="lowess"', 'thr_lowess=1.0',
    'blank_subtraction=true', 'blank_method="shift"', 'blank_value=source.blank_value',
);
excludes(batchLoglinLowess, 'pt_avg=', 'start_exp_win_thr=', 'blank_timeseries=');

const batchLoglinGaussian = generateBatchLogLinKinbiontCode({ _request: {
    experiment: 'exp', wells: ['A1'], type_of_smoothing: 'gaussian',
    gaussian_h_mult: 1.5,
} }, true);
includes(batchLoglinGaussian, 'type_of_smoothing="gaussian"', 'gaussian_h_mult=1.5');
excludes(batchLoglinGaussian, 'pt_avg=', 'thr_lowess=');

const batchLoglinThreshold = generateBatchLogLinKinbiontCode({ _request: {
    experiment: 'exp', wells: ['A1'], type_of_smoothing: 'NO',
    type_of_win: 'global_thr', start_exp_win_thr: 1,
} }, true);
includes(batchLoglinThreshold, 'type_of_smoothing="NO"', 'start_exp_win_thr=1.0');
excludes(batchLoglinThreshold, 'pt_avg=', 'thr_lowess=');

const clusterLowess = generateClusterCode({ _request: {
    _mode: 'file', csv_path: 'data.csv', k: 3,
    smooth_method: 'lowess', lowess_frac: 0.05, gaussian_h_mult: 2,
    cluster_method: 'kmeans', maxiter: 300, tol: 1e-6, kmeans_n_init: 3,
    subtract_blank: false, derive_non_growing_blanks: false,
    interpolate: false, prescreen_constant: true, prescreen_tol_const: 1.7,
    prescreen_q_low: 0.1, prescreen_q_high: 0.9,
    trend_test_flat: false,
} }, true);
includes(
    clusterLowess,
    'lowess_frac   = 0.05', 'cluster_method=:kmeans',
    'kmeans_n_init=3', 'kmeans_seed=42', 'cluster_prescreen_constant=true',
    'cluster_trend_test=false',
);
excludes(
    clusterLowess,
    'gaussian_h_mult', 'detection_smooth', 'interp_n=', 'interp_quantile_',
    'kmedoids_seed', 'cluster_hclust_linkage', 'cluster_dbscan_',
    'PRESCREEN_CONSTANT', 'assignment_rows', 'smooth_pt_avg',
);

const clusterRolling = generateClusterCode({ _request: {
    _mode: 'file', csv_path: 'data.csv', k: 3,
    smooth_method: 'rolling_avg', smooth_pt_avg: 11,
    cluster_method: 'kmeans', maxiter: 300, tol: 1e-6, kmeans_n_init: 3,
    subtract_blank: false, derive_non_growing_blanks: false,
    interpolate: false, prescreen_constant: false, trend_test_flat: false,
} }, true);
includes(clusterRolling, 'smooth_method = :rolling_avg', 'smooth_pt_avg = 11');
excludes(clusterRolling, 'lowess_frac', 'gaussian_h_mult');

const clusterRollingDerived = generateClusterCode({ _request: {
    _mode: 'file', csv_name: 'uploaded_curves.csv', k: 2,
    smooth_method: 'rolling_avg', smooth_pt_avg: 11,
    cluster_method: 'kmeans', maxiter: 100, tol: 1e-6, kmeans_n_init: 3,
    derive_non_growing_blanks: true, prescreen_constant: true,
    trend_test_flat: false, blank_method: 'pointbypoint',
} }, true);
includes(
    clusterRollingDerived,
    'const DATA_PATH = "uploaded_curves.csv"',
    'detection_smooth_method=:rolling_avg', 'detection_smooth_pt_avg=11',
);
excludes(clusterRollingDerived, 'detection_lowess_frac', 'detection_gaussian_h_mult');

const clusterGaussianDerived = generateClusterCode({ _request: {
    _mode: 'file', csv_path: 'data.csv', k: 2,
    smooth_method: 'gaussian', lowess_frac: 0.2, gaussian_h_mult: 2,
    cluster_method: 'kmedoids', maxiter: 20, tol: 1,
    subtract_blank: true, blank_method: 'pointbypoint',
    derive_non_growing_blanks: true, prescreen_constant: true,
    prescreen_tol_const: 2, prescreen_q_low: 0, prescreen_q_high: 1,
    trend_test_flat: true, trend_p_thr: 1,
} }, true);
includes(
    clusterGaussianDerived,
    'gaussian_h_mult = 2.0', 'detection_gaussian_h_mult=2.0',
    'blank_prescreen_tol=2.0', 'blank_trend_p_threshold=1.0',
    'kmeans_tol=1.0', 'kmedoids_seed=42', 'cluster_trend_test=false',
);
excludes(
    clusterGaussianDerived,
    'lowess_frac', 'detection_lowess_frac', 'kmeans_n_init', 'kmeans_seed',
    'cluster_prescreen_constant', 'smooth_pt_avg',
);

const clusterDbscan = generateClusterCode({ _request: {
    _mode: 'file', csv_path: 'data.csv', k: 99,
    smooth_method: 'none', cluster_method: 'dbscan',
    dbscan_eps: 1, dbscan_min_pts: 4,
    subtract_blank: false, derive_non_growing_blanks: false,
    prescreen_constant: false, trend_test_flat: false,
} }, true);
includes(
    clusterDbscan,
    'cluster_method=:dbscan', 'cluster_dbscan_eps=1.0',
    'cluster_dbscan_minpts=4', 'cluster_trend_test=false',
);
excludes(
    clusterDbscan,
    'N_REQUESTED_CLUSTERS', 'N_CLUSTER_LABELS', 'n_clusters=',
    'kmeans_', 'kmedoids_seed', 'cluster_hclust_linkage', 'cluster_prescreen_constant',
    'smooth_opts',
);

const clusterHclust = generateClusterCode({ _request: {
    experiments: ['exp'], k: 2, smooth_method: 'none',
    cluster_method: 'hclust', hclust_linkage: 'average',
} }, true);
includes(clusterHclust, 'cluster_method=:hclust', 'cluster_hclust_linkage=:average');
excludes(clusterHclust, 'kmeans_', 'kmedoids_seed', 'cluster_dbscan_');

const compactScripts = {
    fit_compact: generateFitCode({ _request: {
        experiment: 'exp', well: 'A1', model_name: 'logistic',
        optimizer: 'LN_COBYLA', smooth: false, compute_loglin: false,
    } }, false),
    batch_compact: generateBatchCode({ _request: {
        experiment: 'exp', wells: ['A1'], model_name: 'logistic',
        optimizer: 'LN_COBYLA', smooth: false, compute_loglin: false,
    } }, false),
    batch_loglin_compact: generateBatchLogLinKinbiontCode({ _request: {
        experiment: 'exp', wells: ['A1'], type_of_smoothing: 'lowess',
        thr_lowess: 0.05,
    } }, false),
    cluster_compact: generateClusterCode({ _request: {
        _mode: 'file', csv_path: 'data.csv', k: 3,
        smooth_method: 'lowess', lowess_frac: 0.05,
        cluster_method: 'kmeans', maxiter: 300, tol: 1e-6,
        kmeans_n_init: 3, prescreen_constant: false, trend_test_flat: false,
    } }, false),
};
for (const code of Object.values(compactScripts)) {
    assert.ok(!code.split('\n').some(line => line.trimStart().startsWith('#')));
}

if (process.env.CODE_EXPORT_TEST_OUT) {
    fs.mkdirSync(process.env.CODE_EXPORT_TEST_OUT, { recursive: true });
    const scripts = {
        fit_minimal: fitMinimal,
        fit_full: fitFull,
        fit_loglin_gaussian: fitLoglinGaussian,
        fit_companion_none: fitCompanionNone,
        fit_bbo: fitBbo,
        batch_minimal: batchMinimal,
        batch_bbo: batchBbo,
        batch_companion_rolling: batchCompanionRolling,
        batch_loglin_rolling: batchLoglinRolling,
        batch_loglin_lowess: batchLoglinLowess,
        batch_loglin_threshold: batchLoglinThreshold,
        cluster_lowess: clusterLowess,
        cluster_gaussian_derived: clusterGaussianDerived,
        cluster_dbscan: clusterDbscan,
        cluster_hclust: clusterHclust,
        ...compactScripts,
    };
    for (const [name, code] of Object.entries(scripts)) {
        fs.writeFileSync(path.join(process.env.CODE_EXPORT_TEST_OUT, `${name}.jl`), code);
    }
}

console.log('code export tests passed');
