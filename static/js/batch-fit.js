import { state, API_BASE } from './state.js';
import { buildOptimizerPayload } from './optimizers.js';

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

async function runBatchFit() {
    const experiment = document.getElementById('batch-fit-experiment').value;
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
        const maxiters = Math.max(1, parseInt(document.getElementById('batch-fit-maxiters')?.value || '100000', 10) || 100000);
        const abstol = parseFloat(document.getElementById('batch-fit-abstol')?.value || DEFAULT_BATCH_FIT_ABSTOL) || parseFloat(DEFAULT_BATCH_FIT_ABSTOL);
        const skipFlat = Math.max(0, parseFloat(document.getElementById('batch-fit-skip-flat')?.value || '0.05') || 0);
        const requestPayload = {
            experiment,
            wells,
            ...modelPayload,
            blank_subtraction: document.getElementById('batch-fit-blank-subtraction').checked,
            blank_method: document.getElementById('batch-fit-blank-method').value,
            ...buildOptimizerPayload('batch-fit'),
            maxiters,
            abstol,
            skip_flat_threshold: skipFlat,
            ...(batchCalFile ? { calibration_file: batchCalFile } : {}),
        };
        const startResp = await fetch(`${API_BASE}/api/batch-fit`, {
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
        runBtn.textContent = '⚡ Run Batch Fit';
        setTimeout(() => { progressEl.style.display = 'none'; }, 2000);
    }
}

// ---------------------------------------------------------------------------
// Display results
// ---------------------------------------------------------------------------

function displayBatchResults(data) {
    const exportBtn = document.getElementById('batch-export-btn');
    if (exportBtn) exportBtn.style.display = '';
    const resultsDiv = document.getElementById('batch-fit-results');
    const { experiment, model, model_names, summary, results } = data;
    const modelLabel = model === 'multi'
        ? `AICc from: ${(model_names || []).join(', ')}`
        : model;

    // Summary bar
    const skippedCount = summary.skipped || 0;
    const summaryHtml = `
        <div class="batch-summary-bar">
            <span><strong>Experiment:</strong> ${experiment}</span>
            <span><strong>Model:</strong> ${modelLabel}</span>
            <span class="batch-stat-ok">✓ ${summary.success} fitted</span>
            ${summary.failed > 0 ? `<span class="batch-stat-err">✗ ${summary.failed} failed</span>` : ''}
            ${skippedCount > 0 ? `<span style="color:#6c757d;">⊘ ${skippedCount} skipped (flat)</span>` : ''}
            <button class="btn" style="margin-left:auto;" onclick="downloadBatchCSV()">📥 Download CSV</button>
        </div>
    `;

    // Collect all unique param names across results for table headers
    const allParamNames = [];
    results.forEach(r => {
        (r.param_names || []).forEach(n => {
            if (!allParamNames.includes(n)) allParamNames.push(n);
        });
    });

    // Table header
    const headerCells = ['Well', 'Model', ...allParamNames, 'Stationary phase start', 'AICc'];
    const headerHtml = headerCells.map(h => `<th>${h}</th>`).join('');

    // Table rows
    const rowsHtml = results.map(r => {
        const paramCells = allParamNames.map(name => {
            const idx = (r.param_names || []).indexOf(name);
            const val = idx >= 0 && r.parameters && r.parameters[idx] != null
                ? Number(r.parameters[idx]).toFixed(4) : '—';
            return `<td>${val}</td>`;
        }).join('');
        const statStart = r.stationary_phase_start != null
            ? Number(r.stationary_phase_start).toFixed(2) : '—';
        const aic = r.aic != null ? Number(r.aic).toFixed(2) : '—';
        return `<tr>
            <td>${r.well}</td>
            <td><span class="batch-model-tag">${r.model || model}</span></td>
            ${paramCells}
            <td>${statStart}</td>
            <td>${aic}</td>
        </tr>`;
    }).join('');

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

function downloadBatchCSV() {
    const data = state.lastBatchFitData;
    if (!data || !data.results || data.results.length === 0) return;

    const { experiment, model, results } = data;

    // Collect all param names
    const allParamNames = [];
    results.forEach(r => {
        (r.param_names || []).forEach(n => {
            if (!allParamNames.includes(n)) allParamNames.push(n);
        });
    });

    const headers = ['experiment', 'well', 'model', ...allParamNames,
                     'stationary_phase_start', 'aic', 'loss', 'optimizer_used'];
    const rows = results.map(r => {
        const paramVals = allParamNames.map(name => {
            const idx = (r.param_names || []).indexOf(name);
            return idx >= 0 && r.parameters && r.parameters[idx] != null
                ? r.parameters[idx] : '';
        });
        return [
            experiment,
            r.well,
            r.model || model,
            ...paramVals,
            r.stationary_phase_start != null ? r.stationary_phase_start : '',
            r.aic != null ? r.aic : '',
            r.loss != null ? r.loss : '',
            r.optimizer_used || '',
        ];
    });

    const csvContent = [headers, ...rows]
        .map(row => row.map(v => `"${String(v).replace(/"/g, '""')}"`).join(','))
        .join('\n');

    const blob = new Blob([csvContent], { type: 'text/csv' });
    const url  = URL.createObjectURL(blob);
    const a    = document.createElement('a');
    a.href     = url;
    a.download = `${experiment}_batch_fit.csv`;
    a.click();
    URL.revokeObjectURL(url);
}

export {
    initBatchFitTab, loadBatchFitModels, loadBatchFitExperiments,
    onBatchExperimentChange, updateBatchWellCount,
    selectAllBatchWells, clearAllBatchWells,
    onBatchModeChange, selectAllBatchModels, clearAllBatchModels,
    runBatchFit, displayBatchResults, downloadBatchCSV,
};
