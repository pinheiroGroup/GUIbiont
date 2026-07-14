import { state, CHANNEL_AXIS_COLORS, API_BASE } from './state.js';
import { showLoading, hideLoading, showError } from './ui.js';

const GROWTH_HOVER_LIMIT = 20;
const GROWTH_X_TITLE_STANDOFF = 2;
const GROWTH_MAIN_PLOT_HEIGHT = 485;
const GROWTH_SPLIT_PLOT_HEIGHT = 345;
const GROWTH_LEGEND_MAX_HEIGHT = 245;

function resizePlot() {
    const growthPlot = document.getElementById('plot-growth');
    const fittingPlot = document.getElementById('plot-fitting');

    if (growthPlot && typeof Plotly !== 'undefined' && document.getElementById('plot-growth-container').style.display === 'block') {
        setTimeout(() => Plotly.Plots.resize(growthPlot), 100);
    }

    if (fittingPlot && typeof Plotly !== 'undefined' && document.getElementById('plot-fitting-container').style.display === 'block') {
        setTimeout(() => Plotly.Plots.resize(fittingPlot), 100);
    }
}

function escapeHtml(value) {
    return String(value ?? '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

function formatHoverNumber(value) {
    const numeric = Number(value);
    if (!Number.isFinite(numeric)) return String(value ?? '');
    return Math.abs(numeric) >= 1000 || (Math.abs(numeric) > 0 && Math.abs(numeric) < 0.001)
        ? numeric.toExponential(3)
        : numeric.toPrecision(4).replace(/\.?0+$/, '');
}

function yAxisLayoutKey(trace) {
    const axis = trace.yaxis || 'y';
    return axis === 'y' ? 'yaxis' : `yaxis${axis.slice(1)}`;
}

function axisPixelToData(axis, pixel) {
    if (!axis) return NaN;
    if (typeof axis.p2c === 'function') return axis.p2c(pixel);
    if (typeof axis.p2l === 'function') return axis.p2l(pixel);
    const range = axis.range || [];
    if (range.length < 2 || !Number.isFinite(range[0]) || !Number.isFinite(range[1]) || !axis._length) return NaN;
    return range[0] + (pixel / axis._length) * (range[1] - range[0]);
}

function nearestSortedIndex(values, target) {
    let lo = 0;
    let hi = values.length - 1;
    while (lo <= hi) {
        const mid = (lo + hi) >> 1;
        const value = Number(values[mid]);
        if (!Number.isFinite(value) || value < target) lo = mid + 1;
        else hi = mid - 1;
    }
    return lo;
}

function closestGrowthPoint(plotDiv, trace, curveNumber, cursorXByAxis, cursorYByAxis, cursorDataX) {
    const xAxis = plotDiv._fullLayout?.xaxis;
    const yAxis = plotDiv._fullLayout?.[yAxisLayoutKey(trace)] || plotDiv._fullLayout?.yaxis;
    const xs = trace.x || [];
    const ys = trace.y || [];
    if (!xAxis || !yAxis || xs.length === 0 || ys.length === 0) return null;

    const center = nearestSortedIndex(xs, cursorDataX);
    const start = Math.max(0, center - 3);
    const end = Math.min(xs.length - 1, center + 3);
    let best = null;

    for (let pointNumber = start; pointNumber <= end; pointNumber += 1) {
        const xVal = Number(xs[pointNumber]);
        const yRaw = ys[pointNumber];
        const yVal = Number(yRaw);
        if (!Number.isFinite(xVal) || !Number.isFinite(yVal)) continue;

        const px = xAxis.l2p(xVal);
        const py = yAxis.l2p(yVal);
        if (!Number.isFinite(px) || !Number.isFinite(py)) continue;

        const dx = px - cursorXByAxis;
        const dy = py - cursorYByAxis;
        const d2 = dx * dx + dy * dy;
        if (!best || d2 < best.d2) {
            const fullTrace = plotDiv._fullData?.[curveNumber] || trace;
            best = {
                d2,
                x: xVal,
                y: yVal,
                name: trace.name || fullTrace.name || `Curve ${curveNumber + 1}`,
                color: fullTrace.line?.color || fullTrace.marker?.color || trace.line?.color || trace.marker?.color || '#495057'
            };
        }
    }

    return best;
}

function positionGrowthTooltip(plotDiv, tooltip, event) {
    const rect = plotDiv.getBoundingClientRect();
    let left = event.clientX - rect.left + 14;
    let top = event.clientY - rect.top + 14;

    tooltip.style.left = `${left}px`;
    tooltip.style.top = `${top}px`;

    const width = tooltip.offsetWidth;
    const height = tooltip.offsetHeight;
    if (left + width > plotDiv.clientWidth - 8) left = event.clientX - rect.left - width - 14;
    if (top + height > plotDiv.clientHeight - 8) top = event.clientY - rect.top - height - 14;

    tooltip.style.left = `${Math.max(8, left)}px`;
    tooltip.style.top = `${Math.max(8, top)}px`;
}

function renderGrowthTooltip(plotDiv, tooltip, event) {
    const fullLayout = plotDiv._fullLayout;
    const xAxis = fullLayout?.xaxis;
    const yAxis = fullLayout?.yaxis;
    if (!xAxis || !yAxis || !plotDiv.data) return;

    const rect = plotDiv.getBoundingClientRect();
    const cursorXByAxis = event.clientX - rect.left - xAxis._offset;
    const cursorYByPrimaryAxis = event.clientY - rect.top - yAxis._offset;
    if (
        cursorXByAxis < 0 || cursorXByAxis > xAxis._length ||
        cursorYByPrimaryAxis < 0 || cursorYByPrimaryAxis > yAxis._length
    ) {
        tooltip.classList.remove('visible');
        return;
    }

    const cursorDataX = axisPixelToData(xAxis, cursorXByAxis);
    if (!Number.isFinite(cursorDataX)) {
        tooltip.classList.remove('visible');
        return;
    }

    const closest = [];
    plotDiv.data.forEach((trace, curveNumber) => {
        if (!trace || trace.visible === 'legendonly' || trace.visible === false) return;
        const traceYAxis = fullLayout[yAxisLayoutKey(trace)] || yAxis;
        const cursorYByAxis = event.clientY - rect.top - traceYAxis._offset;
        const point = closestGrowthPoint(plotDiv, trace, curveNumber, cursorXByAxis, cursorYByAxis, cursorDataX);
        if (point) closest.push(point);
    });

    closest.sort((a, b) => a.d2 - b.d2);
    const rows = closest.slice(0, GROWTH_HOVER_LIMIT);
    if (rows.length === 0) {
        tooltip.classList.remove('visible');
        return;
    }

    tooltip.innerHTML = `
        ${rows.map(row => `
            <div class="growth-hover-row">
                <span class="growth-hover-swatch" style="background:${escapeHtml(row.color)}"></span>
                <span class="growth-hover-name">${escapeHtml(row.name)}</span>
                <span class="growth-hover-values">t=${formatHoverNumber(row.x)} OD=${formatHoverNumber(row.y)}</span>
            </div>
        `).join('')}
    `;
    tooltip.classList.add('visible');
    positionGrowthTooltip(plotDiv, tooltip, event);
}

function detachGrowthHover(plotDiv) {
    if (plotDiv?._growthHoverCleanup) {
        plotDiv._growthHoverCleanup();
        delete plotDiv._growthHoverCleanup;
    }
}

function detachGrowthLegend(plotDiv) {
    plotDiv?.querySelector('.growth-legend-panel')?.remove();
    plotDiv?.nextElementSibling?.classList?.contains('growth-legend-panel') && plotDiv.nextElementSibling.remove();
}

function traceDisplayColor(plotDiv, trace, traceIndex) {
    const fullTrace = plotDiv._fullData?.[traceIndex] || trace;
    return fullTrace.line?.color || fullTrace.marker?.color || trace.line?.color || trace.marker?.color || '#495057';
}

function setGrowthPlotHeight(plotDiv, height = GROWTH_MAIN_PLOT_HEIGHT) {
    if (plotDiv) plotDiv.style.height = `${height}px`;
}

function installGrowthLegend(plotDiv) {
    if (!plotDiv) return;
    detachGrowthLegend(plotDiv);

    const legend = document.createElement('div');
    legend.className = 'growth-legend-panel';
    legend.style.setProperty('--growth-legend-font-size', `${state.legendFontSize}px`);
    legend.style.setProperty('--growth-legend-max-height', `${GROWTH_LEGEND_MAX_HEIGHT}px`);

    (plotDiv.data || []).forEach((trace, traceIndex) => {
        const item = document.createElement('button');
        item.type = 'button';
        item.className = 'growth-legend-item';
        item.title = trace.name || `Curve ${traceIndex + 1}`;

        const swatch = document.createElement('span');
        swatch.className = 'growth-legend-swatch';
        swatch.style.background = traceDisplayColor(plotDiv, trace, traceIndex);

        const label = document.createElement('span');
        label.className = 'growth-legend-label';
        label.textContent = trace.name || `Curve ${traceIndex + 1}`;

        item.append(swatch, label);
        item.classList.toggle('hidden-trace', trace.visible === 'legendonly' || trace.visible === false);
        item.addEventListener('click', () => {
            const isHidden = plotDiv.data?.[traceIndex]?.visible === 'legendonly' || plotDiv.data?.[traceIndex]?.visible === false;
            const nextVisible = isHidden ? true : 'legendonly';
            item.classList.toggle('hidden-trace', !isHidden);
            Plotly.restyle(plotDiv, { visible: [nextVisible] }, [traceIndex]);
        });

        legend.appendChild(item);
    });

    plotDiv.insertAdjacentElement('afterend', legend);
    if (plotDiv.closest('.fullscreen-plot')) {
        requestAnimationFrame(() => window.dispatchEvent(new Event('resize')));
    }
}

function installGrowthHover(plotDiv) {
    if (!plotDiv) return;
    detachGrowthHover(plotDiv);

    plotDiv.style.position = plotDiv.style.position || 'relative';
    plotDiv.dataset.growthHoverInstalled = 'true';
    const tooltip = document.createElement('div');
    tooltip.className = 'growth-hover-tooltip';
    plotDiv.appendChild(tooltip);

    let lastEvent = null;
    let frame = null;
    const scheduleRender = event => {
        lastEvent = event;
        if (frame !== null) return;
        frame = requestAnimationFrame(() => {
            frame = null;
            renderGrowthTooltip(plotDiv, tooltip, lastEvent);
        });
    };
    const hide = () => tooltip.classList.remove('visible');

    plotDiv.addEventListener('mousemove', scheduleRender);
    plotDiv.addEventListener('mouseleave', hide);
    plotDiv._growthHoverCleanup = () => {
        plotDiv.removeEventListener('mousemove', scheduleRender);
        plotDiv.removeEventListener('mouseleave', hide);
        if (frame !== null) cancelAnimationFrame(frame);
        tooltip.remove();
        delete plotDiv.dataset.growthHoverInstalled;
    };
}

function buildMultiChannelLayout(channelList, title) {
    const N = channelList.length;
    const multi = N > 1;
    const rightAxes = Math.max(0, N - 1);
    const STEP = 0.08;
    const xDomainEnd = rightAxes <= 1 ? 1.0 : Math.max(0.5, 1.0 - STEP * (rightAxes - 1));
    const layout = {
        title: { text: title, font: { size: 20, color: '#495057' } },
        xaxis: {
            title: { text: 'Time (hours)', font: { size: state.axisTitleFontSize }, standoff: GROWTH_X_TITLE_STANDOFF },
            tickfont: { size: state.axisTickFontSize },
            gridcolor: '#e9ecef',
            domain: [0, xDomainEnd]
        },
        hovermode: 'x unified',
        template: 'plotly_white',
        showlegend: false,
        margin: { l: 70, r: multi ? 90 + 80 * Math.max(0, rightAxes - 1) : 30, t: 70, b: 55 },
        autosize: true
    };

    channelList.forEach((ch, i) => {
        const axKey = i === 0 ? 'yaxis' : `yaxis${i + 1}`;
        const color = CHANNEL_AXIS_COLORS[ch] || '#333';
        layout[axKey] = {
            title: { text: `Ch ${ch} - OD`, font: { size: state.axisTitleFontSize, color } },
            tickfont: { size: state.axisTickFontSize, color },
            gridcolor: '#e9ecef',
        };
        if (i === 1) {
            layout[axKey].overlaying = 'y';
            layout[axKey].side = 'right';
            layout[axKey].anchor = 'x';
        } else if (i >= 2) {
            layout[axKey].overlaying = 'y';
            layout[axKey].side = 'right';
            layout[axKey].anchor = 'free';
            layout[axKey].position = Math.min(0.99, xDomainEnd + STEP * (i - 1));
        }
    });

    if (!multi && layout.yaxis) layout.yaxis.title.text = 'Optical Density (OD)';
    return layout;
}

function channelToYAxis(ch, channelList) {
    const idx = channelList.indexOf(ch);
    return idx === 0 ? 'y' : `y${idx + 1}`;
}

function growthTraceMax(trace) {
    let maxVal = -Infinity;
    (trace.y || []).forEach(v => {
        if (v === null || Number.isNaN(v)) return;
        const numeric = Number(v);
        if (Number.isFinite(numeric) && numeric > maxVal) maxVal = numeric;
    });
    return maxVal;
}

function growthTraceXRange(traces) {
    let minX = Infinity;
    let maxX = -Infinity;

    traces.forEach(trace => {
        const xs = trace.x || [];
        const ys = trace.y || [];
        xs.forEach((x, i) => {
            const y = ys[i];
            if (y === null || y === undefined || Number.isNaN(y)) return;
            const numericY = Number(y);
            if (!Number.isFinite(numericY)) return;

            const numericX = Number(x);
            if (!Number.isFinite(numericX)) return;
            if (numericX < minX) minX = numericX;
            if (numericX > maxX) maxX = numericX;
        });
    });

    if (!Number.isFinite(minX) || !Number.isFinite(maxX)) return null;
    if (minX === maxX) {
        const pad = Math.max(Math.abs(minX) * 0.01, 0.5);
        return [minX - pad, maxX + pad];
    }
    return [minX, maxX];
}

function prepareGrowthPagedData(data) {
    const stats = data.stats || [];
    const entries = (data.traces || []).map((trace, index) => ({
        trace,
        stat: stats[index],
        maxY: growthTraceMax(trace)
    }));

    entries.sort((a, b) => {
        if (a.maxY === b.maxY) return String(a.trace.well).localeCompare(String(b.trace.well));
        if (!Number.isFinite(a.maxY)) return 1;
        if (!Number.isFinite(b.maxY)) return -1;
        return a.maxY - b.maxY;
    });

    return {
        traces: entries.map(e => e.trace),
        stats: entries.map(e => e.stat).filter(Boolean)
    };
}

function currentGrowthPageSize(totalTraces) {
    const raw = String(state.growthPlotGroupSize || '20');
    if (raw === 'all') return Math.max(totalTraces, 1);
    const parsed = parseInt(raw, 10);
    if (!Number.isFinite(parsed) || parsed < 1) return 20;
    return parsed;
}

function growthPageCount(totalTraces) {
    return Math.max(1, Math.ceil(totalTraces / currentGrowthPageSize(totalTraces)));
}

function growthPageSlice(data) {
    const total = data.traces.length;
    const pageCount = growthPageCount(total);
    state._growthPlotPageIndex = Math.min(Math.max(state._growthPlotPageIndex, 0), pageCount - 1);
    const baseSize = Math.floor(total / pageCount);
    const largerGroups = total % pageCount;
    const pageSize = baseSize + (state._growthPlotPageIndex < largerGroups ? 1 : 0);
    const start = state._growthPlotPageIndex * baseSize + Math.min(state._growthPlotPageIndex, largerGroups);
    const end = Math.min(start + pageSize, total);
    return {
        traces: data.traces.slice(start, end),
        stats: data.stats.slice(start, end),
        start,
        end,
        total,
        pageSize,
        pageCount
    };
}

function updateGrowthGroupControls(slice) {
    const controls = document.getElementById('growth-group-controls');
    if (!controls) return;

    const shouldShow = slice.total > 20 || state.growthPlotGroupSize !== '20';
    controls.style.display = shouldShow ? 'flex' : 'none';

    const sizeInput = document.getElementById('growth-group-size');
    if (sizeInput) {
        sizeInput.value = state.growthPlotGroupSize === 'all'
            ? String(Math.max(slice.total, 1))
            : state.growthPlotGroupSize;
        resizeNumericInput(sizeInput);
    }

    const allBtn = document.getElementById('growth-group-all');
    if (allBtn) allBtn.classList.toggle('active', state.growthPlotGroupSize === 'all');

    const pageInput = document.getElementById('growth-group-page');
    if (pageInput) {
        pageInput.value = String(state._growthPlotPageIndex + 1);
        pageInput.max = String(slice.pageCount);
        resizeNumericInput(pageInput);
    }

    const pageTotal = document.getElementById('growth-group-total-pages');
    if (pageTotal) pageTotal.textContent = `/ ${slice.pageCount}`;

    const curveRange = document.getElementById('growth-group-curve-range');
    if (curveRange) {
        const first = slice.total === 0 ? 0 : slice.start + 1;
        curveRange.textContent = `${first}-${slice.end} / ${slice.total}`;
    }

    const prevBtn = document.getElementById('growth-group-prev');
    const nextBtn = document.getElementById('growth-group-next');
    if (prevBtn) prevBtn.disabled = state._growthPlotPageIndex <= 0;
    if (nextBtn) nextBtn.disabled = state._growthPlotPageIndex >= slice.pageCount - 1;
}

function resizeNumericInput(input) {
    const digits = Math.max(String(input.value || '').length, 1);
    const extraPx = input.classList.contains('growth-group-size-input') ? 30 : 0;
    input.style.setProperty('--digits-width', `calc(${digits + 1.4}ch + ${extraPx}px)`);
}

function resizeGrowthNumericInput(input) {
    resizeNumericInput(input);
}

function buildGrowthPlotTrace(trace, channelList, multi) {
    const ch = trace.channel || 1;
    const wellName = trace.well_name || trace.well.split('_').slice(1).join('_');
    const chLabel = multi ? ` [Ch ${ch}]` : '';
    const color = multi ? (CHANNEL_AXIS_COLORS[ch] || undefined) : undefined;
    return {
        type: 'scattergl',
        x: trace.x,
        y: trace.y,
        mode: 'lines+markers',
        name: `${trace.experiment}: ${wellName}${chLabel} (${trace.condition})`,
        yaxis: channelToYAxis(ch, channelList),
        line: { width: 2, color },
        marker: { size: 4, color },
        hoverinfo: 'skip'
    };
}

async function renderGrowthPage() {
    const data = state._growthPlotPagedData;
    if (!data) return;

    const slice = growthPageSlice(data);
    const pageChannels = [...new Set(slice.traces.map(t => t.channel || 1))].sort((a, b) => a - b);
    const allChannels = [...new Set(data.traces.map(t => t.channel || 1))].sort((a, b) => a - b);
    const channelList = pageChannels.length > 0 ? pageChannels : allChannels;
    const multi = allChannels.length > 1;
    const traces = slice.traces.map(trace => buildGrowthPlotTrace(trace, channelList, multi));

    const experimentNames = Array.from(state.selectedExperiments).join(', ');
    const pageSuffix = slice.pageCount > 1
        ? ` | group ${state._growthPlotPageIndex + 1}/${slice.pageCount}, curves ${slice.start + 1}-${slice.end}/${slice.total}`
        : '';
    const layout = buildMultiChannelLayout(
        channelList,
        `Growth Curves - ${experimentNames} (${slice.total} wells${pageSuffix})`
    );
    layout.hovermode = false;
    const xRange = growthTraceXRange(slice.traces);
    if (xRange) layout.xaxis.range = xRange;
    const config = { responsive: true, displayModeBar: true, modeBarButtonsToRemove: ['lasso2d', 'select2d'] };

    document.getElementById('plot-growth-container').style.display = 'block';
    document.getElementById('stats-container').style.display = 'block';
    document.getElementById('plot-growth').style.display = '';
    document.getElementById('plot-growth-split').style.display = 'none';

    const splitBtn = document.getElementById('split-channels-btn');
    if (splitBtn) {
        splitBtn.style.display = multi ? '' : 'none';
        splitBtn.textContent = 'Split by Channel';
    }
    state._splitChannelsActive = false;

    updateGrowthGroupControls(slice);

    const plotDiv = document.getElementById('plot-growth');
    detachGrowthLegend(plotDiv);
    detachGrowthHover(plotDiv);
    Plotly.purge(plotDiv);
    setGrowthPlotHeight(plotDiv);
    await Plotly.newPlot(plotDiv, traces, layout, config);
    installGrowthLegend(plotDiv);
    installGrowthHover(plotDiv);
    displayStats(slice.stats);
}

async function plotGrowthCurves() {
    if (state.selectedWellIds.size === 0) return;
    const requestId = ++state._growthPlotRequestId;
    showLoading();

    try {
        const wellInfoById = new Map(state.allWells.map(w => [w.well_id, w]));
        const wellSelections = Array.from(state.selectedWellIds).map(wellId => {
            const wellInfo = wellInfoById.get(wellId);
            if (!wellInfo) return null;
            return { experiment: wellInfo.experiment, well: wellInfo.well, channel: wellInfo.channel || 1 };
        }).filter(Boolean);

        const response = await fetch(`${API_BASE}/api/plot-data`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ well_selections: wellSelections })
        });
        const data = await response.json();
        if (requestId !== state._growthPlotRequestId) return;

        state._lastGrowthData = data;
        state._growthPlotPagedData = prepareGrowthPagedData(data);
        state._growthPlotPageIndex = 0;
        await renderGrowthPage();
        hideLoading();
    } catch (error) {
        console.error('Error plotting data:', error);
        if (requestId === state._growthPlotRequestId) {
            hideLoading();
            showError('Error loading plot data');
        }
    }
}

