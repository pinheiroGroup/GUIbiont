import { state, API_BASE } from './state.js';
import { relayoutFontSizes, setLegendFontSize, setAxisTitleFontSize, setAxisTickFontSize,
         switchTab, showLoading, hideLoading, showError, hideWellsAndPlot, hidePlotAndStats,
         toggleExperimentSection } from './ui.js';
import { plotGrowthCurves, buildMultiChannelLayout, channelToYAxis,
         toggleSplitChannels, renderSplitChannels, displayStats, resizePlot,
         onGrowthGroupSizeChange, goToGrowthGroup, previousGrowthGroup, nextGrowthGroup,
         resizeGrowthNumericInput } from './plot.js';
import { buildReplicateList, toggleReplicate, selectAllReplicates, clearAllReplicates,
         updateSelectedReplicatesCount, onShowIndividualChange, setPlotMode,
         computeReplicateAverage, trapezoidalAUC, plotReplicates } from './replicates.js';
import { displayWells, createWellItem, toggleExperiment, toggleWell,
         updateExperimentHeaders, updateSelectedCount,
         selectAllFilteredWells, clearAllSelectedWells, filterWellsAccordion } from './wells.js';
import { setFitMode, onFittingReplicateChange, fitReplicateAverage,
         loadFittingModels, onFittingModelChange, loadFittingExperiments,
         onFittingExperimentChange, onFittingWellChange, onBlankSubtractionChange,
         onBlankMethodChange, useAutoDetectedBlanks, runBlankAnalysis, renderBlankAnalysisCard,
         fitGrowthCurve, displayFittingResults, onFitShowIndividualChange,
         updateFitPlot, plotFittedCurve,
         fitLogLinCurve, displayLogLinResults, plotLogLinCurve, toggleLogLinOptions,
         onFitSmoothingChange, onLogLinSmoothingChange, onLogLinWindowTypeChange } from './fitting.js?v=20260724-3';
import { toggleFullscreen, handleEscapeKey, exportPlot, exportPlotSVG,
         generateFilename, showExportMessage } from './export.js';
import { debouncedGlobalSearch, globalSearchExperiments, displayGlobalSearchResults,
         selectFromSearch, clearGlobalSearch } from './search.js';
import { loadRawExperiments, cleanExperimentData } from './cleaning.js';
import { initBatchFitTab, loadBatchFitModels, loadBatchFitExperiments,
         onBatchExperimentChange, updateBatchWellCount,
         selectAllBatchWells, clearAllBatchWells,
         onBatchModeChange, onBatchFitMethodChange, onBatchFitSmoothingChange,
         toggleBatchLogLinOptions, onBatchLogLinCompanionChange,
         onBatchLogLinSmoothingChange, onBatchLogLinWindowTypeChange,
         selectAllBatchModels, clearAllBatchModels,
         runBatchFit, displayBatchResults, downloadBatchCSV,
         downloadBatchFittedCurvesCSV } from './batch-fit.js?v=20260724-4';
import { onFitResultsFileChange, onFeatureMatrixFileChange, updateMlRunBtn,
         runMlAnalysis, onCorrParamChange, onCorrZoomToggle, onMlLabelColChange,
         downloadMlResultsCSV } from './ml-analysis.js';
import { openFitCodeExport, openBatchCodeExport, openClusterCodeExport,
         closeCodeExportModal, toggleCodeComments, downloadExportedCode } from './code-export.js?v=20260724-3';
import { loadOptimizers, onFitOptimizerModeChange, onBatchFitOptimizerModeChange,
         buildOptimizerPayload } from './optimizers.js?v=20260722-5';
import { setClusteringMode, populateClusteringExperiments,
         selectAllClusteringExperiments, clearAllClusteringExperiments,
         onClusteringFileChange, onClusterNormalizeChange, updateClusteringRunBtn, toggleClusteringAdvanced,
         onClusterSmoothChange, onClusterMethodChange, onClusterBlankChange, onClusterDerivedBlankChange, onClusterInterpolateChange,
         renderClusterBlankNotice, runClustering, renderClusterGrid,
         exportClusterCSV, exportAllClustersCSV, exportClusterCentroidsCSV, exportAllClustersPNG,
         renderQualityPanel, runClusterSweep, renderSweepPanel,
         saveCurrentClustering, clearSavedClusterings, refreshSavedClusteringSelects,
         runClusterComparison, renderComparisonResult, hexToRgba,
         runBatchAverage } from './clustering.js';

