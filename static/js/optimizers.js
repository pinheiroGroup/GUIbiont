// Best-of-N optimizer selection UI.
//
// Each panel (single-fit, batch-fit, replicate-fit) renders a mode toggle —
// Single uses one dropdown; Best of N renders checkbox lists for
// deterministic/stochastic optimizers plus a runs-per-stochastic input.
// `buildOptimizerPayload(prefix)` returns the right JSON shape for the
// backend depending on the toggle state.

import { API_BASE } from './state.js';

const OPTIMIZER_LABELS = {
    'LN_BOBYQA':                                 'BOBYQA',
    'LN_COBYLA':                                 'COBYLA',
    'GN_ISRES':                                  'GN ISRES',
    'GN_DIRECT_L':                               'GN DIRECT-L',
    'BBO_adaptive_de_rand_1_bin_radiuslimited':  'BBO Adaptive DE',
};

// Defaults for "Best of N" mode: COBYLA (cheap deterministic baseline) +
// BBO × 3 (the combo that beat single-optimizer fits in our testing).
const DEFAULT_BEST_DETERMINISTIC = ['LN_COBYLA'];
const DEFAULT_BEST_STOCHASTIC    = ['BBO_adaptive_de_rand_1_bin_radiuslimited'];

// HTML prefixes for the panels that have a best-of-N UI. Each prefix
// expects DOM ids: `${prefix}-optimizer-mode`, `${prefix}-optimizer`,
// `${prefix}-optimizer-best-panel`, `${prefix}-det-optimizers`,
// `${prefix}-sto-optimizers`, `${prefix}-sto-runs`.
const PANEL_PREFIXES = ['fit', 'batch-fit'];

let _optimizersCache = null;

export async function loadOptimizers() {
    try {
        const response = await fetch(`${API_BASE}/api/optimizers`);
        if (!response.ok) return;
        _optimizersCache = await response.json();
        PANEL_PREFIXES.forEach(populatePanel);
    } catch (e) {
        console.error('Failed to load optimizers:', e);
    }
}

function populatePanel(prefix) {
    const detSpan = document.getElementById(`${prefix}-det-optimizers`);
    const stoSpan = document.getElementById(`${prefix}-sto-optimizers`);
    if (!detSpan || !stoSpan || !_optimizersCache) return;

    detSpan.innerHTML = '';
    stoSpan.innerHTML = '';

    _optimizersCache.forEach(opt => {
        const target = opt.type === 'stochastic' ? stoSpan : detSpan;
        const defaults = opt.type === 'stochastic'
            ? DEFAULT_BEST_STOCHASTIC
            : DEFAULT_BEST_DETERMINISTIC;
        const checked = defaults.includes(opt.name) ? 'checked' : '';
        const label = OPTIMIZER_LABELS[opt.name] || opt.name;
        const wrap = document.createElement('label');
        wrap.style.cssText = 'display: inline-flex; align-items: center; gap: 4px; margin-right: 10px; cursor: pointer;';
        wrap.innerHTML = `<input type="checkbox" data-optimizer="${opt.name}" data-type="${opt.type}" ${checked}>${label}`;
        target.appendChild(wrap);
    });
}

export function onFitOptimizerModeChange() {
    toggleMode('fit');
}

export function onBatchFitOptimizerModeChange() {
    toggleMode('batch-fit');
}

function toggleMode(prefix) {
    const mode = document.getElementById(`${prefix}-optimizer-mode`).value;
    const single = document.getElementById(`${prefix}-optimizer`);
    const panel  = document.getElementById(`${prefix}-optimizer-best-panel`);
    if (single) single.style.display = mode === 'best' ? 'none' : '';
    if (panel)  panel.style.display  = mode === 'best' ? '' : 'none';
}

// Returns a payload object to merge into the fit-request body.
// In single mode: `{ optimizer: "LN_COBYLA" }`.
// In best-of mode: `{ deterministic_optimizers: [...], stochastic_optimizers: [...], stochastic_runs: N }`.
export function buildOptimizerPayload(prefix) {
    const modeEl = document.getElementById(`${prefix}-optimizer-mode`);
    const mode = modeEl ? modeEl.value : 'single';

    if (mode === 'best') {
        const det = collectChecked(`${prefix}-det-optimizers`);
        const sto = collectChecked(`${prefix}-sto-optimizers`);
        const runs = Math.max(1, parseInt(
            document.getElementById(`${prefix}-sto-runs`)?.value || '3', 10) || 3);
        return {
            deterministic_optimizers: det,
            stochastic_optimizers:    sto,
            stochastic_runs:          runs,
        };
    }

    const single = document.getElementById(`${prefix}-optimizer`);
    return { optimizer: (single && single.value) || 'LN_COBYLA' };
}

function collectChecked(containerId) {
    const container = document.getElementById(containerId);
    if (!container) return [];
    return Array.from(container.querySelectorAll('input[type="checkbox"]:checked'))
        .map(cb => cb.dataset.optimizer);
}
