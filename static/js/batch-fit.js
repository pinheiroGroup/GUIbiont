import { state, API_BASE } from './state.js';
import { buildOptimizerPayload } from './optimizers.js?v=20260722-5';

// Models pre-checked in "compare" mode by default
const DEFAULT_COMPARE_MODELS = new Set([
    'aHPM', 'logistic', 'gompertz', 'baranyi_richards', 'NL_Gompertz', 'NL_logistic'
]);
const DEFAULT_BATCH_FIT_ABSTOL = '1e-15';

// ---------------------------------------------------------------------------
// Batch fit tab — experiment / well selection
// ---------------------------------------------------------------------------

async function initBatchFitTab() {
    const abstolSelect = document.getElementById('batch-fit-abstol');
    if (abstolSelect) abstolSelect.value = DEFAULT_BATCH_FIT_ABSTOL;
    onBatchFitMethodChange();
    onBatchFitSmoothingChange();
    onBatchLogLinCompanionChange();
    onBatchLogLinSmoothingChange();
    onBatchLogLinWindowTypeChange();
    await loadBatchFitModels();
    await loadBatchFitExperiments();
}

async function loadBatchFitModels() {
    try {
        const r = await fetch(`${API_BASE}/api/models`);
        if (!r.ok) return;
        const models = await r.json();

        // Single-model dropdown
        const sel = document.getElementById('batch-fit-model');
        sel.innerHTML = '';
        models.forEach(m => {
            const opt = document.createElement('option');
            opt.value = m.name;
            opt.textContent = `${m.name}  (${m.param_names.length} params)`;
            if (m.name === 'aHPM') opt.selected = true;
            sel.appendChild(opt);
        });

        // Multi-model checklist
        const grid = document.getElementById('batch-model-checkboxes');
        grid.innerHTML = '';
        models.forEach(m => {
            const label = document.createElement('label');
            label.className = 'batch-model-cb-label';
            const checked = DEFAULT_COMPARE_MODELS.has(m.name) ? 'checked' : '';
            label.innerHTML = `
                <input type="checkbox" class="batch-model-cb" value="${m.name}" ${checked}>
                <span>${m.name}</span><span class="batch-model-nparams">${m.param_names.length}p</span>
            `;
            grid.appendChild(label);
        });
    } catch (e) {
        console.error('Failed to load models for batch fit:', e);
    }
}

function onBatchModeChange() {
    const mode = document.querySelector('input[name="batch-fit-mode"]:checked').value;
    document.getElementById('batch-single-model-wrap').style.display = mode === 'single' ? 'block' : 'none';
    document.getElementById('batch-multi-model-wrap').style.display  = mode === 'multi'  ? 'block' : 'none';
}

// Toggle between the parametric batch fit (existing /api/batch-fit) and the
// log-linear-only batch fit (/api/batch-fit-loglin). Hides controls that
// don't apply to the selected method and updates the run-button label.
function onBatchFitMethodChange() {
    const method = document.querySelector('input[name="batch-fit-method"]:checked').value;
    const isLoglin = method === 'loglin';

    _placeBatchLogLinOptions(isLoglin);

    document.getElementById('batch-parametric-wrap').style.display = isLoglin ? 'none' : 'block';
    document.getElementById('batch-loglin-wrap').style.display     = isLoglin ? 'block' : 'none';

    // Hide optimizer/maxiters/tolerance — irrelevant for log-lin.
    const optimizationPanel = document.getElementById('batch-fit-optimization-options');
    if (optimizationPanel) optimizationPanel.style.display = isLoglin ? 'none' : 'block';

    // Best-of-N is irrelevant for log-lin. Restore its previous mode when the
    // user switches back to parametric fitting.
    const bestPanel = document.getElementById('batch-fit-optimizer-best-panel');
    if (bestPanel) {
        const bestSelected = document.getElementById('batch-fit-optimizer-mode')?.value === 'best';
        bestPanel.style.display = !isLoglin && bestSelected ? '' : 'none';
    }

    const btn = document.getElementById('batch-fit-run-btn');
    if (btn) btn.textContent = isLoglin ? '⚡ Run log-linear batch fit' : '⚡ Run Batch Fit';

    const companionEnabled = document.getElementById('batch-fit-also-loglin')?.checked || false;
    if (!isLoglin && !companionEnabled) {
        document.getElementById('batch-loglin-options').style.display = 'none';
    }
}

