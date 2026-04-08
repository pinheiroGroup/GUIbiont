import { state, API_BASE } from './state.js';

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
        experimentInfo = experiments;
        allExperiments = experiments;

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
async function loadExperimentData() {
    if (selectedExperiments.size === 0) return;
    
    showLoading();
    
    try {
        const response = await fetch(`${API_BASE}/api/multi-experiment-info`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({
                experiments: Array.from(selectedExperiments)
            })
        });
        
        experimentInfo = await response.json();
        allWells = experimentInfo.wells;
        selectedReplicateKeys.clear();

        displayWells(allWells);
        hideLoading();
        
    } catch (error) {
        console.error('Error loading experiment info:', error);
        hideLoading();
        showError('Error loading experiment data');
    }
}

// Update experiment count display
async function globalSearchExperiments() {
    const conditionQuery = document.getElementById('global-condition-search').value.trim();
    const antibioticQuery = document.getElementById('global-antibiotic-search').value.trim();
    
    if (!conditionQuery && !antibioticQuery) {
        // Clear results and filters if both fields are empty
        const resultsDiv = document.getElementById('global-search-results');
        if (resultsDiv) {
            resultsDiv.style.display = 'none';
        }
        
        // Remove all search filtering classes
        const experimentItems = document.querySelectorAll('.experiment-checkbox-item');
        experimentItems.forEach(item => {
            item.classList.remove('search-filtered-out', 'search-match');
        });
        return;
    }
    
    try {
        const response = await fetch('/api/global-search', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                condition: conditionQuery,
                antibiotic: antibioticQuery
            }),
        });
        
        console.log('Response status:', response.status);
        
        if (!response.ok) {
            const errorText = await response.text();
            console.error('Server error:', errorText);
            throw new Error(`Server returned ${response.status}: ${errorText}`);
        }
        
        const searchResults = await response.json();
        console.log('Search results:', searchResults);
        displayGlobalSearchResults(searchResults);
        
    } catch (error) {
        console.error('Error performing global search:', error);
        alert(`Error performing search: ${error.message}. Check console for details.`);
    }
}

async function loadRawExperiments() {
    const rawExperimentSelect = document.getElementById('raw-experiment');
    const cleanButton = document.getElementById('clean-button');
    
    try {
        const response = await fetch(`${API_BASE}/api/raw-experiments`);
        const rawExperiments = await response.json();
        
        // Clear previous options
        rawExperimentSelect.innerHTML = '<option value="">Select Raw Experiment</option>';
        
        if (rawExperiments.length === 0) {
            rawExperimentSelect.innerHTML = '<option value="">No raw experiments found</option>';
            return;
        }
        
        rawExperiments.forEach(exp => {
            const option = document.createElement('option');
            option.value = exp;
            option.textContent = exp;
            rawExperimentSelect.appendChild(option);
        });
        
        // Add event listener
        rawExperimentSelect.addEventListener('change', () => {
            cleanButton.disabled = !rawExperimentSelect.value;
        });
        
    } catch (error) {
        console.error('Error loading raw experiments:', error);
        rawExperimentSelect.innerHTML = '<option value="">Error loading experiments</option>';
    }
}

async function cleanExperimentData() {
    const rawExperimentSelect = document.getElementById('raw-experiment');
    const wellCountInput = document.getElementById('well-count');
    const cleanButton = document.getElementById('clean-button');
    const progressDiv = document.getElementById('cleaning-progress');
    const resultsDiv = document.getElementById('cleaning-results');
    const progressFill = document.getElementById('progress-fill');
    const progressText = document.getElementById('progress-text');
    const cleaningLog = document.getElementById('cleaning-log');
    
    const experiment = rawExperimentSelect.value;
    const wellCount = parseInt(wellCountInput.value);
    
    if (!experiment) {
        alert('Please select a raw experiment');
        return;
    }
    
    if (![6, 48, 96].includes(wellCount)) {
        alert('Well count must be 6, 48, or 96');
        return;
    }
    
    // Show progress and disable button
    cleanButton.disabled = true;
    cleanButton.textContent = '🔄 Cleaning...';
    progressDiv.style.display = 'block';
    resultsDiv.style.display = 'none';
    
    // Animate progress bar
    let progress = 0;
    const progressInterval = setInterval(() => {
        progress += 2;
        progressFill.style.width = Math.min(progress, 90) + '%';
        
        if (progress < 30) {
            progressText.textContent = 'Reading raw data files...';
        } else if (progress < 60) {
            progressText.textContent = 'Processing annotation data...';
        } else if (progress < 90) {
            progressText.textContent = 'Cleaning time series data...';
        }
    }, 100);
    
    try {
        const response = await fetch(`${API_BASE}/api/clean-data`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                experiment: experiment,
                well_count: wellCount
            })
        });
        
        clearInterval(progressInterval);
        progressFill.style.width = '100%';
        progressText.textContent = 'Complete!';
        
        if (!response.ok) {
            const errorData = await response.json();
            throw new Error(errorData.error || 'Cleaning failed');
        }
        
        const cleaningData = await response.json();
        
        // Show results
        setTimeout(() => {
            progressDiv.style.display = 'none';
            resultsDiv.style.display = 'block';
            
            let logHtml = `
                <div class="log-entry log-success">✅ ${cleaningData.message}</div>
                <div class="log-entry log-info">📂 Output folder: ${cleaningData.output_path}</div>
                <div class="log-entry log-info">🧪 Wells processed: ${cleaningData.well_count}</div>
                <div class="log-entry log-info">📄 Files created: ${cleaningData.created_files.length}</div>
            `;
            
            cleaningData.created_files.forEach(file => {
                logHtml += `<div class="log-entry log-success">   └── ${file}</div>`;
            });
            
            cleaningLog.innerHTML = logHtml;
            
            // Refresh the cleaned experiments list for other tabs
            loadExperiments();
            
        }, 1000);
        
    } catch (error) {
        clearInterval(progressInterval);
        console.error('Error cleaning data:', error);
        
        progressDiv.style.display = 'none';
        resultsDiv.style.display = 'block';
        cleaningLog.innerHTML = `<div class="log-entry log-error">❌ Error: ${error.message}</div>`;
        
    } finally {
        cleanButton.disabled = false;
        cleanButton.textContent = '🧹 Clean Data';
    }
}

// Curve fitting functionality
