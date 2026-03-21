import { state, API_BASE } from './state.js';
import { plotGrowthCurves } from './plot.js';
import { buildReplicateList } from './replicates.js';

function displayWells(wells) {
    console.log('displayWells called with', wells.length, 'wells');
    console.log('Current state.selectedWellIds:', Array.from(state.selectedWellIds));

    const wellsAccordion = document.getElementById('wells-accordion');
    const wellsGroup = document.getElementById('wells-group');

    // Store which experiments are currently expanded
    const expandedExperiments = new Set();
    document.querySelectorAll('.experiment-header.active').forEach(header => {
        const experimentTitle = header.querySelector('.experiment-title').textContent;
        expandedExperiments.add(experimentTitle);
    });

    // Group wells by experiment
    const experimentWells = {};
    wells.forEach(wellInfo => {
        if (!experimentWells[wellInfo.experiment]) {
            experimentWells[wellInfo.experiment] = [];
        }
        experimentWells[wellInfo.experiment].push(wellInfo);
    });

    // Clear existing accordion
    wellsAccordion.innerHTML = '';

    // Create accordion for each experiment
    Object.keys(experimentWells).forEach((experiment, index) => {
        const expWells = experimentWells[experiment];
        const selectedWells = expWells.filter(w => state.selectedWellIds.has(w.well_id));
        const unselectedWells = expWells.filter(w => !state.selectedWellIds.has(w.well_id));
        const nChannels = expWells.length > 0 ? (expWells[0].n_channels || 1) : 1;

        console.log(`Experiment ${experiment}: ${selectedWells.length} selected, ${unselectedWells.length} unselected, ${nChannels} channels`);

        // Build inner content: per-channel sections if multi-channel, else single pair
        let innerContent = '';
        if (nChannels > 1) {
            for (let ch = 1; ch <= nChannels; ch++) {
                const chWells = expWells.filter(w => (w.channel || 1) === ch);
                const chSelected = chWells.filter(w => state.selectedWellIds.has(w.well_id));
                const chAvailable = chWells.filter(w => !state.selectedWellIds.has(w.well_id));
                innerContent += `
                    <div class="channel-section">
                        <div class="channel-section-header">Channel ${ch}</div>
                        <div class="wells-grid-container">
                            <div class="wells-column">
                                <div class="wells-column-header selected-wells-header">
                                    Selected Wells (${chSelected.length})
                                </div>
                                <div class="wells-list" id="selected-${experiment}-ch${ch}">
                                    ${chSelected.map(well => createWellItem(well, true)).join('')}
                                </div>
                            </div>
                            <div class="wells-column">
                                <div class="wells-column-header available-wells-header">
                                    Available Wells (${chAvailable.length})
                                </div>
                                <div class="wells-list" id="available-${experiment}-ch${ch}">
                                    ${chAvailable.map(well => createWellItem(well, false)).join('')}
                                </div>
                            </div>
                        </div>
                    </div>
                `;
            }
        } else {
            innerContent = `
                <div class="wells-grid-container">
                    <div class="wells-column">
                        <div class="wells-column-header selected-wells-header">
                            Selected Wells (${selectedWells.length})
                        </div>
                        <div class="wells-list" id="selected-${experiment}">
                            ${selectedWells.map(well => createWellItem(well, true)).join('')}
                        </div>
                    </div>
                    <div class="wells-column">
                        <div class="wells-column-header available-wells-header">
                            Available Wells (${unselectedWells.length})
                        </div>
                        <div class="wells-list" id="available-${experiment}">
                            ${unselectedWells.map(well => createWellItem(well, false)).join('')}
                        </div>
                    </div>
                </div>
            `;
        }

        const experimentItem = document.createElement('div');
        experimentItem.className = 'experiment-item';
        experimentItem.innerHTML = `
            <div class="experiment-header" onclick="toggleExperiment('${experiment}')">
                <div>
                    <div class="experiment-title">${experiment}</div>
                    <div class="experiment-info">
                        <span>${expWells.length} wells total</span>
                        <span>${selectedWells.length} selected</span>
                        ${nChannels > 1 ? `<span>${nChannels} channels</span>` : ''}
                    </div>
                </div>
                <span class="accordion-icon">▼</span>
            </div>
            <div class="experiment-content" id="content-${experiment}">
                ${innerContent}
            </div>
        `;

        wellsAccordion.appendChild(experimentItem);

        // Restore expansion state or open first experiment by default
        if (expandedExperiments.has(experiment) || (index === 0 && expandedExperiments.size === 0)) {
            setTimeout(() => toggleExperiment(experiment), 100);
        }
    });

    wellsGroup.style.display = 'block';
    updateSelectedCount();
    buildReplicateList(wells);

    // Reapply any existing filters
    setTimeout(() => {
        filterWellsAccordion();
    }, 150);

    const experimentNames = Array.from(state.selectedExperiments).join(', ');
    document.getElementById('info').innerHTML = `📊 Experiments loaded: <strong>${experimentNames}</strong><br>Found ${wells.length} wells total. Click on experiment headers to expand/collapse. Click wells to select/deselect them.`;
    document.getElementById('info').className = 'info';
}