const FULLSCREEN_GROWTH_PLOT_FRACTION = 0.65;
const FULLSCREEN_GROWTH_MIN_PLOT_HEIGHT = 220;
const FULLSCREEN_GROWTH_MIN_LEGEND_HEIGHT = 48;

// ---------------------------------------------------------------------------
// Initialization functions (wired here because they call many other modules)
// ---------------------------------------------------------------------------

async function init() {
    document.querySelectorAll('.legend-font-select').forEach(s => s.value = state.legendFontSize);
    document.querySelectorAll('.axis-title-font-select').forEach(s => s.value = state.axisTitleFontSize);
    document.querySelectorAll('.axis-tick-font-select').forEach(s => s.value = state.axisTickFontSize);
    await applyConfig();
    await loadExperiments();
    loadFittingExperiments();
    loadFittingModels();
    onFitSmoothingChange();
    loadRawExperiments();
    initBatchFitTab();
    loadOptimizers();
    updateMlRunBtn();
}

async function applyConfig() {
    try {
        const response = await fetch(`${API_BASE}/api/config`);
        if (!response.ok) return;
        const config = await response.json();
        if (config.enable_clean_data_tab === false) {
            const tabButton = document.querySelector('[onclick="switchTab(\'clean-data\')"]');
            const tabContent = document.getElementById('clean-data-content');
            if (tabButton) tabButton.style.display = 'none';
            if (tabContent) tabContent.remove();
            // Activate first visible tab
            const firstButton = document.querySelector('.tab-button:not([style*="display: none"])');
            if (firstButton) firstButton.click();
        }
    } catch (e) {
        // Config fetch failed; keep defaults
    }
}

// Tab switching functionality
async function loadExperiments() {
    try {
        const response = await fetch(`${API_BASE}/api/experiments`);
        const experiments = await response.json();

        // Store experiments globally for fitting interface
        state.experimentInfo = experiments;
        state.allExperiments = experiments;

        const experimentList = document.getElementById('experiment-list');
        experimentList.innerHTML = '';

        experiments.forEach(exp => {
            const checkboxItem = document.createElement('div');
            checkboxItem.className = 'experiment-checkbox-item';
            checkboxItem.dataset.experiment = exp;
            checkboxItem.onclick = () => toggleExperimentSelection(exp);
            checkboxItem.innerHTML = `
                <div class="experiment-checkbox"></div>
                <div class="experiment-name">${exp}</div>
            `;
            experimentList.appendChild(checkboxItem);
        });

        populateClusteringExperiments();

    } catch (error) {
        console.error('Error loading experiments:', error);
        const infoEl = document.getElementById('info');
        if (infoEl) { infoEl.innerHTML = '❌ Error loading experiments. Make sure the server is running.'; infoEl.className = 'error'; }
    }
}

// Toggle individual experiment selection
function toggleExperimentSelection(experiment) {
    const checkboxItem = document.querySelector(`[data-experiment="${experiment}"]`);
    
    if (!checkboxItem) {
        console.error(`Could not find checkbox item for experiment: ${experiment}`);
        return;
    }
    
    if (state.selectedExperiments.has(experiment)) {
        // Deselect experiment
        state.selectedExperiments.delete(experiment);
        checkboxItem.classList.remove('selected');
        
        // Remove wells from this experiment
        const wellsToRemove = Array.from(state.selectedWellIds).filter(wellId => 
            wellId.startsWith(experiment + '_')
        );
        wellsToRemove.forEach(wellId => state.selectedWellIds.delete(wellId));
    } else {
        // Select experiment
        state.selectedExperiments.add(experiment);
        checkboxItem.classList.add('selected');
    }
    
    updateExperimentCount();
    
    if (state.selectedExperiments.size === 0) {
        hideWellsAndPlot();
        return;
    }
    
    // Load experiment data
    loadExperimentData();
}

