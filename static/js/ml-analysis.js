import { state, API_BASE } from './state.js';

// ---------------------------------------------------------------------------
// ML Downstream Analysis tab
// ---------------------------------------------------------------------------
// Workflow:
//   1. User uploads batch-fit CSV  (any label column + numeric param columns)
//   2. User uploads feature CSV    (any label column + numeric feature columns)
//   3. User selects label column (default: first column) and growth params
//   4. Click "Run ML Analysis" → POST /api/ml-downstream
//   5. Render: Spearman correlation bar chart + RF feature importance + PDPs

// ---------------------------------------------------------------------------
// CSV header parser
// ---------------------------------------------------------------------------

function parseCsvHeader(text) {
    const firstLine = text.trim().split(/\r?\n/)[0];
    return firstLine.split(',').map(h => h.trim());
}

function isNumericColumn(text, colIdx) {
    const lines = text.trim().split(/\r?\n/);
    // Check up to 10 data rows
    const dataLines = lines.slice(1, Math.min(11, lines.length));
    let numericCount = 0;
    for (const line of dataLines) {
        const val = line.split(',')[colIdx]?.trim();
        if (val !== undefined && val !== '' && !isNaN(Number(val))) numericCount++;
    }
    return numericCount > 0 && numericCount >= Math.min(dataLines.length, 3);
}

// ---------------------------------------------------------------------------
// File upload handlers
// ---------------------------------------------------------------------------

function onFitResultsFileChange() {
    resetMlExport();
    const file = document.getElementById('ml-fit-file').files[0];
    const label = document.getElementById('ml-fit-file-label');
    label.textContent = file ? file.name : 'No file chosen';

    if (!file) { updateMlRunBtn(); return; }

    const reader = new FileReader();
    reader.onload = e => {
        const text = e.target.result;
        state._fitCsvText = text;
        const headers = parseCsvHeader(text);

        // Populate label column selector
        const labelSel = document.getElementById('ml-label-col-select');
        labelSel.innerHTML = '';
        headers.forEach((h, i) => {
            const opt = document.createElement('option');
            opt.value = h;
            opt.textContent = h;
            if (i === 0) opt.selected = true;
            labelSel.appendChild(opt);
        });
        document.getElementById('ml-label-col-wrap').style.display = 'block';

        // Populate param checkboxes (numeric columns only, skip first column = label)
        const numericCols = headers.filter(h => {
            const realIdx = headers.indexOf(h);
            return realIdx !== 0 && isNumericColumn(text, realIdx);
        });

        const checkboxContainer = document.getElementById('ml-param-checkboxes');
        if (numericCols.length === 0) {
            checkboxContainer.innerHTML =
                '<span style="color:#dc3545; font-size:0.88em;">No numeric columns detected.</span>';
        } else {
            checkboxContainer.innerHTML = '';
            numericCols.forEach(col => {
                const id = `ml-param-${col}`;
                const wrap = document.createElement('label');
                wrap.style.cssText = 'display:flex; align-items:center; gap:6px; cursor:pointer;';
                wrap.innerHTML = `<input type="checkbox" id="${id}" value="${col}" checked>
                    <span>${col}</span>`;
                checkboxContainer.appendChild(wrap);
            });
        }

        // Populate correlation selector
        const corrSel = document.getElementById('ml-corr-param-sel');
        corrSel.innerHTML = '';
        numericCols.forEach((col, i) => {
            const opt = document.createElement('option');
            opt.value = col;
            opt.textContent = col;
            if (i === 0) opt.selected = true;
            corrSel.appendChild(opt);
        });

        validateLabels();
        updateMlRunBtn();
    };
    reader.readAsText(file);
}

function onFeatureMatrixFileChange() {
    resetMlExport();
    const file = document.getElementById('ml-feature-file').files[0];
    const label = document.getElementById('ml-feature-file-label');
    label.textContent = file ? file.name : 'No file chosen';

    if (!file) { updateMlRunBtn(); return; }

    const reader = new FileReader();
    reader.onload = e => {
        state._featCsvText = e.target.result;
        validateLabels();
        updateMlRunBtn();
    };
    reader.readAsText(file);
}

