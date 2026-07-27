import { state, API_BASE } from './state.js';
import { buildMultiChannelLayout, channelToYAxis } from './plot.js';
import { computeReplicateAverage, trapezoidalAUC } from './replicates.js';
import { buildOptimizerPayload } from './optimizers.js';

const DEFAULT_FIT_MAXITERS = 100000;
const DEFAULT_FIT_ABSTOL = '1e-15';

function buildFitOptionsPayload() {
    const maxiters = Math.max(
        1,
        parseInt(document.getElementById('fit-maxiters')?.value || `${DEFAULT_FIT_MAXITERS}`, 10) || DEFAULT_FIT_MAXITERS
    );
    const abstol = parseFloat(document.getElementById('fit-abstol')?.value || DEFAULT_FIT_ABSTOL) || parseFloat(DEFAULT_FIT_ABSTOL);
    const smoothMethod = document.getElementById('fit-smooth-method')?.value || 'none';
    const smoothPtAvg = Math.min(99, Math.max(
        3,
        parseInt(document.getElementById('fit-smooth-pt-avg')?.value || '7', 10) || 7
    ));
    const lowessFrac = Math.min(1, Math.max(
        0.01,
        parseFloat(document.getElementById('fit-lowess-frac')?.value || '0.05') || 0.05
    ));
    const gaussianHMult = Math.min(20, Math.max(
        0.1,
        parseFloat(document.getElementById('fit-gaussian-hmult')?.value || '2.0') || 2.0
    ));
    return {
        maxiters,
        abstol,
        smooth: smoothMethod !== 'none',
        smooth_method: smoothMethod,
        smooth_pt_avg: smoothPtAvg,
        lowess_frac: lowessFrac,
        gaussian_h_mult: gaussianHMult,
    };
}

function onFitSmoothingChange() {
    const method = document.getElementById('fit-smooth-method')?.value || 'none';
    const rolling = document.getElementById('fit-rolling-param');
    const lowess = document.getElementById('fit-lowess-param');
    const gaussian = document.getElementById('fit-gaussian-param');
    if (rolling) rolling.style.display = method === 'rolling_avg' ? 'flex' : 'none';
    if (lowess) lowess.style.display = method === 'lowess' ? 'flex' : 'none';
    if (gaussian) gaussian.style.display = method === 'gaussian' ? 'flex' : 'none';
}