function onGrowthGroupSizeChange(value) {
    const raw = String(value || '').trim().toLowerCase();
    if (raw === 'all') {
        state.growthPlotGroupSize = 'all';
    } else {
        const parsed = Math.max(1, parseInt(raw, 10) || 20);
        state.growthPlotGroupSize = String(parsed);
    }
    localStorage.setItem('growthPlotGroupSize', state.growthPlotGroupSize);
    state._growthPlotPageIndex = 0;
    renderGrowthPage();
}

function goToGrowthGroup(value) {
    const data = state._growthPlotPagedData;
    if (!data) return;

    const requested = parseInt(value, 10);
    if (!Number.isFinite(requested)) {
        updateGrowthGroupControls(growthPageSlice(data));
        return;
    }
    state._growthPlotPageIndex = Math.min(Math.max(requested - 1, 0), growthPageCount(data.traces.length) - 1);
    renderGrowthPage();
}

function previousGrowthGroup() {
    state._growthPlotPageIndex = Math.max(state._growthPlotPageIndex - 1, 0);
    renderGrowthPage();
}

function nextGrowthGroup() {
    const data = state._growthPlotPagedData;
    if (!data) return;
    state._growthPlotPageIndex = Math.min(state._growthPlotPageIndex + 1, growthPageCount(data.traces.length) - 1);
    renderGrowthPage();
}