function createWellItem(wellInfo, isSelected) {
    const channel = wellInfo.channel || 1;
    const nChannels = wellInfo.n_channels || 1;
    const chLabel = nChannels > 1 ? ` [Ch ${channel}]` : '';
    return `
        <div class="well-item ${isSelected ? 'selected' : ''}"
             onclick="toggleWell('${wellInfo.well_id}')"
             data-well-id="${wellInfo.well_id}"
             data-experiment="${wellInfo.experiment}"
             data-channel="${channel}"
             data-condition="${wellInfo.condition.toLowerCase()}"
             data-antibiotic="${wellInfo.antibiotic.toLowerCase()}">
            <div class="well-name">${wellInfo.experiment}: ${wellInfo.well}${chLabel}</div>
            <div class="well-condition">${wellInfo.condition} | ${wellInfo.antibiotic}</div>
        </div>
    `;
}

// Toggle accordion experiment
function toggleExperiment(experiment) {
    const header = document.querySelector(`[onclick="toggleExperiment('${experiment}')"]`);
    const content = document.getElementById(`content-${experiment}`);
    const icon = header.querySelector('.accordion-icon');

    if (content.classList.contains('active')) {
        content.classList.remove('active');
        header.classList.remove('active');
        icon.textContent = '▼';
    } else {
        content.classList.add('active');
        header.classList.add('active');
        icon.textContent = '▲';
    }
}

// Toggle individual well selection
function _wellColumnId(experiment, channel, type) {
    // Returns the DOM id of the selected/available column for a well.
    // type: 'selected' | 'available'
    const chSuffix = document.getElementById(`${type}-${experiment}-ch${channel}`) ? `-ch${channel}` : '';
    return `${type}-${experiment}${chSuffix}`;
}

function toggleWell(wellId) {
    const wellItem = document.querySelector(`[data-well-id="${wellId}"]`);
    const experiment = wellItem.dataset.experiment;
    const channel = parseInt(wellItem.dataset.channel || '1');

    if (state.selectedWellIds.has(wellId)) {
        // Deselect well
        state.selectedWellIds.delete(wellId);
        wellItem.classList.remove('selected');

        // Move to available column
        const availableColumn = document.getElementById(_wellColumnId(experiment, channel, 'available'));
        availableColumn.appendChild(wellItem);
    } else {
        // Select well
        state.selectedWellIds.add(wellId);
        wellItem.classList.add('selected');

        // Move to selected column
        const selectedColumn = document.getElementById(_wellColumnId(experiment, channel, 'selected'));
        selectedColumn.appendChild(wellItem);
    }

    // Update headers and counts
    updateExperimentHeaders();
    updateSelectedCount();

    // Update plot
    if (state.selectedWellIds.size > 0) {
        plotGrowthCurves();
    } else {
        hidePlotAndStats();
    }
}

