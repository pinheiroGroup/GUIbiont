import { state, API_BASE } from './state.js';
import { buildMultiChannelLayout, channelToYAxis } from './plot.js';
import { computeReplicateAverage, trapezoidalAUC } from './replicates.js';

function setFitMode(mode) {
    state.currentFitMode = mode;
    const wellSelect = document.getElementById('fitting-well');
    const replicateSelect = document.getElementById('fitting-replicate');
    document.getElementById('fit-mode-btn-well').classList.toggle('active', mode === 'well');
    document.getElementById('fit-mode-btn-replicate').classList.toggle('active', mode === 'replicate');
    document.getElementById('fit-show-individual-container').style.display = mode === 'replicate' ? 'block' : 'none';
    if (mode === 'well') {
        wellSelect.style.display = '';
        replicateSelect.style.display = 'none';
        document.getElementById('fit-button').disabled = !wellSelect.value;
    } else {
        wellSelect.style.display = 'none';
        replicateSelect.style.display = '';
        document.getElementById('fit-button').disabled = !replicateSelect.value;
    }
}

function onFittingReplicateChange() {
    const replicateSelect = document.getElementById('fitting-replicate');
    document.getElementById('fit-button').disabled = !replicateSelect.value;
}

async function fitReplicateAverage() {
    const experimentSelect = document.getElementById('fitting-experiment');
    const replicateSelect = document.getElementById('fitting-replicate');
    const fitButton = document.getElementById('fit-button');

    const experiment = experimentSelect.value;
    const replicateKey = replicateSelect.value;
    if (!experiment || !replicateKey) {
        alert('Please select an experiment and a replicate');
        return;
    }

    fitButton.disabled = true;
    fitButton.textContent = '⏳ Fitting...';

    try {
        const selectedOption = replicateSelect.selectedOptions[0];
        const replicateWells = JSON.parse(selectedOption.dataset.wells);
        const label = selectedOption.textContent;

        // Fetch individual well traces for optional overlay
        const plotResponse = await fetch(`${API_BASE}/api/plot-data`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ well_selections: replicateWells })
        });
        const plotData = await plotResponse.json();
        state.lastReplicateTraces = plotData.traces || [];

        const fitResponse = await fetch(`${API_BASE}/api/fit-replicate`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                well_selections: replicateWells,
                label: label,
                experiment: experiment
            })
        });

        if (!fitResponse.ok) {
            const errorData = await fitResponse.json();
            throw new Error(errorData.error || 'Fitting failed');
        }

        const fitData = await fitResponse.json();
        state.lastFitData = fitData;
        displayFittingResults(fitData);
        updateFitPlot(fitData);

    } catch (error) {
        console.error('Error fitting replicate:', error);
        alert(`Error fitting replicate: ${error.message}`);
    } finally {
        fitButton.disabled = false;
        fitButton.textContent = '📊 Fit Curve';
    }
}

// Initialize the app when page loads
window.addEventListener('load', init);

// Handle window resize
window.addEventListener('resize', () => {
    if (isFullscreen) {
        // In fullscreen mode, find the currently active plot and resize it
        const growthContainer = document.getElementById('plot-growth-container');
        const fittingContainer = document.getElementById('plot-fitting-container');
        
        let activePlotDiv = null;
        if (growthContainer && growthContainer.classList.contains('fullscreen-plot')) {
            activePlotDiv = document.getElementById('plot-growth');
        } else if (fittingContainer && fittingContainer.classList.contains('fullscreen-plot')) {
            activePlotDiv = document.getElementById('plot-fitting');
        }
        
        if (activePlotDiv && typeof Plotly !== 'undefined') {
            const newWidth = window.innerWidth;
            const newHeight = window.innerHeight - 80;
            
            Plotly.relayout(activePlotDiv, {
                width: newWidth,
                height: newHeight
            });
        }
    } else {
        resizePlot();
    }
});

// Fullscreen functionality
function loadFittingExperiments() {
    const experimentSelect = document.getElementById('fitting-experiment');
    
    // Clear previous options
    experimentSelect.innerHTML = '<option value="">Select Experiment</option>';
    
    // Load experiments from existing data
    if (state.experimentInfo && state.experimentInfo.length > 0) {
        state.experimentInfo.forEach(exp => {
            const option = document.createElement('option');
            option.value = exp;
            option.textContent = exp;
            experimentSelect.appendChild(option);
        });
    }
    
    // Add event listener
    experimentSelect.addEventListener('change', onFittingExperimentChange);
}