function toggleBatchLogLinOptions() {
    const panel = document.getElementById('batch-loglin-options');
    onBatchLogLinSmoothingChange();
    onBatchLogLinWindowTypeChange();
    panel.style.display = panel.style.display === 'none' ? 'block' : 'none';
}

function onBatchFitSmoothingChange() {
    const method = document.getElementById('batch-fit-smooth-method')?.value || 'none';
    const rolling = document.getElementById('batch-fit-rolling-param');
    const lowess = document.getElementById('batch-fit-lowess-param');
    const gaussian = document.getElementById('batch-fit-gaussian-param');
    if (rolling) rolling.style.display = method === 'rolling_avg' ? 'flex' : 'none';
    if (lowess) lowess.style.display = method === 'lowess' ? 'flex' : 'none';
    if (gaussian) gaussian.style.display = method === 'gaussian' ? 'flex' : 'none';
}

function onBatchLogLinSmoothingChange() {
    const method = document.getElementById('batch-loglin-smoothing')?.value || 'rolling_avg';
    const rollingField = document.getElementById('batch-loglin-pt-avg-field');
    const lowessField = document.getElementById('batch-loglin-lowess-field');
    const gaussianField = document.getElementById('batch-loglin-gaussian-field');
    if (rollingField) rollingField.style.display = method === 'rolling_avg' ? 'flex' : 'none';
    if (lowessField) lowessField.style.display = method === 'lowess' ? 'flex' : 'none';
    if (gaussianField) gaussianField.style.display = method === 'gaussian' ? 'flex' : 'none';
}

function onBatchLogLinWindowTypeChange() {
    const winType = document.getElementById('batch-loglin-win-type')?.value || 'maximum';
    const startField = document.getElementById('batch-loglin-start-thr-field');
    if (startField) {
        startField.style.display =
            winType === 'global_thr' || winType === 'max_with_min_OD' ? 'flex' : 'none';
    }
}

function _placeBatchLogLinOptions(isLoglin) {
    const panel = document.getElementById('batch-loglin-options');
    const anchorId = isLoglin
        ? 'batch-loglin-options-standalone-anchor'
        : 'batch-loglin-options-parametric-anchor';
    const anchor = document.getElementById(anchorId);
    if (panel.parentElement !== anchor) anchor.appendChild(panel);
}

function onBatchLogLinCompanionChange() {
    const enabled = document.getElementById('batch-fit-also-loglin').checked;
    _placeBatchLogLinOptions(false);
    const optionsBtn = document.getElementById('batch-companion-loglin-options-btn');
    optionsBtn.disabled = !enabled;
    document.getElementById('batch-loglin-options').style.display = enabled ? 'block' : 'none';
}

function selectAllBatchModels() {
    document.querySelectorAll('.batch-model-cb').forEach(cb => cb.checked = true);
}

function clearAllBatchModels() {
    document.querySelectorAll('.batch-model-cb').forEach(cb => cb.checked = false);
}

async function loadBatchFitExperiments() {
    const sel = document.getElementById('batch-fit-experiment');
    if (!state.experimentInfo || state.experimentInfo.length === 0) return;
    sel.innerHTML = '<option value="">Select Experiment</option>';
    state.experimentInfo.forEach(exp => {
        const opt = document.createElement('option');
        opt.value = exp;
        opt.textContent = exp;
        sel.appendChild(opt);
    });
}

