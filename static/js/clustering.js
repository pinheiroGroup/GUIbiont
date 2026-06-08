import { state, API_BASE, CLUSTER_PALETTE } from './state.js';

// ----------------------------------------------------------------
// K-means Clustering
// ----------------------------------------------------------------



function hexToRgba(hex, alpha) {
    const r = parseInt(hex.slice(1, 3), 16);
    const g = parseInt(hex.slice(3, 5), 16);
    const b = parseInt(hex.slice(5, 7), 16);
    return `rgba(${r},${g},${b},${alpha})`;
}

function setClusteringMode(mode) {
    state.currentClusteringMode = mode;
    document.getElementById('cluster-mode-btn-file').classList.toggle('active', mode === 'file');
    document.getElementById('cluster-mode-btn-experiments').classList.toggle('active', mode === 'experiments');
    document.getElementById('cluster-file-content').style.display = mode === 'file' ? 'block' : 'none';
    document.getElementById('cluster-experiments-content').style.display = mode === 'experiments' ? 'block' : 'none';
    document.getElementById('cluster-interp-block').style.display = mode === 'file' ? 'flex' : 'none';
    updateClusteringRunBtn();
}

function renderClusterBlankNotice(data) {
    const notice = document.getElementById('cluster-blank-notice');
    if (!data.blank_subtracted) { notice.style.display = 'none'; return; }
    const src   = data.blank_source === 'auto' ? 'Auto-detected' : 'Annotated';
    const wells = (data.blank_wells_used || []).join(', ') || '—';
    notice.textContent = `🧪 Blank subtraction applied — ${src} blank wells: ${wells}`;
    notice.style.display = 'block';
}

function onClusterBlankChange() {
    const checked = document.getElementById('cluster-subtract-blank').checked;
    document.getElementById('cluster-blank-method-row').style.display = checked ? 'flex' : 'none';
}

function onClusterInterpolateChange() {
    const checked = document.getElementById('cluster-interpolate').checked;
    document.getElementById('cluster-interp-params').style.display = checked ? 'flex' : 'none';
}

// Read a pair of quantile inputs, validate, reset to defaults on bad input,
// and write the canonical values back to the DOM so the user sees what got used.
function readQuantileRange(loId, hiId, defLo = 0.05, defHi = 0.95) {
    let qLo = parseFloat(document.getElementById(loId).value);
    let qHi = parseFloat(document.getElementById(hiId).value);
    if (!Number.isFinite(qLo) || qLo < 0 || qLo > 1) qLo = defLo;
    if (!Number.isFinite(qHi) || qHi < 0 || qHi > 1) qHi = defHi;
    if (qLo >= qHi) {
        qLo = defLo;
        qHi = defHi;
    }
    document.getElementById(loId).value = qLo;
    document.getElementById(hiId).value = qHi;
    return { qLo, qHi };
}

const getClusterInterpQuantiles    = () => readQuantileRange('cluster-interp-qlo',    'cluster-interp-qhi');
const getClusterPrescreenQuantiles = () => readQuantileRange('cluster-prescreen-qlo', 'cluster-prescreen-qhi');

function updateClusteringRunBtn() {
    const hasData = state.currentClusteringMode === 'file'
        ? (!!document.getElementById('clustering-file').files[0] ||
           !!document.getElementById('cluster-server-path').value.trim())
        : document.querySelectorAll('.clustering-exp-checkbox:checked').length > 0;
    document.getElementById('clustering-run-btn').disabled  = !hasData;
    document.getElementById('cluster-sweep-btn').disabled   = !hasData;
}

function selectAllClusteringExperiments() {
    document.querySelectorAll('.clustering-exp-checkbox').forEach(cb => cb.checked = true);
    updateClusteringRunBtn();
}

function clearAllClusteringExperiments() {
    document.querySelectorAll('.clustering-exp-checkbox').forEach(cb => cb.checked = false);
    updateClusteringRunBtn();
}

function populateClusteringExperiments() {
    const list = document.getElementById('clustering-experiments-list');
    if (!list || !state.allExperiments.length) return;
    list.innerHTML = '';
    state.allExperiments.forEach(exp => {
        const item = document.createElement('label');
        item.className = 'clustering-exp-item';
        item.innerHTML = `<input type="checkbox" class="clustering-exp-checkbox" value="${exp}"> ${exp}`;
        item.querySelector('input').onchange = updateClusteringRunBtn;
        list.appendChild(item);
    });
}

function onClusteringFileChange() {
    updateClusteringRunBtn();
}

function toggleClusteringAdvanced() {
    const adv = document.getElementById('clustering-advanced');
    adv.style.display = adv.style.display === 'none' ? 'block' : 'none';
}