async function onFittingExperimentChange() {
    const experimentSelect = document.getElementById('fitting-experiment');
    const wellSelect = document.getElementById('fitting-well');
    const fitButton = document.getElementById('fit-button');
    
    const selectedExperiment = experimentSelect.value;
    
    if (!selectedExperiment) {
        wellSelect.innerHTML = '<option value="">Select Well</option>';
        wellSelect.disabled = true;
        fitButton.disabled = true;
        return;
    }
    state._lastBlankAnalysis = null;
    document.getElementById('blank-analysis-card').style.display = 'none';
    
    try {
        const response = await fetch(`${API_BASE}/api/experiment/${selectedExperiment}/info`);
        const expInfo = await response.json();

        wellSelect.innerHTML = '<option value="">Select Well</option>';
        if (expInfo.wells) {
            expInfo.wells.forEach(wellInfo => {
                const option = document.createElement('option');
                option.value = wellInfo.well;
                option.textContent = `${wellInfo.well} (${wellInfo.condition} | ${wellInfo.antibiotic})`;
                wellSelect.appendChild(option);
            });
        }
        wellSelect.disabled = false;
        wellSelect.addEventListener('change', onFittingWellChange);

        // Populate replicate selector
        const replicateSelect = document.getElementById('fitting-replicate');
        replicateSelect.innerHTML = '<option value="">Select Replicate</option>';
        if (expInfo.wells) {
            const repMap = {};
            expInfo.wells.forEach(wellInfo => {
                const ch = wellInfo.channel || 1;
                const key = `${wellInfo.condition}|||${wellInfo.antibiotic}|||ch${ch}`;
                if (!repMap[key]) {
                    repMap[key] = { label: `${wellInfo.condition} | ${wellInfo.antibiotic} | Ch${ch}`, wells: [] };
                }
                repMap[key].wells.push({ experiment: selectedExperiment, well: wellInfo.well, channel: ch });
            });
            Object.entries(repMap)
                .filter(([, rep]) => rep.wells.length >= 2)
                .forEach(([, rep]) => {
                    const option = document.createElement('option');
                    option.textContent = `${rep.label} (${rep.wells.length} wells)`;
                    option.dataset.wells = JSON.stringify(rep.wells);
                    replicateSelect.appendChild(option);
                });
        }
        replicateSelect.disabled = false;
        replicateSelect.addEventListener('change', onFittingReplicateChange);

    } catch (error) {
        console.error('Error loading wells for fitting:', error);
        wellSelect.disabled = true;
        fitButton.disabled = true;
    }
}

async function onFittingWellChange() {
    const wellSelect = document.getElementById('fitting-well');
    const fitButton = document.getElementById('fit-button');
    fitButton.disabled = !wellSelect.value;
    if (wellSelect.value) await runBlankAnalysis();
}

function onBlankSubtractionChange() {
    const checked = document.getElementById('fit-blank-subtraction').checked;
    document.getElementById('fit-blank-method-container').style.display = checked ? 'flex' : 'none';
    if (checked) renderBlankAnalysisCard(state._lastBlankAnalysis);
    else document.getElementById('blank-analysis-card').style.display = 'none';
}

function onBlankMethodChange() {
    renderBlankAnalysisCard(state._lastBlankAnalysis);
}

// Called when user accepts auto-detected blank wells.
// Injects them into _lastBlankAnalysis so the full card renders.
async function useAutoDetectedBlanks(wells) {
    if (!wells || !wells.length) return;
    const experiment = document.getElementById('fitting-experiment').value;
    const well       = document.getElementById('fitting-well').value;
    if (!experiment || !well) return;
    try {
        const resp = await fetch(`${API_BASE}/api/blank-analysis`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ experiment, well, override_blank_wells: wells }),
        });
        if (!resp.ok) return;
        const data = await resp.json();
        state._lastBlankAnalysis = data;
        renderBlankAnalysisCard(data);
    } catch (e) {
        console.error('useAutoDetectedBlanks failed:', e);
    }
}