// Update experiment headers with current counts
function updateExperimentHeaders() {
    Object.keys(state.experimentInfo.wells.reduce((acc, well) => {
        acc[well.experiment] = true;
        return acc;
    }, {})).forEach(experiment => {
        const expWells = state.experimentInfo.wells.filter(w => w.experiment === experiment);
        const selectedWells = expWells.filter(w => state.selectedWellIds.has(w.well_id));
        const nChannels = expWells.length > 0 ? (expWells[0].n_channels || 1) : 1;

        const header = document.querySelector(`[onclick="toggleExperiment('${experiment}')"]`);
        if (!header) return;
        const infoDiv = header.querySelector('.experiment-info');
        infoDiv.innerHTML = `
            <span>${expWells.length} wells total</span>
            <span>${selectedWells.length} selected</span>
            ${nChannels > 1 ? `<span>${nChannels} channels</span>` : ''}
        `;

        if (nChannels > 1) {
            for (let ch = 1; ch <= nChannels; ch++) {
                const chWells = expWells.filter(w => (w.channel || 1) === ch);
                const chSelected = chWells.filter(w => state.selectedWellIds.has(w.well_id));
                const selList = document.getElementById(`selected-${experiment}-ch${ch}`);
                const avlList = document.getElementById(`available-${experiment}-ch${ch}`);
                if (selList) selList.previousElementSibling.textContent = `Selected Wells (${chSelected.length})`;
                if (avlList) avlList.previousElementSibling.textContent = `Available Wells (${chWells.length - chSelected.length})`;
            }
        } else {
            const selEl = document.querySelector(`#selected-${experiment}`);
            const avlEl = document.querySelector(`#available-${experiment}`);
            if (selEl) selEl.previousElementSibling.textContent = `Selected Wells (${selectedWells.length})`;
            if (avlEl) avlEl.previousElementSibling.textContent = `Available Wells (${expWells.length - selectedWells.length})`;
        }
    });
}

// Update selected wells count
function updateSelectedCount() {
    document.getElementById('selected-count').textContent = 
        `${state.selectedWellIds.size} wells selected`;
}

// Select all filtered wells
function selectAllFilteredWells() {
    const visibleWells = document.querySelectorAll('.well-item:not([style*="display: none"])');
    visibleWells.forEach(wellItem => {
        const wellId = wellItem.dataset.wellId;
        if (!state.selectedWellIds.has(wellId)) {
            toggleWell(wellId);
        }
    });
}

// Clear all selected wells
function clearAllSelectedWells() {
    // Get a copy of all currently selected well IDs
    const selectedWells = Array.from(state.selectedWellIds);

    // Clear the selected wells set first
    state.selectedWellIds.clear();

    // Move all wells back to available columns and remove selected styling
    selectedWells.forEach(wellId => {
        const wellItem = document.querySelector(`[data-well-id="${wellId}"]`);
        if (wellItem) {
            const experiment = wellItem.dataset.experiment;
            const channel = parseInt(wellItem.dataset.channel || '1');
            wellItem.classList.remove('selected');

            // Move to available column (channel-aware)
            const availableColumn = document.getElementById(_wellColumnId(experiment, channel, 'available'));
            if (availableColumn) {
                availableColumn.appendChild(wellItem);
            }
        }
    });
    
    // Update the selected count
    updateSelectedCount();
    
    // Update the plot (clear it)
    updatePlotWithSelectedWells();
}

// Filter wells in accordion based on condition and antibiotic text
function filterWellsAccordion() {
    const conditionFilter = document.getElementById('condition-filter').value.toLowerCase().trim();
    const antibioticFilter = document.getElementById('antibiotic-filter').value.toLowerCase().trim();
    const filterInfo = document.getElementById('filter-info');
    
    let visibleCount = 0;
    let matchingCount = 0;
    
    // Show/hide wells based on filters
    const allWellItems = document.querySelectorAll('.well-item');
    allWellItems.forEach(wellItem => {
        const conditionText = wellItem.dataset.condition;
        const antibioticText = wellItem.dataset.antibiotic;
        
        const conditionMatch = conditionFilter === '' || conditionText.includes(conditionFilter);
        const antibioticMatch = antibioticFilter === '' || antibioticText.includes(antibioticFilter);
        
        if (conditionMatch && antibioticMatch) {
            wellItem.style.display = 'block';
            visibleCount++;
            if (conditionFilter !== '' || antibioticFilter !== '') matchingCount++;
        } else {
            wellItem.style.display = 'none';
        }
    });
    
    // Update filter info
    const activeFilters = [];
    if (conditionFilter !== '') activeFilters.push(`condition: "${conditionFilter}"`);
    if (antibioticFilter !== '') activeFilters.push(`antibiotic: "${antibioticFilter}"`);
    
    if (activeFilters.length === 0) {
        filterInfo.textContent = `Showing all ${visibleCount} wells`;
    } else {
        filterInfo.textContent = `Filter ${activeFilters.join(' & ')}: ${matchingCount} wells match`;
    }
}

// Helper function to resize plot

export {
    displayWells, createWellItem, toggleExperiment, toggleWell,
    updateExperimentHeaders, updateSelectedCount,
    selectAllFilteredWells, clearAllSelectedWells, filterWellsAccordion,
};