function onClusterSmoothChange() {
    const method = document.getElementById('cluster-smooth-method').value;
    document.getElementById('cluster-lowess-param').style.display   = method === 'lowess'   ? 'flex' : 'none';
    document.getElementById('cluster-gaussian-param').style.display = method === 'gaussian' ? 'flex' : 'none';
}

function onClusterMethodChange() {
    const method = document.getElementById('cluster-method').value;
    const isDbscan = method === 'dbscan';
    const isHclust = method === 'hclust';
    const needsIter = method === 'kmeans' || method === 'kmedoids';
    document.getElementById('clustering-k-label').textContent = isDbscan ? 'k (unused)' : 'k =';
    document.getElementById('clustering-k').disabled = isDbscan;
    document.getElementById('cluster-hclust-params').style.display = isHclust ? 'flex' : 'none';
    document.getElementById('cluster-dbscan-params').style.display = isDbscan ? 'flex' : 'none';
    document.getElementById('cluster-iter-params').style.display   = needsIter ? 'flex' : 'none';
}

// Store last cluster data for export

async function runClustering() {
    const k          = parseInt(document.getElementById('clustering-k').value) || 3;
    const normalize  = document.getElementById('clustering-normalize').checked;
    const smooth     = document.getElementById('cluster-smooth-method').value;
    const lowessFrac = parseFloat(document.getElementById('cluster-lowess-frac').value);
    const gHmult     = parseFloat(document.getElementById('cluster-gaussian-hmult').value);
    const method     = document.getElementById('cluster-method').value;
    const maxiter    = parseInt(document.getElementById('cluster-maxiter').value) || 300;
    const tol        = parseFloat(document.getElementById('cluster-tol').value) || 1e-6;
    const hLinkage   = document.getElementById('cluster-hclust-linkage').value;
    const dbscanEps  = parseFloat(document.getElementById('cluster-dbscan-eps').value);
    const dbscanMin  = parseInt(document.getElementById('cluster-dbscan-minpts').value);
    let body;

    if (state.currentClusteringMode === 'file') {
        const serverPath = document.getElementById('cluster-server-path').value.trim();
        const file = document.getElementById('clustering-file').files[0];
        if (serverPath) {
            body = { csv_path: serverPath, k, normalize };
        } else if (file) {
            body = { csv: await file.text(), k, normalize };
        } else return;
    } else {
        const selected = [...document.querySelectorAll('.clustering-exp-checkbox:checked')].map(c => c.value);
        if (!selected.length) return;
        body = { experiments: selected, k, normalize };
    }
    const doInterpolate = state.currentClusteringMode === 'file' &&
        document.getElementById('cluster-interpolate').checked;
    const { qLo: interpQLo, qHi: interpQHi } = getClusterInterpQuantiles();
    const { qLo: preQLo, qHi: preQHi }       = getClusterPrescreenQuantiles();

    Object.assign(body, {
        smooth_method: smooth,
        lowess_frac: lowessFrac,
        gaussian_h_mult: gHmult,
        cluster_method: method,
        maxiter, tol,
        hclust_linkage: hLinkage,
        dbscan_eps: dbscanEps,
        dbscan_min_pts: dbscanMin,
        subtract_blank:       document.getElementById('cluster-subtract-blank').checked,
        blank_method:         document.getElementById('cluster-blank-method').value,
        blank_range_thr:      parseFloat(document.getElementById('cluster-blank-range-thr').value),
        blank_od_percentile:  parseFloat(document.getElementById('cluster-blank-od-pct').value),
        interpolate:           doInterpolate,
        interp_n:              parseInt(document.getElementById('cluster-interp-n').value) || 100,
        interp_quantile_lo:    interpQLo,
        interp_quantile_hi:    interpQHi,
        prescreen_constant:    document.getElementById('cluster-prescreen').checked,
        prescreen_tol_const:   parseFloat(document.getElementById('cluster-prescreen-tol').value) || 1.5,
        prescreen_q_low:       preQLo,
        prescreen_q_high:      preQHi,
        trend_test_flat:       document.getElementById('cluster-trend-test').checked,
        trend_p_thr:           parseFloat(document.getElementById('cluster-trend-p').value) || 0.05,
    });

    document.getElementById('loading').style.display = 'flex';
    document.getElementById('cluster-grid-container').style.display = 'none';

    try {
        const response = await fetch(`${API_BASE}/api/cluster`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body)
        });
        if (!response.ok) {
            const err = await response.json();
            alert('Clustering error: ' + (err.error || response.statusText));
            return;
        }
        const data = await response.json();
        data._request = {
            _mode:          state.currentClusteringMode,
            k,
            normalize,
            smooth_method:  smooth,
            lowess_frac:    lowessFrac,
            gaussian_h_mult: gHmult,
            cluster_method: method,
            maxiter,
            tol,
            hclust_linkage: hLinkage,
            dbscan_eps:     dbscanEps,
            dbscan_min_pts: dbscanMin,
            subtract_blank: document.getElementById('cluster-subtract-blank').checked,
            blank_method:   document.getElementById('cluster-blank-method').value,
        };
        state._lastClusterData = data;
        document.getElementById('cluster-export-btn').disabled = false;
        renderClusterGrid(data);
        renderQualityPanel(data);
        renderClusterBlankNotice(data);
        // Reset panels that depend on a new run
        document.getElementById('cluster-sweep-panel').style.display = 'none';
        document.getElementById('cluster-compare-panel').style.display = state._savedClusterings.length ? 'block' : 'none';
    } catch (e) {
        alert('Clustering failed: ' + e.message);
    } finally {
        document.getElementById('loading').style.display = 'none';
    }
}

