import { state, API_BASE } from './state.js';

// ---------------------------------------------------------------------------
// ML Downstream Analysis tab
// ---------------------------------------------------------------------------
// Workflow:
//   1. User uploads batch-fit CSV  (columns: label, gr, exit_lag_rate, N_max, shape)
//   2. User uploads feature CSV    (columns: label, feature1, feature2, …)
//   3. User selects growth params to include in RF importance
//   4. Click "Run ML Analysis" → POST /api/ml-downstream
//   5. Render: Spearman correlation bar chart + RF feature importance bar charts

const ML_PARAMS = ['gr', 'exit_lag_rate', 'N_max', 'shape'];

// ---------------------------------------------------------------------------
// File upload handlers
// ---------------------------------------------------------------------------

function onFitResultsFileChange() {
    const file = document.getElementById('ml-fit-file').files[0];
    const label = document.getElementById('ml-fit-file-label');
    label.textContent = file ? file.name : 'No file chosen';
    updateMlRunBtn();
}

function onFeatureMatrixFileChange() {
    const file = document.getElementById('ml-feature-file').files[0];
    const label = document.getElementById('ml-feature-file-label');
    label.textContent = file ? file.name : 'No file chosen';
    updateMlRunBtn();
}

function updateMlRunBtn() {
    const fitFile     = document.getElementById('ml-fit-file').files[0];
    const featFile    = document.getElementById('ml-feature-file').files[0];
    document.getElementById('ml-run-btn').disabled = !(fitFile && featFile);
}

// ---------------------------------------------------------------------------
// Main: run ML analysis
// ---------------------------------------------------------------------------

async function runMlAnalysis() {
    const fitFile  = document.getElementById('ml-fit-file').files[0];
    const featFile = document.getElementById('ml-feature-file').files[0];
    if (!fitFile || !featFile) return;

    const selectedParams = ML_PARAMS.filter(p =>
        document.getElementById(`ml-param-${p}`)?.checked
    );
    if (selectedParams.length === 0) {
        alert('Please select at least one growth parameter for feature importance.');
        return;
    }

    const statusEl = document.getElementById('ml-status');
    const resultsEl = document.getElementById('ml-results');
    statusEl.textContent = 'Running analysis…';
    statusEl.style.display = 'block';
    resultsEl.style.display = 'none';

    try {
        const fitText  = await fitFile.text();
        const featText = await featFile.text();

        const fitRows = parseCsvToObjects(fitText);
        if (fitRows.length === 0) {
            statusEl.textContent = 'Error: fit results CSV is empty or malformed.';
            return;
        }

        const fitResults = fitRows.map(r => ({
            label:         String(r.label ?? r[Object.keys(r)[0]]),
            gr:            parseFloat(r.gr)            || 0,
            exit_lag_rate: parseFloat(r.exit_lag_rate) || 0,
            N_max:         parseFloat(r.N_max)         || 0,
            shape:         parseFloat(r.shape)         || 0,
        }));

        const body = {
            fit_results:    fitResults,
            feature_matrix: featText,
            params:         selectedParams,
        };

        const resp = await fetch(`${API_BASE}/api/ml-downstream`, {
            method:  'POST',
            headers: { 'Content-Type': 'application/json' },
            body:    JSON.stringify(body),
        });

        if (!resp.ok) {
            const err = await resp.json();
            statusEl.textContent = `Error: ${err.error}`;
            return;
        }

        const data = await resp.json();
        state._mlCorrelations = data.correlations;
        statusEl.style.display = 'none';
        renderMlResults(data, selectedParams);
        resultsEl.style.display = 'block';

    } catch (e) {
        console.error('ML analysis error:', e);
        statusEl.textContent = `Error: ${e.message}`;
    }
}

// ---------------------------------------------------------------------------
// Render results
// ---------------------------------------------------------------------------

function renderMlResults(data, selectedParams) {
    document.getElementById('ml-n-wells').textContent =
        `${data.n_wells} wells matched between fit results and feature matrix.`;

    renderCorrelationChart(data.correlations);
    renderImportanceCharts(data.importance, selectedParams);
    renderPDPCharts(data.pdp, selectedParams);
}

function renderCorrelationChart(correlations) {
    if (!correlations || correlations.length === 0) {
        document.getElementById('ml-corr-container').innerHTML =
            '<p style="color:#6c757d; padding:10px;">No correlation data available.</p>';
        return;
    }

    // Show correlation for 'gr' by default; user can switch via selector
    const paramSel = document.getElementById('ml-corr-param-sel');
    const activeParam = paramSel ? paramSel.value : 'gr';
    _drawCorrBar(correlations, activeParam);
}