// Load experiment data for selected experiments
async function loadExperimentData() {
    if (state.selectedExperiments.size === 0) return;
    
    showLoading();
    
    try {
        const response = await fetch(`${API_BASE}/api/multi-experiment-info`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({
                experiments: Array.from(state.selectedExperiments)
            })
        });
        
        state.experimentInfo = await response.json();
        state.allWells = state.experimentInfo.wells;
        state.selectedReplicateKeys.clear();

        displayWells(state.allWells);
        hideLoading();
        
    } catch (error) {
        console.error('Error loading experiment info:', error);
        hideLoading();
        showError('Error loading experiment data');
    }
}

// Update experiment count display
function updateExperimentCount() {
    document.getElementById('experiment-count').textContent = 
        `${state.selectedExperiments.size} experiments selected`;
}

// Select all experiments
function selectAllExperiments() {
    const checkboxItems = document.querySelectorAll('.experiment-checkbox-item');
    checkboxItems.forEach(item => {
        const experimentName = item.querySelector('.experiment-name').textContent;
        if (!state.selectedExperiments.has(experimentName)) {
            state.selectedExperiments.add(experimentName);
            item.classList.add('selected');
        }
    });
    updateExperimentCount();
    loadExperimentData();
}

// Clear all experiments
function clearAllExperiments() {
    state.selectedExperiments.clear();
    state.selectedWellIds.clear();
    const checkboxItems = document.querySelectorAll('.experiment-checkbox-item');
    checkboxItems.forEach(item => {
        item.classList.remove('selected');
    });
    updateExperimentCount();
    hideWellsAndPlot();
}

// Display wells for selection using accordion

// ---------------------------------------------------------------------------
// Expose all functions on window so inline HTML handlers work
// ---------------------------------------------------------------------------
Object.assign(window, {
    // UI
    switchTab, relayoutFontSizes, setLegendFontSize, setAxisTitleFontSize, setAxisTickFontSize,
    showLoading, hideLoading, showError, hideWellsAndPlot, hidePlotAndStats,
    toggleExperimentSection,
    // Experiments / Wells
    loadExperiments, toggleExperimentSelection, loadExperimentData,
    updateExperimentCount, selectAllExperiments, clearAllExperiments,
    displayWells, createWellItem, toggleExperiment, toggleWell,
    updateExperimentHeaders, updateSelectedCount,
    selectAllFilteredWells, clearAllSelectedWells, filterWellsAccordion,
    // Plot
    plotGrowthCurves, buildMultiChannelLayout, channelToYAxis,
    toggleSplitChannels, renderSplitChannels, displayStats, resizePlot,
    onGrowthGroupSizeChange, goToGrowthGroup, previousGrowthGroup, nextGrowthGroup,
    resizeGrowthNumericInput,
    // Replicates
    buildReplicateList, toggleReplicate, selectAllReplicates, clearAllReplicates,
    updateSelectedReplicatesCount, onShowIndividualChange, setPlotMode,
    computeReplicateAverage, trapezoidalAUC, plotReplicates,
    // Fitting
    setFitMode, onFittingReplicateChange, fitReplicateAverage,
    loadFittingModels, onFittingModelChange, loadFittingExperiments,
    onFittingExperimentChange, onFittingWellChange, onBlankSubtractionChange,
    onBlankMethodChange, useAutoDetectedBlanks, runBlankAnalysis, renderBlankAnalysisCard,
    fitGrowthCurve, displayFittingResults, onFitShowIndividualChange,
    updateFitPlot, plotFittedCurve,
    fitLogLinCurve, displayLogLinResults, plotLogLinCurve, toggleLogLinOptions,
    onFitSmoothingChange, onLogLinSmoothingChange, onLogLinWindowTypeChange,
    // Export / Fullscreen
    toggleFullscreen, handleEscapeKey, exportPlot, exportPlotSVG,
    generateFilename, showExportMessage,
    // Search
    debouncedGlobalSearch, globalSearchExperiments, displayGlobalSearchResults,
    selectFromSearch, clearGlobalSearch,
    // Cleaning
    loadRawExperiments, cleanExperimentData,
    // Clustering
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
    // Batch fitting
    initBatchFitTab, loadBatchFitModels, loadBatchFitExperiments,
    onBatchExperimentChange, updateBatchWellCount,
    selectAllBatchWells, clearAllBatchWells,
    onBatchModeChange, onBatchFitMethodChange, onBatchFitSmoothingChange,
    toggleBatchLogLinOptions, onBatchLogLinCompanionChange,
    onBatchLogLinSmoothingChange, onBatchLogLinWindowTypeChange,
    selectAllBatchModels, clearAllBatchModels,
    runBatchFit, displayBatchResults, downloadBatchCSV, downloadBatchFittedCurvesCSV,
    // ML downstream analysis
    onFitResultsFileChange, onFeatureMatrixFileChange, updateMlRunBtn,
    runMlAnalysis, onCorrParamChange, onCorrZoomToggle, onMlLabelColChange, downloadMlResultsCSV,
    // Code export modal
    openFitCodeExport, openBatchCodeExport, openClusterCodeExport,
    closeCodeExportModal, toggleCodeComments, downloadExportedCode,
    // Optimizers
    onFitOptimizerModeChange, onBatchFitOptimizerModeChange,
});