function renderClusterGrid(data) {
    const grid = document.getElementById('cluster-grid');
    grid.innerHTML = '';

    const time = data.time;
    const clusters = data.clusters;

    // Build experiment → color map (labels may be "ExpName/WellName")
    const expColorMap = {};
    let colorIdx = 0;
    clusters.forEach(cluster => {
        cluster.series_labels.forEach(label => {
            const exp = label.includes('/') ? label.split('/')[0] : null;
            if (exp && !(exp in expColorMap)) {
                expColorMap[exp] = CLUSTER_PALETTE[colorIdx++ % CLUSTER_PALETTE.length];
            }
        });
    });
    const hasExperiments = Object.keys(expColorMap).length > 0;

    clusters.forEach(cluster => {
        const cell = document.createElement('div');
        cell.className = 'cluster-cell';

        // Title bar
        const title = document.createElement('div');
        title.className = 'cluster-cell-title';
        const titleText = document.createElement('span');
        titleText.className = 'cluster-title-text';
        const clusterLabel = cluster.label || String(cluster.id);
        const total = cluster.n_total ?? cluster.series_labels.length;
        const shown = cluster.series_labels.length;
        titleText.textContent = total > shown
            ? `Cluster ${clusterLabel}  (${total} series, showing ${shown})`
            : `Cluster ${clusterLabel}  (${total} series)`;
        title.appendChild(titleText);

        const seriesBtn = document.createElement('button');
        seriesBtn.className = 'cluster-btn';
        seriesBtn.textContent = '📋 Series';
        title.appendChild(seriesBtn);

        const exportCsvBtn = document.createElement('button');
        exportCsvBtn.className = 'cluster-btn';
        exportCsvBtn.textContent = '📥 CSV';
        title.appendChild(exportCsvBtn);

        const exportPngBtn = document.createElement('button');
        exportPngBtn.className = 'cluster-btn';
        exportPngBtn.textContent = '🖼 PNG';
        title.appendChild(exportPngBtn);

        const fsBtn = document.createElement('button');
        fsBtn.className = 'cluster-btn';
        fsBtn.textContent = '⛶ Fullscreen';
        title.appendChild(fsBtn);

        cell.appendChild(title);

        // Plot div
        const plotDiv = document.createElement('div');
        plotDiv.className = 'cluster-plot-div';
        plotDiv.style.width = '100%';
        plotDiv.style.height = '300px';
        cell.appendChild(plotDiv);

        // Series list — group by experiment
        const seriesList = document.createElement('div');
        seriesList.className = 'cluster-series-list';
        if (hasExperiments) {
            // Group wells by experiment
            const byExp = {};
            cluster.series_labels.forEach(label => {
                const slash = label.indexOf('/');
                const exp  = slash >= 0 ? label.slice(0, slash) : '';
                const well = slash >= 0 ? label.slice(slash + 1) : label;
                if (!byExp[exp]) byExp[exp] = [];
                byExp[exp].push(well);
            });
            Object.entries(byExp).forEach(([exp, wells]) => {
                const line = document.createElement('div');
                line.className = 'series-line';
                const color = expColorMap[exp] || '#888';
                line.innerHTML = `<span style="color:${color};font-weight:600;">${exp}:</span> ${wells.join(', ')}`;
                seriesList.appendChild(line);
            });
        } else {
            // File mode — just list all labels
            const line = document.createElement('div');
            line.className = 'series-line';
            line.textContent = cluster.series_labels.join(', ');
            seriesList.appendChild(line);
        }
        cell.appendChild(seriesList);

        grid.appendChild(cell);

        seriesBtn.onclick = () => {
            seriesList.classList.toggle('open');
            seriesBtn.textContent = seriesList.classList.contains('open') ? '📋 Hide' : '📋 Series';
        };

        fsBtn.onclick = () => {
            const isFs = cell.classList.toggle('fullscreen');
            fsBtn.textContent = isFs ? '✕ Exit' : '⛶ Fullscreen';
            document.body.style.overflow = isFs ? 'hidden' : '';
            Plotly.Plots.resize(plotDiv);
        };

        exportCsvBtn.onclick = () => exportClusterCSV(cluster);
        exportPngBtn.onclick = () => Plotly.downloadImage(plotDiv, {
            format: 'png', width: 900, height: 500,
            filename: `cluster_${clusterLabel}`
        });

        // Build traces
        const traces = [];
        const seriesData   = cluster.series_data;
        const seriesLabels = cluster.series_labels;

        seriesData.forEach((y, i) => {
            const label = seriesLabels[i];
            const exp   = label.includes('/') ? label.split('/')[0] : null;
            const color = exp ? hexToRgba(expColorMap[exp], 0.45) : 'rgba(120,120,120,0.4)';
            traces.push({
                x: time, y,
                mode: 'lines', type: 'scatter',
                name: label,
                line: { width: 1, color },
                showlegend: false
            });
        });

        // SD band (filled area between centroid−SD and centroid+SD)
        const centroid   = cluster.centroid;
        const centroidSd = cluster.centroid_sd;
        if (centroid && centroidSd) {
            const upper = centroid.map((v, i) => v + centroidSd[i]);
            const lower = centroid.map((v, i) => v - centroidSd[i]);
            traces.push({
                x: [...time, ...time.slice().reverse()],
                y: [...upper, ...lower.slice().reverse()],
                fill: 'toself', fillcolor: 'rgba(180,0,0,0.10)',
                line: { color: 'transparent' },
                type: 'scatter', mode: 'lines',
                name: '±SD', showlegend: false, hoverinfo: 'skip',
            });
            traces.push({
                x: time, y: centroid,
                mode: 'lines', type: 'scatter',
                name: 'Mean ± SD',
                line: { width: 2, color: 'rgb(180,0,0)' },
                showlegend: true,
            });
        } else {
            // Fallback: compute mean client-side if backend didn't supply centroid
            const avgY = time.map((_, ti) => {
                const vals = seriesData.map(s => s[ti]).filter(v => isFinite(v));
                return vals.length ? vals.reduce((a, b) => a + b, 0) / vals.length : null;
            });
            traces.push({
                x: time, y: avgY,
                mode: 'lines', type: 'scatter',
                name: 'Mean',
                line: { width: 2, color: 'rgb(180,0,0)' },
                showlegend: true,
            });
        }

        const layout = {
            margin: { t: 10, r: 10, b: 40, l: 50 },
            xaxis: { title: data.time_normalized ? 'Normalized time [0–1]' : 'Time' },
            yaxis: { title: 'Value' },
            legend: { x: 0, y: 1 }
        };

        Plotly.newPlot(plotDiv, traces, layout, { responsive: true, displayModeBar: false }).then(() => {
            Plotly.Plots.resize(plotDiv);
        });
    });

    document.getElementById('cluster-grid-container').style.display = 'block';
}