async function onBatchExperimentChange() {
    const experiment = document.getElementById('batch-fit-experiment').value;
    const wellsDiv   = document.getElementById('batch-fit-wells');
    const runBtn     = document.getElementById('batch-fit-run-btn');
    const countEl    = document.getElementById('batch-fit-well-count');

    wellsDiv.innerHTML = '';
    runBtn.disabled = true;
    countEl.textContent = '';

    if (!experiment) return;

    try {
        const r = await fetch(`${API_BASE}/api/experiment/${experiment}/info`);
        const info = await r.json();
        if (!info.wells) return;

        // Only non-blank wells
        const wells = info.wells.filter(w => w.condition !== 'b' && w.condition !== 'X');
        wells.forEach(w => {
            const label = document.createElement('label');
            label.className = 'batch-well-label';
            label.innerHTML = `
                <input type="checkbox" class="batch-well-cb" value="${w.well}" checked>
                <span class="batch-well-name">${w.well}</span>
                <span class="batch-well-cond">${w.condition || ''}</span>
            `;
            wellsDiv.appendChild(label);
        });

        updateBatchWellCount();
        document.querySelectorAll('.batch-well-cb').forEach(cb =>
            cb.addEventListener('change', updateBatchWellCount));
        runBtn.disabled = false;

    } catch (e) {
        console.error('Error loading wells for batch fit:', e);
    }
}

function updateBatchWellCount() {
    const checked = document.querySelectorAll('.batch-well-cb:checked').length;
    const total   = document.querySelectorAll('.batch-well-cb').length;
    document.getElementById('batch-fit-well-count').textContent =
        `${checked} / ${total} wells selected`;
    document.getElementById('batch-fit-run-btn').disabled = checked === 0;
}

function selectAllBatchWells() {
    document.querySelectorAll('.batch-well-cb').forEach(cb => cb.checked = true);
    updateBatchWellCount();
}

function clearAllBatchWells() {
    document.querySelectorAll('.batch-well-cb').forEach(cb => cb.checked = false);
    updateBatchWellCount();
}

// ---------------------------------------------------------------------------
// Run batch fit
// ---------------------------------------------------------------------------

// Read the log-lin parameters with safe defaults. The standalone batch
// endpoint accepts the complete Kinbiont option set; the parametric companion
// consumes the compatible subset below.
function _readLoglinParams() {
    const intOr = (id, dflt) => {
        const v = parseInt(document.getElementById(id)?.value || '', 10);
        return Number.isFinite(v) && v > 0 ? v : dflt;
    };
    const fltOr = (id, dflt) => {
        const v = parseFloat(document.getElementById(id)?.value || '');
        return Number.isFinite(v) ? v : dflt;
    };
    return {
        type_of_smoothing:       document.getElementById('batch-loglin-smoothing')?.value || 'rolling_avg',
        type_of_win:             document.getElementById('batch-loglin-win-type')?.value || 'maximum',
        pt_avg:                  intOr('batch-loglin-pt-avg', 7),
        pt_smoothing_derivative: intOr('batch-loglin-pt-deriv', 7),
        pt_min_size_of_win:      intOr('batch-loglin-pt-min-win', 7),
        threshold_of_exp:        Math.max(0, Math.min(1, fltOr('batch-loglin-thr-exp', 0.9))),
        start_exp_win_thr:       Math.max(0, fltOr('batch-loglin-start-thr', 0.05)),
        thr_lowess:              Math.max(0.01, Math.min(1, fltOr('batch-loglin-thr-lowess', 0.05))),
        gaussian_h_mult:         Math.max(0.1, Math.min(20, fltOr('batch-loglin-gaussian-hmult', 2.0))),
    };
}

