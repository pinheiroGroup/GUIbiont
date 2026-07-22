// Shared application state — all mutable globals live here so every module
// works with the same instance (ES modules are singletons).
export const state = {
    selectedExperiments:   new Set(),
    experimentInfo:        null,
    selectedWellIds:       new Set(),
    allWells:              [],
    allExperiments:        [],
    experimentSearchData:  {},
    currentPlotMode:       'wells',
    currentFitMode:        'well',
    selectedReplicateKeys: new Set(),
    allReplicates:         {},
    lastFitData:           null,
    lastReplicateTraces:   [],
    lastBatchFitData:      null,
    _lastGrowthData:       null,
    _splitChannelsActive:  false,
    _growthPlotRequestId:  0,
    _growthPlotPagedData:  null,
    _growthPlotPageIndex:  0,
    growthPlotGroupSize:   localStorage.getItem('growthPlotGroupSize') || '20',
    isFullscreen:          false,
    searchTimeout:         null,
    currentClusteringMode: 'file',
    _lastClusterData:      null,
    _clusterPlotsNormalized: false,
    _clusterPlotRefreshers: [],
    _lastClusterSweep:     [],
    _savedClusterings:     [],
    _lastBlankAnalysis:    null,
    legendFontSize:        parseInt(localStorage.getItem('legendFontSize')     || '14'),
    axisTitleFontSize:     parseInt(localStorage.getItem('axisTitleFontSize')  || '14'),
    axisTickFontSize:      parseInt(localStorage.getItem('axisTickFontSize')   || '12'),
};

export const API_BASE = '';

export const CHANNEL_AXIS_COLORS = { 1: '#2563eb', 2: '#dc2626', 3: '#16a34a', 4: '#9333ea', 5: '#ea580c', 6: '#0891b2' };

export const CLUSTER_PALETTE = [
    '#4facfe', '#f5576c', '#43e97b', '#f093fb', '#ffd06e',
    '#00c9ff', '#c471ed', '#f7971e', '#12c2e9', '#4776e6'
];
