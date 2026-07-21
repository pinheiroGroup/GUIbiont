import { state, CHANNEL_AXIS_COLORS, API_BASE } from './state.js';
import { showLoading, hideLoading, showError } from './ui.js';

function resizePlot() {
    // Resize both plots if they exist
    const growthPlot = document.getElementById('plot-growth');
    const fittingPlot = document.getElementById('plot-fitting');
    
    if (growthPlot && typeof Plotly !== 'undefined' && document.getElementById('plot-growth-container').style.display === 'block') {
        setTimeout(() => {
            Plotly.Plots.resize(growthPlot);
        }, 100);
    }
    
    if (fittingPlot && typeof Plotly !== 'undefined' && document.getElementById('plot-fitting-container').style.display === 'block') {
        setTimeout(() => {
            Plotly.Plots.resize(fittingPlot);
        }, 100);
    }
}

// Plot growth curves
// Build a Plotly layout with one y-axis per channel. Channels 2..N stack on
// the right; the x-domain shrinks to make room. Beyond ~4 right-side axes the
// overlay gets crowded — at that point the "Split by Channel" view is nicer,
// but every channel still renders here.
function buildMultiChannelLayout(channelList, title) {
    const N = channelList.length;
    const multi = N > 1;
    // Number of axes that need to sit on the right side (index 1..N-1).
    const rightAxes = Math.max(0, N - 1);
    // Each extra right-side axis (beyond the first one which hugs the plot
    // edge) steps out by 0.08 in normalized x.
    const STEP = 0.08;
    const xDomainEnd = rightAxes <= 1 ? 1.0 : Math.max(0.5, 1.0 - STEP * (rightAxes - 1));
    const layout = {
        title: { text: title, font: { size: 20, color: '#495057' } },
        xaxis: {
            title: { text: 'Time (hours)', font: { size: state.axisTitleFontSize } },
            tickfont: { size: state.axisTickFontSize },
            gridcolor: '#e9ecef',
            domain: [0, xDomainEnd]
        },
        hovermode: 'x unified',
        template: 'plotly_white',
        legend: { orientation: 'h', xanchor: 'center', x: 0.5, y: -0.2, font: { size: state.legendFontSize } },
        margin: { l: 70, r: multi ? 90 + 80 * Math.max(0, rightAxes - 1) : 30, t: 80, b: 120 },
        autosize: true
    };
    channelList.forEach((ch, i) => {
        const axKey = i === 0 ? 'yaxis' : `yaxis${i + 1}`;
        const color = CHANNEL_AXIS_COLORS[ch] || '#333';
        layout[axKey] = {
            title: { text: `Ch ${ch} — OD`, font: { size: state.axisTitleFontSize, color } },
            tickfont: { size: state.axisTickFontSize, color },
            gridcolor: '#e9ecef',
        };
        if (i === 1) {
            layout[axKey].overlaying = 'y';
            layout[axKey].side = 'right';
            layout[axKey].anchor = 'x';                       // hugs xDomainEnd
        } else if (i >= 2) {
            layout[axKey].overlaying = 'y';
            layout[axKey].side = 'right';
            layout[axKey].anchor = 'free';
            layout[axKey].position = Math.min(0.99, xDomainEnd + STEP * (i - 1));
        }
    });
    if (!multi) layout.yaxis.title.text = 'Optical Density (OD)';
    return layout;
}

// Return the Plotly yaxis ref ('y', 'y2', 'y3') for a channel given the ordered channel list.
function channelToYAxis(ch, channelList) {
    const idx = channelList.indexOf(ch);
    return idx === 0 ? 'y' : `y${idx + 1}`;
}

async function plotGrowthCurves() {
    if (state.selectedWellIds.size === 0) return;
    showLoading();

    try {
        const wellSelections = Array.from(state.selectedWellIds).map(wellId => {
            const wellInfo = state.allWells.find(w => w.well_id === wellId);
            return { experiment: wellInfo.experiment, well: wellInfo.well, channel: wellInfo.channel || 1 };
        });

        const response = await fetch(`${API_BASE}/api/plot-data`, {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ well_selections: wellSelections })
        });
        const data = await response.json();
        state._lastGrowthData = data;
        const channelList = [...new Set(data.traces.map(t => t.channel || 1))].sort((a, b) => a - b);
        const multi = channelList.length > 1;

        const traces = data.traces.map(trace => {
            const ch = trace.channel || 1;
            const wellName = trace.well_name || trace.well.split('_').slice(1).join('_');
            const chLabel = multi ? ` [Ch ${ch}]` : '';
            const color = multi ? (CHANNEL_AXIS_COLORS[ch] || undefined) : undefined;
            return {
                x: trace.x, y: trace.y,
                mode: 'lines+markers',
                name: `${trace.experiment}: ${wellName}${chLabel} (${trace.condition})`,
                yaxis: channelToYAxis(ch, channelList),
                line: { width: 2, color },
                marker: { size: 4, color }
            };
        });

        const experimentNames = Array.from(state.selectedExperiments).join(', ');
        const layout = buildMultiChannelLayout(
            channelList,
            `Growth Curves — ${experimentNames} (${state.selectedWellIds.size} wells)`
        );
        const config = { responsive: true, displayModeBar: true, modeBarButtonsToRemove: ['lasso2d', 'select2d'] };

        document.getElementById('plot-growth-container').style.display = 'block';
        document.getElementById('stats-container').style.display = 'block';
        // Reset split view
        document.getElementById('plot-growth').style.display = '';
        document.getElementById('plot-growth-split').style.display = 'none';
        const splitBtn = document.getElementById('split-channels-btn');
        splitBtn.style.display = multi ? '' : 'none';
        splitBtn.textContent = '📊 Split by Channel';

        const plotDiv = document.getElementById('plot-growth');
        Plotly.purge(plotDiv);
        await Plotly.newPlot(plotDiv, traces, layout, config);
        displayStats(data.stats);
        hideLoading();
    } catch (error) {
        console.error('Error plotting data:', error);
        hideLoading();
        showError('Error loading plot data');
    }
}