// ----------------------------------------------------------------
// Cluster export helpers
// ----------------------------------------------------------------

function _clusterToCSVRows(cluster) {
    const rows = [['Cluster', 'Experiment', 'Well']];
    const label = cluster.label || String(cluster.id);
    cluster.series_labels.forEach(lbl => {
        const slash = lbl.indexOf('/');
        const exp  = slash >= 0 ? lbl.slice(0, slash) : '';
        const well = slash >= 0 ? lbl.slice(slash + 1) : lbl;
        rows.push([label, exp, well]);
    });
    return rows;
}

function _downloadCSV(rows, filename) {
    const csv = rows.map(r => r.map(v => `"${String(v).replace(/"/g, '""')}"`).join(',')).join('\n');
    const blob = new Blob([csv], { type: 'text/csv' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = filename;
    a.click();
    URL.revokeObjectURL(a.href);
}

function exportClusterCSV(cluster) {
    _downloadCSV(_clusterToCSVRows(cluster), `cluster_${cluster.label || cluster.id}.csv`);
}

function exportAllClustersCSV() {
    if (!state._lastClusterData) return;
    const rows = [['Cluster', 'Experiment', 'Well']];
    state._lastClusterData.clusters.forEach(cluster => {
        const label = cluster.label || String(cluster.id);
        cluster.series_labels.forEach(lbl => {
            const slash = lbl.indexOf('/');
            rows.push([label, slash >= 0 ? lbl.slice(0, slash) : '', slash >= 0 ? lbl.slice(slash + 1) : lbl]);
        });
    });
    _downloadCSV(rows, 'clusters_all.csv');
}

async function exportAllClustersPNG() {
    if (!state._lastClusterData) return;
    const plotDivs = document.querySelectorAll('.cluster-plot-div');
    for (let i = 0; i < plotDivs.length; i++) {
        const cluster = state._lastClusterData.clusters[i];
        if (!cluster) continue;
        await Plotly.downloadImage(plotDivs[i], {
            format: 'png', width: 900, height: 500,
            filename: `cluster_${cluster.label || cluster.id}`
        });
        await new Promise(r => setTimeout(r, 400));
    }
}

// ----------------------------------------------------------------
// Quality indices rendering
// ----------------------------------------------------------------

function renderQualityPanel(data) {
    if (!data.quality) return;
    const q = data.quality;
    const panel = document.getElementById('cluster-quality-panel');
    panel.style.display = 'block';

    // Summary table
    const indices = [
        { key: 'silhouette_mean',   label: 'Silhouette (mean)',   fmt: v => v.toFixed(4), range: '−1 to 1',  better: '↑ higher is better. Average fit quality across all series.' },
        { key: 'dunn',              label: 'Dunn index',          fmt: v => v.toFixed(4), range: '0 to ∞',   better: '↑ higher is better. Ratio of minimum inter-cluster distance to maximum cluster diameter.' },
        { key: 'davies_bouldin',    label: 'Davies-Bouldin',      fmt: v => v.toFixed(4), range: '0 to ∞',   better: '↓ lower is better. Average similarity between each cluster and its most similar neighbour.' },
        { key: 'calinski_harabasz', label: 'Calinski-Harabasz',   fmt: v => v.toFixed(2), range: '0 to ∞',   better: '↑ higher is better. Ratio of between-cluster to within-cluster variance.' },
        { key: 'xie_beni',          label: 'Xie-Beni',            fmt: v => v.toFixed(4), range: '0 to ∞',   better: '↓ lower is better. Ratio of within-cluster inertia to minimum distance between centres.' },
    ];

    let tableHtml = `<table style="border-collapse:collapse; font-size:0.875em; width:100%;">
        <thead><tr style="border-bottom:2px solid #dee2e6;">
            <th style="padding:4px 16px 4px 4px; text-align:left;">Index</th>
            <th style="padding:4px 16px 4px 4px; text-align:right;">Value</th>
            <th style="padding:4px 16px 4px 4px; text-align:center;">Range</th>
            <th style="padding:4px 4px; text-align:left; color:#6c757d;">Better</th>
        </tr></thead><tbody>`;
    indices.forEach(({ key, label, fmt, range, better }) => {
        const v = q[key];
        const valStr = (v === null || v === undefined) ? '<span style="color:#aaa">N/A</span>' : fmt(v);
        tableHtml += `<tr style="border-bottom:1px solid #f0f0f0;">
            <td style="padding:4px 16px 4px 4px; white-space:nowrap;">${label}</td>
            <td style="padding:4px 16px 4px 4px; text-align:right; font-family:monospace; white-space:nowrap;">${valStr}</td>
            <td style="padding:4px 16px 4px 4px; text-align:center; color:#6c757d; white-space:nowrap;">${range}</td>
            <td style="padding:4px 4px; color:#6c757d; font-size:0.82em;">${better}</td>
        </tr>`;
    });
    tableHtml += '</tbody></table>';
    document.getElementById('cluster-quality-table').innerHTML = tableHtml;

    // Silhouette bar chart per series — one trace per cluster for legend
    const silDiv = document.getElementById('cluster-silhouette-plot');
    if (q.silhouettes && q.series_labels) {
        const sil         = q.silhouettes;
        const labs        = q.series_labels;
        const assignments = data.assignments || [];
        const palette     = CLUSTER_PALETTE;

        // Sort all points by silhouette score descending
        const points = sil.map((v, i) => ({
            v, lab: labs[i],
            clusterId: assignments[i],
        })).filter(x => isFinite(x.v)).sort((a, b) => b.v - a.v);

        // Group into one trace per cluster
        const clusterIds = [...new Set(assignments)].sort((a, b) => a - b);
        const traces = clusterIds.map(cid => {
            const pts   = points.filter(p => p.clusterId === cid);
            const color = palette[((cid - 1) % palette.length + palette.length) % palette.length] || '#888';
            return {
                type: 'bar', name: cid === 0 ? 'Noise' : `Cluster ${cid}`,
                x: pts.map(p => p.lab),
                y: pts.map(p => p.v),
                marker: { color },
                hovertemplate: '%{x}: %{y:.3f}<extra></extra>',
            };
        });

        Plotly.newPlot(silDiv, traces, {
            barmode: 'overlay',
            margin: { t: 30, b: 80, l: 50, r: 10 },
            xaxis: { tickangle: -45, tickfont: { size: 9 }, showticklabels: points.length < 80 },
            yaxis: { title: 'Silhouette score', zeroline: true, zerolinecolor: '#888' },
            title: { text: 'Silhouette per series', font: { size: 13 } },
            legend: { orientation: 'h', y: 1.12 },
            shapes: [{ type: 'line', x0: 0, x1: 1, xref: 'paper', y0: 0, y1: 0,
                       line: { color: 'red', width: 1, dash: 'dot' } }],
        }, { responsive: true, displayModeBar: false });
    } else {
        silDiv.innerHTML = '<p style="color:#aaa; text-align:center; padding:20px;">Silhouette not available</p>';
    }
}

// ----------------------------------------------------------------
// Best-k sweep
// ----------------------------------------------------------------

async function runClusterSweep() {
    const kMax    = parseInt(document.getElementById('cluster-sweep-kmax').value) || 10;
    const smooth  = document.getElementById('cluster-smooth-method').value;
    const method  = document.getElementById('cluster-method').value;
    const lowess  = parseFloat(document.getElementById('cluster-lowess-frac').value);
    const gHmult  = parseFloat(document.getElementById('cluster-gaussian-hmult').value);
    const maxiter = parseInt(document.getElementById('cluster-maxiter').value) || 300;
    const tol     = parseFloat(document.getElementById('cluster-tol').value) || 1e-6;
    const hLink   = document.getElementById('cluster-hclust-linkage').value;
    let body;

    if (state.currentClusteringMode === 'file') {
        const serverPath = document.getElementById('cluster-server-path').value.trim();
        const file = document.getElementById('clustering-file').files[0];
        if (serverPath) {
            body = { csv_path: serverPath, k_max: kMax };
        } else if (file) {
            body = { csv: await file.text(), k_max: kMax };
        } else return;
    } else {
        const selected = [...document.querySelectorAll('.clustering-exp-checkbox:checked')].map(c => c.value);
        if (!selected.length) return;
        body = { experiments: selected, k_max: kMax };
    }
    const doInterpolate = state.currentClusteringMode === 'file' &&
        document.getElementById('cluster-interpolate').checked;
    const { qLo: interpQLo, qHi: interpQHi } = getClusterInterpQuantiles();
    const { qLo: preQLo, qHi: preQHi }       = getClusterPrescreenQuantiles();
    Object.assign(body, {
        smooth_method: smooth, lowess_frac: lowess, gaussian_h_mult: gHmult,
        cluster_method: method, maxiter, tol, hclust_linkage: hLink,
        interpolate:         doInterpolate,
        interp_n:            parseInt(document.getElementById('cluster-interp-n').value) || 100,
        interp_quantile_lo:  interpQLo,
        interp_quantile_hi:  interpQHi,
        prescreen_constant:  document.getElementById('cluster-prescreen').checked,
        prescreen_tol_const: parseFloat(document.getElementById('cluster-prescreen-tol').value) || 1.5,
        prescreen_q_low:     preQLo,
        prescreen_q_high:    preQHi,
        trend_test_flat:     document.getElementById('cluster-trend-test').checked,
        trend_p_thr:         parseFloat(document.getElementById('cluster-trend-p').value) || 0.05,
    });

    document.getElementById('loading').style.display = 'flex';
    try {
        const res  = await fetch(`${API_BASE}/api/cluster-sweep`, {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body),
        });
        if (!res.ok) { alert('Sweep failed: ' + (await res.json()).error); return; }
        const data = await res.json();
        renderSweepPanel(data.sweep);
    } catch (e) {
        alert('Sweep failed: ' + e.message);
    } finally {
        document.getElementById('loading').style.display = 'none';
    }
}

// Return the k at which the second derivative of WCSS is maximised (elbow).
function _detectElbow(ks, wcss) {
    if (wcss.length < 3) return ks[0];
    let maxD2 = -Infinity, elbowIdx = 1;
    for (let i = 1; i < wcss.length - 1; i++) {
        const d2 = wcss[i - 1] - 2 * wcss[i] + wcss[i + 1];
        if (d2 > maxD2) { maxD2 = d2; elbowIdx = i; }
    }
    return ks[elbowIdx];
}

function renderSweepPanel(sweep) {
    document.getElementById('cluster-sweep-panel').style.display = 'block';
    const ks   = sweep.map(r => r.k);
    const wcss = sweep.map(r => r.wcss);

    // --- WCSS elbow plot ---
    const elbowK = _detectElbow(ks, wcss);
    const elbowY = wcss[ks.indexOf(elbowK)];
    Plotly.newPlot(document.getElementById('cluster-sweep-plot-wcss'), [
        {
            type: 'scatter', mode: 'lines+markers',
            x: ks, y: wcss, name: 'WCSS',
            marker: { size: 7, color: '#2c7bb6' },
            line:   { color: '#2c7bb6' },
            hovertemplate: 'k=%{x}  WCSS=%{y:.2f}<extra></extra>',
        },
        {
            type: 'scatter', mode: 'markers', name: `Elbow (k=${elbowK})`,
            x: [elbowK], y: [elbowY],
            marker: { size: 12, color: '#e74c3c', symbol: 'star' },
            hovertemplate: `Elbow k=${elbowK}<extra></extra>`,
        },
    ], {
        margin: { t: 36, b: 36, l: 52, r: 10 },
        xaxis:  { title: 'N clusters', dtick: 1, tickfont: { size: 11 } },
        yaxis:  { title: 'WCSS', tickfont: { size: 11 } },
        title:  { text: `WCSS (elbow: k=${elbowK}) ↓`, font: { size: 12 } },
        showlegend: false,
    }, { responsive: true, displayModeBar: false });

    // --- Other quality indices ---
    const indices = [
        { key: 'silhouette_mean',   divId: 'cluster-sweep-plot-silhouette',     label: 'Silhouette (mean) ↑',  color: '#4a90e2' },
        { key: 'calinski_harabasz', divId: 'cluster-sweep-plot-calinski',        label: 'Calinski-Harabasz ↑',  color: '#e67e22' },
        { key: 'xie_beni',          divId: 'cluster-sweep-plot-xie_beni',        label: 'Xie-Beni ↓',           color: '#8e44ad' },
        { key: 'davies_bouldin',    divId: 'cluster-sweep-plot-davies_bouldin',  label: 'Davies-Bouldin ↓',     color: '#e74c3c' },
        { key: 'dunn',              divId: 'cluster-sweep-plot-dunn',            label: 'Dunn ↑',               color: '#27ae60' },
    ];

    indices.forEach(({ key, divId, label, color }) => {
        const points = sweep.filter(r => Number.isFinite(r[key]));
        const xs = points.map(r => r.k);
        const ys = points.map(r => r[key]);
        Plotly.newPlot(document.getElementById(divId), [{
            type: 'scatter', mode: 'lines+markers',
            x: xs, y: ys,
            marker: { size: 7, color },
            line:   { color },
            hovertemplate: 'k=%{x}  %{y:.4f}<extra></extra>',
        }], {
            margin: { t: 36, b: 36, l: 52, r: 10 },
            xaxis:  { title: 'N clusters', dtick: 1, tickfont: { size: 11 } },
            yaxis:  { title: 'Quality', tickfont: { size: 11 } },
            title:  { text: label, font: { size: 12 } },
        }, { responsive: true, displayModeBar: false });
    });
}

// ----------------------------------------------------------------
// Save & Compare clusterings
// ----------------------------------------------------------------


function saveCurrentClustering() {
    if (!state._lastClusterData || !state._lastClusterData.assignments) return;
    const name = prompt('Name for this clustering:', `k${state._lastClusterData.assignments ? Math.max(...state._lastClusterData.assignments) : '?'} ${state._lastClusterData.cluster_method}`);
    if (!name) return;
    state._savedClusterings.push({
        name,
        assignments: state._lastClusterData.assignments,
        labels:      state._lastClusterData.series_labels,
        cluster_method: state._lastClusterData.cluster_method,
        smooth_method:  state._lastClusterData.smooth_method,
    });
    refreshSavedClusteringSelects();
    document.getElementById('cluster-compare-panel').style.display = 'block';
}

function refreshSavedClusteringSelects() {
    ['compare-select-a', 'compare-select-b'].forEach(id => {
        const sel = document.getElementById(id);
        sel.innerHTML = state._savedClusterings.map((c, i) =>
            `<option value="${i}">${c.name}</option>`).join('');
    });
    if (state._savedClusterings.length > 1) document.getElementById('compare-select-b').selectedIndex = 1;
}

function clearSavedClusterings() {
    state._savedClusterings = [];
    refreshSavedClusteringSelects();
    document.getElementById('cluster-compare-panel').style.display = 'none';
}

async function runClusterComparison() {
    const iA = parseInt(document.getElementById('compare-select-a').value);
    const iB = parseInt(document.getElementById('compare-select-b').value);
    if (isNaN(iA) || isNaN(iB)) return;
    const cA = state._savedClusterings[iA];
    const cB = state._savedClusterings[iB];
    if (!cA || !cB) return;
    if (cA.assignments.length !== cB.assignments.length) {
        alert('Cannot compare: clusterings have different numbers of series (' +
              cA.assignments.length + ' vs ' + cB.assignments.length + ').');
        return;
    }
    document.getElementById('loading').style.display = 'flex';
    try {
        const res = await fetch(`${API_BASE}/api/cluster-compare`, {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ assignments1: cA.assignments, assignments2: cB.assignments }),
        });
        if (!res.ok) { alert('Compare failed: ' + (await res.json()).error); return; }
        renderComparisonResult(await res.json(), cA, cB);
    } catch (e) {
        alert('Compare failed: ' + e.message);
    } finally {
        document.getElementById('loading').style.display = 'none';
    }
}