function toggleSplitChannels() {
    state._splitChannelsActive = !state._splitChannelsActive;
    const btn = document.getElementById('split-channels-btn');
    if (state._splitChannelsActive) {
        if (btn) btn.textContent = 'Combined View';
        const mainPlot = document.getElementById('plot-growth');
        detachGrowthLegend(mainPlot);
        mainPlot.style.display = 'none';
        renderSplitChannels(state._lastGrowthData);
    } else {
        if (btn) btn.textContent = 'Split by Channel';
        renderGrowthPage();
    }
}

function renderSplitChannels(data) {
    if (!data) return;
    const pageData = state._growthPlotPagedData ? growthPageSlice(state._growthPlotPagedData) : null;
    const tracesForSplit = pageData ? pageData.traces : data.traces;
    const splitDiv = document.getElementById('plot-growth-split');
    splitDiv.querySelectorAll('.growth-legend-panel').forEach(el => el.remove());
    splitDiv.querySelectorAll('[data-growth-hover-installed="true"]').forEach(detachGrowthHover);
    splitDiv.innerHTML = '';
    splitDiv.style.display = 'block';

    const byChannel = {};
    tracesForSplit.forEach(trace => {
        const ch = trace.channel || 1;
        if (!byChannel[ch]) byChannel[ch] = [];
        byChannel[ch].push(trace);
    });

    const config = { responsive: true, displayModeBar: true, modeBarButtonsToRemove: ['lasso2d', 'select2d'] };

    Object.keys(byChannel).sort((a, b) => Number(a) - Number(b)).forEach(chRaw => {
        const ch = parseInt(chRaw, 10);
        const color = CHANNEL_AXIS_COLORS[ch] || '#333';
        const container = document.createElement('div');
        container.style.cssText = `border-top: 3px solid ${color}; margin-top: 8px;`;
        const plotEl = document.createElement('div');
        plotEl.style.cssText = `width:100%; height:${GROWTH_SPLIT_PLOT_HEIGHT}px;`;
        container.appendChild(plotEl);
        splitDiv.appendChild(container);

        const traces = byChannel[ch].map(trace => {
            const wellName = trace.well_name || trace.well.split('_').slice(1).join('_');
            return {
                type: 'scattergl',
                x: trace.x,
                y: trace.y,
                mode: 'lines+markers',
                name: `${trace.experiment}: ${wellName} (${trace.condition})`,
                line: { width: 2 },
                marker: { size: 4 },
                hoverinfo: 'skip'
            };
        });

        const layout = {
            title: { text: `Channel ${ch}`, font: { size: 16, color } },
            xaxis: { title: { text: 'Time (hours)', font: { size: state.axisTitleFontSize }, standoff: GROWTH_X_TITLE_STANDOFF }, tickfont: { size: state.axisTickFontSize }, gridcolor: '#e9ecef' },
            yaxis: { title: { text: `Ch ${ch} - OD`, font: { size: state.axisTitleFontSize, color } }, tickfont: { size: state.axisTickFontSize, color }, gridcolor: '#e9ecef' },
            hovermode: false,
            template: 'plotly_white',
            showlegend: false,
            margin: { l: 70, r: 30, t: 50, b: 55 },
            autosize: true
        };
        const xRange = growthTraceXRange(byChannel[ch]);
        if (xRange) layout.xaxis.range = xRange;
        Plotly.newPlot(plotEl, traces, layout, config).then(() => {
            installGrowthLegend(plotEl);
            installGrowthHover(plotEl);
        });
    });
}