function toggleSplitChannels() {
    state._splitChannelsActive = !state._splitChannelsActive;
    const btn = document.getElementById('split-channels-btn');
    if (state._splitChannelsActive) {
        btn.textContent = '📈 Combined View';
        document.getElementById('plot-growth').style.display = 'none';
        renderSplitChannels(state._lastGrowthData);
    } else {
        btn.textContent = '📊 Split by Channel';
        document.getElementById('plot-growth').style.display = '';
        document.getElementById('plot-growth-split').style.display = 'none';
    }
}

function renderSplitChannels(data) {
    if (!data) return;
    const splitDiv = document.getElementById('plot-growth-split');
    splitDiv.innerHTML = '';
    splitDiv.style.display = 'block';

    const byChannel = {};
    data.traces.forEach(trace => {
        const ch = trace.channel || 1;
        if (!byChannel[ch]) byChannel[ch] = [];
        byChannel[ch].push(trace);
    });

    const config = { responsive: true, displayModeBar: true, modeBarButtonsToRemove: ['lasso2d', 'select2d'] };

    Object.keys(byChannel).sort().forEach(ch => {
        ch = parseInt(ch);
        const color = CHANNEL_AXIS_COLORS[ch] || '#333';
        const container = document.createElement('div');
        container.style.cssText = `border-top: 3px solid ${color}; margin-top: 8px;`;
        const plotEl = document.createElement('div');
        plotEl.style.cssText = 'width:100%; height:500px;';
        container.appendChild(plotEl);
        splitDiv.appendChild(container);

        const traces = byChannel[ch].map(trace => {
            const wellName = trace.well_name || trace.well.split('_').slice(1).join('_');
            return {
                x: trace.x, y: trace.y,
                mode: 'lines+markers',
                name: `${trace.experiment}: ${wellName} (${trace.condition})`,
                line: { width: 2 }, marker: { size: 4 }
            };
        });
        const layout = {
            title: { text: `Channel ${ch}`, font: { size: 16, color } },
            xaxis: { title: { text: 'Time (hours)', font: { size: state.axisTitleFontSize } }, tickfont: { size: state.axisTickFontSize }, gridcolor: '#e9ecef' },
            yaxis: { title: { text: `Ch ${ch} — OD`, font: { size: state.axisTitleFontSize, color } }, tickfont: { size: state.axisTickFontSize, color }, gridcolor: '#e9ecef' },
            hovermode: 'x unified', template: 'plotly_white',
            legend: { orientation: 'h', xanchor: 'center', x: 0.5, y: -0.25, font: { size: state.legendFontSize } },
            margin: { l: 70, r: 30, t: 50, b: 100 }, autosize: true
        };
        Plotly.newPlot(plotEl, traces, layout, config);
    });
}

// Display statistics table
function displayStats(stats) {
    const statsTable = document.getElementById('stats-table');
    
    if (stats.length === 0) {
        statsTable.innerHTML = '<p>No data available</p>';
        return;
    }

    const formatStat = (value, digits) => {
        const numeric = Number(value);
        return value !== null && value !== undefined && Number.isFinite(numeric)
            ? numeric.toFixed(digits)
            : '—';
    };
    
    let tableHTML = `
        <table>
            <thead>
                <tr>
                    <th>Well</th>
                    <th>Condition</th>
                    <th>Antibiotic</th>
                    <th>Specific growth rate (/h)</th>
                    <th>Saturation OD</th>
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
                <td>${formatStat(stat.specific_growth_rate, 4)}</td>
                <td>${formatStat(stat.saturation_od, 3)}</td>
                <td>${stat.auc}</td>
            </tr>
        `;
    });
    
    tableHTML += '</tbody></table>';
    statsTable.innerHTML = tableHTML;
}


export {
    resizePlot, buildMultiChannelLayout, channelToYAxis,
    plotGrowthCurves, toggleSplitChannels, renderSplitChannels, displayStats,
};