async function runBatchFit() {
    const experiment = document.getElementById('batch-fit-experiment').value;
    const method = document.querySelector('input[name="batch-fit-method"]:checked')?.value || 'parametric';
    const mode = document.querySelector('input[name="batch-fit-mode"]:checked').value;
    const wells = Array.from(document.querySelectorAll('.batch-well-cb:checked')).map(cb => cb.value);
    const runBtn = document.getElementById('batch-fit-run-btn');
    const progressEl  = document.getElementById('batch-fit-progress');
    const progressBar = document.getElementById('batch-fit-progress-bar');
    const progressLbl = document.getElementById('batch-fit-progress-label');
    const progressPct = document.getElementById('batch-fit-progress-pct');

    if (!experiment || wells.length === 0) {
        alert('Please select an experiment and at least one well.');
        return;
    }

    let modelPayload = {};
    if (method === 'parametric') {
        if (mode === 'single') {
            modelPayload.model_name = document.getElementById('batch-fit-model').value || 'aHPM';
        } else {
            const selected = Array.from(document.querySelectorAll('.batch-model-cb:checked')).map(cb => cb.value);
            if (selected.length === 0) { alert('Select at least one model to compare.'); return; }
            if (selected.length === 1) {
                modelPayload.model_name = selected[0];
            } else {
                modelPayload.model_names = selected;
            }
        }
    }

    const originalBtnLabel = runBtn.textContent;
    runBtn.disabled = true;
    runBtn.textContent = '⏳ Fitting…';
    progressEl.style.display = 'block';
    progressBar.value = 0;
    progressBar.max = 100;
    progressLbl.textContent = `Starting…`;
    progressPct.textContent = '';
    document.getElementById('batch-fit-results').style.display = 'none';
    const batchExportBtn = document.getElementById('batch-export-btn');
    if (batchExportBtn) batchExportBtn.style.display = 'none';

    try {
        const batchCalFile = (document.getElementById('batch-fit-calibration-file')?.value || '').trim();
        const skipFlat = Math.max(0, parseFloat(document.getElementById('batch-fit-skip-flat')?.value || '0.02') || 0);

        let endpoint, requestPayload;
        if (method === 'loglin') {
            const ll = _readLoglinParams();
            endpoint = '/api/batch-fit-loglin';
            requestPayload = {
                experiment,
                wells,
                blank_subtraction: document.getElementById('batch-fit-blank-subtraction').checked,
                blank_method:      document.getElementById('batch-fit-blank-method').value,
                override_blank_wells: state._acceptedBlankWells || [],
                skip_flat_threshold: skipFlat,
                ...ll,
            };
        } else {
            const maxiters = Math.max(1, parseInt(document.getElementById('batch-fit-maxiters')?.value || '100000', 10) || 100000);
            const abstol = parseFloat(document.getElementById('batch-fit-abstol')?.value || DEFAULT_BATCH_FIT_ABSTOL) || parseFloat(DEFAULT_BATCH_FIT_ABSTOL);
            const alsoLoglin = document.getElementById('batch-fit-also-loglin')?.checked || false;
            const ll = alsoLoglin ? _readLoglinParams() : null;
            const smoothMethod = document.getElementById('batch-fit-smooth-method')?.value || 'none';
            const smoothPtAvg = Math.min(99, Math.max(
                3,
                parseInt(document.getElementById('batch-fit-smooth-pt-avg')?.value || '7', 10) || 7
            ));
            const lowessFrac = Math.min(1, Math.max(
                0.01,
                parseFloat(document.getElementById('batch-fit-lowess-frac')?.value || '0.05') || 0.05
            ));
            const gaussianHMult = Math.min(20, Math.max(
                0.1,
                parseFloat(document.getElementById('batch-fit-gaussian-hmult')?.value || '2.0') || 2.0
            ));
            endpoint = '/api/batch-fit';
            requestPayload = {
                experiment,
                wells,
                ...modelPayload,
                blank_subtraction: document.getElementById('batch-fit-blank-subtraction').checked,
                blank_method: document.getElementById('batch-fit-blank-method').value,
                override_blank_wells: state._acceptedBlankWells || [],
                ...buildOptimizerPayload('batch-fit'),
                maxiters,
                abstol,
                smooth: smoothMethod !== 'none',
                smooth_method: smoothMethod,
                smooth_pt_avg: smoothPtAvg,
                lowess_frac: lowessFrac,
                gaussian_h_mult: gaussianHMult,
                skip_flat_threshold: skipFlat,
                ...(batchCalFile ? { calibration_file: batchCalFile } : {}),
                ...(alsoLoglin ? {
                    compute_loglin: true,
                    loglin_type_of_smoothing:        ll.type_of_smoothing,
                    loglin_type_of_win:              ll.type_of_win,
                    loglin_pt_avg:                   ll.pt_avg,
                    loglin_pt_smoothing_derivative:  ll.pt_smoothing_derivative,
                    loglin_pt_min_size_of_win:       ll.pt_min_size_of_win,
                    loglin_threshold_of_exp:         ll.threshold_of_exp,
                    loglin_start_exp_win_thr:        ll.start_exp_win_thr,
                    loglin_thr_lowess:                ll.thr_lowess,
                    loglin_gaussian_h_mult:           ll.gaussian_h_mult,
                } : {}),
            };
        }

        const startResp = await fetch(`${API_BASE}${endpoint}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(requestPayload),
        });

        if (!startResp.ok) {
            const err = await startResp.json();
            throw new Error(err.error || 'Batch fitting failed');
        }

        const { job_id, total } = await startResp.json();

        await new Promise((resolve, reject) => {
            const poll = setInterval(async () => {
                try {
                    const progResp = await fetch(`${API_BASE}/api/batch-fit/progress/${job_id}`);
                    if (!progResp.ok) { clearInterval(poll); reject(new Error('Progress check failed')); return; }
                    const p = await progResp.json();

                    const pct = total > 0 ? Math.round((p.completed / total) * 100) : 0;
                    progressBar.value = pct;
                    progressPct.textContent = `${pct}%`;
                    if (p.current_well) {
                        progressLbl.textContent = `Fitting ${p.current_well} (${p.completed + 1}/${total})`;
                    } else {
                        progressLbl.textContent = `${p.completed}/${total} fitted`;
                    }

                    if (p.status === 'done') {
                        clearInterval(poll);
                        progressBar.value = 100;
                        progressPct.textContent = '100%';
                        progressLbl.textContent = `Done — ${p.summary.success}/${total} converged`;
                        state.lastBatchFitData = { ...p, _request: requestPayload };
                        displayBatchResults(state.lastBatchFitData);
                        resolve();
                    }
                } catch (e) {
                    clearInterval(poll);
                    reject(e);
                }
            }, 500);
        });

    } catch (e) {
        console.error('Batch fit error:', e);
        alert(`Error: ${e.message}`);
    } finally {
        runBtn.disabled = false;
        runBtn.textContent = originalBtnLabel || '⚡ Run Batch Fit';
        setTimeout(() => { progressEl.style.display = 'none'; }, 2000);
    }
}

// ---------------------------------------------------------------------------
// Display results
// ---------------------------------------------------------------------------

// Format a numeric value or return "—" for null/undefined/NaN.
function _fmtNum(v, digits = 4) {
    if (v == null) return '—';
    const n = Number(v);
    return Number.isFinite(n) ? n.toFixed(digits) : '—';
}

function displayBatchResults(data) {
    const exportBtn = document.getElementById('batch-export-btn');
    if (exportBtn) exportBtn.style.display = '';
    const resultsDiv = document.getElementById('batch-fit-results');
    const { experiment, model, model_names, summary, results } = data;
    const isLoglin = model === 'log_lin';
    const modelLabel = isLoglin
        ? 'log-linear μ_max'
        : (model === 'multi' ? `AICc from: ${(model_names || []).join(', ')}` : model);

    // Summary bar
    const skippedCount = summary.skipped || 0;
    const summaryHtml = `
        <div class="batch-summary-bar">
            <span><strong>Experiment:</strong> ${experiment}</span>
            <span><strong>Method:</strong> ${modelLabel}</span>
            <span class="batch-stat-ok">✓ ${summary.success} fitted</span>
            ${summary.failed > 0 ? `<span class="batch-stat-err">✗ ${summary.failed} failed</span>` : ''}
            ${skippedCount > 0 ? `<span style="color:#6c757d;">⊘ ${skippedCount} skipped (flat)</span>` : ''}
            <button class="btn" style="margin-left:auto;" onclick="downloadBatchCSV()">📥 Download CSV</button>
            <button class="btn" onclick="downloadBatchFittedCurvesCSV()">📈 Download fitted curves</button>
        </div>
    `;

    // Log-lin and parametric results have different row shapes — branch the
    // table rendering rather than try to unify them.
    let headerHtml, rowsHtml;
    if (isLoglin) {
        const headers = ['Well', 'μ_max', '1σ', 'R²', 't_exp_start', 't_exp_end',
                         'Doubling time', 'Lag (h)', 'N_max (stationary cutoff)', 'Converged'];
        headerHtml = headers.map(h => `<th>${h}</th>`).join('');
        rowsHtml = results.map(r => `
            <tr>
                <td>${r.well}</td>
                <td>${_fmtNum(r.gr_loglin)}</td>
                <td>${_fmtNum(r.gr_loglin_se)}</td>
                <td>${_fmtNum(r.R_squared_loglin)}</td>
                <td>${_fmtNum(r.t_exp_start_loglin, 2)}</td>
                <td>${_fmtNum(r.t_exp_end_loglin, 2)}</td>
                <td>${_fmtNum(r.doubling_time_loglin, 2)}</td>
                <td>${_fmtNum(r.lag_loglin, 2)}</td>
                <td>${_fmtNum(r.N_max_emp, 3)}</td>
                <td>${r.loglin_converged ? '✓' : '✗'}</td>
            </tr>
        `).join('');
    } else {
        // Collect all unique param names across results for table headers
        const allParamNames = [];
        results.forEach(r => {
            (r.param_names || []).forEach(n => {
                if (!allParamNames.includes(n)) allParamNames.push(n);
            });
        });

        // When the companion log-lin field is present, surface μ_max alongside
        // the parametric parameters so the user can compare them inline.
        const anyCompanion = results.some(r => r.loglin_converged === true ||
                                                Number.isFinite(r.gr_loglin));
        const extraCols = anyCompanion ? ['μ_max (log-lin)', 'R² (log-lin)'] : [];

        const headerCells = ['Well', 'Model', ...allParamNames, ...extraCols,
                             'Stationary phase start', 'AICc'];
        headerHtml = headerCells.map(h => `<th>${h}</th>`).join('');

        rowsHtml = results.map(r => {
            const paramCells = allParamNames.map(name => {
                const idx = (r.param_names || []).indexOf(name);
                const val = idx >= 0 && r.parameters && r.parameters[idx] != null
                    ? Number(r.parameters[idx]).toFixed(4) : '—';
                return `<td>${val}</td>`;
            }).join('');
            const extraCells = anyCompanion ? `
                <td>${_fmtNum(r.gr_loglin)}</td>
                <td>${_fmtNum(r.R_squared_loglin)}</td>` : '';
            const statStart = r.stationary_phase_start != null
                ? Number(r.stationary_phase_start).toFixed(2) : '—';
            const aic = r.aic != null ? Number(r.aic).toFixed(2) : '—';
            return `<tr>
                <td>${r.well}</td>
                <td><span class="batch-model-tag">${r.model || model}</span></td>
                ${paramCells}
                ${extraCells}
                <td>${statStart}</td>
                <td>${aic}</td>
            </tr>`;
        }).join('');
    }

    // Errors section
    const errorsHtml = summary.errors && summary.errors.length > 0
        ? `<div class="batch-errors">
               <strong>⚠ ${summary.errors.length} well(s) failed:</strong>
               <ul>${summary.errors.map(e => `<li>${e}</li>`).join('')}</ul>
           </div>`
        : '';

    const skippedList = Array.isArray(data.skipped) ? data.skipped : [];
    const skippedHtml = skippedList.length > 0
        ? `<details style="margin-top:8px; color:#6c757d;">
               <summary style="cursor:pointer;">⊘ ${skippedList.length} well(s) skipped (flat curves, not fit)</summary>
               <ul style="margin-top:4px; font-size:0.9em;">${skippedList.map(s => `<li>${s.well}: ${s.reason}</li>`).join('')}</ul>
           </details>`
        : '';

    resultsDiv.innerHTML = `
        ${summaryHtml}
        <div class="batch-table-wrap">
            <table class="batch-results-table">
                <thead><tr>${headerHtml}</tr></thead>
                <tbody>${rowsHtml}</tbody>
            </table>
        </div>
        ${errorsHtml}
        ${skippedHtml}
    `;
    resultsDiv.style.display = 'block';
}

// ---------------------------------------------------------------------------
// CSV download (client-side)
// ---------------------------------------------------------------------------

// Extract a well name and reason from a batch error string such as
// "Well 'A3': insufficient data points". Falls back to the whole string.
function _parseBatchError(e) {
    const s = String(e);
    const m = s.match(/Well\s+'([^']+)'\s*:?\s*(.*)$/i);
    if (m) return { well: m[1], reason: (m[2] || '').trim() || s };
    return { well: '', reason: s };
}

function downloadBatchCSV() {
    const data = state.lastBatchFitData;
    if (!data || !data.results || data.results.length === 0) return;

    const { experiment, model, results } = data;
    const isLoglin = model === 'log_lin';

    let headers, rows, filenameSuffix;
    if (isLoglin) {
        headers = ['experiment', 'well', 'method',
                   'gr_loglin', 'gr_loglin_se', 'gr_max_sliding',
                   't_exp_start_loglin', 't_exp_end_loglin',
                   'doubling_time_loglin', 'R_squared_loglin',
                   'lag_loglin', 'N_max_emp',
                   'loglin_converged'];
        rows = results.map(r => [
            experiment, r.well, 'log_lin',
            r.gr_loglin            ?? '',
            r.gr_loglin_se         ?? '',
            r.gr_max_sliding       ?? '',
            r.t_exp_start_loglin   ?? '',
            r.t_exp_end_loglin     ?? '',
            r.doubling_time_loglin ?? '',
            r.R_squared_loglin     ?? '',
            r.lag_loglin           ?? '',
            r.N_max_emp            ?? '',
            r.loglin_converged ? 'true' : 'false',
        ]);
        filenameSuffix = 'batch_fit_loglin';
    } else {
        // Collect all param names
        const allParamNames = [];
        results.forEach(r => {
            (r.param_names || []).forEach(n => {
                if (!allParamNames.includes(n)) allParamNames.push(n);
            });
        });

        // Add companion log-lin columns when any well reports them
        const anyCompanion = results.some(r => r.loglin_converged === true ||
                                                Number.isFinite(r.gr_loglin));
        const loglinHeaders = anyCompanion
            ? ['gr_loglin', 'gr_loglin_se', 'gr_max_sliding',
               't_exp_start_loglin', 't_exp_end_loglin',
               'doubling_time_loglin', 'R_squared_loglin',
               'lag_loglin', 'N_max_emp', 'loglin_converged']
            : [];

        headers = ['experiment', 'well', 'model', ...allParamNames,
                   ...loglinHeaders,
                   'stationary_phase_start', 'aic', 'loss_rmse', 'loss_re', 'optimizer_used'];

        rows = results.map(r => {
            const paramVals = allParamNames.map(name => {
                const idx = (r.param_names || []).indexOf(name);
                return idx >= 0 && r.parameters && r.parameters[idx] != null
                    ? r.parameters[idx] : '';
            });
            const loglinVals = anyCompanion ? [
                r.gr_loglin            ?? '',
                r.gr_loglin_se         ?? '',
                r.gr_max_sliding       ?? '',
                r.t_exp_start_loglin   ?? '',
                r.t_exp_end_loglin     ?? '',
                r.doubling_time_loglin ?? '',
                r.R_squared_loglin     ?? '',
                r.lag_loglin           ?? '',
                r.N_max_emp            ?? '',
                r.loglin_converged == null ? '' : (r.loglin_converged ? 'true' : 'false'),
            ] : [];
            return [
                experiment, r.well, r.model || model,
                ...paramVals, ...loglinVals,
                r.stationary_phase_start != null ? r.stationary_phase_start : '',
                r.aic != null ? r.aic : '',
                r.loss_rmse != null ? r.loss_rmse : (r.loss != null ? r.loss : ''),
                r.loss_re != null ? r.loss_re : '',
                r.optimizer_used || '',
            ];
        });
        filenameSuffix = 'batch_fit';
    }

    // Append status columns and rows for skipped (flat) and failed wells, so the
    // downloaded CSV is a complete record rather than successful fits only.
    const statusCols = ['status', 'status_reason'];
    const nDataCols = headers.length;
    headers = [...headers, ...statusCols];
    rows = rows.map(r => [...r, 'ok', '']);

    const skippedList = Array.isArray(data.skipped) ? data.skipped : [];
    skippedList.forEach(s => {
        const row = new Array(nDataCols).fill('');
        row[0] = experiment;
        row[1] = s.well ?? '';
        rows.push([...row, 'skipped', s.reason ?? '']);
    });

    const errorList = (data.summary && Array.isArray(data.summary.errors))
        ? data.summary.errors : [];
    errorList.forEach(e => {
        const { well, reason } = _parseBatchError(e);
        const row = new Array(nDataCols).fill('');
        row[0] = experiment;
        row[1] = well;
        rows.push([...row, 'failed', reason]);
    });

    const csvContent = [headers, ...rows]
        .map(row => row.map(v => `"${String(v).replace(/"/g, '""')}"`).join(','))
        .join('\n');

    const blob = new Blob([csvContent], { type: 'text/csv' });
    const url  = URL.createObjectURL(blob);
    const a    = document.createElement('a');
    a.href     = url;
    a.download = `${experiment}_${filenameSuffix}.csv`;
    a.click();
    URL.revokeObjectURL(url);
}

