import { state, API_BASE } from './state.js';
import { buildMultiChannelLayout, channelToYAxis, displayStats } from './plot.js';
import { hidePlotAndStats } from './ui.js';

function buildReplicateList(wells) {
    state.allReplicates = {};
    wells.forEach(wellInfo => {
        const ch = wellInfo.channel || 1;
        const key = `${wellInfo.condition}|||${wellInfo.antibiotic}|||ch${ch}`;
        if (!state.allReplicates[key]) {
            state.allReplicates[key] = { label: `${wellInfo.condition} | ${wellInfo.antibiotic} | Ch${ch}`, wells: [], channel: ch };
        }
        state.allReplicates[key].wells.push(wellInfo);
    });

    const replicatesList = document.getElementById('replicates-list');
    replicatesList.innerHTML = '';

    const entries = Object.entries(state.allReplicates).filter(([, rep]) => rep.wells.length >= 2);
    if (entries.length === 0) {
        replicatesList.innerHTML = '<p style="color:#6c757d;font-style:italic;padding:10px;">No replicates found (need at least 2 wells with matching conditions).</p>';
        return;
    }

    entries.forEach(([key, rep]) => {
        const experiments = [...new Set(rep.wells.map(w => w.experiment))];
        const expLabel = experiments.length === 1 ? experiments[0] : `${experiments.length} experiments`;
        const item = document.createElement('div');
        item.className = `replicate-item ${state.selectedReplicateKeys.has(key) ? 'selected' : ''}`;
        item.dataset.replicateKey = key;
        item.onclick = function() { toggleReplicate(key, this); };
        item.innerHTML = `
            <div class="replicate-name">${rep.label}</div>
            <div class="replicate-count">${rep.wells.length} wells · ${expLabel}</div>
        `;
        replicatesList.appendChild(item);
    });
}

function toggleReplicate(key, el) {
    if (state.selectedReplicateKeys.has(key)) {
        state.selectedReplicateKeys.delete(key);
        if (el) el.classList.remove('selected');
    } else {
        state.selectedReplicateKeys.add(key);
        if (el) el.classList.add('selected');
    }
    updateSelectedReplicatesCount();
    if (state.selectedReplicateKeys.size > 0) {
        plotReplicates();
    } else {
        hidePlotAndStats();
    }
}

function selectAllReplicates() {
    document.querySelectorAll('.replicate-item').forEach(item => {
        const key = item.dataset.replicateKey;
        if (key) {
            state.selectedReplicateKeys.add(key);
            item.classList.add('selected');
        }
    });
    updateSelectedReplicatesCount();
    if (state.selectedReplicateKeys.size > 0) plotReplicates();
}

function clearAllReplicates() {
    state.selectedReplicateKeys.clear();
    document.querySelectorAll('.replicate-item').forEach(item => item.classList.remove('selected'));
    updateSelectedReplicatesCount();
    hidePlotAndStats();
}

function updateSelectedReplicatesCount() {
    document.getElementById('selected-replicates-count').textContent =
        `${state.selectedReplicateKeys.size} replicates selected`;
}

function onShowIndividualChange() {
    if (state.selectedReplicateKeys.size > 0) plotReplicates();
}

function setPlotMode(mode) {
    state.currentPlotMode = mode;
    document.getElementById('wells-mode-content').style.display = mode === 'wells' ? 'block' : 'none';
    document.getElementById('replicates-mode-content').style.display = mode === 'replicates' ? 'block' : 'none';
    document.getElementById('mode-btn-wells').classList.toggle('active', mode === 'wells');
    document.getElementById('mode-btn-replicates').classList.toggle('active', mode === 'replicates');

    if (mode === 'wells') {
        if (state.selectedWellIds.size > 0) plotGrowthCurves(); else hidePlotAndStats();
    } else {
        if (state.selectedReplicateKeys.size > 0) plotReplicates(); else hidePlotAndStats();
    }
}

function computeReplicateAverage(traces) {
    if (traces.length === 0) return { x: [], y: [] };
    if (traces.length === 1) return { x: traces[0].x, y: [...traces[0].y] };
    const minLen = Math.min(...traces.map(t => t.x.length));
    const avgX = traces[0].x.slice(0, minLen);
    const avgY = avgX.map((_, i) => {
        const vals = traces.map(t => t.y[i]).filter(v => !isNaN(v));
        return vals.length > 0 ? vals.reduce((a, b) => a + b, 0) / vals.length : NaN;
    });
    return { x: avgX, y: avgY };
}

function trapezoidalAUC(x, y) {
    let auc = 0;
    for (let i = 1; i < x.length; i++) {
        if (!isNaN(y[i]) && !isNaN(y[i - 1])) {
            auc += (x[i] - x[i - 1]) * (y[i] + y[i - 1]) / 2;
        }
    }
    return auc;
}