// Handle window resize — fullscreen plots need manual relayout, others use resizePlot
window.addEventListener('resize', () => {
    const clusterFullscreenPlot = document.querySelector('.cluster-cell.fullscreen .cluster-plot-div');
    if (clusterFullscreenPlot && typeof Plotly !== 'undefined') {
        Plotly.Plots.resize(clusterFullscreenPlot);
        return;
    }
    if (state.isFullscreen) {
        const growthContainer   = document.getElementById('plot-growth-container');
        const fittingContainer  = document.getElementById('plot-fitting-container');
        let activePlotDiv = null;
        if (growthContainer  && growthContainer.classList.contains('fullscreen-plot'))
            activePlotDiv = document.getElementById('plot-growth');
        else if (fittingContainer && fittingContainer.classList.contains('fullscreen-plot'))
            activePlotDiv = document.getElementById('plot-fitting');
        if (activePlotDiv && typeof Plotly !== 'undefined') {
            let plotHeight = window.innerHeight - 80;
            if (growthContainer && growthContainer.classList.contains('fullscreen-plot') && activePlotDiv.id === 'plot-growth') {
                const controls = growthContainer.querySelector('.plot-controls');
                const controlsHeight = controls ? Math.ceil(controls.getBoundingClientRect().height) : 80;
                const containerStyle = getComputedStyle(growthContainer);
                const paddingY = (parseFloat(containerStyle.paddingTop) || 0) + (parseFloat(containerStyle.paddingBottom) || 0);
                const availableHeight = Math.max(180, window.innerHeight - controlsHeight - paddingY);
                const legend = activePlotDiv.nextElementSibling?.classList?.contains('growth-legend-panel')
                    ? activePlotDiv.nextElementSibling
                    : null;
                const legendStyle = legend ? getComputedStyle(legend) : null;
                const legendMargins = legendStyle
                    ? (parseFloat(legendStyle.marginTop) || 0) + (parseFloat(legendStyle.marginBottom) || 0)
                    : 0;
                const minPlotHeight = Math.max(FULLSCREEN_GROWTH_MIN_PLOT_HEIGHT, Math.floor(availableHeight * FULLSCREEN_GROWTH_PLOT_FRACTION));
                const legendHeight = Math.max(FULLSCREEN_GROWTH_MIN_LEGEND_HEIGHT, availableHeight - minPlotHeight - legendMargins);
                const legendNeededHeight = legend ? Math.min(legend.scrollHeight, legendHeight) : 0;
                plotHeight = Math.max(minPlotHeight, availableHeight - legendNeededHeight - legendMargins);
                growthContainer.style.setProperty('--plot-controls-height', `${controlsHeight}px`);
                growthContainer.style.setProperty('--growth-fullscreen-plot-height', `${plotHeight}px`);
                growthContainer.style.setProperty('--growth-fullscreen-legend-height', `${legendHeight}px`);
                if (legend) legend.style.setProperty('--growth-legend-max-height', `${legendHeight}px`);
            }
            Plotly.relayout(activePlotDiv, {
                width:  window.innerWidth,
                height: plotHeight,
            });
        }
    } else {
        resizePlot();
    }
});

// Start the application
window.addEventListener('load', init);
