import { state, API_BASE } from './state.js';

function relayoutFontSizes() {
    const plots = [
        { divId: 'plot-growth', containerId: 'plot-growth-container' },
        { divId: 'plot-fitting', containerId: 'plot-fitting-container' }
    ];
    plots.forEach(({ divId, containerId }) => {
        const container = document.getElementById(containerId);
        const plotDiv = document.getElementById(divId);
        if (!container || container.style.display === 'none') return;
        if (!plotDiv || !plotDiv._fullLayout) return;
        Plotly.relayout(plotDiv, {
            'legend.font.size': state.legendFontSize,
            'xaxis.title.font.size': state.axisTitleFontSize,
            'yaxis.title.font.size': state.axisTitleFontSize,
            'xaxis.tickfont.size': state.axisTickFontSize,
            'yaxis.tickfont.size': state.axisTickFontSize
        });
    });
}

function setLegendFontSize(val) {
    state.legendFontSize = parseInt(val);
    localStorage.setItem('state.legendFontSize', String(val));
    document.querySelectorAll('.legend-font-select').forEach(s => s.value = val);
    relayoutFontSizes();
}

function setAxisTitleFontSize(val) {
    state.axisTitleFontSize = parseInt(val);
    localStorage.setItem('state.axisTitleFontSize', String(val));
    document.querySelectorAll('.axis-title-font-select').forEach(s => s.value = val);
    relayoutFontSizes();
}

function setAxisTickFontSize(val) {
    state.axisTickFontSize = parseInt(val);
    localStorage.setItem('state.axisTickFontSize', String(val));
    document.querySelectorAll('.axis-tick-font-select').forEach(s => s.value = val);
    relayoutFontSizes();
}

function switchTab(tabName) {
    // Hide all tab contents
    const tabContents = document.querySelectorAll('.tab-content');
    tabContents.forEach(content => content.classList.remove('active'));
    
    // Remove active class from all tab buttons
    const tabButtons = document.querySelectorAll('.tab-button');
    tabButtons.forEach(button => button.classList.remove('active'));
    
    // Show selected tab content
    const selectedContent = document.getElementById(`${tabName}-content`);
    if (selectedContent) {
        selectedContent.classList.add('active');
    }
    
    // Activate selected tab button
    const selectedButton = document.querySelector(`[onclick="switchTab('${tabName}')"]`);
    if (selectedButton) {
        selectedButton.classList.add('active');
    }
    
    // Show/hide appropriate plot containers based on tab
    const growthContainer = document.getElementById('plot-growth-container');
    const fittingContainer = document.getElementById('plot-fitting-container');
    const statsContainer = document.getElementById('stats-container');
    
    const clusterGridContainer = document.getElementById('cluster-grid-container');
    // Always hide clustering panels when leaving that tab
    if (tabName !== 'clustering') {
        if (clusterGridContainer) clusterGridContainer.style.display = 'none';
        document.getElementById('cluster-quality-panel').style.display = 'none';
        document.getElementById('cluster-sweep-panel').style.display   = 'none';
        document.getElementById('cluster-compare-panel').style.display = 'none';
    }

    if (tabName === 'plot-growth') {
        // Show growth plot if it has been created (check if plot div has data)
        const growthPlotDiv = document.getElementById('plot-growth');
        if (growthPlotDiv && growthPlotDiv.hasChildNodes() && growthPlotDiv.children.length > 0) {
            growthContainer.style.display = 'block';
        } else {
            growthContainer.style.display = 'none';
        }
        fittingContainer.style.display = 'none';

        // Show stats if they exist for growth plot
        if (statsContainer.querySelector('#stats-table') && statsContainer.querySelector('#stats-table').innerHTML.trim()) {
            statsContainer.style.display = 'block';
        } else {
            statsContainer.style.display = 'none';
        }

        document.getElementById('fitting-results').style.display = 'none';
    } else if (tabName === 'fit-curve') {
        // Show fitting plot if it has been created (check if plot div has data)
        const fittingPlotDiv = document.getElementById('plot-fitting');
        if (fittingPlotDiv && fittingPlotDiv.hasChildNodes() && fittingPlotDiv.children.length > 0) {
            fittingContainer.style.display = 'block';
        } else {
            fittingContainer.style.display = 'none';
        }
        growthContainer.style.display = 'none';
        if (clusterGridContainer) clusterGridContainer.style.display = 'none';

        // Hide stats for fitting (not relevant)
        statsContainer.style.display = 'none';
        
        // Show fitting results if they have content
        const fittingResults = document.getElementById('fitting-results');
        if (fittingResults && fittingResults.innerHTML.trim()) {
            fittingResults.style.display = 'block';
        }
    } else if (tabName === 'clustering') {
        growthContainer.style.display = 'none';
        fittingContainer.style.display = 'none';
        statsContainer.style.display = 'none';
        if (clusterGridContainer) {
            const hasResults = document.getElementById('cluster-grid').innerHTML.trim();
            clusterGridContainer.style.display = hasResults ? 'block' : 'none';
        }
        // Restore clustering analysis panels if they have content
        const qualityPanel = document.getElementById('cluster-quality-panel');
        if (qualityPanel && document.getElementById('cluster-quality-table').innerHTML.trim())
            qualityPanel.style.display = 'block';
        const sweepPanel = document.getElementById('cluster-sweep-panel');
        if (sweepPanel && document.getElementById('cluster-sweep-plot-silhouette').innerHTML.trim())
            sweepPanel.style.display = 'block';
        const comparePanel = document.getElementById('cluster-compare-panel');
        if (comparePanel && state._savedClusterings.length)
            comparePanel.style.display = 'block';
    }
}

// Load available experiments
function showLoading() {
    document.getElementById('loading').style.display = 'block';
}

function hideLoading() {
    document.getElementById('loading').style.display = 'none';
}

function showError(message) {
    const infoEl = document.getElementById('info');
    if (infoEl) { infoEl.innerHTML = `❌ ${message}`; infoEl.className = 'error'; }
}

function hideWellsAndPlot() {
    document.getElementById('wells-group').style.display = 'none';
    state.selectedReplicateKeys.clear();
    hidePlotAndStats();
    const infoEl = document.getElementById('info');
    if (infoEl) { infoEl.innerHTML = '👋 Select an experiment to get started.'; infoEl.className = 'info'; }
}

function hidePlotAndStats() {
    document.getElementById('plot-growth-container').style.display = 'none';
    document.getElementById('plot-fitting-container').style.display = 'none';
    document.getElementById('stats-container').style.display = 'none';
}

// Toggle experiment section
function toggleExperimentSection() {
    const header = document.querySelector('.experiment-section-header');
    const section = document.getElementById('experiment-section');
    const icon = document.querySelector('.experiment-section-icon');
    
    if (section.style.display === 'none') {
        // Show section
        section.style.display = 'block';
        header.classList.add('active');
        icon.textContent = '▲';
    } else {
        // Hide section
        section.style.display = 'none';
        header.classList.remove('active');
        icon.textContent = '▼';
    }
}

// ── Replicate helpers ──────────────────────────────────────────────────


export {
    relayoutFontSizes, setLegendFontSize, setAxisTitleFontSize, setAxisTickFontSize,
    switchTab,
    showLoading, hideLoading, showError, hideWellsAndPlot, hidePlotAndStats,
    toggleExperimentSection,
};