function renderComparisonResult(data, cA, cB) {
    const div = document.getElementById('compare-result');
    const fmt = v => (v === null || v === undefined) ? 'N/A' : v.toFixed(4);
    const metrics = [
        ['Rand Index',           data.rand_index,          'Fraction of pairs assigned consistently (0–1, ↑)'],
        ['Adjusted Rand Index',  data.adjusted_rand_index, 'Chance-corrected RI (–1 to 1, ↑)'],
        ['Variation of Info',    data.varinfo,             'Information distance (↓ = more similar)'],
        ['Mutual Information',   data.mutualinfo,          'Shared information (↑)'],
        ['V-measure',            data.vmeasure,            'Harmonic mean of homogeneity & completeness (↑)'],
    ];

    let html = `<p style="font-size:0.875em; color:#495057; margin-bottom:10px;">
        Comparing <strong>${cA.name}</strong> vs <strong>${cB.name}</strong></p>`;
    html += `<table style="border-collapse:collapse; font-size:0.875em; margin-bottom:16px;">
        <thead><tr style="border-bottom:2px solid #dee2e6;">
            <th style="padding:4px 16px 4px 4px; text-align:left;">Metric</th>
            <th style="padding:4px 16px 4px 4px; text-align:right;">Value</th>
            <th style="padding:4px 4px; text-align:left; color:#6c757d; font-size:0.9em;">Description</th>
        </tr></thead><tbody>`;
    metrics.forEach(([label, val, desc]) => {
        html += `<tr style="border-bottom:1px solid #f0f0f0;">
            <td style="padding:4px 16px 4px 4px;">${label}</td>
            <td style="padding:4px 16px 4px 4px; text-align:right; font-family:monospace;">${fmt(val)}</td>
            <td style="padding:4px 4px; color:#6c757d; font-size:0.85em;">${desc}</td>
        </tr>`;
    });
    html += '</tbody></table>';

    // Contingency matrix heatmap
    if (data.contingency) {
        const ct = data.contingency;
        const nA = ct.length;
        const nB = ct[0].length;
        const z  = ct;
        const xLabels = Array.from({length: nB}, (_, i) => `${cB.name} C${i+1}`);
        const yLabels = Array.from({length: nA}, (_, i) => `${cA.name} C${i+1}`);
        html += `<div id="compare-heatmap" style="height:${Math.max(200, nA * 40 + 80)}px;"></div>`;
        div.innerHTML = html;
        Plotly.newPlot(document.getElementById('compare-heatmap'), [{
            type: 'heatmap', z, x: xLabels, y: yLabels,
            colorscale: 'Blues', showscale: true,
            text: z.map(row => row.map(v => String(v))),
            texttemplate: '%{text}', textfont: { size: 12 },
            hovertemplate: '%{y} → %{x}: %{z} series<extra></extra>',
        }], {
            margin: { t: 40, b: 80, l: 120, r: 20 },
            xaxis: { title: cB.name, tickangle: -30 },
            yaxis: { title: cA.name },
            title: { text: 'Contingency matrix', font: { size: 13 } },
        }, { responsive: true, displayModeBar: false });
    } else {
        div.innerHTML = html;
    }
}


