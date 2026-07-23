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

const CLUSTER_DRILL_COLORS = [
    '#2563eb', '#dc2626', '#16a34a', '#9333ea', '#ea580c',
    '#0891b2', '#be123c', '#4d7c0f', '#7c3aed', '#ca8a04'
];

function getClusterSeriesId(cluster, index) {
    const label = cluster.series_labels?.[index] ?? `Series ${index + 1}`;
    const metadata = cluster.series_metadata?.[index] || cluster.series_meta?.[index] || null;
    if (metadata && typeof metadata === 'object') {
        const keys = ['id', 'ID', 'Id', 'label', 'Label', 'name', 'Name', 'well', 'Well'];
        for (const key of keys) {
            const value = metadata[key];
            if (value !== undefined && value !== null && String(value).trim() !== '') {
                return String(value);
            }
        }
    }
    return String(label);
}

function clusterPlotsUseNormalized() {
    const bottom = document.getElementById('cluster-plot-normalize');
    if (bottom) return bottom.checked;
    return !!state._clusterPlotsNormalized;
}

function getClusterSeriesData(cluster) {
    if (clusterPlotsUseNormalized()) {
        return cluster.series_data_normalized || cluster.series_data || [];
    }
    return cluster.series_data_raw || cluster.series_data || [];
}

function getClusterCentroidData(cluster) {
    if (clusterPlotsUseNormalized()) {
        return {
            centroid: cluster.centroid_normalized || cluster.centroid,
            centroidSd: cluster.centroid_normalized_sd || cluster.centroid_sd,
        };
    }
    return {
        centroid: cluster.centroid_raw || cluster.centroid,
        centroidSd: cluster.centroid_raw_sd || cluster.centroid_sd,
    };
}

function syncClusterNormalizeCheckboxes(source = null) {
    const bottom = document.getElementById('cluster-plot-normalize');
    const fullscreenChecks = document.querySelectorAll('.cluster-fullscreen-normalize');
    let checked;
    if (source && typeof source === 'object' && 'checked' in source) {
        checked = !!source.checked;
    } else if (source === 'bottom' && bottom) {
        checked = bottom.checked;
    } else if (bottom) {
        checked = bottom.checked;
    } else {
        checked = !!state._clusterPlotsNormalized;
    }
    state._clusterPlotsNormalized = checked;
    if (bottom) bottom.checked = checked;
    fullscreenChecks.forEach(input => { input.checked = checked; });
    return checked;
}