function onMlLabelColChange() {
    validateLabels();
}

// ---------------------------------------------------------------------------
// Label validation: count matches between fit results and feature matrix
// ---------------------------------------------------------------------------

function validateLabels() {
    const statusEl = document.getElementById('ml-label-match-status');
    if (!state._fitCsvText || !state._featCsvText) {
        statusEl.style.display = 'none';
        return;
    }

    const labelCol = document.getElementById('ml-label-col-select')?.value;
    if (!labelCol) { statusEl.style.display = 'none'; return; }

    // Extract labels from fit CSV using selected label column
    const fitHeaders = parseCsvHeader(state._fitCsvText);
    const labelIdx = fitHeaders.indexOf(labelCol);
    const fitLines = state._fitCsvText.trim().split(/\r?\n/).slice(1);
    const fitLabels = new Set(fitLines.map(l => l.split(',')[labelIdx]?.trim()).filter(Boolean));

    // Extract labels from feature CSV (always first column)
    const featLines = state._featCsvText.trim().split(/\r?\n/).slice(1);
    const featLabels = new Set(featLines.map(l => l.split(',')[0]?.trim()).filter(Boolean));

    const matched = [...fitLabels].filter(l => featLabels.has(l)).length;
    const total   = fitLabels.size;

    statusEl.style.display = 'block';
    if (matched === 0) {
        statusEl.style.background = '#fff3cd';
        statusEl.style.borderColor = '#ffc107';
        statusEl.style.color = '#856404';
        statusEl.textContent = `Warning: 0 / ${total} labels matched between files. Check that label columns are consistent.`;
    } else {
        statusEl.style.background = '#d1e7dd';
        statusEl.style.borderColor = '#0f5132';
        statusEl.style.color = '#0f5132';
        statusEl.textContent = `${matched} / ${total} labels matched.`;
    }
}

function updateMlRunBtn() {
    const hasFit  = !!state._fitCsvText;
    const hasFeat = !!state._featCsvText;
    const canRun = hasFit && hasFeat;
    document.getElementById('ml-run-btn').disabled = !canRun;
    if (!canRun) resetMlExport();
}

function resetMlExport() {
    state._mlResults = null;
    const exportBtn = document.getElementById('ml-export-btn');
    if (exportBtn) exportBtn.disabled = true;
}

function enableMlExport(data) {
    state._mlResults = data;
    const exportBtn = document.getElementById('ml-export-btn');
    if (exportBtn) exportBtn.disabled = false;
}

// ---------------------------------------------------------------------------
// Main: run ML analysis
// ---------------------------------------------------------------------------

function getSelectedParams() {
    return [...document.querySelectorAll('#ml-param-checkboxes input[type=checkbox]')]
        .filter(cb => cb.checked)
        .map(cb => cb.value);
}

async function runMlAnalysis() {
    if (!state._fitCsvText || !state._featCsvText) return;

    const labelCol = document.getElementById('ml-label-col-select')?.value;
    if (!labelCol) { alert('Please select a label column.'); return; }

    const selectedParams = getSelectedParams();
    if (selectedParams.length === 0) {
        alert('Please select at least one growth parameter for feature importance.');
        return;
    }

    const statusEl = document.getElementById('ml-status');
    const resultsEl = document.getElementById('ml-results');
    resetMlExport();
    statusEl.textContent = 'Running analysis…';
    statusEl.style.display = 'block';
    resultsEl.style.display = 'none';

    try {
        const body = {
            fit_csv:        state._fitCsvText,
            label_col:      labelCol,
            feature_matrix: state._featCsvText,
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
        enableMlExport(data);
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

    const paramSel = document.getElementById('ml-corr-param-sel');
    const activeParam = paramSel ? paramSel.value : correlations[0] ?
        Object.keys(correlations[0]).find(k => k !== 'feature') : null;
    if (activeParam) _drawCorrBar(correlations, activeParam);
}

function _correlationsForParam(correlations, param) {
    return [...(correlations || [])]
        .filter(r => r[param] !== null && r[param] !== undefined &&
            r[param] !== '' && Number.isFinite(Number(r[param])))
        .sort((a, b) => Math.abs(Number(b[param])) - Math.abs(Number(a[param])));
}

function _mlPlotConfig(svgFilename) {
    return {
        responsive: true,
        modeBarButtonsToAdd: [{
            name: 'Download plot as SVG',
            icon: Plotly.Icons.disk,
            click: gd => Plotly.downloadImage(gd, {
                format: 'svg',
                filename: svgFilename,
            }),
        }],
    };
}

function _drawCorrBar(correlations, param) {
    const sorted = _correlationsForParam(correlations, param).slice(0, 30);

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
    }, _mlPlotConfig(`ml-correlation-${param}`));
}