function _csvEscape(v) {
    return `"${String(v ?? '').replace(/"/g, '""')}"`;
}

function _formatTimeHeader(t) {
    const n = Number(t);
    if (!Number.isFinite(n)) return String(t);
    return Number.isInteger(n) ? String(n) : String(Number(n.toPrecision(12)));
}

// Export every fitted curve in the last batch run as a wide CSV (one row per
// well, time-points as columns). We assume every well in a batch shares the
// same time grid — true today because all wells in a single /api/batch-fit
// response come from the same data_channel CSV. If that ever changes (e.g.
// merging fits from heterogeneous experiments), the column-union below will
// still produce a valid CSV but rows for wells that don't sample every
// timepoint will contain empty cells.
function downloadBatchFittedCurvesCSV() {
    const data = state.lastBatchFitData;
    if (!data || !data.results || data.results.length === 0) {
        alert('No batch-fit results to export — run a batch fit first.');
        return;
    }

    const { experiment, model, results } = data;
    const curves = results.filter(r =>
        Array.isArray(r.fit_time) && Array.isArray(r.fit_od) &&
        r.fit_time.length > 0 && r.fit_od.length > 0
    );
    if (curves.length === 0) {
        alert('No fitted curves available to export — every well returned an empty fit.');
        return;
    }

    const timeSet = new Set();
    curves.forEach(r => {
        r.fit_time.forEach(t => timeSet.add(_formatTimeHeader(t)));
    });
    const times = Array.from(timeSet).sort((a, b) => Number(a) - Number(b));
    const headers = ['experiment', 'well', 'model', ...times.map(t => `t_${t}`)];

    const rows = curves.map(r => {
        const odByTime = new Map();
        const n = Math.min(r.fit_time.length, r.fit_od.length);
        for (let i = 0; i < n; i++) {
            odByTime.set(_formatTimeHeader(r.fit_time[i]), r.fit_od[i]);
        }
        return [
            experiment,
            r.well,
            r.model || model,
            ...times.map(t => odByTime.has(t) ? odByTime.get(t) : ''),
        ];
    });

    const csvContent = [headers, ...rows]
        .map(row => row.map(_csvEscape).join(','))
        .join('\n');

    const blob = new Blob([csvContent], { type: 'text/csv' });
    const url  = URL.createObjectURL(blob);
    const a    = document.createElement('a');
    a.href     = url;
    a.download = `${experiment}_batch_fit_fitted_curves.csv`;
    a.click();
    URL.revokeObjectURL(url);
}

export {
    initBatchFitTab, loadBatchFitModels, loadBatchFitExperiments,
    onBatchExperimentChange, updateBatchWellCount,
    selectAllBatchWells, clearAllBatchWells,
    onBatchModeChange, onBatchFitMethodChange, onBatchFitSmoothingChange,
    toggleBatchLogLinOptions, onBatchLogLinCompanionChange,
    onBatchLogLinSmoothingChange, onBatchLogLinWindowTypeChange,
    selectAllBatchModels, clearAllBatchModels,
    runBatchFit, displayBatchResults, downloadBatchCSV, downloadBatchFittedCurvesCSV,
};