function buildClusterPlotTraces(data, cluster, expColorMap, selectedIndices = null) {
    const time = data.time;
    const traces = [];
    const seriesData = getClusterSeriesData(cluster);
    const seriesLabels = cluster.series_labels || [];

    if (Array.isArray(selectedIndices)) {
        const selectedSet = new Set(selectedIndices);
        seriesData.forEach((y, i) => {
            if (!Array.isArray(y) || selectedSet.has(i)) return;
            traces.push({
                x: time,
                y,
                mode: 'lines',
                type: 'scatter',
                name: '',
                line: { width: 0.6, color: 'rgba(170,170,170,0.32)' },
                showlegend: false,
                hoverinfo: 'skip',
            });
        });

        selectedIndices.forEach((seriesIndex, selectedIndex) => {
            const y = seriesData[seriesIndex];
            if (!Array.isArray(y)) return;
            const label = seriesLabels[seriesIndex] || `Series ${seriesIndex + 1}`;
            const seriesId = getClusterSeriesId(cluster, seriesIndex);
            const color = CLUSTER_DRILL_COLORS[selectedIndex % CLUSTER_DRILL_COLORS.length];
            traces.push({
                x: time,
                y,
                mode: 'lines',
                type: 'scatter',
                name: seriesId,
                customdata: time.map(() => seriesId),
                line: { width: 2.5, color },
                showlegend: true,
                hovertemplate: 'ID: %{customdata}<br>Time: %{x}<br>Value: %{y}<extra></extra>',
            });
            if (label !== seriesId) {
                traces[traces.length - 1].legendgroup = label;
            }
        });
        return traces;
    }

    seriesData.forEach((y, i) => {
        const label = seriesLabels[i] || `Series ${i + 1}`;
        const exp = label.includes('/') ? label.split('/')[0] : null;
        const color = exp ? hexToRgba(expColorMap[exp], 0.45) : 'rgba(120,120,120,0.4)';
        traces.push({
            x: time, y,
            mode: 'lines', type: 'scatter',
            name: label,
            line: { width: 1, color },
            showlegend: false
        });
    });

    const { centroid, centroidSd } = getClusterCentroidData(cluster);
    if (centroid && centroidSd) {
        const upper = centroid.map((v, i) => v + centroidSd[i]);
        const lower = centroid.map((v, i) => v - centroidSd[i]);
        traces.push({
            x: [...time, ...time.slice().reverse()],
            y: [...upper, ...lower.slice().reverse()],
            fill: 'toself', fillcolor: 'rgba(180,0,0,0.10)',
            line: { color: 'transparent' },
            type: 'scatter', mode: 'lines',
            name: '+/- SD', showlegend: false, hoverinfo: 'skip',
        });
        traces.push({
            x: time, y: centroid,
            mode: 'lines', type: 'scatter',
            name: 'Mean +/- SD',
            line: { width: 2, color: 'rgb(180,0,0)' },
            showlegend: true,
        });
    } else {
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

    return traces;
}

function buildClusterPlotLayout(data, selectedIndices = null, viewRange = null, lensActive = false) {
    const selected = Array.isArray(selectedIndices);
    const layout = {
        margin: { t: selected ? 28 : 10, r: 10, b: 40, l: 50 },
        xaxis: { title: data.time_normalized ? 'Normalized time [0-1]' : 'Time' },
        yaxis: { title: clusterPlotsUseNormalized() ? 'Normalized value (z-score)' : 'Value' },
        legend: { x: 0, y: 1, orientation: selected ? 'h' : 'v' },
        title: selected ? { text: `${selectedIndices.length} nearest curves`, font: { size: 14 } } : { text: '' },
        dragmode: lensActive ? 'zoom' : false,
    };
    if (viewRange?.xRange) layout.xaxis.range = viewRange.xRange;
    if (viewRange?.yRange) layout.yaxis.range = viewRange.yRange;
    return layout;
}

function getPlotClickPoint(plotDiv, event) {
    const layout = plotDiv._fullLayout;
    if (!layout || !layout.xaxis || !layout.yaxis || !layout._size) return null;
    const rect = plotDiv.getBoundingClientRect();
    const xPixel = event.clientX - rect.left - layout._size.l;
    const yPixel = event.clientY - rect.top - layout._size.t;
    if (xPixel < 0 || yPixel < 0 || xPixel > layout._size.w || yPixel > layout._size.h) return null;
    const x = layout.xaxis.p2c(xPixel);
    const y = layout.yaxis.p2c(yPixel);
    if (!Number.isFinite(x) || !Number.isFinite(y)) return null;
    return { x, y };
}

function nearestClusterSeriesIndices(time, seriesData, point, xRange, yRange, count = 5) {
    const xSpan = Math.max(Math.abs((xRange?.[1] ?? time[time.length - 1]) - (xRange?.[0] ?? time[0])), 1e-12);
    const ySpan = Math.max(Math.abs((yRange?.[1] ?? 1) - (yRange?.[0] ?? 0)), 1e-12);
    const distances = [];
    seriesData.forEach((series, seriesIndex) => {
        let best = Infinity;
        for (let i = 0; i < Math.min(time.length, series.length); i += 1) {
            const x = Number(time[i]);
            const y = Number(series[i]);
            if (!Number.isFinite(x) || !Number.isFinite(y)) continue;
            const dx = (x - point.x) / xSpan;
            const dy = (y - point.y) / ySpan;
            best = Math.min(best, dx * dx + dy * dy);
        }
        if (Number.isFinite(best)) distances.push({ seriesIndex, distance: best });
    });
    return distances
        .sort((a, b) => a.distance - b.distance)
        .slice(0, count)
        .map(item => item.seriesIndex);
}

function cloneClusterView(view) {
    return {
        selected: Array.isArray(view?.selected) ? [...view.selected] : null,
        xRange: Array.isArray(view?.xRange) ? [...view.xRange] : null,
        yRange: Array.isArray(view?.yRange) ? [...view.yRange] : null,
    };
}

function rangesAreEqual(a, b) {
    if (!Array.isArray(a) && !Array.isArray(b)) return true;
    if (!Array.isArray(a) || !Array.isArray(b)) return false;
    return Math.abs(Number(a[0]) - Number(b[0])) < 1e-10 &&
        Math.abs(Number(a[1]) - Number(b[1])) < 1e-10;
}

function clusterViewsAreEqual(a, b) {
    const aSelected = Array.isArray(a?.selected) ? a.selected : null;
    const bSelected = Array.isArray(b?.selected) ? b.selected : null;
    const sameSelected = (!aSelected && !bSelected) ||
        (aSelected && bSelected &&
            aSelected.length === bSelected.length &&
            aSelected.every((value, index) => value === bSelected[index]));
    return sameSelected &&
        rangesAreEqual(a?.xRange, b?.xRange) &&
        rangesAreEqual(a?.yRange, b?.yRange);
}

function getCurrentClusterPlotRange(plotDiv) {
    const xRange = plotDiv._fullLayout?.xaxis?.range;
    const yRange = plotDiv._fullLayout?.yaxis?.range;
    return {
        xRange: Array.isArray(xRange) ? [Number(xRange[0]), Number(xRange[1])] : null,
        yRange: Array.isArray(yRange) ? [Number(yRange[0]), Number(yRange[1])] : null,
    };
}

function rangeFromClusterRelayout(eventData, axisName) {
    const start = eventData?.[`${axisName}.range[0]`];
    const end = eventData?.[`${axisName}.range[1]`];
    if (start !== undefined && end !== undefined) return [Number(start), Number(end)];
    const range = eventData?.[`${axisName}.range`];
    if (Array.isArray(range) && range.length >= 2) return [Number(range[0]), Number(range[1])];
    if (eventData?.[`${axisName}.autorange`]) return null;
    return undefined;
}

function createClusterIconButton(title, svgContent) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'cluster-drill-nav-btn cluster-icon-btn';
    button.title = title;
    button.setAttribute('aria-label', title);
    button.innerHTML = `<svg viewBox="0 0 24 24" aria-hidden="true">${svgContent}</svg>`;
    return button;
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
    const src = data.blank_source === 'derived' ? 'Derived' :
        data.blank_source === 'annotated+derived' ? 'Annotated and derived' : 'Annotated';
    const wells = (data.blank_wells_used || []).join(', ') || '—';
    const message = document.createElement('span');
    message.className = 'cluster-blank-notice-text';
    message.textContent = `🧪 Blank subtraction applied — ${src} blank wells: ${wells}`;
    const uncorrected = data.blank_uncorrected_experiments || [];
    if (uncorrected.length) {
        message.textContent += `; no same-experiment blank for: ${uncorrected.join(', ')}`;
    }

    const downloadButton = document.createElement('button');
    downloadButton.type = 'button';
    downloadButton.className = 'cluster-annotated-download-btn';
    downloadButton.textContent = 'Download annotated files';
    downloadButton.title =
        'Download the original data_channel_1.csv together with annotation_clean.csv marking the blank wells, ready for a Clean_data folder.';
    downloadButton.addEventListener('click', () =>
        downloadClusterAnnotatedFiles(downloadButton));

    notice.replaceChildren(message, downloadButton);
    notice.style.display = 'flex';
}

