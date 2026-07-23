import fs from 'node:fs';
globalThis.localStorage = {getItem: () => null, setItem: () => {}};
globalThis.document = {getElementById: () => null, createElement: () => ({})};
const {generateFitCode, generateClusterCode, generateBatchCode} =
  await import('../static/js/code-export.js');

const root = process.env.PARITY_OUT || 'C:/Users/edo01/Desktop/GUIPaper';
const fitRequest = {
  experiment: 'LG166', well: 'A3', model_name: 'logistic', smooth: false,
  blank_subtraction: false, model_names: ['logistic'], optimizer: 'LN_COBYLA',
  deterministic_optimizers: [], stochastic_optimizers: [], stochastic_runs: 1
};
const clusterRequest = {
  experiments: ['LG166'], k: 2, smooth_method: 'none', subtract_blank: false,
  interpolate: false, prescreen_constant: false, trend_test_flat: false,
  cluster_method: 'kmeans', kmeans_n_init: 1, maxiter: 300, tol: 1e-6,
  normalize: false
};
const batchRequest = {
  experiment: 'LG166', wells: ['A3'], model_name: 'logistic', smooth: false,
  blank_subtraction: false, optimizer: 'LN_COBYLA',
  deterministic_optimizers: [], stochastic_optimizers: [], stochastic_runs: 1
};
fs.writeFileSync(`${root}/fit_export.jl`, generateFitCode({_request: fitRequest}, true));
fs.writeFileSync(`${root}/cluster_export.jl`, generateClusterCode({_request: clusterRequest}, true));
fs.writeFileSync(`${root}/batch_export.jl`, generateBatchCode({_request: batchRequest}, true));