async function runBlankAnalysis() {
    const experiment = document.getElementById('fitting-experiment').value;
    const well = document.getElementById('fitting-well').value;
    if (!experiment || !well) return;
    try {
        const resp = await fetch(`${API_BASE}/api/blank-analysis`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ experiment, well })
        });
        if (!resp.ok) return;
        const data = await resp.json();
        state._lastBlankAnalysis = data;
        renderBlankAnalysisCard(data);
    } catch (e) {
        console.error('Blank analysis failed:', e);
    }
}

function renderBlankAnalysisCard(data) {
    const card = document.getElementById('blank-analysis-card');
    const subtractChecked = document.getElementById('fit-blank-subtraction').checked;
    if (!data || !subtractChecked) { card.style.display = 'none'; return; }

    if (!data.has_blank_wells) {
        card.className = 'blank-analysis-card';
        const hasAuto = data.auto_detected_wells && data.auto_detected_wells.length > 0;
        card.style.borderLeftColor = hasAuto ? '#4a90e2' : '#ff9800';
        card.style.background      = hasAuto ? 'rgba(74,144,226,0.07)' : 'rgba(255,152,0,0.07)';
        card.innerHTML = hasAuto
            ? `<div class="ba-title">🔍 No blank wells annotated — auto-detected candidates</div>
               <div style="margin-bottom:8px;">${data.message}</div>
               <button class="btn" style="padding:4px 14px; font-size:0.85em;"
                   onclick="useAutoDetectedBlanks(${JSON.stringify(data.auto_detected_wells)})">
                   Use these as blanks
               </button>
               <button class="btn" style="padding:4px 10px; font-size:0.85em; margin-left:6px; color:#6c757d;"
                   onclick="document.getElementById('blank-analysis-card').style.display='none'">
                   Dismiss
               </button>`
            : `<div class="ba-title">⚠ No blank wells found</div>
               <div>${data.message}</div>`;
        card.style.display = '';
        return;
    }

    const currentMethod = document.getElementById('fit-blank-method').value;
    const notes = data.method_notes || {};
    const methodLabels = { pointbypoint: 'Point-by-point', shift: 'Shift minimum', clip: 'Clip to zero' };
    const statusIcon = { good: '✓', ok: '~', warning: '✗', not_recommended: '✗' };

    // Auto-select recommended method if user hasn't manually changed it
    if (data.recommendation && document.getElementById('fit-blank-method').value !== data.recommendation) {
        const sel = document.getElementById('fit-blank-method');
        // Only auto-select if current value is the default (pointbypoint) or matches recommendation
        if (sel.value === 'pointbypoint' || sel.value === data.recommendation) {
            sel.value = data.recommendation;
        }
    }

    let rows = '';
    for (const [method, label] of Object.entries(methodLabels)) {
        const n = notes[method] || {};
        const statusClass = `ba-status-${n.status || 'ok'}`;
        const icon = statusIcon[n.status] || '~';
        const badge = method === data.recommendation
            ? `<span class="ba-recommended-badge">recommended</span>` : '';
        const active = method === currentMethod ? ' style="font-weight:700;"' : '';
        rows += `<div class="ba-row"${active}>
            <span class="ba-method-label ${statusClass}">${icon} ${label}${badge}</span>
            <span>${n.note || ''}</span>
        </div>`;
    }

    card.className = 'blank-analysis-card';
    card.style.borderLeftColor = '#4facfe';
    card.style.background = 'rgba(79,172,254,0.07)';
    card.innerHTML = `
        <div class="ba-title">Blank analysis — ${data.blank_wells.join(', ')} (mean OD: ${data.blank_value.toFixed(4)})</div>
        ${rows}`;
    card.style.display = '';
}

async function fitGrowthCurve() {
    if (state.currentFitMode === 'replicate') {
        return fitReplicateAverage();
    }

    const experimentSelect = document.getElementById('fitting-experiment');
    const wellSelect = document.getElementById('fitting-well');
    const fitButton = document.getElementById('fit-button');
    const resultsDiv = document.getElementById('fitting-results');

    const experiment = experimentSelect.value;
    const well = wellSelect.value;

    if (!experiment || !well) {
        alert('Please select both experiment and well');
        return;
    }
    
    fitButton.disabled = true;
    fitButton.textContent = '⏳ Fitting...';
    
    try {
        const response = await fetch(`${API_BASE}/api/fit-curve`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                experiment: experiment,
                well: well,
                blank_subtraction: document.getElementById('fit-blank-subtraction').checked,
                blank_method: document.getElementById('fit-blank-method').value
            })
        });
        
        if (!response.ok) {
            const errorData = await response.json();
            throw new Error(errorData.error || 'Fitting failed');
        }
        
        const fitData = await response.json();
        
        // Display fitting results
        displayFittingResults(fitData);
        
        // Plot the data with fitted curve
        plotFittedCurve(fitData);
        
    } catch (error) {
        console.error('Error fitting curve:', error);
        alert(`Error fitting curve: ${error.message}`);
    } finally {
        fitButton.disabled = false;
        fitButton.textContent = '📊 Fit Curve';
    }
}