async function downloadClusterAnnotatedFiles(button) {
    const data = state._lastClusterData;
    const source = data?._annotatedExportSource;
    if (!data?.blank_subtracted || !source) {
        alert('Run clustering with blank subtraction before downloading annotated files.');
        return;
    }

    const originalText = button.textContent;
    button.disabled = true;
    button.textContent = 'Preparing…';
    try {
        const response = await fetch(`${API_BASE}/api/cluster/annotated-files`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                ...source,
                blank_wells_used: data.blank_wells_used || [],
            }),
        });
        if (!response.ok) {
            let message = response.statusText;
            try {
                const errorBody = await response.json();
                message = errorBody.error || message;
            } catch (_) {}
            throw new Error(message);
        }

        const blob = await response.blob();
        const disposition = response.headers.get('Content-Disposition') || '';
        const filenameMatch = disposition.match(/filename="?([^";]+)"?/i);
        const filename = filenameMatch?.[1] || 'clustering_annotated_files.zip';
        const url = URL.createObjectURL(blob);
        const link = document.createElement('a');
        link.href = url;
        link.download = filename;
        document.body.appendChild(link);
        link.click();
        link.remove();
        URL.revokeObjectURL(url);
    } catch (error) {
        alert(`Annotated-file download failed: ${error.message}`);
    } finally {
        button.disabled = false;
        button.textContent = originalText;
    }
}

function onClusterBlankChange() {
    const checked = document.getElementById('cluster-subtract-blank').checked;
    if (!checked) document.getElementById('cluster-derive-blank').checked = false;
    document.getElementById('cluster-blank-method-row').style.display = checked ? 'flex' : 'none';
}

function onClusterDerivedBlankChange() {
    const derive = document.getElementById('cluster-derive-blank').checked;
    if (derive) document.getElementById('cluster-subtract-blank').checked = true;
    onClusterBlankChange();
}

