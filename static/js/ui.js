import { state, API_BASE } from './state.js';

function relayoutFontSizes() {
    document.querySelectorAll('.growth-legend-panel')
        .forEach(el => el.style.setProperty('--growth-legend-font-size', `${state.legendFontSize}px`));
    if (document.querySelector('.fullscreen-plot .growth-legend-panel')) {
        requestAnimationFrame(() => window.dispatchEvent(new Event('resize')));
    }

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
    localStorage.setItem('legendFontSize', String(val));
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

// Floating containers that live OUTSIDE the tab-content divs (positioned
// at the root of the .container). Each is owned by exactly one tab; on
// switch we hide all of them, then re-show the ones that belong to the
// active tab if they currently have content. Keep this in sync with the
// HTML — any new free-standing container needs an entry below.
const FLOATING_CONTAINER_OWNERS = {
    'plot-growth-container':   { tab: 'plot-growth', hasContent: () => _plotHasContent('plot-growth') },
    'stats-container':         { tab: 'plot-growth', hasContent: () => _innerNonEmpty('stats-table') },
    'plot-fitting-container':  { tab: 'fit-curve',   hasContent: () => _plotHasContent('plot-fitting') },
    'cluster-grid-container':  { tab: 'clustering',  hasContent: () => _innerNonEmpty('cluster-grid') },
    'cluster-quality-panel':   { tab: 'clustering',  hasContent: () => _innerNonEmpty('cluster-quality-table') },
    'cluster-sweep-panel':     { tab: 'clustering',  hasContent: () => _innerNonEmpty('cluster-sweep-plot-silhouette') },
    'cluster-compare-panel':   { tab: 'clustering',  hasContent: () => state._savedClusterings && state._savedClusterings.length > 0 },
};

function _plotHasContent(id) {
    const el = document.getElementById(id);
    return !!el && el.hasChildNodes() && el.children.length > 0;
}

function _innerNonEmpty(id) {
    const el = document.getElementById(id);
    return !!el && !!el.innerHTML && !!el.innerHTML.trim();
}

function switchTab(tabName) {
    document.querySelectorAll('.tab-content')
        .forEach(content => content.classList.remove('active'));
    document.querySelectorAll('.tab-button')
        .forEach(button => button.classList.remove('active'));

    const selectedContent = document.getElementById(`${tabName}-content`);
    if (selectedContent) selectedContent.classList.add('active');

    const selectedButton = document.querySelector(`[onclick="switchTab('${tabName}')"]`);
    if (selectedButton) selectedButton.classList.add('active');

    // Hide every floating container, then re-show the ones owned by this
    // tab that actually have content. This makes tabs without their own
    // floating output (clean-data, batch-fit, ml-analysis) automatically
    // hide whatever the previous tab left on screen.
    for (const [id, { tab, hasContent }] of Object.entries(FLOATING_CONTAINER_OWNERS)) {
        const el = document.getElementById(id);
        if (!el) continue;
        el.style.display = (tab === tabName && hasContent()) ? 'block' : 'none';
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