const STATS_VISIBLE_ROWS = 11;

function updateStatsTableScroll(statsTable, rowCount) {
    statsTable.classList.toggle('stats-scrollable', rowCount > STATS_VISIBLE_ROWS);
    statsTable.style.maxHeight = '';

    if (rowCount <= STATS_VISIBLE_ROWS) return;

    const header = statsTable.querySelector('thead');
    const rows = Array.from(statsTable.querySelectorAll('tbody tr')).slice(0, STATS_VISIBLE_ROWS);
    const visibleHeight = rows.reduce((sum, row) => sum + row.getBoundingClientRect().height, header?.getBoundingClientRect().height || 0);
    statsTable.style.maxHeight = `${Math.ceil(visibleHeight) + 2}px`;
}

function displayStats(stats) {
    const statsTable = document.getElementById('stats-table');
    if (stats.length === 0) {
        updateStatsTableScroll(statsTable, 0);
        statsTable.innerHTML = '<p>No data available</p>';
        return;
    }

    let tableHTML = `
        <table>
            <thead>
                <tr>
                    <th>Well</th>
                    <th>Condition</th>
                    <th>Antibiotic</th>
                    <th>Max OD</th>
                    <th>Final OD</th>
                    <th>AUC</th>
                </tr>
            </thead>
            <tbody>
    `;

    stats.forEach(stat => {
        tableHTML += `
            <tr>
                <td><strong>${stat.well}</strong></td>
                <td>${stat.condition}</td>
                <td>${stat.antibiotic || 'Unknown'}</td>
                <td>${stat.max_od}</td>
                <td>${stat.final_od}</td>
                <td>${stat.auc}</td>
            </tr>
        `;
    });

    tableHTML += '</tbody></table>';
    statsTable.innerHTML = tableHTML;
    updateStatsTableScroll(statsTable, stats.length);
}

export {
    resizePlot, buildMultiChannelLayout, channelToYAxis,
    plotGrowthCurves, toggleSplitChannels, renderSplitChannels, displayStats,
    onGrowthGroupSizeChange, goToGrowthGroup, previousGrowthGroup, nextGrowthGroup,
    resizeGrowthNumericInput, installGrowthHover, detachGrowthHover,
    setGrowthPlotHeight,
    installGrowthLegend, detachGrowthLegend,
};