function displayFittingResults(fitData) {
    const resultsDiv = document.getElementById('fitting-results');
    const parametersDiv = document.getElementById('fitting-parameters');
    
    // Debug logging
    console.log('Fit data received:', fitData);
    console.log('Parameters:', fitData.parameters);
    console.log('Parameters types:', fitData.parameters?.map(p => typeof p));
    
    // Show aHPM parameter names
    const parameterNames = ['Growth Rate (μ)', 'Exit Lag Rate (r)', 'Carrying Capacity (N_max)', 'Shape Parameter (α)'];
    
    let html = `
        <div class="parameter-row">
            <span class="parameter-name">Experiment:</span>
            <span class="parameter-value">${fitData.experiment}</span>
        </div>
        <div class="parameter-row">
            <span class="parameter-name">${state.currentFitMode === 'replicate' ? 'Replicate:' : 'Well:'}</span>
            <span class="parameter-value">${fitData.well}</span>
        </div>
        <div class="parameter-row">
            <span class="parameter-name">Model:</span>
            <span class="parameter-value">${fitData.model}</span>
        </div>
        <div class="parameter-row">
            <span class="parameter-name">Blank Value:</span>
            <span class="parameter-value">${typeof fitData.blank_value === 'number' && isFinite(fitData.blank_value) ? fitData.blank_value.toFixed(4) : String(fitData.blank_value)}</span>
        </div>
        ${fitData.blank_subtraction && fitData.blank_wells && fitData.blank_wells.length > 0 ? `
        <div class="parameter-row">
            <span class="parameter-name">Blank Wells:</span>
            <span class="parameter-value">${fitData.blank_wells.join(', ')}</span>
        </div>` : ''}
        ${fitData.blank_subtraction ? `
        <div class="parameter-row">
            <span class="parameter-name">Blank Subtraction:</span>
            <span class="parameter-value" style="color: #4caf50;">${fitData.blank_method === 'pointbypoint' ? 'Point-by-point' : fitData.blank_method === 'clip' ? 'Clip to zero' : 'Shift minimum'}</span>
        </div>` : ''}
        <div class="parameter-row">
            <span class="parameter-name">Stationary Phase Start:</span>
            <span class="parameter-value">${typeof fitData.stationary_phase_start === 'number' && isFinite(fitData.stationary_phase_start) ? fitData.stationary_phase_start.toFixed(2) : String(fitData.stationary_phase_start)}</span>
        </div>
    `;
    
    // Add fitted parameters - only show the first 4 aHPM parameters
    console.log('Full parameters array:', fitData.parameters);
    console.log('Parameters length:', fitData.parameters?.length);
    
    if (fitData.parameters && Array.isArray(fitData.parameters)) {
        // Find the actual numerical parameters (skip any text/metadata entries)
        const numericalParams = [];
        for (let i = 0; i < fitData.parameters.length; i++) {
            const param = fitData.parameters[i];
            if (typeof param === 'number' && !isNaN(param) && isFinite(param)) {
                numericalParams.push(param);
            }
            console.log(`Parameter ${i}:`, param, `(type: ${typeof param})`);
        }
        
        console.log('Numerical parameters found:', numericalParams);
        
        // Display only the first 4 numerical parameters (aHPM model parameters)
        for (let i = 0; i < Math.min(4, numericalParams.length); i++) {
            html += `
                <div class="parameter-row">
                    <span class="parameter-name">${parameterNames[i]}:</span>
                    <span class="parameter-value">${numericalParams[i].toFixed(6)}</span>
                </div>
            `;
        }
        
        if (numericalParams.length < 4) {
            html += `
                <div class="parameter-row">
                    <span class="parameter-name">Warning:</span>
                    <span class="parameter-value" style="color: orange;">Only ${numericalParams.length} numerical parameters found</span>
                </div>
            `;
        }
    } else {
        html += `
            <div class="parameter-row">
                <span class="parameter-name">Error:</span>
                <span class="parameter-value" style="color: red;">No valid parameters found</span>
            </div>
        `;
    }
    
    parametersDiv.innerHTML = html;
    resultsDiv.style.display = 'block';
}