function onCorrParamChange() {
    const sel = document.getElementById('ml-corr-param-sel');
    if (state._mlCorrelations) _drawCorrBar(state._mlCorrelations, sel.value);
}

function _csvCell(v) {
    const s = v === null || v === undefined ? '' : String(v);
    return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

function _downloadCSV(rows, filename) {
    const csv = rows.map(row => row.map(_csvCell).join(',')).join('\n');
    const blob = new Blob([csv], { type: 'text/csv' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = filename;
    a.click();
    URL.revokeObjectURL(a.href);
}

function _mlResultRows(data, selectedParams) {
    const rows = [[
        'growth_parameter',
        'feature',
        'spearman_rho',
        'importance',
        'pdp_feature_value',
        'pdp_mean_prediction',
    ]];
    const merged = new Map();

    function resultRow(param, feature) {
        const key = `${param}\u0000${feature}`;
        if (!merged.has(key)) {
            merged.set(key, {
                param,
                feature,
                spearman: '',
                importance: '',
                pdpGrid: [],
                pdpMean: [],
            });
        }
        return merged.get(key);
    }

    const correlations = data.correlations || [];
    const importance = data.importance || {};
    const pdp = data.pdp || {};

    const params = (selectedParams && selectedParams.length)
        ? selectedParams
        : correlations.reduce((acc, row) => {
            Object.keys(row || {}).forEach(key => {
                if (key !== 'feature' && !acc.includes(key)) acc.push(key);
            });
            return acc;
        }, []);

    params.forEach(param => {
        _correlationsForParam(correlations, param).forEach(row => {
            resultRow(param, row.feature ?? '').spearman = row[param];
        });

        (importance[param] || []).forEach(row => {
            resultRow(param, row.feature ?? '').importance = row.importance ?? '';
        });

        (pdp[param] || []).forEach(curve => {
            const row = resultRow(param, curve.feature ?? '');
            row.pdpGrid = curve.grid || [];
            row.pdpMean = curve.mean || [];
        });
    });

    merged.forEach(row => {
        const nPdpPoints = Math.max(row.pdpGrid.length, row.pdpMean.length);
        if (nPdpPoints === 0) {
            rows.push([
                row.param,
                row.feature,
                row.spearman,
                row.importance,
                '',
                '',
            ]);
            return;
        }

        for (let i = 0; i < nPdpPoints; i++) {
            rows.push([
                row.param,
                row.feature,
                row.spearman,
                row.importance,
                row.pdpGrid[i] ?? '',
                row.pdpMean[i] ?? '',
            ]);
        }
    });

    return rows;
}

function downloadMlResultsCSV() {
    if (!state._mlResults) return;
    _downloadCSV(_mlResultRows(state._mlResults, getSelectedParams()), 'ml_analysis_results.csv');
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
        }, _mlPlotConfig(`ml-feature-importance-${param}`));
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
        }, _mlPlotConfig(`ml-partial-dependence-${param}`));
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
    onMlLabelColChange,
    downloadMlResultsCSV,
};
