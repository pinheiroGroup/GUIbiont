import { state, API_BASE } from './state.js';


function debouncedGlobalSearch() {
    clearTimeout(state.searchTimeout);
    state.searchTimeout = setTimeout(globalSearchExperiments, 500); // Wait 500ms after user stops typing
}

// Global search functionality
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

function displayGlobalSearchResults(results) {
    try {
        const resultsDiv = document.getElementById('global-search-results');
        
        if (!Array.isArray(results)) {
            console.error('Results is not an array:', results);
            return;
        }
        
        // Create a set of matching experiment names for easy lookup
        const matchingExperiments = new Set(results.map(result => result.experiment));
        
        // Get all experiment checkboxes and apply visual filtering
        const experimentItems = document.querySelectorAll('.experiment-checkbox-item');
        let matchCount = 0;
        
        experimentItems.forEach(item => {
            const experimentName = item.dataset.experiment;
            if (matchingExperiments.has(experimentName)) {
                // Highlight matching experiments
                item.classList.remove('search-filtered-out');
                item.classList.add('search-match');
                matchCount++;
            } else {
                // Gray out non-matching experiments
                item.classList.remove('search-match');
                item.classList.add('search-filtered-out');
            }
        });
        
        // Show search status
        if (results.length === 0) {
            resultsDiv.innerHTML = '<div class="search-status">No experiments match your search criteria.</div>';
            // Gray out all experiments
            experimentItems.forEach(item => {
                item.classList.remove('search-match');
                item.classList.add('search-filtered-out');
            });
        } else {
            const totalWells = results.reduce((sum, result) => sum + result.matching_wells.length, 0);
            resultsDiv.innerHTML = `<div class="search-status">Found ${results.length} experiment(s) with ${totalWells} matching well(s)</div>`;
        }
        
        resultsDiv.style.display = 'block';
        
    } catch (error) {
        console.error('Error displaying search results:', error);
        throw error;
    }
}

function selectFromSearch(experimentName) {
    // Add the experiment to selected experiments if not already selected
    if (!state.selectedExperiments.has(experimentName)) {
        state.selectedExperiments.add(experimentName);
        updateExperimentCheckboxes();
        onExperimentChange();
    }
    
    // Clear search results
    clearGlobalSearch();
    
    // Scroll to experiment section
    document.querySelector('.experiment-section-header').scrollIntoView({ behavior: 'smooth' });
}

function clearGlobalSearch() {
    document.getElementById('global-condition-search').value = '';
    document.getElementById('global-antibiotic-search').value = '';
    document.getElementById('global-search-results').style.display = 'none';
    
    // Remove all search filtering classes
    const experimentItems = document.querySelectorAll('.experiment-checkbox-item');
    experimentItems.forEach(item => {
        item.classList.remove('search-filtered-out', 'search-match');
    });
}

// Data cleaning functionality

export {
    debouncedGlobalSearch, globalSearchExperiments,
    displayGlobalSearchResults, selectFromSearch, clearGlobalSearch,
};