async function plotReplicates() {
    if (state.selectedReplicateKeys.size === 0) return;
    showLoading();
    try {
        const allWellSelections = [];
        const replicateWellMap = {};

        state.selectedReplicateKeys.forEach(key => {
            const rep = state.allReplicates[key];
            replicateWellMap[key] = [];
            rep.wells.forEach(wellInfo => {
                allWellSelections.push({ experiment: wellInfo.experiment, well: wellInfo.well, channel: wellInfo.channel || 1 });
                replicateWellMap[key].push(`${wellInfo.experiment}_${wellInfo.well}`);
            });
        });

        const response = await fetch(`${API_BASE}/api/plot-data`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ well_selections: allWellSelections })
        });
        const data = await response.json();

        const traceMap = {};
        data.traces.forEach(trace => { traceMap[trace.well] = trace; });
        const stationaryStatMap = {};
        (data.stats || []).forEach(stat => { stationaryStatMap[stat.well] = stat; });
        const meanStationaryStat = (items, field, digits) => {
            const values = items.flatMap(item => {
                const value = item?.[field];
                if (value === null || value === undefined) return [];
                const numeric = Number(value);
                return Number.isFinite(numeric) ? [numeric] : [];
            });
            if (values.length === 0) return null;
            const mean = values.reduce((sum, value) => sum + value, 0) / values.length;
            return mean.toFixed(digits);
        };

        const showIndividual = document.getElementById('show-individual-wells').checked;
        const plotTraces = [];
        const stats = [];
        const GROUP_COLORS = ['#4facfe', '#e74c3c', '#2ecc71', '#e67e22', '#9b59b6', '#1abc9c', '#f39c12', '#3498db'];
        let colorIdx = 0;

        // Track trace indices so the average can be updated when individual traces are toggled
        const traceGroupMeta = {};
        let traceIdx = 0;

        // Collect unique channels across selected replicate groups for multi-axis
        const repChannelList = [...new Set(
            [...state.selectedReplicateKeys].map(k => state.allReplicates[k].channel || 1)
        )].sort((a, b) => a - b);

        state.selectedReplicateKeys.forEach(key => {
            const rep = state.allReplicates[key];
            const groupTraces = replicateWellMap[key].map(id => traceMap[id]).filter(Boolean);
            if (groupTraces.length === 0) return;

            const repCh = rep.channel || 1;
            const yax = channelToYAxis(repCh, repChannelList);
            const color = GROUP_COLORS[colorIdx % GROUP_COLORS.length];
            colorIdx++;

            const avg = computeReplicateAverage(groupTraces);
            plotTraces.push({
                x: avg.x, y: avg.y,
                mode: 'lines+markers',
                name: `${rep.label} (avg, n=${groupTraces.length})`,
                yaxis: yax,
                line: { width: 3, color },
                marker: { size: 5, color }
            });
            traceGroupMeta[key] = { avgIdx: traceIdx, individualIdxs: [] };
            traceIdx++;

            const groupStationaryStats = replicateWellMap[key]
                .map(id => stationaryStatMap[id])
                .filter(Boolean);
            stats.push({
                well: `${rep.label} (avg)`,
                condition: groupTraces[0].condition,
                antibiotic: groupTraces[0].antibiotic,
                specific_growth_rate: meanStationaryStat(
                    groupStationaryStats, 'specific_growth_rate', 4
                ),
                saturation_od: meanStationaryStat(
                    groupStationaryStats, 'saturation_od', 3
                ),
                auc: trapezoidalAUC(avg.x, avg.y).toFixed(2)
            });

            if (showIndividual) {
                groupTraces.forEach(trace => {
                    plotTraces.push({
                        x: trace.x, y: trace.y,
                        mode: 'lines',
                        name: trace.well,
                        yaxis: yax,
                        line: { width: 1, color, dash: 'dot' },
                        opacity: 0.5
                    });
                    traceGroupMeta[key].individualIdxs.push(traceIdx);
                    traceIdx++;
                });
            }
        });

        const layout = buildMultiChannelLayout(repChannelList, 'Growth Curves — Replicates');
        const config = { responsive: true, displayModeBar: true, modeBarButtonsToRemove: ['lasso2d', 'select2d'] };

        document.getElementById('plot-growth-container').style.display = 'block';
        document.getElementById('stats-container').style.display = 'block';
        const plotDiv = document.getElementById('plot-growth');
        Plotly.purge(plotDiv);
        await Plotly.newPlot(plotDiv, plotTraces, layout, config);
        displayStats(stats);

        // Recalculate the group average whenever an individual trace is shown/hidden via the legend
        plotDiv.on('plotly_restyle', function(eventData) {
            if (!eventData || !eventData[0] || !eventData[0].hasOwnProperty('visible')) return;
            const plotData = plotDiv.data;
            Object.entries(traceGroupMeta).forEach(([key, meta]) => {
                if (meta.individualIdxs.length === 0) return;
                const visibleTraces = meta.individualIdxs
                    .filter(i => plotData[i].visible !== 'legendonly')
                    .map(i => ({ x: plotData[i].x, y: plotData[i].y }));
                if (visibleTraces.length === 0) return;
                const newAvg = computeReplicateAverage(visibleTraces);
                const rep = state.allReplicates[key];
                Plotly.restyle(plotDiv, {
                    x: [newAvg.x],
                    y: [newAvg.y],
                    name: [`${rep.label} (avg, n=${visibleTraces.length})`]
                }, [meta.avgIdx]);
            });
        });

        hideLoading();
    } catch (error) {
        console.error('Error plotting replicates:', error);
        hideLoading();
        showError('Error plotting replicates');
    }
}

// ── Fit Curve replicate mode ───────────────────────────────────────────


export {
    buildReplicateList, toggleReplicate, selectAllReplicates, clearAllReplicates,
    updateSelectedReplicatesCount, onShowIndividualChange, setPlotMode,
    computeReplicateAverage, trapezoidalAUC, plotReplicates,
};
