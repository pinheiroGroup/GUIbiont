import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
globalThis.localStorage = {getItem: () => null, setItem: () => {}};
globalThis.document = {getElementById: () => null, createElement: () => ({})};
const {generateFitCode, generateClusterCode, generateBatchCode} =
  await import('../static/js/code-export.js');

// Where the generated .jl files land. Override with PARITY_OUT; by default
// write to a sibling folder of the repo so nothing lands inside the checkout.
const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const root = process.env.PARITY_OUT ||
  path.join(scriptDir, '..', '..', 'GUIbiont-parity-out');
fs.mkdirSync(root, {recursive: true});
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
