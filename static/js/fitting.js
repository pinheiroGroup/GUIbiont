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
                experiment: experiment,
                model_name: document.getElementById('fitting-model').value || 'aHPM',
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

// Brief descriptions for well-known models shown in the info card.
const MODEL_DESCRIPTIONS = {
    aHPM:                            'Adjusted Hyper-exponential Plateau Model — ODE-based model with explicit lag, exponential growth, and stationary phase (McKellar 1997).',
    HPM:                             'Hyper-exponential Plateau Model — original HPM without shape parameter.',
    HPM_exp:                         'HPM exponential variant — two-parameter simplified HPM.',
    HPM_3_death:                     'HPM with inactivation and death phases.',
    HPM_3_inhibition:                'HPM with growth inhibition term.',
    HPM_inhibition:                  'HPM with inhibitor-driven growth reduction.',
    aHPM_inhibition:                 'aHPM extended with inhibition kinetics.',
    aHPM_3_death_resistance:         'aHPM with death and antibiotic-resistance subpopulation.',
    logistic:                        'Classic logistic growth (Verhulst 1838) — two-parameter ODE.',
    alogistic:                       'Logistic with a shape parameter controlling the inflection point.',
    hyper_logistic:                  'Logistic with additional doubling-time and shape parameters.',
    gompertz:                        'Gompertz ODE — asymmetric sigmoidal growth (Gompertz 1825).',
    hyper_gompertz:                  'Gompertz with an additional shape parameter.',
    baranyi_exp:                     'Baranyi & Roberts model with exponential lag exit (Baranyi & Roberts 1994).',
    baranyi_richards:                'Baranyi with Richards-type stationary phase flexibility.',
    baranyi_roberts:                 'Full Baranyi–Roberts model with two shape parameters.',
    bertalanffy_richards:            'von Bertalanffy growth with Richards shape flexibility.',
    ode_von_bertalanffy:             'Classic von Bertalanffy ODE with anabolism–catabolism balance.',
    exponential:                     'Single-parameter exponential growth — no saturation.',
    NL_logistic:                     'Phenomenological logistic with explicit lag time.',
    NL_Gompertz:                     'Gompertz phenomenological model with lag (Zwietering 1990).',
    NL_Richards:                     'Richards phenomenological model with shape and lag.',
    NL_Bertalanffy:                  'Bertalanffy phenomenological model.',
    NL_Weibull:                      'Weibull-based phenomenological model.',
    NL_exponential:                  'Phenomenological exponential — N₀ and growth rate.',
    NL_Morgan:                       'Morgan dose–response type growth model.',
    NL_piecewise_exp_logistic:       'Piecewise: exponential lag exit then logistic saturation.',
    NL_piecewise_lin_logistic:       'Piecewise: linear lag exit then logistic saturation.',
    triple_piecewise:                'Three-phase piecewise: lag, exponential, stationary.',
    triple_piecewise_adjusted_logistic: 'Three-phase piecewise with adjusted logistic saturation.',
    triple_piecewise_bertalanffy_richards: 'Three-phase piecewise with Bertalanffy–Richards saturation.',
    triple_piecewise_sub_linear:     'Three-phase piecewise with sub-linear stationary decline.',
    piecewise_adjusted_logistic:     'Two-phase piecewise with adjusted logistic saturation.',
    ODE_four_piecewise:              'Four-phase ODE piecewise model.',
    gbsm_piecewise:                  'Gompertz–Baranyi structured model piecewise variant.',
    ODEs_HPM_SR:                     'HPM ODE system with phage, susceptible and resistant subpopulations.',
    Diauxic_replicator_1:            'Diauxic growth model — single replicator with linear stationary term.',
    Diauxic_replicator_2:            'Diauxic growth model — replicator with stationary growth term.',
    Diauxic_piecewise_adjusted_logistic: 'Diauxic growth with two sequential adjusted-logistic phases.',
};

