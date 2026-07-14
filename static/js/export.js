import { state } from './state.js';


function toggleFullscreen(plotType = 'plot-growth') {
    const containerId = plotType === 'plot-growth' ? 'plot-growth-container' : 'plot-fitting-container';
    const buttonId = plotType === 'plot-growth' ? 'fullscreen-growth-btn' : 'fullscreen-fitting-btn';
    
    const plotContainer = document.getElementById(containerId);
    const plotDiv = document.getElementById(plotType);
    const fullscreenBtn = document.getElementById(buttonId);

    function plotAvailableHeight() {
        const controls = plotContainer.querySelector('.plot-controls');
        const controlsHeight = controls ? Math.ceil(controls.getBoundingClientRect().height) : 80;
        plotContainer.style.setProperty('--plot-controls-height', `${controlsHeight}px`);
        return Math.max(240, window.innerHeight - controlsHeight);
    }
    
    if (!state.isFullscreen) {
        // Enter fullscreen
        plotContainer.classList.add('fullscreen-plot');
        fullscreenBtn.innerHTML = '🔙 Exit Fullscreen';
        state.isFullscreen = true;
        
        // Add escape key listener
        document.addEventListener('keydown', handleEscapeKey);
        
        // Force resize plot after DOM update with multiple attempts
        setTimeout(() => {
            const newWidth = window.innerWidth;
            const newHeight = plotAvailableHeight();
            
            // Use Plotly's relayout to properly resize
            if (plotDiv && typeof Plotly !== 'undefined') {
                Plotly.relayout(plotDiv, {
                    width: newWidth,
                    height: newHeight,
                    autosize: true
                }).then(() => {
                    // Additional resize call for good measure
                    Plotly.Plots.resize(plotDiv);
                });
            }
        }, 150);
        
        // Additional resize after a longer delay
        setTimeout(() => {
            if (plotDiv && typeof Plotly !== 'undefined') {
                const newHeight = plotAvailableHeight();
                Plotly.relayout(plotDiv, {
                    width: window.innerWidth,
                    height: newHeight,
                    autosize: true
                });
                Plotly.Plots.resize(plotDiv);
            }
        }, 300);
    } else {
        // Exit fullscreen
        plotContainer.classList.remove('fullscreen-plot');
        plotContainer.style.removeProperty('--plot-controls-height');
        fullscreenBtn.innerHTML = '🔍 Fullscreen';
        state.isFullscreen = false;
        
        // Remove escape key listener
        document.removeEventListener('keydown', handleEscapeKey);
        
        // Resize plot back to normal size
        setTimeout(() => {
            if (plotDiv && typeof Plotly !== 'undefined') {
                Plotly.relayout(plotDiv, {
                    width: null,
                    height: 700,
                    autosize: true
                }).then(() => {
                    Plotly.Plots.resize(plotDiv);
                });
            }
        }, 150);
        
        // Additional resize after a longer delay
        setTimeout(() => {
            if (plotDiv && typeof Plotly !== 'undefined') {
                Plotly.Plots.resize(plotDiv);
            }
        }, 300);
    }
}

function handleEscapeKey(event) {
    if (event.key === 'Escape' && state.isFullscreen) {
        toggleFullscreen();
    }
}

// Export functionality
function exportPlot(plotType = 'plot-growth') {
    const plotDiv = document.getElementById(plotType);
    if (plotDiv && typeof Plotly !== 'undefined') {
        const filename = generateFilename('png');
        
        Plotly.downloadImage(plotDiv, {
            format: 'png',
            width: 1200,
            height: 800,
            filename: filename
        }).then(() => {
            showExportMessage('PNG exported successfully!');
        }).catch((error) => {
            console.error('Export failed:', error);
            showExportMessage('Export failed. Please try again.', true);
        });
    }
}

function exportPlotSVG(plotType = 'plot-growth') {
    const plotDiv = document.getElementById(plotType);
    if (plotDiv && typeof Plotly !== 'undefined') {
        const filename = generateFilename('svg');
        
        Plotly.downloadImage(plotDiv, {
            format: 'svg',
            width: 1200,
            height: 800,
            filename: filename
        }).then(() => {
            showExportMessage('SVG exported successfully!');
        }).catch((error) => {
            console.error('Export failed:', error);
            showExportMessage('Export failed. Please try again.', true);
        });
    }
}

function generateFilename(extension) {
    const experimentNames = Array.from(state.selectedExperiments).join('-');
    const timestamp = new Date().toISOString().slice(0, 19).replace(/:/g, '-');
    return `growth-curves-${experimentNames}-${state.selectedWellIds.size}wells-${timestamp}.${extension}`;
}

function showExportMessage(message, isError = false) {
    // Create temporary message element
    const messageDiv = document.createElement('div');
    messageDiv.style.cssText = `
        position: fixed;
        top: 20px;
        right: 20px;
        padding: 15px 20px;
        border-radius: 8px;
        color: white;
        font-weight: 600;
        z-index: 10001;
        animation: slideIn 0.3s ease-out;
        ${isError ? 
            'background: linear-gradient(135deg, #ff6b6b 0%, #ee5a52 100%);' : 
            'background: linear-gradient(135deg, #51cf66 0%, #40c057 100%);'
        }
    `;
    messageDiv.textContent = message;
    
    // Add animation keyframes
    if (!document.getElementById('export-animations')) {
        const style = document.createElement('style');
        style.id = 'export-animations';
        style.textContent = `
            @keyframes slideIn {
                from { transform: translateX(100%); opacity: 0; }
                to { transform: translateX(0); opacity: 1; }
            }
            @keyframes slideOut {
                from { transform: translateX(0); opacity: 1; }
                to { transform: translateX(100%); opacity: 0; }
            }
        `;
        document.head.appendChild(style);
    }
    
    document.body.appendChild(messageDiv);
    
    // Remove message after 3 seconds
    setTimeout(() => {
        messageDiv.style.animation = 'slideOut 0.3s ease-in';
        setTimeout(() => {
            document.body.removeChild(messageDiv);
        }, 300);
    }, 3000);
}

// Debounced search functionality

export {
    toggleFullscreen, handleEscapeKey,
    exportPlot, exportPlotSVG, generateFilename, showExportMessage,
};