function onFitShowIndividualChange() {
    if (state.lastFitData) updateFitPlot(state.lastFitData);
}

function updateFitPlot(fitData) {
    plotFittedCurve(fitData);

    const showIndividual = document.getElementById('fit-show-individual-wells').checked;
    if (state.currentFitMode === 'replicate' && showIndividual && state.lastReplicateTraces.length > 0) {
        const individualTraces = state.lastReplicateTraces.map(trace => ({
            x: trace.x,
            y: trace.y,
            mode: 'lines',
            type: 'scatter',
            name: trace.well,
            line: { width: 1, color: '#4facfe', dash: 'dot' },
            opacity: 0.5
        }));
        Plotly.addTraces(document.getElementById('plot-fitting'), individualTraces);
    }
}

function plotFittedCurve(fitData) {
    const plotDiv = document.getElementById('plot-fitting');
    const blankSub = fitData.blank_subtraction && fitData.experimental_od_subtracted;

    // Raw experimental data — always shown
    const experimentalTrace = {
        x: fitData.experimental_time,
        y: fitData.experimental_od,
        mode: 'markers',
        type: 'scatter',
        name: `${fitData.experiment}: ${fitData.well} (Raw)`,
        marker: {
            color: blankSub ? 'rgba(150,150,150,0.4)' : 'black',
            size: 6
        }
    };

    const data = [experimentalTrace];

    // Blank-subtracted experimental data (only when blank subtraction was applied)
    if (blankSub) {
        data.push({
            x: fitData.experimental_time,
            y: fitData.experimental_od_subtracted,
            mode: 'markers',
            type: 'scatter',
            name: `${fitData.experiment}: ${fitData.well} (Blank-subtracted)`,
            marker: { color: 'black', size: 6 }
        });
    }

    // Fitted curve trace
    data.push({
        x: fitData.fit_time,
        y: fitData.fit_od,
        mode: 'lines',
        type: 'scatter',
        name: `aHPM Fit`,
        line: { color: 'red', width: 3 }
    });

    // Stationary phase marker (use subtracted OD range when applicable)
    const yRef = blankSub ? fitData.experimental_od_subtracted : fitData.experimental_od;
    const stationaryLine = {
        x: [fitData.stationary_phase_start, fitData.stationary_phase_start],
        y: [Math.min(...yRef), Math.max(...yRef)],
        mode: 'lines',
        type: 'scatter',
        name: 'Stationary Phase Start',
        line: { color: 'gray', width: 2, dash: 'dash' }
    };
    data.push(stationaryLine);
    
    const layout = {
        title: `Growth Curve Fitting: ${fitData.experiment} - ${fitData.well}`,
        xaxis: { title: { text: 'Time (hours)', font: { size: state.axisTitleFontSize } }, tickfont: { size: state.axisTickFontSize } },
        yaxis: { title: { text: 'OD (Arb. Units)', font: { size: state.axisTitleFontSize } }, tickfont: { size: state.axisTickFontSize } },
        showlegend: true,
        legend: { font: { size: state.legendFontSize } },
        hovermode: 'closest',
        autosize: true
    };
    
    const config = {
        responsive: true,
        displayModeBar: true,
        displaylogo: false
    };
    
    // Show plot container first
    document.getElementById('plot-fitting-container').style.display = 'block';
    
    // Create the plot
    Plotly.newPlot(plotDiv, data, layout, config).then(() => {
        // Force a resize to ensure proper width
        setTimeout(() => {
            Plotly.Plots.resize(plotDiv);
        }, 100);
    });
    
    // Clear stats since this is curve fitting, not multi-well analysis
    document.getElementById('stats-container').style.display = 'none';
}


export {
    setFitMode, onFittingReplicateChange, fitReplicateAverage,
    loadFittingExperiments, onFittingExperimentChange, onFittingWellChange,
    onBlankSubtractionChange, onBlankMethodChange,
    useAutoDetectedBlanks, runBlankAnalysis, renderBlankAnalysisCard,
    fitGrowthCurve, displayFittingResults, onFitShowIndividualChange,
    updateFitPlot, plotFittedCurve,
};