// References for selected models (DOI or URL).
const MODEL_REFS = {
    aHPM:           { text: 'McKellar & Lu (2004)', url: 'https://doi.org/10.1016/j.ijfoodmicro.2003.08.018' },
    logistic:       { text: 'Verhulst (1838)', url: 'https://doi.org/10.1007/BF02309004' },
    gompertz:       { text: 'Gompertz (1825)', url: 'https://doi.org/10.1098/rstl.1825.0026' },
    baranyi_exp:    { text: 'Baranyi & Roberts (1994)', url: 'https://doi.org/10.1016/0168-1605(94)90157-0' },
    baranyi_richards: { text: 'Baranyi & Roberts (1994)', url: 'https://doi.org/10.1016/0168-1605(94)90157-0' },
    baranyi_roberts:  { text: 'Baranyi & Roberts (1994)', url: 'https://doi.org/10.1016/0168-1605(94)90157-0' },
    NL_Gompertz:    { text: 'Zwietering et al. (1990)', url: 'https://doi.org/10.1128/aem.56.6.1875-1881.1990' },
    NL_Richards:    { text: 'Richards (1959)', url: 'https://doi.org/10.1093/jxb/10.2.290' },
    ode_von_bertalanffy: { text: 'von Bertalanffy (1957)', url: 'https://doi.org/10.1086/physzool.10.2.30151538' },
};

// Cache of model metadata returned by /api/models, keyed by name.
const _modelRegistry = {};

async function loadFittingModels() {
    const modelSelect = document.getElementById('fitting-model');
    try {
        const response = await fetch(`${API_BASE}/api/models`);
        if (!response.ok) return;
        const models = await response.json();
        modelSelect.innerHTML = '';
        models.forEach(m => {
            _modelRegistry[m.name] = m;
            const option = document.createElement('option');
            option.value = m.name;
            option.textContent = `${m.name}  (${m.param_names.length} params)`;
            if (m.name === 'aHPM') option.selected = true;
            modelSelect.appendChild(option);
        });
        onFittingModelChange();
    } catch (e) {
        console.error('Failed to load models:', e);
    }
}

function onFittingModelChange() {
    const name = document.getElementById('fitting-model').value;
    const card = document.getElementById('model-info-card');
    const m = _modelRegistry[name];
    if (!m) { card.style.display = 'none'; return; }

    const typeCls  = m.model_type === 'NL' ? 'nl' : 'ode';
    const typeLabel = m.model_type === 'NL' ? 'Phenomenological' : 'ODE-based';
    const chips    = m.param_names.map(p => `<span class="mi-param-chip">${p}</span>`).join('');
    const desc     = MODEL_DESCRIPTIONS[name] || '';
    const ref      = MODEL_REFS[name];
    const refHtml  = ref
        ? `<div class="mi-refs">Reference: <a href="${ref.url}" target="_blank" rel="noopener">${ref.text}</a></div>`
        : '';

    card.innerHTML = `
        <div class="mi-header">
            <span class="model-type-badge ${typeCls}">${typeLabel}</span>
            <span style="font-weight:600;">${name}</span>
            <span style="color:#6c757d;">(${m.param_names.length} parameters)</span>
        </div>
        <div class="mi-params">${chips}</div>
        ${desc  ? `<div class="mi-description">${desc}</div>` : ''}
        ${refHtml}
    `;
    card.style.display = 'block';
}

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
                blank_method: document.getElementById('fit-blank-method').value,
                model_name: document.getElementById('fitting-model').value || 'aHPM',
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
    
    const parameterNames = fitData.param_names || [];
    
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
        const numericalParams = fitData.parameters.filter(p => typeof p === 'number' && isFinite(p));
        numericalParams.forEach((val, i) => {
            const name = parameterNames[i] || `param_${i + 1}`;
            html += `
                <div class="parameter-row">
                    <span class="parameter-name">${name}:</span>
                    <span class="parameter-value">${val.toFixed(6)}</span>
                </div>
            `;
        });
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
        name: `${fitData.model} Fit`,
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
    loadFittingModels, onFittingModelChange, loadFittingExperiments, onFittingExperimentChange, onFittingWellChange,
    onBlankSubtractionChange, onBlankMethodChange,
    useAutoDetectedBlanks, runBlankAnalysis, renderBlankAnalysisCard,
    fitGrowthCurve, displayFittingResults, onFitShowIndividualChange,
    updateFitPlot, plotFittedCurve,
};