function setFitMode(mode) {
    state.currentFitMode = mode;
    const wellSelect = document.getElementById('fitting-well');
    const replicateSelect = document.getElementById('fitting-replicate');
    const logLinBtn = document.getElementById('fit-loglin-button');
    document.getElementById('fit-mode-btn-well').classList.toggle('active', mode === 'well');
    document.getElementById('fit-mode-btn-replicate').classList.toggle('active', mode === 'replicate');
    document.getElementById('fit-show-individual-container').style.display = mode === 'replicate' ? 'block' : 'none';
    if (mode === 'well') {
        wellSelect.style.display = '';
        replicateSelect.style.display = 'none';
        document.getElementById('fit-button').disabled = !wellSelect.value;
        if (logLinBtn) logLinBtn.disabled = !wellSelect.value;
    } else {
        wellSelect.style.display = 'none';
        replicateSelect.style.display = '';
        document.getElementById('fit-button').disabled = !replicateSelect.value;
        // Log-Lin endpoint only supports a single well, not replicates.
        if (logLinBtn) logLinBtn.disabled = true;
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

        const fitCalFile = (document.getElementById('fit-calibration-file')?.value || '').trim();
        const requestPayload = {
            well_selections: replicateWells,
            label,
            experiment,
            model_name: document.getElementById('fitting-model').value || 'aHPM',
            ...buildOptimizerPayload('fit'),
            ...buildFitOptionsPayload(),
            ...(fitCalFile ? { calibration_file: fitCalFile } : {}),
        };
        const fitResponse = await fetch(`${API_BASE}/api/fit-replicate`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(requestPayload)
        });

        if (!fitResponse.ok) {
            const errorData = await fitResponse.json();
            throw new Error(errorData.error || 'Fitting failed');
        }

        const fitData = await fitResponse.json();
        fitData._request = requestPayload;
        fitData._workflow = 'parametric';
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
        const logLinBtnReset = document.getElementById('fit-loglin-button');
        if (logLinBtnReset) logLinBtnReset.disabled = true;
        return;
    }
    state._lastBlankAnalysis = null;
    state._acceptedBlankWells = [];
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
    const logLinBtn = document.getElementById('fit-loglin-button');
    fitButton.disabled = !wellSelect.value;
    if (logLinBtn) logLinBtn.disabled = !wellSelect.value || state.currentFitMode === 'replicate';
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
// Injects them into _lastBlankAnalysis so the full card renders, and records
// them in _acceptedBlankWells so the fit requests below carry them as
// override_blank_wells — otherwise accepting would only restyle the card.
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
        state._lastBlankAnalysis  = data;
        state._acceptedBlankWells = wells.slice();
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
    const methodLabels = { pointbypoint: 'Point-by-point', shift: 'Shift minimum', clip: 'Clip to floor' };
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
        const calFile = (document.getElementById('fit-calibration-file')?.value || '').trim();
        const requestPayload = {
            experiment,
            well,
            blank_subtraction: document.getElementById('fit-blank-subtraction').checked,
            blank_method: document.getElementById('fit-blank-method').value,
            override_blank_wells: state._acceptedBlankWells || [],
            model_name: document.getElementById('fitting-model').value || 'aHPM',
            ...buildOptimizerPayload('fit'),
            ...buildFitOptionsPayload(),
            ...buildLogLinCompanionPayload(),
            ...(calFile ? { calibration_file: calFile } : {}),
        };
        const response = await fetch(`${API_BASE}/api/fit-curve`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify(requestPayload)
        });

        if (!response.ok) {
            const errorData = await response.json();
            throw new Error(errorData.error || 'Fitting failed');
        }

        const fitData = await response.json();
        fitData._request = requestPayload;
        fitData._workflow = 'parametric';

        // Preserve both the result and the exact submitted settings for export.
        state.lastFitData = fitData;
        displayFittingResults(fitData);
        plotFittedCurve(fitData);
        renderLogLinCompanion(fitData);
        
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
            <span class="parameter-value" style="color: #4caf50;">${fitData.blank_method === 'pointbypoint' ? 'Point-by-point' : fitData.blank_method === 'clip' ? 'Clip to floor' : 'Shift minimum'}</span>
        </div>` : ''}
        <div class="parameter-row">
            <span class="parameter-name">Stationary Phase Start:</span>
            <span class="parameter-value">${typeof fitData.stationary_phase_start === 'number' && isFinite(fitData.stationary_phase_start) ? fitData.stationary_phase_start.toFixed(2) : String(fitData.stationary_phase_start)}</span>
        </div>
        ${fitData.optimizer_used && Array.isArray(fitData.all_attempts) && fitData.all_attempts.length > 1 ? `
        <div class="parameter-row">
            <span class="parameter-name">Winning optimizer:</span>
            <span class="parameter-value">${fitData.optimizer_used}${fitData.optimizer_run > 1 ? ` (run ${fitData.optimizer_run})` : ''} — loss ${typeof fitData.loss === 'number' ? fitData.loss.toFixed(5) : '—'}</span>
        </div>
        <div class="parameter-row" style="display: block;">
            <details><summary style="cursor: pointer; color: #6c757d;">All ${fitData.all_attempts.length} attempts</summary>
                <table style="font-size: 0.85em; margin-top: 4px; border-collapse: collapse;">
                    <tr style="border-bottom: 1px solid #dee2e6;"><th style="text-align: left; padding: 2px 8px;">Optimizer</th><th style="text-align: right; padding: 2px 8px;">Run</th><th style="text-align: right; padding: 2px 8px;">Loss</th><th style="text-align: left; padding: 2px 8px;">Status</th></tr>
                    ${fitData.all_attempts.map(a => `<tr><td style="padding: 2px 8px;">${a.optimizer}</td><td style="text-align: right; padding: 2px 8px;">${a.run}</td><td style="text-align: right; padding: 2px 8px;">${typeof a.loss === 'number' && isFinite(a.loss) ? a.loss.toFixed(5) : '—'}</td><td style="padding: 2px 8px; color: ${a.status === 'ok' ? '#28a745' : '#dc3545'};">${a.status}</td></tr>`).join('')}
                </table>
            </details>
        </div>` : ''}
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

    if (fitData.loglin_converged === true) {
        const fmt = (v, d = 4) => (typeof v === 'number' && isFinite(v)) ? v.toFixed(d) : '—';
        html += `
            <div class="parameter-row" style="border-top:1px dashed #ced4da; margin-top:8px; padding-top:8px;">
                <span class="parameter-name" style="font-weight:600;">Log-Lin companion:</span>
                <span class="parameter-value"></span>
            </div>
            <div class="parameter-row">
                <span class="parameter-name">µ (log-lin, ±SE):</span>
                <span class="parameter-value">${fmt(fitData.gr_loglin, 5)} ± ${fmt(fitData.gr_loglin_se, 5)} /h</span>
            </div>
            <div class="parameter-row">
                <span class="parameter-name">Doubling time:</span>
                <span class="parameter-value">${fmt(fitData.doubling_time_loglin)} h</span>
            </div>
            <div class="parameter-row">
                <span class="parameter-name">R²:</span>
                <span class="parameter-value">${fmt(fitData.R_squared_loglin, 5)}</span>
            </div>
            <div class="parameter-row">
                <span class="parameter-name">Exp. window:</span>
                <span class="parameter-value">${fmt(fitData.t_exp_start_loglin, 3)} → ${fmt(fitData.t_exp_end_loglin, 3)} h</span>
            </div>
            <div class="parameter-row">
                <span class="parameter-name">Lag (tangent-intercept):</span>
                <span class="parameter-value">${fmt(fitData.lag_loglin, 3)} h</span>
            </div>
            <div class="parameter-row">
                <span class="parameter-name">N<sub>max</sub> (stationary cutoff):</span>
                <span class="parameter-value">${fmt(fitData.N_max_emp, 4)}</span>
            </div>
        `;
    } else if (fitData.compute_loglin !== false && 'loglin_converged' in fitData) {
        html += `
            <div class="parameter-row" style="border-top:1px dashed #ced4da; margin-top:8px; padding-top:8px;">
                <span class="parameter-name">Log-Lin companion:</span>
                <span class="parameter-value" style="color:#856404;">no exponential window detected</span>
            </div>
        `;
    }

    parametersDiv.innerHTML = html;
    resultsDiv.style.display = 'block';
    // Surface the code-export button now that we have a fit to export.
    // Mirrors the batch-fit tab's behaviour (batch-export-btn shown after
    // displayBatchResults). Without this the modal can be opened only via
    // the console, which breaks the abstract's reproducibility claim.
    const exportBtn = document.getElementById('fit-export-btn');
    if (exportBtn) exportBtn.style.display = '';
}

function onFitShowIndividualChange() {
    if (state.lastFitData) updateFitPlot(state.lastFitData);
}

function updateFitPlot(fitData) {
    plotFittedCurve(fitData);
    renderLogLinCompanion(fitData);

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

    if (Array.isArray(fitData.smoothed_time) && Array.isArray(fitData.smoothed_od) && fitData.smoothed_time.length > 0) {
        const preprocessing = fitData.preprocessing || {};
        const smoothingLabel = preprocessing.smooth_method === 'rolling_avg'
            ? `Rolling average (${preprocessing.smooth_pt_avg || 7} points)`
            : preprocessing.smooth_method === 'lowess'
                ? `LOWESS (fraction ${preprocessing.lowess_frac || 0.05})`
                : preprocessing.smooth_method === 'gaussian'
                    ? `Gaussian (multiplier ${preprocessing.gaussian_h_mult || 2.0})`
                    : `Centered average (${preprocessing.smooth_window || 3} points)`;
        data.push({
            x: fitData.smoothed_time,
            y: fitData.smoothed_od,
            mode: 'lines',
            type: 'scatter',
            name: smoothingLabel,
            line: { color: '#167d8d', width: 2 }
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


// ---------------------------------------------------------------------------
// Log-linear (exponential-phase) fitting
// ---------------------------------------------------------------------------

function toggleLogLinOptions() {
    const panel = document.getElementById('loglin-options');
    if (panel) {
        onLogLinSmoothingChange();
        onLogLinWindowTypeChange();
        panel.style.display = panel.style.display === 'none' ? '' : 'none';
    }
}

function onLogLinSmoothingChange() {
    const method = document.getElementById('loglin-smoothing')?.value || 'rolling_avg';
    const rollingField = document.getElementById('loglin-pt-avg-field');
    const lowessField = document.getElementById('loglin-lowess-field');
    const gaussianField = document.getElementById('loglin-gaussian-field');
    if (rollingField) rollingField.style.display = method === 'rolling_avg' ? 'flex' : 'none';
    if (lowessField) lowessField.style.display = method === 'lowess' ? 'flex' : 'none';
    if (gaussianField) gaussianField.style.display = method === 'gaussian' ? 'flex' : 'none';
}

function onLogLinWindowTypeChange() {
    const winType = document.getElementById('loglin-win-type')?.value || 'maximum';
    const startField = document.getElementById('loglin-start-thr-field');
    if (startField) {
        startField.style.display =
            winType === 'global_thr' || winType === 'max_with_min_OD' ? 'flex' : 'none';
    }
}

// Payload for the `compute_loglin` companion fit on /api/fit-curve. Reuses the
// existing Log-Lin options panel; falls back to defaults when controls are
// absent (e.g. headless tests).
function buildLogLinCompanionPayload() {
    const intnum = (id, fallback) => {
        const v = parseInt(document.getElementById(id)?.value, 10);
        return Number.isFinite(v) ? v : fallback;
    };
    const num = (id, fallback) => {
        const v = parseFloat(document.getElementById(id)?.value);
        return Number.isFinite(v) ? v : fallback;
    };
    const enabled = document.getElementById('fit-compute-loglin');
    return {
        compute_loglin:                  enabled ? enabled.checked : true,
        loglin_type_of_smoothing:         document.getElementById('loglin-smoothing')?.value || 'rolling_avg',
        loglin_type_of_win:               document.getElementById('loglin-win-type')?.value || 'maximum',
        loglin_pt_avg:                   intnum('loglin-pt-avg', 7),
        loglin_pt_smoothing_derivative:  intnum('loglin-pt-deriv', 7),
        loglin_pt_min_size_of_win:       intnum('loglin-pt-min-win', 7),
        loglin_threshold_of_exp:         num('loglin-thr-exp', 0.9),
        loglin_start_exp_win_thr:         num('loglin-start-thr', 0.05),
        loglin_thr_lowess:                num('loglin-thr-lowess', 0.05),
        loglin_gaussian_h_mult:           num('loglin-gaussian-hmult', 2.0),
    };
}

// Render the second (log-lin) plot under the main model fit. Hides the panel
// when the server didn't return a converged log-lin fit.
function renderLogLinCompanion(fitData) {
    const div = document.getElementById('plot-fitting-loglin');
    if (!div) return;
    const hasFit = Array.isArray(fitData.loglin_fit_time) && fitData.loglin_fit_time.length > 0;
    if (!hasFit || fitData.loglin_converged === false) {
        div.style.display = 'none';
        return;
    }
    const blankSub = fitData.blank_subtraction && fitData.experimental_od_subtracted;
    const traces = [
        {
            x: fitData.experimental_time,
            y: blankSub ? fitData.experimental_od_subtracted : fitData.experimental_od,
            mode: 'markers',
            type: 'scatter',
            name: `${fitData.experiment}: ${fitData.well}`,
            marker: { color: 'black', size: 5 }
        },
        {
            x: fitData.loglin_fit_time,
            y: fitData.loglin_fit_od,
            mode: 'lines',
            type: 'scatter',
            name: 'Log-Lin Fit',
            line: { color: '#d62728', width: 3 }
        }
    ];
    const annotations = [];
    if (Number.isFinite(fitData.gr_loglin)) {
        const mu  = fitData.gr_loglin;
        const dt  = fitData.doubling_time_loglin;
        const r2  = fitData.R_squared_loglin;
        const se  = fitData.gr_loglin_se;
        const tStart = fitData.t_exp_start_loglin;
        const tEnd   = fitData.t_exp_end_loglin;
        annotations.push({
            xref: 'paper', yref: 'paper', x: 0.02, y: 0.98, xanchor: 'left', yanchor: 'top',
            showarrow: false, align: 'left',
            text:
                `<b>µ</b> = ${mu.toFixed(4)} ± ${Number.isFinite(se) ? se.toFixed(4) : '—'} /h<br>` +
                `<b>doubling</b> = ${Number.isFinite(dt) ? dt.toFixed(3) : '—'} h<br>` +
                `<b>R²</b> = ${Number.isFinite(r2) ? r2.toFixed(4) : '—'}<br>` +
                `<b>window</b> = ${Number.isFinite(tStart) ? tStart.toFixed(2) : '—'} → ${Number.isFinite(tEnd) ? tEnd.toFixed(2) : '—'} h`,
            font: { size: 12, color: '#222' },
            bgcolor: 'rgba(255,255,255,0.85)',
            bordercolor: '#aaa', borderwidth: 1, borderpad: 6,
        });
    }
    const layout = {
        title: `Log-Linear Companion Fit (log y): ${fitData.experiment} - ${fitData.well}`,
        xaxis: { title: { text: 'Time (h)', font: { size: state.axisTitleFontSize } }, tickfont: { size: state.axisTickFontSize } },
        yaxis: { title: { text: 'OD (log)', font: { size: state.axisTitleFontSize } }, tickfont: { size: state.axisTickFontSize }, type: 'log' },
        showlegend: true,
        legend: { font: { size: state.legendFontSize } },
        hovermode: 'closest',
        autosize: true,
        annotations,
    };
    div.style.display = 'block';
    Plotly.newPlot(div, traces, layout, { responsive: true, displayModeBar: true, displaylogo: false }).then(() => {
        setTimeout(() => Plotly.Plots.resize(div), 100);
    });
}

function buildLogLinPayload() {
    const num = (id, fallback) => {
        const v = parseFloat(document.getElementById(id)?.value);
        return Number.isFinite(v) ? v : fallback;
    };
    const intnum = (id, fallback) => {
        const v = parseInt(document.getElementById(id)?.value, 10);
        return Number.isFinite(v) ? v : fallback;
    };
    return {
        type_of_smoothing: document.getElementById('loglin-smoothing')?.value || 'rolling_avg',
        type_of_win: document.getElementById('loglin-win-type')?.value || 'maximum',
        pt_avg: intnum('loglin-pt-avg', 7),
        pt_smoothing_derivative: intnum('loglin-pt-deriv', 7),
        pt_min_size_of_win: intnum('loglin-pt-min-win', 7),
        threshold_of_exp: num('loglin-thr-exp', 0.9),
        start_exp_win_thr: num('loglin-start-thr', 0.05),
        thr_lowess: num('loglin-thr-lowess', 0.05),
        gaussian_h_mult: num('loglin-gaussian-hmult', 2.0),
    };
}

async function fitLogLinCurve() {
    if (state.currentFitMode === 'replicate') {
        alert('Log-Lin fit is only available for a single well — switch to "Fit Well" mode.');
        return;
    }

    const experiment = document.getElementById('fitting-experiment').value;
    const well = document.getElementById('fitting-well').value;
    if (!experiment || !well) {
        alert('Please select both experiment and well');
        return;
    }

    const btn = document.getElementById('fit-loglin-button');
    const originalLabel = btn.textContent;
    btn.disabled = true;
    btn.textContent = '⏳ Fitting...';

    try {
        const requestPayload = {
            experiment,
            well,
            blank_subtraction: document.getElementById('fit-blank-subtraction').checked,
            blank_method: document.getElementById('fit-blank-method').value,
            override_blank_wells: state._acceptedBlankWells || [],
            ...buildLogLinPayload(),
        };
        const response = await fetch(`${API_BASE}/api/fit-loglin`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(requestPayload),
        });

        if (!response.ok) {
            const errorData = await response.json();
            throw new Error(errorData.error || 'Log-linear fit failed');
        }

        const fitData = await response.json();
        fitData._request = requestPayload;
        fitData._workflow = 'loglin';
        state.lastFitData = fitData;
        displayLogLinResults(fitData);
        plotLogLinCurve(fitData);
        const exportBtn = document.getElementById('fit-export-btn');
        if (exportBtn) exportBtn.style.display = '';
    } catch (error) {
        alert(`Error fitting log-linear curve: ${error.message}`);
    } finally {
        btn.disabled = false;
        btn.textContent = originalLabel;
    }
}

function _fmt(v, digits = 4) {
    if (typeof v !== 'number' || !isFinite(v)) return '—';
    return v.toFixed(digits);
}

function displayLogLinResults(fitData) {
    const resultsDiv = document.getElementById('fitting-results');
    const parametersDiv = document.getElementById('fitting-parameters');

    const names = fitData.param_names || [];
    const params = fitData.parameters || [];
    const get = (key) => {
        const i = names.indexOf(key);
        return i >= 0 ? params[i] : undefined;
    };

    const muMax = get('slope');
    const muSigma = get('slope_se');
    const dt = get('doubling_time');
    const dtMinus = get('doubling_time_minus_se');
    const dtPlus = get('doubling_time_plus_se');
    const grMax = get('gr_max');
    const tStart = get('t_start_exp');
    const tEnd = get('t_end_exp');
    const tMaxGr = get('t_max_gr');
    const intercept = get('intercept');
    const interceptSigma = get('intercept_se');
    const r2 = get('R_squared');

    let html = `
        <div class="parameter-row">
            <span class="parameter-name">Experiment:</span>
            <span class="parameter-value">${fitData.experiment}</span>
        </div>
        <div class="parameter-row">
            <span class="parameter-name">Well:</span>
            <span class="parameter-value">${fitData.well}</span>
        </div>
        <div class="parameter-row">
            <span class="parameter-name">Method:</span>
            <span class="parameter-value">${fitData.method || 'Log-lin'}</span>
        </div>
        <div class="parameter-row">
            <span class="parameter-name">Blank value:</span>
            <span class="parameter-value">${_fmt(fitData.blank_value, 4)}</span>
        </div>
        ${fitData.blank_subtraction ? `
        <div class="parameter-row">
            <span class="parameter-name">Blank subtraction:</span>
            <span class="parameter-value" style="color:#4caf50;">${fitData.blank_method === 'pointbypoint' ? 'Point-by-point' : fitData.blank_method === 'clip' ? 'Clip to floor' : 'Shift minimum'}</span>
        </div>` : ''}
        <div class="parameter-row">
            <span class="parameter-name">Exponential window:</span>
            <span class="parameter-value">${_fmt(tStart, 3)} → ${_fmt(tEnd, 3)} h</span>
        </div>
        <div class="parameter-row">
            <span class="parameter-name">Time of max GR:</span>
            <span class="parameter-value">${_fmt(tMaxGr, 3)} h</span>
        </div>
        <div class="parameter-row">
            <span class="parameter-name">µ (slope, ±1 SE):</span>
            <span class="parameter-value">${_fmt(muMax, 5)} ± ${_fmt(muSigma, 5)} /h</span>
        </div>
        <div class="parameter-row">
            <span class="parameter-name">Max GR from derivative:</span>
            <span class="parameter-value">${_fmt(grMax, 5)} /h</span>
        </div>
        <div class="parameter-row">
            <span class="parameter-name">Doubling time (±1 SE):</span>
            <span class="parameter-value">${_fmt(dt, 4)} h  (${_fmt(dtMinus, 4)} … ${_fmt(dtPlus, 4)})</span>
        </div>
        <div class="parameter-row">
            <span class="parameter-name">Intercept (±1 SE):</span>
            <span class="parameter-value">${_fmt(intercept, 4)} ± ${_fmt(interceptSigma, 4)}</span>
        </div>
        <div class="parameter-row">
            <span class="parameter-name">R²:</span>
            <span class="parameter-value">${_fmt(r2, 5)}</span>
        </div>
        <div class="parameter-row">
            <span class="parameter-name">Lag (tangent-intercept):</span>
            <span class="parameter-value">${_fmt(fitData.lag_loglin, 3)} h</span>
        </div>
        <div class="parameter-row">
            <span class="parameter-name">N<sub>max</sub> (stationary cutoff):</span>
            <span class="parameter-value">${_fmt(fitData.N_max_emp, 4)}</span>
        </div>
    `;

    parametersDiv.innerHTML = html;
    resultsDiv.style.display = 'block';
}

function plotLogLinCurve(fitData) {
    const plotDiv = document.getElementById('plot-fitting');
    const blankSub = fitData.blank_subtraction && fitData.experimental_od_subtracted;

    // Raw experimental data
    const traces = [{
        x: fitData.experimental_time,
        y: fitData.experimental_od,
        mode: 'markers',
        type: 'scatter',
        name: `${fitData.experiment}: ${fitData.well} (Raw)`,
        marker: { color: blankSub ? 'rgba(150,150,150,0.4)' : 'black', size: 6 }
    }];

    if (blankSub) {
        traces.push({
            x: fitData.experimental_time,
            y: fitData.experimental_od_subtracted,
            mode: 'markers',
            type: 'scatter',
            name: `${fitData.experiment}: ${fitData.well} (Blank-subtracted)`,
            marker: { color: 'black', size: 6 }
        });
    }

    if (Array.isArray(fitData.smoothed_time) && Array.isArray(fitData.smoothed_od) && fitData.smoothed_time.length > 0) {
        traces.push({
            x: fitData.smoothed_time,
            y: fitData.smoothed_od,
            mode: 'lines',
            type: 'scatter',
            name: 'Smoothed',
            line: { color: '#1f77b4', width: 1.5, dash: 'dot' }
        });
    }

    if (Array.isArray(fitData.fit_time) && Array.isArray(fitData.fit_od) && fitData.fit_time.length > 0) {
        traces.push({
            x: fitData.fit_time,
            y: fitData.fit_od,
            mode: 'lines',
            type: 'scatter',
            name: 'Log-Lin Fit',
            line: { color: 'red', width: 3 }
        });
    }

    const layout = {
        title: `Log-Linear Fit: ${fitData.experiment} - ${fitData.well}`,
        xaxis: { title: { text: 'Time (hours)', font: { size: state.axisTitleFontSize } }, tickfont: { size: state.axisTickFontSize } },
        yaxis: { title: { text: 'OD (Arb. Units)', font: { size: state.axisTitleFontSize } }, tickfont: { size: state.axisTickFontSize }, type: 'log' },
        showlegend: true,
        legend: { font: { size: state.legendFontSize } },
        hovermode: 'closest',
        autosize: true
    };

    document.getElementById('plot-fitting-container').style.display = 'block';
    Plotly.newPlot(plotDiv, traces, layout, { responsive: true, displayModeBar: true, displaylogo: false }).then(() => {
        setTimeout(() => Plotly.Plots.resize(plotDiv), 100);
    });
    document.getElementById('stats-container').style.display = 'none';
}

export {
    setFitMode, onFittingReplicateChange, fitReplicateAverage,
    loadFittingModels, onFittingModelChange, loadFittingExperiments, onFittingExperimentChange, onFittingWellChange,
    onBlankSubtractionChange, onBlankMethodChange,
    useAutoDetectedBlanks, runBlankAnalysis, renderBlankAnalysisCard,
    fitGrowthCurve, displayFittingResults, onFitShowIndividualChange,
    updateFitPlot, plotFittedCurve,
    fitLogLinCurve, displayLogLinResults, plotLogLinCurve, toggleLogLinOptions,
    onFitSmoothingChange, onLogLinSmoothingChange, onLogLinWindowTypeChange,
    buildLogLinCompanionPayload, renderLogLinCompanion,
};