async function deriveBlanksFromNonGrowingCluster() {
    const deriveInput = document.getElementById('cluster-derive-blank');
    deriveInput.checked = true;
    onClusterDerivedBlankChange();
    if (document.getElementById('cluster-method').value !== 'dbscan') {
        const kInput = document.getElementById('clustering-k');
        kInput.value = Math.max(1, (parseInt(kInput.value, 10) || 1) - 1);
    }
    await runClustering();
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
    const sweepBtn = document.getElementById('cluster-sweep-btn');
    const isDbscan = document.getElementById('cluster-method').value === 'dbscan';
    sweepBtn.disabled = !hasData || isDbscan;
    sweepBtn.title = isDbscan
        ? 'Cluster-number sweep is unavailable for DBSCAN because DBSCAN does not use k'
        : 'Evaluate clustering across candidate values of k';
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

function onClusterNormalizeChange(source = null) {
    const checked = syncClusterNormalizeCheckboxes(source);
    if (!state._lastClusterData) return;
    const refreshers = state._clusterPlotRefreshers || [];
    if (refreshers.length) {
        refreshers.forEach(refresh => refresh());
    } else {
        renderClusterGrid(state._lastClusterData);
    }
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
    document.getElementById('cluster-n-init-param').style.display   = method === 'kmeans' ? 'flex' : 'none';
    updateClusteringRunBtn();
}

// Store last cluster data for export

async function runClustering() {
    const k          = parseInt(document.getElementById('clustering-k').value) || 3;
    const normalize  = syncClusterNormalizeCheckboxes('bottom');
    const smooth     = document.getElementById('cluster-smooth-method').value;
    const lowessFrac = parseFloat(document.getElementById('cluster-lowess-frac').value);
    const gHmult     = parseFloat(document.getElementById('cluster-gaussian-hmult').value);
    const method     = document.getElementById('cluster-method').value;
    const maxiter    = parseInt(document.getElementById('cluster-maxiter').value) || 300;
    const tol        = parseFloat(document.getElementById('cluster-tol').value) || 1e-6;
    const nInit      = Math.min(100, Math.max(1, parseInt(document.getElementById('cluster-n-init').value, 10) || 3));
    document.getElementById('cluster-n-init').value = nInit;
    const hLinkage   = document.getElementById('cluster-hclust-linkage').value;
    const dbscanEps  = parseFloat(document.getElementById('cluster-dbscan-eps').value);
    const dbscanMin  = parseInt(document.getElementById('cluster-dbscan-minpts').value);
    const deriveBlanks = document.getElementById('cluster-derive-blank').checked;
    const usePrescreen = document.getElementById('cluster-prescreen').checked;
    const useTrendTest = document.getElementById('cluster-trend-test').checked;
    if (deriveBlanks && !usePrescreen && !useTrendTest) {
        alert('Enable the non-growing pre-screen, the trend test, or both before deriving blanks.');
        return;
    }
    let sourceInfo    = {};
    let annotatedExportSource = {};
    let body;

    if (state.currentClusteringMode === 'file') {
        const serverPath = document.getElementById('cluster-server-path').value.trim();
        const file = document.getElementById('clustering-file').files[0];
        if (serverPath) {
            body = { csv_path: serverPath, k, normalize };
            sourceInfo = { csv_path: serverPath };
            annotatedExportSource = {
                csv_path: serverPath,
                csv_name: serverPath.split(/[\\/]/).pop() || 'clustering_data.csv',
            };
        } else if (file) {
            const csvText = await file.text();
            body = { csv: csvText, k, normalize };
            sourceInfo = { csv_name: file.name };
            annotatedExportSource = { csv: csvText, csv_name: file.name };
        } else return;
    } else {
        const selected = [...document.querySelectorAll('.clustering-exp-checkbox:checked')].map(c => c.value);
        if (!selected.length) return;
        body = { experiments: selected, k, normalize };
        sourceInfo = { experiments: selected };
        annotatedExportSource = { experiments: selected };
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
        maxiter,
        tol,
        kmeans_n_init: nInit,
        hclust_linkage: hLinkage,
        dbscan_eps: dbscanEps,
        dbscan_min_pts: dbscanMin,
        subtract_blank:       document.getElementById('cluster-subtract-blank').checked,
        derive_non_growing_blanks: deriveBlanks,
        blank_method:         document.getElementById('cluster-blank-method').value,
        interpolate:           doInterpolate,
        interp_n:              parseInt(document.getElementById('cluster-interp-n').value) || 100,
        interp_quantile_lo:    interpQLo,
        interp_quantile_hi:    interpQHi,
        prescreen_constant:    usePrescreen,
        prescreen_tol_const:   parseFloat(document.getElementById('cluster-prescreen-tol').value) || 1.5,
        prescreen_q_low:       preQLo,
        prescreen_q_high:      preQHi,
        trend_test_flat:       useTrendTest,
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
            ...sourceInfo,
            k,
            normalize,
            smooth_method:  smooth,
            lowess_frac:    lowessFrac,
            gaussian_h_mult: gHmult,
            cluster_method: method,
            maxiter,
            tol,
            kmeans_n_init: nInit,
            hclust_linkage: hLinkage,
            dbscan_eps:     dbscanEps,
            dbscan_min_pts: dbscanMin,
            subtract_blank: document.getElementById('cluster-subtract-blank').checked,
            derive_non_growing_blanks: deriveBlanks,
            blank_method:   document.getElementById('cluster-blank-method').value,
            interpolate:         doInterpolate,
            interp_n:            parseInt(document.getElementById('cluster-interp-n').value) || 100,
            interp_quantile_lo:  interpQLo,
            interp_quantile_hi:  interpQHi,
            prescreen_constant:  usePrescreen,
            prescreen_tol_const: parseFloat(document.getElementById('cluster-prescreen-tol').value) || 1.5,
            prescreen_q_low:     preQLo,
            prescreen_q_high:    preQHi,
            trend_test_flat:     useTrendTest,
            trend_p_thr:         parseFloat(document.getElementById('cluster-trend-p').value) || 0.05,
        };
        data._annotatedExportSource = annotatedExportSource;
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
    state._clusterPlotRefreshers = [];

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

        if (cluster.is_non_growing) {
            const deriveBtn = document.createElement('button');
            deriveBtn.className = 'cluster-btn';
            deriveBtn.textContent = 'Derive blanks';
            deriveBtn.title = 'Use these non-growing curves as experiment-specific blanks and rerun clustering';
            deriveBtn.addEventListener('click', deriveBlanksFromNonGrowingCluster);
            title.appendChild(deriveBtn);
        }

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

        const drillNav = document.createElement('div');
        drillNav.className = 'cluster-drill-nav';
        const drillPrevBtn = document.createElement('button');
        drillPrevBtn.type = 'button';
        drillPrevBtn.className = 'cluster-drill-nav-btn';
        drillPrevBtn.textContent = '<';
        drillPrevBtn.title = 'Previous view';
        const drillHomeBtn = createClusterIconButton(
            'Reset view',
            '<path d="M4 11.5L12 5l8 6.5"></path><path d="M6.5 10.5V20h11V10.5"></path><path d="M9.5 20v-5h5v5"></path>'
        );
        const drillNextBtn = document.createElement('button');
        drillNextBtn.type = 'button';
        drillNextBtn.className = 'cluster-drill-nav-btn';
        drillNextBtn.textContent = '>';
        drillNextBtn.title = 'Next view';
        const zoomBtn = createClusterIconButton(
            'Draw rectangle to zoom',
            '<circle cx="10.5" cy="10.5" r="6"></circle><line x1="15" y1="15" x2="21" y2="21"></line>'
        );
        const resetZoomBtn = createClusterIconButton(
            'Reset zoom, keep selected curves',
            '<circle cx="10.5" cy="10.5" r="6"></circle><line x1="15" y1="15" x2="21" y2="21"></line><line class="cluster-reset-x" x1="8.3" y1="8.3" x2="12.7" y2="12.7"></line><line class="cluster-reset-x" x1="12.7" y1="8.3" x2="8.3" y2="12.7"></line>'
        );
        const fsNormalizeLabel = document.createElement('label');
        fsNormalizeLabel.className = 'cluster-fullscreen-normalize-label';
        const fsNormalizeInput = document.createElement('input');
        fsNormalizeInput.type = 'checkbox';
        fsNormalizeInput.className = 'cluster-fullscreen-normalize';
        fsNormalizeInput.checked = clusterPlotsUseNormalized();
        fsNormalizeInput.onchange = event => {
            event.stopPropagation();
            onClusterNormalizeChange(fsNormalizeInput);
        };
        fsNormalizeLabel.appendChild(fsNormalizeInput);
        fsNormalizeLabel.appendChild(document.createTextNode(' Normalize'));
        drillNav.appendChild(drillPrevBtn);
        drillNav.appendChild(drillHomeBtn);
        drillNav.appendChild(drillNextBtn);
        drillNav.appendChild(zoomBtn);
        drillNav.appendChild(resetZoomBtn);
        drillNav.appendChild(fsNormalizeLabel);
        cell.appendChild(drillNav);

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

        const viewState = {
            history: [{ selected: null, xRange: null, yRange: null }],
            index: 0,
            lensActive: false,
            suppressRelayout: false,
            displayNormalized: clusterPlotsUseNormalized(),
        };

        function currentView() {
            return viewState.history[viewState.index] || { selected: null, xRange: null, yRange: null };
        }

        function updateDrillNav() {
            const isFs = cell.classList.contains('fullscreen');
            const view = currentView();
            drillNav.hidden = !isFs;
            drillPrevBtn.disabled = viewState.index <= 0;
            drillHomeBtn.disabled = viewState.index === 0;
            drillNextBtn.disabled = viewState.index >= viewState.history.length - 1;
            resetZoomBtn.disabled = !view.xRange && !view.yRange;
            zoomBtn.classList.toggle('active', viewState.lensActive);
            fsNormalizeInput.checked = clusterPlotsUseNormalized();
            plotDiv.classList.toggle('cluster-zoom-active', isFs && viewState.lensActive);
        }

        function pushClusterView(nextView) {
            const normalized = cloneClusterView(nextView);
            if (clusterViewsAreEqual(currentView(), normalized)) {
                updateDrillNav();
                return;
            }
            viewState.history = viewState.history.slice(0, viewState.index + 1);
            viewState.history.push(normalized);
            viewState.index = viewState.history.length - 1;
            updateDrillNav();
        }

        function renderClusterPlot() {
            const displayNormalized = clusterPlotsUseNormalized();
            if (viewState.displayNormalized !== displayNormalized) {
                viewState.history = viewState.history.map(view => ({
                    ...view,
                    yRange: null,
                }));
                viewState.displayNormalized = displayNormalized;
            }
            const view = currentView();
            const selected = view.selected;
            const traces = buildClusterPlotTraces(data, cluster, expColorMap, selected);
            const layout = buildClusterPlotLayout(data, selected, view, viewState.lensActive);
            viewState.suppressRelayout = true;
            return Plotly.react(plotDiv, traces, layout, { responsive: true, displayModeBar: false }).then(() => {
                Plotly.Plots.resize(plotDiv);
                viewState.suppressRelayout = false;
                updateDrillNav();
            }).catch((err) => {
                viewState.suppressRelayout = false;
                console.error('Cluster plot render failed:', err);
            });
        }
        state._clusterPlotRefreshers.push(renderClusterPlot);

        function resetClusterDrill() {
            viewState.history = [{ selected: null, xRange: null, yRange: null }];
            viewState.index = 0;
            viewState.lensActive = false;
            return renderClusterPlot();
        }

        function moveClusterDrill(offset) {
            const next = viewState.index + offset;
            if (next < 0 || next >= viewState.history.length) return;
            viewState.index = next;
            renderClusterPlot();
        }

        function resetClusterZoom() {
            const view = cloneClusterView(currentView());
            if (!view.xRange && !view.yRange) return;
            viewState.lensActive = false;
            pushClusterView({
                selected: view.selected,
                xRange: null,
                yRange: null,
            });
            renderClusterPlot();
        }

        function bindClusterZoomHistory() {
            if (plotDiv._clusterZoomHistoryBound || typeof plotDiv.on !== 'function') return;
            plotDiv._clusterZoomHistoryBound = true;
            plotDiv.on('plotly_relayout', eventData => {
                if (viewState.suppressRelayout || !cell.classList.contains('fullscreen') || !viewState.lensActive) return;
                const current = cloneClusterView(currentView());
                const xRange = rangeFromClusterRelayout(eventData, 'xaxis');
                const yRange = rangeFromClusterRelayout(eventData, 'yaxis');
                if (xRange === undefined && yRange === undefined) return;
                const fullRange = getCurrentClusterPlotRange(plotDiv);
                pushClusterView({
                    selected: current.selected,
                    xRange: xRange === undefined ? fullRange.xRange : xRange,
                    yRange: yRange === undefined ? fullRange.yRange : yRange,
                });
            });
        }

        seriesBtn.onclick = () => {
            seriesList.classList.toggle('open');
            seriesBtn.textContent = seriesList.classList.contains('open') ? '📋 Hide' : '📋 Series';
        };

        fsBtn.onclick = () => {
            const isFs = cell.classList.toggle('fullscreen');
            fsBtn.textContent = isFs ? '✕ Exit' : '⛶ Fullscreen';
            document.body.style.overflow = isFs ? 'hidden' : '';
            if (isFs) {
                updateDrillNav();
            Plotly.Plots.resize(plotDiv);
            } else {
                resetClusterDrill();
            }
        };

        drillPrevBtn.onclick = event => {
            event.stopPropagation();
            moveClusterDrill(-1);
        };
        drillNextBtn.onclick = event => {
            event.stopPropagation();
            moveClusterDrill(1);
        };
        drillHomeBtn.onclick = event => {
            event.stopPropagation();
            if (viewState.index === 0) return;
            viewState.index = 0;
            renderClusterPlot();
        };
        zoomBtn.onclick = event => {
            event.stopPropagation();
            viewState.lensActive = !viewState.lensActive;
            renderClusterPlot();
        };
        resetZoomBtn.onclick = event => {
            event.stopPropagation();
            resetClusterZoom();
        };

        exportCsvBtn.onclick = () => exportClusterCSV(cluster);
        exportPngBtn.onclick = () => Plotly.downloadImage(plotDiv, {
            format: 'png', width: 900, height: 500,
            filename: `cluster_${clusterLabel}`
        });

        plotDiv.addEventListener('click', event => {
            if (!cell.classList.contains('fullscreen')) return;
            if (viewState.lensActive) return;
            if (event.target.closest('.modebar') || event.target.closest('.legend')) return;
            const point = getPlotClickPoint(plotDiv, event);
            if (!point) return;
            const currentRange = getCurrentClusterPlotRange(plotDiv);
            const selected = nearestClusterSeriesIndices(
                time,
                getClusterSeriesData(cluster),
                point,
                currentRange.xRange,
                currentRange.yRange,
                5
            );
            if (!selected.length) return;
            pushClusterView({
                selected,
                xRange: currentRange.xRange,
                yRange: currentRange.yRange,
            });
            renderClusterPlot();
            });

        renderClusterPlot().then(bindClusterZoomHistory);
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

function exportClusterCentroidsCSV() {
    const data = state._lastClusterData;
    if (!data || !Array.isArray(data.clusters) || data.clusters.length === 0) {
        alert('No clustering results to export.');
        return;
    }

    const time = Array.isArray(data.time) ? data.time : [];
    const nTimeCols = Math.max(
        time.length,
        ...data.clusters.map(cluster => Math.max(
            (cluster.centroid_raw || []).length,
            (cluster.centroid_raw_sd || []).length,
            (cluster.centroid_normalized || []).length,
            (cluster.centroid_normalized_sd || []).length,
        )),
    );
    const timeLabels = Array.from({ length: nTimeCols }, (_, i) => {
        const t = time[i];
        const n = Number(t);
        const suffix = Number.isFinite(n)
            ? (Number.isInteger(n) ? String(n) : String(Number(n.toPrecision(12))))
            : String(t);
        return suffix === '' || suffix === 'undefined' ? String(i + 1) : suffix;
    });
    const clusters = [...data.clusters].sort((a, b) => {
        const ai = Number.isFinite(a.id) ? a.id : Number.MAX_SAFE_INTEGER;
        const bi = Number.isFinite(b.id) ? b.id : Number.MAX_SAFE_INTEGER;
        if (ai !== bi) return ai - bi;
        return String(a.label || '').localeCompare(String(b.label || ''));
    });
    const hasDistinctClusterLabels = clusters.some(cluster => {
        const id = cluster.id ?? '';
        return String(cluster.label || id) !== String(id);
    });
    const clusterColumns = hasDistinctClusterLabels
        ? ['cluster_id', 'cluster_label']
        : ['cluster'];
    const header = [
        ...clusterColumns,
        'n_series',
        'type',
        ...timeLabels.map(t => `centroid_t_${t}`),
        ...timeLabels.map(t => `centroid_sd_t_${t}`),
    ];
    const rows = [header];

    clusters.forEach(cluster => {
        const nSeries  = cluster.n_total ?? (cluster.series_labels || []).length;
        const idxs     = Array.from({ length: nTimeCols }, (_, i) => i);
        const clusterValues = hasDistinctClusterLabels
            ? [cluster.id ?? '', cluster.label || String(cluster.id ?? '')]
            : [cluster.label || String(cluster.id ?? '')];

        [
            ['normalized', cluster.centroid_normalized || [], cluster.centroid_normalized_sd || []],
            ['raw',        cluster.centroid_raw || [],        cluster.centroid_raw_sd || []],
        ].forEach(([type, centroid, centroidSd]) => {
            rows.push([
                ...clusterValues,
                nSeries,
                type,
                ...idxs.map(i => centroid[i] ?? ''),
                ...idxs.map(i => centroidSd[i] ?? ''),
            ]);
        });
    });

    _downloadCSV(rows, 'cluster_centroids_raw_and_normalized.csv');
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

const SWEEP_METRICS = [
    {
        key: 'cost',
        divId: 'cluster-sweep-plot-wcss',
        titleId: 'cluster-sweep-title-wcss',
        label: 'Clustering cost',
        direction: '\u2193',
        color: '#2c7bb6',
    },
    {
        key: 'silhouette_mean',
        divId: 'cluster-sweep-plot-silhouette',
        titleId: 'cluster-sweep-title-silhouette_mean',
        label: 'Silhouette (mean)',
        direction: '\u2191',
        color: '#4a90e2',
    },
    {
        key: 'calinski_harabasz',
        divId: 'cluster-sweep-plot-calinski',
        titleId: 'cluster-sweep-title-calinski_harabasz',
        label: 'Calinski-Harabasz',
        direction: '\u2191',
        color: '#e67e22',
    },
    {
        key: 'xie_beni',
        divId: 'cluster-sweep-plot-xie_beni',
        titleId: 'cluster-sweep-title-xie_beni',
        label: 'Xie-Beni',
        direction: '\u2193',
        color: '#8e44ad',
    },
    {
        key: 'davies_bouldin',
        divId: 'cluster-sweep-plot-davies_bouldin',
        titleId: 'cluster-sweep-title-davies_bouldin',
        label: 'Davies-Bouldin',
        direction: '\u2193',
        color: '#e74c3c',
    },
    {
        key: 'dunn',
        divId: 'cluster-sweep-plot-dunn',
        titleId: 'cluster-sweep-title-dunn',
        label: 'Dunn',
        direction: '\u2191',
        color: '#27ae60',
    },
];

async function runClusterSweep() {
    const kMax    = parseInt(document.getElementById('cluster-sweep-kmax').value) || 10;
    const smooth  = document.getElementById('cluster-smooth-method').value;
    const method  = document.getElementById('cluster-method').value;
    if (method === 'dbscan') {
        alert('Cluster-number sweep is unavailable for DBSCAN because DBSCAN does not use k.');
        return;
    }
    const lowess  = parseFloat(document.getElementById('cluster-lowess-frac').value);
    const gHmult  = parseFloat(document.getElementById('cluster-gaussian-hmult').value);
    const maxiter = parseInt(document.getElementById('cluster-maxiter').value) || 300;
    const tol     = parseFloat(document.getElementById('cluster-tol').value) || 1e-6;
    const nInit   = Math.min(100, Math.max(1, parseInt(document.getElementById('cluster-n-init').value, 10) || 3));
    document.getElementById('cluster-n-init').value = nInit;
    const hLink   = document.getElementById('cluster-hclust-linkage').value;
    const deriveBlanks = document.getElementById('cluster-derive-blank').checked;
    const usePrescreen = document.getElementById('cluster-prescreen').checked;
    const useTrendTest = document.getElementById('cluster-trend-test').checked;
    if (deriveBlanks && !usePrescreen && !useTrendTest) {
        alert('Enable the non-growing pre-screen, the trend test, or both before deriving blanks.');
        return;
    }
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
        cluster_method: method, maxiter, tol, kmeans_n_init: nInit, hclust_linkage: hLink,
        subtract_blank:      document.getElementById('cluster-subtract-blank').checked,
        derive_non_growing_blanks: deriveBlanks,
        blank_method:        document.getElementById('cluster-blank-method').value,
        interpolate:         doInterpolate,
        interp_n:            parseInt(document.getElementById('cluster-interp-n').value) || 100,
        interp_quantile_lo:  interpQLo,
        interp_quantile_hi:  interpQHi,
        prescreen_constant:  usePrescreen,
        prescreen_tol_const: parseFloat(document.getElementById('cluster-prescreen-tol').value) || 1.5,
        prescreen_q_low:     preQLo,
        prescreen_q_high:    preQHi,
        trend_test_flat:     useTrendTest,
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
        state._lastClusterSweep = data.sweep || [];
        state._lastClusterSweepCostMetric = data.cost_metric || 'wcss';
        renderSweepPanel(state._lastClusterSweep);
    } catch (e) {
        alert('Sweep failed: ' + e.message);
    } finally {
        document.getElementById('loading').style.display = 'none';
    }
}

// Return the k at which the second derivative of clustering cost is maximised.
function _detectElbow(ks, costs) {
    if (costs.length < 3) return ks[0];
    let maxD2 = -Infinity, elbowIdx = 1;
    for (let i = 1; i < costs.length - 1; i++) {
        const d2 = costs[i - 1] - 2 * costs[i] + costs[i + 1];
        if (d2 > maxD2) { maxD2 = d2; elbowIdx = i; }
    }
    return ks[elbowIdx];
}

function _setSweepTitle(metricKey, text) {
    const metric = SWEEP_METRICS.find(m => m.key === metricKey);
    const titleEl = metric ? document.getElementById(metric.titleId) : null;
    if (titleEl) titleEl.textContent = text;
}

function _bindSweepDownloadButtons() {
    document.querySelectorAll('.cluster-sweep-download').forEach(btn => {
        btn.onclick = () => downloadSweepMetricCSV(btn.dataset.sweepMetric);
    });
}

function downloadSweepMetricCSV(metricKey) {
    const metric = SWEEP_METRICS.find(m => m.key === metricKey);
    const sweep = state._lastClusterSweep || [];
    if (!metric || sweep.length === 0) {
        alert('No sweep results to export.');
        return;
    }

    const rows = [['k', metric.key]];
    sweep.forEach(r => {
        const value = Number.isFinite(r[metric.key]) ? r[metric.key] : '';
        rows.push([r.k, value]);
    });
    _downloadCSV(rows, `cluster_sweep_${metric.key}.csv`);
}

function renderSweepPanel(sweep) {
    sweep = sweep || [];
    state._lastClusterSweep = sweep || [];
    document.getElementById('cluster-sweep-panel').style.display = 'block';
    _bindSweepDownloadButtons();

    const ks = sweep.map(r => r.k);
    const costs = sweep.map(r => Number.isFinite(r.cost) ? r.cost : r.wcss);
    const costLabel = 'WCSS';

    // --- Method-independent centroid-WCSS elbow plot ---
    const elbowK = _detectElbow(ks, costs);
    const elbowY = costs[ks.indexOf(elbowK)];
    _setSweepTitle('cost', `${costLabel} (elbow: k=${elbowK}) \u2193`);
    Plotly.newPlot(document.getElementById('cluster-sweep-plot-wcss'), [
        {
            type: 'scatter', mode: 'lines+markers',
            x: ks, y: costs, name: costLabel,
            marker: { size: 7, color: '#2c7bb6' },
            line:   { color: '#2c7bb6' },
            hovertemplate: `k=%{x}  ${costLabel}=%{y:.2f}<extra></extra>`,
        },
        {
            type: 'scatter', mode: 'markers', name: `Elbow (k=${elbowK})`,
            x: [elbowK], y: [elbowY],
            marker: { size: 12, color: '#e74c3c', symbol: 'star' },
            hovertemplate: `Elbow k=${elbowK}<extra></extra>`,
        },
    ], {
        margin: { t: 8, b: 36, l: 52, r: 10 },
        xaxis:  { title: 'N clusters', dtick: 1, tickfont: { size: 11 } },
        yaxis:  { title: costLabel, tickfont: { size: 11 } },
        title:  { text: '', font: { size: 12 } },
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
        const metric = SWEEP_METRICS.find(m => m.key === key);
        _setSweepTitle(key, metric ? `${metric.label} ${metric.direction}` : label);
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
            margin: { t: 8, b: 36, l: 52, r: 10 },
            xaxis:  { title: 'N clusters', dtick: 1, tickfont: { size: 11 } },
            yaxis:  { title: 'Quality', tickfont: { size: 11 } },
            title:  { text: '', font: { size: 12 } },
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
    onClusteringFileChange, onClusterNormalizeChange, updateClusteringRunBtn, toggleClusteringAdvanced,
    onClusterSmoothChange, onClusterMethodChange, onClusterBlankChange, onClusterDerivedBlankChange, onClusterInterpolateChange,
    renderClusterBlankNotice, runClustering, renderClusterGrid,
    exportClusterCSV, exportAllClustersCSV, exportClusterCentroidsCSV, exportAllClustersPNG,
    renderQualityPanel, runClusterSweep, renderSweepPanel,
    saveCurrentClustering, clearSavedClusterings, refreshSavedClusteringSelects,
    runClusterComparison, renderComparisonResult, hexToRgba,
    runBatchAverage,
};