// ----------------------------------------------------------------
// Batch replicate averaging
// ----------------------------------------------------------------

async function runBatchAverage() {
    const fileInput  = document.getElementById('batch-avg-file');
    const serverPath = document.getElementById('batch-avg-server-path').value.trim();
    const groupCol   = document.getElementById('batch-avg-group-col').value.trim();
    const statusEl   = document.getElementById('batch-avg-status');

    let body = { group_col: groupCol };
    if (serverPath) {
        body.csv_path = serverPath;
    } else if (fileInput.files[0]) {
        body.csv = await fileInput.files[0].text();
    } else {
        statusEl.textContent = 'Provide a CSV file or server path.';
        return;
    }

    statusEl.textContent = 'Running…';
    try {
        const res = await fetch(`${API_BASE}/api/batch-average`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body),
        });
        const data = await res.json();
        if (!res.ok) { statusEl.textContent = 'Error: ' + (data.error || res.statusText); return; }

        statusEl.textContent =
            `Done — ${data.n_groups} groups × ${data.n_timepoints} time points. Downloading…`;

        const blob = new Blob([data.csv], { type: 'text/csv' });
        const a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = 'averaged_curves.csv';
        a.click();
        URL.revokeObjectURL(a.href);
    } catch (e) {
        statusEl.textContent = 'Error: ' + e.message;
    }
}

export {
    setClusteringMode, populateClusteringExperiments,
    selectAllClusteringExperiments, clearAllClusteringExperiments,
    onClusteringFileChange, updateClusteringRunBtn, toggleClusteringAdvanced,
    onClusterSmoothChange, onClusterMethodChange, onClusterBlankChange, onClusterInterpolateChange,
    renderClusterBlankNotice, runClustering, renderClusterGrid,
    exportClusterCSV, exportAllClustersCSV, exportAllClustersPNG,
    renderQualityPanel, runClusterSweep, renderSweepPanel,
    saveCurrentClustering, clearSavedClusterings, refreshSavedClusteringSelects,
    runClusterComparison, renderComparisonResult, hexToRgba,
    runBatchAverage,
};
