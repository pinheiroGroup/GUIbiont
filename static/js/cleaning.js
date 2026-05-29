import { state, API_BASE } from './state.js';

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
    const machineType = document.getElementById('clean-machine')?.value || 'auto';
    
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
                well_count: wellCount,
                machine_type: machineType
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
                <div class="log-entry log-info">🔬 Reader: ${cleaningData.machine_type || 'n/a'}${cleaningData.data_file ? ' — ' + cleaningData.data_file : ''}</div>
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

export { loadRawExperiments, cleanExperimentData };