function _drawCorrBar(correlations, param) {
    // Sort by |ρ| descending, take top 30
    const sorted = [...correlations]
        .filter(r => r[param] !== undefined && !isNaN(r[param]))
        .sort((a, b) => Math.abs(b[param]) - Math.abs(a[param]))
        .slice(0, 30);

    const features = sorted.map(r => r.feature);
    const rhos     = sorted.map(r => r[param]);
    const colors   = rhos.map(v => v >= 0 ? 'steelblue' : '#e05252');

    Plotly.react('ml-corr-plot', [{
        type:        'bar',
        orientation: 'h',
        x:           rhos,
        y:           features,
        marker:      { color: colors },
        hovertemplate: '%{y}: ρ = %{x:.3f}<extra></extra>',
    }], {
        margin:  { l: 180, r: 20, t: 30, b: 50 },
        xaxis:   { title: 'Spearman ρ', range: [-1, 1], zeroline: true },
        yaxis:   { autorange: 'reversed' },
        height:  Math.max(300, features.length * 20 + 80),
        title:   `Spearman ρ — features vs ${param}`,
    }, { responsive: true });
}

function onCorrParamChange() {
    const sel = document.getElementById('ml-corr-param-sel');
    // Re-read cached correlations from the last result
    if (state._mlCorrelations) _drawCorrBar(state._mlCorrelations, sel.value);
}

function renderImportanceCharts(importance, selectedParams) {
    const container = document.getElementById('ml-importance-container');
    container.innerHTML = '';

    selectedParams.forEach(param => {
        const imp = importance[param];
        if (!imp || imp.length === 0) return;

        const top = imp.slice(0, 15);
        const divId = `ml-imp-plot-${param}`;
        const wrapper = document.createElement('div');
        wrapper.style.cssText = 'width:100%;';
        wrapper.innerHTML = `<div id="${divId}" style="width:100%; height:400px;"></div>`;
        container.appendChild(wrapper);

        const features = top.map(r => r.feature);
        const imps     = top.map(r => r.importance);

        Plotly.newPlot(divId, [{
            type:        'bar',
            orientation: 'h',
            x:           imps,
            y:           features,
            marker:      { color: 'steelblue' },
            hovertemplate: '%{y}: %{x:.4f}<extra></extra>',
        }], {
            margin: { l: 180, r: 20, t: 40, b: 50 },
            xaxis:  { title: 'Importance' },
            yaxis:  { autorange: 'reversed' },
            height: 360,
            title:  `Feature importance — ${param}`,
        }, { responsive: true });
    });
}

// ---------------------------------------------------------------------------
// Partial Dependence Plots
// ---------------------------------------------------------------------------

function renderPDPCharts(pdp, selectedParams) {
    const container = document.getElementById('ml-pdp-container');
    if (!container) return;
    container.innerHTML = '';

    if (!pdp || selectedParams.every(p => !pdp[p] || pdp[p].length === 0)) {
        container.innerHTML = '<p style="color:#6c757d; padding:10px;">No PDP data available.</p>';
        return;
    }

    selectedParams.forEach(param => {
        const curves = pdp[param];
        if (!curves || curves.length === 0) return;

        // One multi-trace plot per parameter: all top-5 features overlaid
        const divId = `ml-pdp-plot-${param}`;
        const wrapper = document.createElement('div');
        wrapper.style.cssText = 'width:100%;';
        wrapper.innerHTML = `<div id="${divId}" style="width:100%; height:400px;"></div>`;
        container.appendChild(wrapper);

        const traces = curves.map(c => ({
            type: 'scatter',
            mode: 'lines',
            name: c.feature,
            x: c.grid,
            y: c.mean,
            hovertemplate: `${c.feature}<br>value: %{x:.3g}<br>predicted ${param}: %{y:.4f}<extra></extra>`,
        }));

        Plotly.newPlot(divId, traces, {
            title:  `Partial dependence — ${param} (top 5 features)`,
            xaxis:  { title: 'Feature value' },
            yaxis:  { title: `Predicted ${param}` },
            height: 400,
            margin: { l: 70, r: 20, t: 50, b: 60 },
            legend: { orientation: 'v', x: 1.02, xanchor: 'left' },
        }, { responsive: true });
    });
}

// ---------------------------------------------------------------------------
// Tiny CSV parser (header row + data rows → array of objects)
// ---------------------------------------------------------------------------

function parseCsvToObjects(text) {
    const lines = text.trim().split(/\r?\n/);
    if (lines.length < 2) return [];
    const headers = lines[0].split(',').map(h => h.trim());
    return lines.slice(1).map(line => {
        const vals = line.split(',');
        const obj = {};
        headers.forEach((h, i) => { obj[h] = vals[i]?.trim() ?? ''; });
        return obj;
    });
}

// ---------------------------------------------------------------------------
// Exports
// ---------------------------------------------------------------------------

export {
    onFitResultsFileChange,
    onFeatureMatrixFileChange,
    updateMlRunBtn,
    runMlAnalysis,
    onCorrParamChange,
};
