// --- Global State ---
let charts = {};
let updateTimer = null;
let timelineDebounce = null;

let currentPage = 1;
let itemsPerPage = 50;
let totalRecords = 0;

let timelineState = {
    start: null,
    end: null
};

// --- Initialization ---
document.addEventListener('DOMContentLoaded', () => {
    const now = new Date();
    timelineState.end = now.getTime();
    timelineState.start = now.getTime() - (24 * 60 * 60 * 1000);
    syncTimelineInputs(); 

    loadFilters(); 
    loadTimeline(timelineState.start, timelineState.end);
    
    // Sync datetime inputs between top and bottom toolbars
    document.querySelectorAll('.ts-start, .ts-end').forEach(input => {
        input.addEventListener('change', function() {
            const isStart = this.classList.contains('ts-start');
            const className = isStart ? '.ts-start' : '.ts-end';
            document.querySelectorAll(className).forEach(el => {
                if (el !== this) el.value = this.value;
            });
        });
    });
    
    // Close multi-selects when clicking outside
    document.addEventListener('click', function(e) {
        if (!e.target.closest('.multi-select')) {
            document.querySelectorAll('.ms-dropdown').forEach(d => d.classList.remove('show'));
        }
    });

    setInterval(loadOverview, 60000);
});

// --- Multi-select Logic ---
function toggleMs(id) {
    // Close others
    document.querySelectorAll('.ms-dropdown').forEach(d => {
        if (d.parentElement.id !== id) d.classList.remove('show');
    });
    const dropdown = document.querySelector(`#${id} .ms-dropdown`);
    dropdown.classList.toggle('show');
}

function getMsValues(id) {
    const checked = document.querySelectorAll(`#${id} .ms-dropdown input:checked`);
    if (checked.length === 0) return 'all';
    return Array.from(checked).map(cb => cb.value);
}

// Update multi-select button label to show selected items
function updateMsLabel(id) {
    const container = document.getElementById(id);
    const btn = container.querySelector('.ms-btn');
    const checked = container.querySelectorAll('.ms-dropdown input:checked');
    const defaultLabel = btn.getAttribute('data-default') || btn.innerText;
    
    // Store default label on first call
    if (!btn.getAttribute('data-default')) {
        btn.setAttribute('data-default', btn.innerText);
    }
    
    if (checked.length === 0) {
        btn.innerText = defaultLabel;
        btn.classList.remove('has-selection');
    } else if (checked.length <= 2) {
        // Show selected values if 2 or less
        const labels = Array.from(checked).map(cb => {
            const label = cb.nextElementSibling;
            return label ? label.innerText : cb.value;
        });
        btn.innerText = labels.join(', ');
        btn.classList.add('has-selection');
    } else {
        // Show count if more than 2
        btn.innerText = `${checked.length} selected`;
        btn.classList.add('has-selection');
    }
}

// Attach change listeners to multi-select checkboxes
function attachMsListeners(id) {
    const container = document.getElementById(id);
    container.querySelectorAll('.ms-dropdown input[type="checkbox"]').forEach(cb => {
        cb.addEventListener('change', () => updateMsLabel(id));
    });
}

function clearMs(id) {
    document.querySelectorAll(`#${id} .ms-dropdown input`).forEach(cb => cb.checked = false);
    updateMsLabel(id);
}

function switchTab(tabId) {
    document.querySelectorAll('.tab-content').forEach(el => el.classList.remove('active'));
    document.querySelectorAll('.tab-btn').forEach(el => el.classList.remove('active'));
    
    document.getElementById(`tab-${tabId}`).classList.add('active');
    event.target.classList.add('active');

    if(tabId === 'timeline') loadTimeline(timelineState.start, timelineState.end);
    if(tabId === 'logs') resetAndLoadLogs();
}

// --- Timeline Logic Helpers (Unchanged) ---
function syncTimelineInputs() {
    const toLocalISO = (ts) => {
        const date = new Date(ts);
        const offsetMs = date.getTimezoneOffset() * 60 * 1000;
        const localDate = new Date(date.getTime() - offsetMs);
        return localDate.toISOString().slice(0, 16);
    };
    // Sync all datetime inputs (top and bottom toolbars)
    document.querySelectorAll('.ts-start').forEach(el => el.value = toLocalISO(timelineState.start));
    document.querySelectorAll('.ts-end').forEach(el => el.value = toLocalISO(timelineState.end));
}

function setWindow(hours) {
    const now = new Date().getTime();
    timelineState.end = now;
    timelineState.start = now - (hours * 60 * 60 * 1000);
    syncTimelineInputs();
    loadTimeline(timelineState.start, timelineState.end);
}

function moveTime(direction) {
    const duration = timelineState.end - timelineState.start;
    const shift = duration * direction; 
    timelineState.start += shift;
    timelineState.end += shift;
    syncTimelineInputs();
    loadTimeline(timelineState.start, timelineState.end);
}

function applyCustomRange() {
    // Get value from any of the datetime inputs (they should be synced)
    const startInputs = document.querySelectorAll('.ts-start');
    const endInputs = document.querySelectorAll('.ts-end');
    const startVal = startInputs[0]?.value;
    const endVal = endInputs[0]?.value;
    if (startVal && endVal) {
        timelineState.start = new Date(startVal).getTime();
        timelineState.end = new Date(endVal).getTime();
        syncTimelineInputs(); // Sync all inputs
        loadTimeline(timelineState.start, timelineState.end);
    }
}

// --- API Functions ---
async function loadOverview() {
    // This function is deprecated - timeline tab now handles stats
    // Keeping for backwards compatibility but doing nothing
    try {
        document.getElementById('last-updated').innerText = new Date().toLocaleTimeString('en-US');
    } catch (e) { /* Element may not exist */ }
}

async function loadTimelineStats(minTs, maxTs) {
    try {
        const res = await fetch(`/api/timeline_stats?start=${minTs/1000}&end=${maxTs/1000}`);
        const m = await res.json();

        document.getElementById('tl-health').innerText = `${m.success_rate}%`;
        document.getElementById('tl-health').style.color = m.success_rate > 95 ? 'var(--success)' : 'var(--danger)';
        document.getElementById('tl-total').innerText = `${m.success} success / ${m.failed} failed`;
        document.getElementById('tl-storage').innerText = m.storage;
        document.getElementById('tl-process-record').innerText = `${m.avg_process_record}s`;
        document.getElementById('tl-process-timelapse').innerText = `${m.avg_process_timelapse}s`;
        document.getElementById('last-updated').innerText = new Date().toLocaleTimeString('en-US');
        
        const statusEl = document.getElementById('tl-status');
        if (m.total === 0) {
            statusEl.innerText = 'No Data';
            statusEl.style.color = 'var(--text-sub)';
            document.getElementById('tl-status-sub').innerText = '';
        } else if (m.success_rate > 95) {
            statusEl.innerText = 'Stable';
            statusEl.style.color = 'var(--success)';
            document.getElementById('tl-status-sub').innerText = `${m.total} events`;
        } else {
            statusEl.innerText = 'Needs Review';
            statusEl.style.color = 'var(--danger)';
            document.getElementById('tl-status-sub').innerText = `${m.total} events`;
        }

        // Render charts for timeline tab
        renderTimelineStackedBar(m.charts.daily);
        renderTimelineDonut(m.charts.reasons);
        
        // Render storage chart with same time axis
        if (m.charts.storage && m.charts.time_labels) {
            renderStorageChart(m.charts.time_labels, m.charts.storage);
        }
        
        // Load trend comparison data
        loadTrendComparison(minTs, maxTs);
    } catch (e) { console.error("Load Timeline Stats Error", e); }
}

async function loadTrendComparison(minTs, maxTs) {
    try {
        const res = await fetch(`/api/trend_comparison?start=${minTs/1000}&end=${maxTs/1000}`);
        const data = await res.json();
        
        if (data.error) {
            console.warn('Trend comparison error:', data.error);
            return;
        }

        // Helper function to update a trend element
        const updateTrend = (elementId, value, isPercentDiff = false, invertColor = false) => {
            const el = document.getElementById(elementId);
            if (!el) return;
            
            const arrow = el.querySelector('.trend-arrow');
            const valueEl = el.querySelector('.trend-value');
            
            // Determine trend direction
            let trendClass = 'neutral';
            let arrowSymbol = '-';
            let displayValue = '0%';
            
            if (value > 0) {
                trendClass = invertColor ? 'negative' : 'positive';
                arrowSymbol = '↑';
                displayValue = `+${value}%`;
            } else if (value < 0) {
                trendClass = invertColor ? 'positive' : 'negative';
                arrowSymbol = '↓';
                displayValue = `${value}%`;
            }
            
            // For success rate diff, show as percentage points difference
            if (isPercentDiff) {
                displayValue = value > 0 ? `+${value}` : `${value}`;
            }
            
            el.className = `metric-trend ${trendClass}`;
            arrow.textContent = arrowSymbol;
            valueEl.textContent = displayValue;
        };

        // Update each trend indicator
        // Success rate: higher is better
        updateTrend('tl-health-trend', data.changes.success_rate_diff, true, false);
        
        // Storage: more storage used means more recordings (usually positive)
        updateTrend('tl-storage-trend', data.changes.storage_pct, false, false);
        
        // Process time: lower is better, so invert color (negative change = green)
        updateTrend('tl-process-record-trend', data.changes.process_record_pct, false, true);
        updateTrend('tl-process-timelapse-trend', data.changes.process_timelapse_pct, false, true);
        
        // Total events: more events usually means more activity (positive)
        updateTrend('tl-total-trend', data.changes.total_pct, false, false);
        
    } catch (e) { 
        console.error("Load Trend Comparison Error", e); 
    }
}

async function loadProcessingEfficiency(minTs, maxTs) {
    try {
        const res = await fetch(`/api/processing_efficiency?start=${minTs / 1000}&end=${maxTs / 1000}`);
        const data = await res.json();

        const ratioRecordEl = document.getElementById('tl-ratio-record');
        const ratioTimelapseEl = document.getElementById('tl-ratio-timelapse');
        const ratioSubEl = document.getElementById('tl-ratio-sub');
        const ratioRecordTrendEl = document.getElementById('tl-ratio-record-trend');
        const ratioTimelapseTrendEl = document.getElementById('tl-ratio-timelapse-trend');
        
        if (!ratioRecordEl) return;

        // Helper to update ratio trend
        const updateRatioTrend = (trendEl, pctChange) => {
            if (!trendEl) return;
            const arrowEl = trendEl.querySelector('.trend-arrow');
            const valueEl = trendEl.querySelector('.trend-value');
            
            if (pctChange === null || pctChange === undefined) {
                trendEl.className = 'metric-trend neutral';
                arrowEl.textContent = '-';
                valueEl.textContent = 'N/A';
            } else {
                const absChange = Math.abs(pctChange);
                // Lower ratio is better, so negative change is positive (green)
                if (pctChange > 0) {
                    arrowEl.textContent = '↑';
                    trendEl.className = 'metric-trend negative'; // Higher is worse
                } else if (pctChange < 0) {
                    arrowEl.textContent = '↓';
                    trendEl.className = 'metric-trend positive'; // Lower is better
                } else {
                    arrowEl.textContent = '-';
                    trendEl.className = 'metric-trend neutral';
                }
                valueEl.textContent = `${absChange.toFixed(1)}%`;
            }
        };

        if (data.error || (data.record_ratio === null && data.timelapse_ratio === null)) {
            ratioRecordEl.innerText = '-';
            ratioTimelapseEl.innerText = '-';
            if (ratioSubEl) ratioSubEl.innerText = 'No data';
            updateRatioTrend(ratioRecordTrendEl, null);
            updateRatioTrend(ratioTimelapseTrendEl, null);
            return;
        }

        // Display Record ratio
        const recordRatio = data.record_ratio;
        if (recordRatio !== null) {
            ratioRecordEl.innerText = `${recordRatio.toFixed(3)}x`;
            if (recordRatio > data.threshold_warning) {
                ratioRecordEl.style.color = 'var(--danger)';
            } else if (recordRatio < 0.1) {
                ratioRecordEl.style.color = 'var(--success)';
            } else {
                ratioRecordEl.style.color = 'var(--text)';
            }
        } else {
            ratioRecordEl.innerText = '-';
            ratioRecordEl.style.color = 'var(--text-sub)';
        }

        // Display Timelapse ratio
        const timelapseRatio = data.timelapse_ratio;
        if (timelapseRatio !== null) {
            ratioTimelapseEl.innerText = `${timelapseRatio.toFixed(3)}x`;
            if (timelapseRatio > data.threshold_warning) {
                ratioTimelapseEl.style.color = 'var(--danger)';
            } else if (timelapseRatio < 0.1) {
                ratioTimelapseEl.style.color = 'var(--success)';
            } else {
                ratioTimelapseEl.style.color = 'var(--text)';
            }
        } else {
            ratioTimelapseEl.innerText = '-';
            ratioTimelapseEl.style.color = 'var(--text-sub)';
        }

        // Show counts in sub text
        if (ratioSubEl) {
            let subParts = [];
            if (data.record_count > 0) subParts.push(`${data.record_count} records`);
            if (data.timelapse_count > 0) subParts.push(`${data.timelapse_count} timelapses`);
            ratioSubEl.innerText = subParts.join(' | ') || 'No data';
        }

        // Update trend indicators
        updateRatioTrend(ratioRecordTrendEl, data.ratio_pct_change);
        updateRatioTrend(ratioTimelapseTrendEl, data.timelapse_ratio_pct_change);

    } catch (e) {
        console.error('Load Processing Efficiency Error', e);
    }
}

function renderStorageChart(labels, storage) {
    const options = {
        series: [
            { name: 'Record (MB)', data: storage.record || [] },
            { name: 'Timelapse (MB)', data: storage.timelapse || [] }
        ],
        chart: { 
            height: 300, 
            type: 'bar', 
            stacked: true,
            animations: { enabled: false },
            toolbar: { show: true },
            id: 'storageChart',
            group: 'timeSync'
        },
        plotOptions: {
            bar: { horizontal: false, columnWidth: '70%' }
        },
        xaxis: { 
            categories: labels,
            labels: { rotate: -45, rotateAlways: labels.length > 15 }
        },
        yaxis: { title: { text: 'Size (MB)' } },
        colors: ['#2563eb', '#10b981'],
        dataLabels: { enabled: false },
        legend: { position: 'top' },
        tooltip: {
            y: { formatter: (val) => val.toFixed(2) + ' MB' }
        }
    };
    
    if(charts.storeBar) charts.storeBar.destroy();
    charts.storeBar = new ApexCharts(document.querySelector("#chart-storage-bar"), options);
    charts.storeBar.render();
}

function renderTimelineStackedBar(data) {
    const categories = data.map(d => d.label); // Use 'label' instead of 'date'
    const successData = data.map(d => d.success);
    const failedData = data.map(d => d.failed);

    const options = {
        series: [
            { name: 'Success', data: successData },
            { name: 'Failed', data: failedData }
        ],
        chart: { 
            type: 'area', 
            height: 300, 
            toolbar: { show: false },
            zoom: { enabled: false },
            id: 'dailyChart',
            group: 'timeSync'
        },
        colors: ['#10b981', '#ef4444'],
        stroke: { curve: 'smooth', width: 2 },
        fill: { 
            type: 'gradient',
            gradient: { shadeIntensity: 1, opacityFrom: 0.4, opacityTo: 0.1 }
        },
        dataLabels: { enabled: false },
        xaxis: { categories: categories },
        yaxis: { title: { text: 'Events' } },
        legend: { position: 'top' },
        tooltip: {
            shared: true,
            intersect: false,
            y: { formatter: (val) => val + ' events' }
        }
    };

    if(charts.tlDaily) charts.tlDaily.destroy();
    charts.tlDaily = new ApexCharts(document.querySelector('#tl-chart-daily'), options);
    charts.tlDaily.render();
}

function renderTimelineDonut(data) {
    // Render error breakdown table
    renderErrorBreakdownTable(data);
}

async function loadTimeline(minTs, maxTs) {
    // Load timeline chart, stats, and performance in parallel
    loadTimelineStats(minTs, maxTs);
    loadPerformance(minTs, maxTs);
    loadCameraPerformance(minTs, maxTs);
    loadDurationDistribution(minTs, maxTs);
    loadPeakActivity(minTs, maxTs);
    loadTypeComparison(minTs, maxTs);
    loadProcessingEfficiency(minTs, maxTs);
    
    let url = `/api/timeline?start=${minTs/1000}&end=${maxTs/1000}`;
    const res = await fetch(url);
    const json = await res.json();
    
    const series = Object.keys(json.data).map(cam => ({
        name: cam,
        data: json.data[cam].map(item => ({
            x: cam,
            y: [item[0], item[1]], 
            fillColor: item[2] === 1 ? '#10b981' : '#ef4444',
            meta: item[3],
            statusStr: item[2] === 1 ? 'Success' : 'Failed'
        }))
    }));

    if (charts.timeline) {
        charts.timeline.updateOptions({ xaxis: { min: minTs, max: maxTs } }, false, false);
        charts.timeline.updateSeries(series);
        return;
    }

    const options = {
        series: series,
        chart: { 
            height: 500, type: 'rangeBar', toolbar: { show: true },
            background: '#e5e7eb', animations: { enabled: false }, zoom: { enabled: true },
            events: {
                dataPointSelection: function(event, chartContext, config) {
                    const dp = config.w.config.series[config.seriesIndex].data[config.dataPointIndex];
                    if (dp.meta) {
                        showModal({
                            id: 'Merged',
                            camera: dp.x,
                            time: new Date(dp.y[0]).toLocaleString('en-US'),
                            isMerged: true,
                            meta: dp.meta
                        });
                    }
                },
                zoomed: function(chartContext, { xaxis }) {
                    timelineState.start = xaxis.min; timelineState.end = xaxis.max;
                    syncTimelineInputs(); debounceTimelineUpdate(xaxis.min, xaxis.max);
                },
                scrolled: function(chartContext, { xaxis }) {
                    timelineState.start = xaxis.min; timelineState.end = xaxis.max;
                    syncTimelineInputs(); debounceTimelineUpdate(xaxis.min, xaxis.max);
                }
            }
        },
        plotOptions: { bar: { horizontal: true, barHeight: '70%', rangeBarGroupRows: true, borderRadius: 0, dataLabels: { enabled: false } } },
        xaxis: { type: 'datetime', min: minTs, max: maxTs },
        tooltip: { 
            custom: function({series, seriesIndex, dataPointIndex, w}) {
                const data = w.config.series[seriesIndex].data[dataPointIndex];
                const start = new Date(data.y[0]).toLocaleString('en-US');
                const end = new Date(data.y[1]).toLocaleString('en-US');
                const color = data.fillColor;
                const status = data.statusStr;
                const countInfo = data.meta ? `(${data.meta.count} events)` : '';
                return `
                    <div class="apexcharts-tooltip-custom" style="padding: 10px; font-size: 12px; line-height: 1.6;">
                        <div style="font-weight: 700; margin-bottom: 4px; border-bottom: 1px solid #eee; padding-bottom: 4px;">${data.x}</div>
                        <div><span style="color:#666">Start:</span> ${start}</div>
                        <div><span style="color:#666">End:</span> ${end}</div>
                        <div style="margin-top:4px;">
                            <span style="color:#666">Status:</span> 
                            <span style="color: ${color}; font-weight: 700;">${status}</span>
                            <span style="font-size:11px; color:#888; margin-left:5px;">${countInfo}</span>
                        </div>
                    </div>
                `;
            }
        },
        grid: { row: { colors: ['transparent'], opacity: 0 }, borderColor: '#ffffff' }
    };

    if(charts.timeline) { charts.timeline.destroy(); charts.timeline = null; }
    charts.timeline = new ApexCharts(document.querySelector("#chart-timeline"), options);
    charts.timeline.render();
}

function debounceTimelineUpdate(min, max) {
    clearTimeout(timelineDebounce);
    timelineDebounce = setTimeout(() => { loadTimeline(min, max); }, 500);
}

function resetAndLoadLogs() {
    currentPage = 1;
    loadLogs(1);
}

function clearFilters() {
    // Clear standard inputs
    document.querySelectorAll('.controls-container input[type="text"], .controls-container input[type="number"], .controls-container input[type="datetime-local"]').forEach(el => el.value = '');
    document.querySelectorAll('.controls-container select').forEach(el => el.selectedIndex = 0);
    
    // Clear Multi-selects
    clearMs('ms-status');
    clearMs('ms-camera');
    clearMs('ms-type');
    clearMs('ms-error');
    clearMs('ms-alert');

    resetAndLoadLogs();
}

function changePage(delta) {
    const totalPages = Math.ceil(totalRecords / itemsPerPage) || 1;
    const newPage = currentPage + delta;
    if (newPage > 0 && newPage <= totalPages) { 
        loadLogs(newPage); 
    }
}

// Navigate to specific page number
function gotoPage(page) {
    const totalPages = Math.ceil(totalRecords / itemsPerPage) || 1;
    const targetPage = parseInt(page, 10);
    if (!isNaN(targetPage) && targetPage >= 1 && targetPage <= totalPages) {
        loadLogs(targetPage);
    }
}

// Handle goto input keypress (Enter to submit)
function handleGotoKeypress(event) {
    if (event.key === 'Enter') {
        const input = event.target;
        gotoPage(input.value);
        input.value = '';
    }
}

// Update items per page and reload from first page
function changeItemsPerPage(value) {
    const newValue = parseInt(value, 10);
    if (!isNaN(newValue) && newValue > 0) {
        itemsPerPage = newValue;
        currentPage = 1;
        loadLogs(1);
    }
}

async function loadLogs(page) {
    currentPage = page;
    const offset = (page - 1) * itemsPerPage;
    
    // Collect Multi-select values
    const statuses = getMsValues('ms-status');
    const cams = getMsValues('ms-camera');
    const types = getMsValues('ms-type');
    const errors = getMsValues('ms-error');
    const alertSent = getMsValues('ms-alert');

    // Collect Other Filters
    const search = document.getElementById('f-search').value;
    const idSearch = document.getElementById('f-id-search').value;
    
    const createdFrom = document.getElementById('f-created-from').value;
    const createdTo = document.getElementById('f-created-to').value;
    const videoFrom = document.getElementById('f-video-from').value;
    const videoTo = document.getElementById('f-video-to').value;
    
    const durMin = document.getElementById('f-dur-min').value;
    const durMax = document.getElementById('f-dur-max').value;
    const sizeMin = document.getElementById('f-size-min').value;
    const sizeMax = document.getElementById('f-size-max').value;
    const procMin = document.getElementById('f-proc-min').value;
    const procMax = document.getElementById('f-proc-max').value;

    const tbody = document.querySelector('#log-table tbody');
    tbody.innerHTML = '<tr><td colspan="14" class="loading-row">Loading page ' + page + '...</td></tr>';

    try {
        const params = new URLSearchParams();
        
        // Helper to add array params
        const addArrayParam = (key, val) => {
            if (Array.isArray(val)) val.forEach(v => params.append(key, v));
            else params.append(key, val);
        };

        addArrayParam('status', statuses);
        addArrayParam('camera', cams);
        addArrayParam('type', types);
        addArrayParam('error', errors);
        addArrayParam('alert_sent', alertSent);

        params.append('search', search);
        params.append('id_search', idSearch);
        params.append('limit', itemsPerPage);
        params.append('offset', offset);
        
        if(createdFrom) params.append('created_from', createdFrom);
        if(createdTo) params.append('created_to', createdTo);
        if(videoFrom) params.append('video_from', videoFrom);
        if(videoTo) params.append('video_to', videoTo);
        if(durMin) params.append('dur_min', durMin);
        if(durMax) params.append('dur_max', durMax);
        if(sizeMin) params.append('size_min', sizeMin);
        if(sizeMax) params.append('size_max', sizeMax);
        if(procMin) params.append('process_min', procMin);
        if(procMax) params.append('process_max', procMax);

        const res = await fetch(`/api/logs?${params.toString()}`);
        const json = await res.json();
        
        totalRecords = json.total; 
        
        tbody.innerHTML = '';
        if(json.data.length === 0) {
            tbody.innerHTML = '<tr><td colspan="14" class="loading-row">No data found</td></tr>';
            renderPagination(0);
            return;
        }

        json.data.forEach(row => {
            const tr = document.createElement('tr');
            // Truncate message for display
            const msgPreview = row.message ? (row.message.length > 50 ? row.message.substring(0, 50) + '...' : row.message) : '-';
            tr.innerHTML = `
                <td><code>${row.id}</code></td>
                <td>${row.time}</td>
                <td><strong>${row.camera}</strong></td>
                <td>${row.type}</td>
                <td><span class="badge ${row.status.toLowerCase()}">${row.status}</span></td>
                <td>${row.video_start}</td>
                <td>${row.video_end}</td>
                <td>${row.duration}</td>
                <td>${row.size}</td>
                <td>${row.process_sec}</td>
                <td style="color:var(--danger)">${row.error_type}</td>
                <td>${row.msg_id}</td>
                <td>${row.alert_sent}</td>
                <td title="${row.message || ''}" style="max-width:200px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${msgPreview}</td>
            `;
            tr.onclick = () => showModal(row);
            tbody.appendChild(tr);
        });

        renderPagination(totalRecords);
    } catch (e) {
        console.error(e);
        tbody.innerHTML = '<tr><td colspan="14" class="loading-row">Server connection error</td></tr>';
    }
}

function renderPagination(total) {
    const totalPages = Math.ceil(total / itemsPerPage) || 1;
    
    // Calculate display range
    const startItem = total === 0 ? 0 : (currentPage - 1) * itemsPerPage + 1;
    const endItem = Math.min(currentPage * itemsPerPage, total);
    
    // Update both pagination containers (top and bottom)
    document.querySelectorAll('.pagination-container').forEach(container => {
        const btnPrev = container.querySelector('.btn-prev');
        const btnNext = container.querySelector('.btn-next');
        const pageRange = container.querySelector('.page-range');
        const pageInfo = container.querySelector('.page-info');
        const pageNumbers = container.querySelector('.page-numbers');
        const perPageSelect = container.querySelector('.per-page-select');

        if (btnPrev) btnPrev.disabled = currentPage === 1;
        if (btnNext) btnNext.disabled = currentPage >= totalPages;
        if (pageRange) pageRange.innerText = `Showing ${startItem}-${endItem}`;
        if (pageInfo) pageInfo.innerText = `of ${total.toLocaleString()} events`;
        if (perPageSelect) perPageSelect.value = itemsPerPage;

        // Render page number buttons
        if (pageNumbers) {
            pageNumbers.innerHTML = generatePageNumbers(currentPage, totalPages);
        }
    });
}

// Generate page number buttons with ellipsis for large page counts
function generatePageNumbers(current, total) {
    const pages = [];
    const maxVisible = 5;
    
    if (total <= maxVisible + 2) {
        // Show all pages if total is small
        for (let i = 1; i <= total; i++) {
            pages.push(i);
        }
    } else {
        // Always show first page
        pages.push(1);
        
        // Calculate range around current page
        let start = Math.max(2, current - 1);
        let end = Math.min(total - 1, current + 1);
        
        // Adjust range to show more pages
        if (current <= 3) {
            end = Math.min(total - 1, maxVisible - 1);
        } else if (current >= total - 2) {
            start = Math.max(2, total - maxVisible + 2);
        }
        
        // Add ellipsis before range if needed
        if (start > 2) pages.push('...');
        
        // Add range pages
        for (let i = start; i <= end; i++) {
            pages.push(i);
        }
        
        // Add ellipsis after range if needed
        if (end < total - 1) pages.push('...');
        
        // Always show last page
        if (total > 1) pages.push(total);
    }
    
    return pages.map(p => {
        if (p === '...') {
            return '<span class="page-ellipsis">...</span>';
        }
        const activeClass = p === current ? 'active' : '';
        return `<button class="page-num ${activeClass}" onclick="gotoPage(${p})">${p}</button>`;
    }).join('');
}

async function loadPerformance(minTs, maxTs) {
    try {
        let url = '/api/performance';
        if (minTs && maxTs) {
            url += `?start=${minTs/1000}&end=${maxTs/1000}`;
        }
        const res = await fetch(url);
        const data = await res.json();
        
        // Validate data structure
        if (!data || !data.performance || !data.storage) {
            console.warn('Invalid performance data received');
            return;
        }
    
    // Render performance comparison table
    const perfCategories = data.performance.categories || [];
    const perfCount = data.performance.count || [];
    const successRates = data.performance.success_rate || [];
    const storageMb = data.performance.storage_mb || [];
    const avgDuration = data.performance.avg_duration || [];
    const avgProcess = data.performance.avg_process || [];
    
    renderPerformanceTable(perfCategories, perfCount, successRates, avgDuration, avgProcess, storageMb);

    } catch (e) { console.error("Load Performance Error", e); }
}

async function loadDurationDistribution(minTs, maxTs) {
    try {
        const res = await fetch(`/api/duration_distribution?start=${minTs / 1000}&end=${maxTs / 1000}`);
        const data = await res.json();

        // Render duration distribution tables for Record and Timelapse
        renderDurationTable('table-duration-record', data.record, 'Record');
        renderDurationTable('table-duration-timelapse', data.timelapse, 'Timelapse');

    } catch (e) {
        console.error('Load Duration Distribution Error', e);
    }
}

// Type comparison is now merged with performance chart - this function is deprecated
// but kept for backwards compatibility
async function loadTypeComparison(minTs, maxTs) {
    // Merged into loadPerformance
}

async function loadPeakActivity(minTs, maxTs) {
    try {
        const res = await fetch(`/api/peak_activity?start=${minTs / 1000}&end=${maxTs / 1000}`);
        const data = await res.json();

        const container = document.querySelector('#chart-peak-heatmap');
        if (!container) return;

        // Validate data
        if (!data.data || data.data.length === 0) {
            container.innerHTML = '<div style="text-align:center;color:var(--text-sub);padding:50px;">No data for this time period</div>';
            return;
        }

        // Reset container if showing "no data" message
        if (container.innerHTML.includes('No data')) {
            container.innerHTML = '';
        }

        // Calculate dynamic thresholds based on FAILED counts (errors)
        const allFailedCounts = data.data.map(d => d.failed || 0).filter(v => v > 0);
        
        // Calculate percentiles for dynamic ranges
        const getPercentile = (arr, p) => {
            if (arr.length === 0) return 0;
            const sorted = [...arr].sort((a, b) => a - b);
            const idx = Math.ceil(p * sorted.length) - 1;
            return sorted[Math.max(0, idx)];
        };
        
        const maxFailed = Math.max(...allFailedCounts, 1);
        const p25 = Math.max(1, getPercentile(allFailedCounts, 0.25));
        const p50 = Math.max(p25 + 1, getPercentile(allFailedCounts, 0.50));
        const p75 = Math.max(p50 + 1, getPercentile(allFailedCounts, 0.75));

        let series = [];
        let categories = [];

        if (data.granularity === 'hour') {
            // Stacked bar for hours: success + failed
            categories = data.hour_labels;
            const successData = new Array(24).fill(0);
            const failedData = new Array(24).fill(0);
            data.data.forEach(d => { 
                successData[d.hour] = d.success || 0;
                failedData[d.hour] = d.failed || 0;
            });
            series = [
                { name: 'Success', data: successData },
                { name: 'Failed', data: failedData }
            ];
        } else {
            // Heatmap: days x hours - use FAILED for red intensity (error distribution)
            // X-axis: hours (hidden labels), Y-axis: days
            categories = data.hour_labels;
            // Build matrix: each day is a series with 24 hours
            // Y value is failed count for color intensity
            series = data.day_labels.map((dayLabel, dayIndex) => {
                const hourData = new Array(24).fill(null).map((_, hourIndex) => {
                    const found = data.data.find(d => d.day === dayIndex && d.hour === hourIndex);
                    return { 
                        x: hourIndex,
                        y: found ? (found.failed || 0) : 0, // Use failed for heatmap color
                        success: found ? (found.success || 0) : 0,
                        total: found ? (found.count || 0) : 0,
                        hourLabel: data.hour_labels[hourIndex]
                    };
                });
                return { name: dayLabel, data: hourData };
            });
        }

        const isHeatmap = data.granularity === 'day_hour';
        const options = {
            series: series,
            chart: {
                type: isHeatmap ? 'heatmap' : 'bar',
                height: isHeatmap ? 280 : 280,
                stacked: !isHeatmap,
                toolbar: { show: false },
                animations: { enabled: false }
            },
            dataLabels: { enabled: !isHeatmap },
            colors: isHeatmap ? ['#ef4444'] : ['#10b981', '#ef4444'],
            plotOptions: isHeatmap ? {
                heatmap: {
                    shadeIntensity: 0.5,
                    colorScale: {
                        ranges: [
                            { from: 0, to: 0, color: '#d1fae5', name: 'No Errors' },
                            { from: 1, to: p25, color: '#fecaca', name: `Low (1-${p25})` },
                            { from: p25 + 1, to: p50, color: '#f87171', name: `Medium (${p25+1}-${p50})` },
                            { from: p50 + 1, to: p75, color: '#ef4444', name: `High (${p50+1}-${p75})` },
                            { from: p75 + 1, to: maxFailed + 1000, color: '#b91c1c', name: `Critical (${p75+1}+)` }
                        ]
                    }
                }
            } : {
                bar: { horizontal: false, columnWidth: '70%', borderRadius: 4 }
            },
            xaxis: isHeatmap ? { 
                labels: { show: false },
                axisBorder: { show: false },
                axisTicks: { show: false },
                tooltip: { enabled: false }
            } : { categories: categories },
            yaxis: { 
                title: { text: isHeatmap ? '' : 'Count' },
                labels: isHeatmap ? { 
                    style: { fontSize: '12px', fontWeight: 500 }
                } : {}
            },
            legend: { show: true, position: 'top' },
            tooltip: isHeatmap ? {
                custom: function({ series, seriesIndex, dataPointIndex, w }) {
                    const dayLabel = w.config.series[seriesIndex].name;
                    const dataPoint = w.config.series[seriesIndex].data[dataPointIndex];
                    const hourLabel = dataPoint.hourLabel || `${dataPointIndex}:00`;
                    const failed = dataPoint.y || 0;
                    const success = dataPoint.success || 0;
                    const total = success + failed;
                    
                    return `<div style="padding: 10px; font-size: 12px; line-height: 1.6;">
                        <div style="font-weight: 700; margin-bottom: 4px;">${dayLabel}, ${hourLabel}</div>
                        <div><span style="color:#ef4444">●</span> Failed: ${failed}</div>
                        <div><span style="color:#10b981">●</span> Success: ${success}</div>
                        <div style="margin-top:4px;border-top:1px solid #eee;padding-top:4px;">Total: ${total} events</div>
                    </div>`;
                }
            } : {
                y: { formatter: (val) => val + ' events' }
            }
        };

        if (charts.peakHeatmap) {
            charts.peakHeatmap.destroy();
        }
        charts.peakHeatmap = new ApexCharts(container, options);
        charts.peakHeatmap.render();
    } catch (e) {
        console.error('Load Peak Activity Error', e);
    }
}

async function loadCameraPerformance(startTs, endTs) {
    try {
        const res = await fetch(`/api/camera_performance?start=${startTs / 1000}&end=${endTs / 1000}`);
        const data = await res.json();

        // Validate data
        if (!data.cameras || data.cameras.length === 0) {
            const container = document.querySelector('#chart-camera-perf');
            if (container) {
                container.innerHTML = '<div style="text-align:center;color:var(--text-sub);padding:50px;">No camera data in selected time range</div>';
            }
            return;
        }

        const categories = data.cameras.map(c => c.name);
        const successCounts = data.cameras.map(c => c.success);
        const failedCounts = data.cameras.map(c => c.failed);

        // Dynamic height based on number of cameras (min 280, 45px per camera for horizontal bars)
        const chartHeight = Math.max(280, data.cameras.length * 45);

        const options = {
            chart: {
                type: 'bar',
                height: chartHeight,
                stacked: true,
                toolbar: { show: false },
                animations: { enabled: false }
            },
            series: [
                {
                    name: 'Success',
                    data: successCounts,
                    color: '#10b981'
                },
                {
                    name: 'Failed',
                    data: failedCounts,
                    color: '#ef4444'
                }
            ],
            plotOptions: {
                bar: {
                    horizontal: true,
                    barHeight: '65%',
                    borderRadius: 4
                }
            },
            xaxis: {
                categories: categories,
                title: { text: 'Events' }
            },
            yaxis: {
                labels: {
                    style: { fontSize: '12px' },
                    maxWidth: 150
                }
            },
            legend: { position: 'top' },
            dataLabels: { enabled: false },
            tooltip: {
                y: {
                    formatter: (val, opts) => {
                        const camera = data.cameras[opts.dataPointIndex];
                        return `${val} events`;
                    }
                },
                custom: function({ series, seriesIndex, dataPointIndex, w }) {
                    const camera = data.cameras[dataPointIndex];
                    return `
                        <div style="padding: 10px; font-size: 12px; line-height: 1.6;">
                            <div style="font-weight: 700; margin-bottom: 4px;">${camera.name}</div>
                            <div>Success: ${camera.success} | Failed: ${camera.failed}</div>
                            <div>Success Rate: ${camera.success_rate}%</div>
                            <div>Storage: ${camera.storage_mb} MB</div>
                            <div>Avg Process: ${camera.avg_process}s</div>
                        </div>
                    `;
                }
            }
        };

        // Clear "no data" message if it was showing
        const container = document.querySelector('#chart-camera-perf');
        if (container && container.innerHTML.includes('No camera data')) {
            container.innerHTML = '';
        }

        if (charts.cameraPerf) {
            charts.cameraPerf.updateOptions(options);
        } else {
            charts.cameraPerf = new ApexCharts(document.querySelector('#chart-camera-perf'), options);
            charts.cameraPerf.render();
        }
    } catch (e) {
        console.error('Error loading camera performance data', e);
    }
}

// --- Helpers ---
async function loadFilters() {
    const res = await fetch('/api/filters');
    const data = await res.json();
    
    const fillMs = (id, items) => {
        const container = document.getElementById(id);
        container.innerHTML = '';
        items.forEach(item => {
            const div = document.createElement('div');
            div.className = 'ms-option';
            div.innerHTML = `<input type="checkbox" value="${item}" id="${id}_${item}"><label for="${id}_${item}">${item}</label>`;
            container.appendChild(div);
        });
    };

    fillMs('ms-camera-list', data.cameras);
    fillMs('ms-type-list', data.types);
    fillMs('ms-error-list', data.errors);
    
    // Attach change listeners for dynamically loaded multi-selects
    attachMsListeners('ms-camera');
    attachMsListeners('ms-type');
    attachMsListeners('ms-error');
    
    // Attach change listeners for static multi-selects
    attachMsListeners('ms-status');
    attachMsListeners('ms-alert');
}

function showModal(data) {
    // Updated Header to match Event ID
    document.getElementById('modal-title').innerText = data.isMerged ? `Merged Events` : `Event #${data.id}`;
    const modalBody = document.getElementById('modal-content');
    
    let contentHtml = "";

    if (data.isMerged) {
        let errorList = "";
        for (const [type, count] of Object.entries(data.meta.breakdown)) {
            errorList += `- ${type}: ${count} times\n`;
        }
        contentHtml = `<div class="raw-message-box">ERROR OVERVIEW (${data.meta.count} events):\n` + 
                      `--------------------------------------------------\n` +
                      `${errorList}\n\n` +
                      `FIRST ERROR SAMPLE:\n${data.meta.sample_msg}</div>`;
    } else {
        contentHtml = `
            <div class="meta-grid">
                <div class="meta-item">
                    <span class="meta-label">ID</span>
                    <span class="meta-value">#${data.id}</span>
                </div>
                <div class="meta-item">
                    <span class="meta-label">Status</span>
                    <span class="meta-value" style="color: ${data.status === 'SUCCESS' ? 'var(--success)' : 'var(--danger)'}">${data.status}</span>
                </div>
                <div class="meta-item">
                    <span class="meta-label">Type</span>
                    <span class="meta-value">${data.type}</span>
                </div>
                <div class="meta-item">
                    <span class="meta-label">Fail Type</span>
                    <span class="meta-value" style="color: var(--danger)">${data.error_type}</span>
                </div>
                <div class="meta-item">
                    <span class="meta-label">Video Start</span>
                    <span class="meta-value">${data.video_start}</span>
                </div>
                <div class="meta-item">
                    <span class="meta-label">Video End</span>
                    <span class="meta-value">${data.video_end}</span>
                </div>
                <div class="meta-item">
                    <span class="meta-label">Duration</span>
                    <span class="meta-value">${data.duration}</span>
                </div>
                <div class="meta-item">
                    <span class="meta-label">File Size</span>
                    <span class="meta-value">${data.size}</span>
                </div>
                <div class="meta-item">
                    <span class="meta-label">Processing Time</span>
                    <span class="meta-value">${data.process_sec}</span>
                </div>
                <div class="meta-item">
                    <span class="meta-label">Telegram Msg ID</span>
                    <span class="meta-value">${data.msg_id}</span>
                </div>
                <div class="meta-item">
                    <span class="meta-label">Alert Sent</span>
                    <span class="meta-value">${data.alert_sent}</span>
                </div>
                <div class="meta-item">
                    <span class="meta-label">Created At</span>
                    <span class="meta-value">${data.time}</span>
                </div>
            </div>
            <div style="margin-bottom:5px; font-weight:600; color:#ccc;">Decoded Message Content:</div>
            <div class="raw-message-box">${data.message || "No message content"}</div>
        `;
    }

    modalBody.innerHTML = contentHtml;
    document.getElementById('msg-modal').showModal();
}

function renderStackedBar(data) {
    const options = {
        series: [{ name: 'Success', data: data.map(d => d.success) }, { name: 'Failed', data: data.map(d => d.failed) }],
        chart: { type: 'bar', height: 350, stacked: true, animations: { enabled: false } },
        colors: ['#10b981', '#ef4444'], xaxis: { categories: data.map(d => d.date) }, plotOptions: { bar: { borderRadius: 4, columnWidth: '40%' } }
    };
    if(charts.daily) charts.daily.destroy();
    charts.daily = new ApexCharts(document.querySelector("#chart-daily"), options);
    charts.daily.render();
}

function renderDonut(data) {
    const options = {
        series: data.series, labels: data.labels, chart: { type: 'donut', height: 350, animations: { enabled: false } },
        colors: ['#ef4444', '#f59e0b', '#3b82f6', '#8b5cf6'], plotOptions: { pie: { donut: { size: '65%' } } }
    };
    if(charts.reasons) charts.reasons.destroy();
    charts.reasons = new ApexCharts(document.querySelector("#chart-reasons"), options);
    charts.reasons.render();
}

// --- Table Rendering Functions ---

/**
 * Render performance comparison data into a vertical table
 * Displays metrics as rows with Record and Timelapse as columns
 */
function renderPerformanceTable(categories, counts, successRates, avgDuration, avgProcess, storageMb) {
    const tbody = document.querySelector('#table-perf-comparison tbody');
    if (!tbody) return;
    
    if (!categories || categories.length === 0) {
        tbody.innerHTML = '<tr><td colspan="3" style="text-align:center;color:var(--text-sub);padding:30px;">No data in selected range</td></tr>';
        return;
    }
    
    // Find Record and Timelapse indices
    const recordIdx = categories.indexOf('Record');
    const timelapseIdx = categories.indexOf('Timelapse');
    
    const getValue = (arr, idx) => idx >= 0 ? arr[idx] : null;
    
    const recordRate = getValue(successRates, recordIdx) || 0;
    const timelapseRate = getValue(successRates, timelapseIdx) || 0;
    const recordRateColor = recordRate >= 95 ? 'var(--success)' : recordRate >= 80 ? 'var(--warning)' : 'var(--danger)';
    const timelapseRateColor = timelapseRate >= 95 ? 'var(--success)' : timelapseRate >= 80 ? 'var(--warning)' : 'var(--danger)';
    
    let html = `
        <tr>
            <td><strong>Count</strong></td>
            <td>${getValue(counts, recordIdx) ?? '-'}</td>
            <td>${getValue(counts, timelapseIdx) ?? '-'}</td>
        </tr>
        <tr>
            <td><strong>Success Rate</strong></td>
            <td style="color: ${recordRateColor}; font-weight: 600;">${recordIdx >= 0 ? recordRate + '%' : '-'}</td>
            <td style="color: ${timelapseRateColor}; font-weight: 600;">${timelapseIdx >= 0 ? timelapseRate + '%' : '-'}</td>
        </tr>
        <tr>
            <td><strong>Avg Duration</strong></td>
            <td>${recordIdx >= 0 ? (avgDuration[recordIdx] || 0).toFixed(1) + 's' : '-'}</td>
            <td>${timelapseIdx >= 0 ? (avgDuration[timelapseIdx] || 0).toFixed(1) + 's' : '-'}</td>
        </tr>
        <tr>
            <td><strong>Avg Process</strong></td>
            <td>${recordIdx >= 0 ? (avgProcess[recordIdx] || 0).toFixed(1) + 's' : '-'}</td>
            <td>${timelapseIdx >= 0 ? (avgProcess[timelapseIdx] || 0).toFixed(1) + 's' : '-'}</td>
        </tr>
        <tr>
            <td><strong>Storage</strong></td>
            <td>${recordIdx >= 0 ? (storageMb[recordIdx] || 0).toFixed(2) + ' MB' : '-'}</td>
            <td>${timelapseIdx >= 0 ? (storageMb[timelapseIdx] || 0).toFixed(2) + ' MB' : '-'}</td>
        </tr>
    `;
    tbody.innerHTML = html;
}

/**
 * Render duration distribution data into a table
 * Displays duration range, count, and percentage
 */
function renderDurationTable(tableId, typeData, typeName) {
    const tbody = document.querySelector(`#${tableId} tbody`);
    if (!tbody) return;
    
    if (!typeData || typeData.length === 0) {
        tbody.innerHTML = `<tr><td colspan="3" style="text-align:center;color:var(--text-sub);padding:30px;">No ${typeName.toLowerCase()} data available</td></tr>`;
        return;
    }

    const bucketsWithData = (typeData || []).filter(b => b.total > 0 || b.count > 0);

    if (bucketsWithData.length === 0) {
        tbody.innerHTML = `<tr><td colspan="3" style="text-align:center;color:var(--text-sub);padding:30px;">No ${typeName.toLowerCase()} data in selected range</td></tr>`;
        return;
    }
    
    const totalCount = bucketsWithData.reduce((sum, b) => sum + (b.total || b.count), 0);
    
    let html = '';
    bucketsWithData.forEach(bucket => {
        const range = bucket.range || `${bucket.duration}s`;
        const count = bucket.total || bucket.count;
        const pct = totalCount > 0 ? ((count / totalCount) * 100).toFixed(1) : 0;
        html += `
            <tr>
                <td>${range}</td>
                <td>${count}</td>
                <td>${pct}%</td>
            </tr>
        `;
    });
    
    // Total row
    html += `
        <tr style="font-weight: 600; border-top: 2px solid var(--border);">
            <td>Total</td>
            <td>${totalCount}</td>
            <td>100%</td>
        </tr>
    `;
    
    tbody.innerHTML = html;
}

/**
 * Render error breakdown data into a table
 * Displays error type, count, and percentage sorted by count descending
 */
function renderErrorBreakdownTable(data) {
    const tbody = document.querySelector('#table-error-breakdown tbody');
    if (!tbody) return;
    
    if (!data.labels || data.labels.length === 0) {
        tbody.innerHTML = '<tr><td colspan="3" style="text-align:center;color:var(--text-sub);padding:30px;">No errors in selected range</td></tr>';
        return;
    }
    
    // Combine and sort by value descending
    const combined = data.labels.map((label, i) => ({ label, value: data.series[i] }));
    combined.sort((a, b) => b.value - a.value);
    
    const totalErrors = combined.reduce((sum, item) => sum + item.value, 0);
    
    let html = '';
    combined.forEach(item => {
        const pct = totalErrors > 0 ? ((item.value / totalErrors) * 100).toFixed(1) : 0;
        html += `
            <tr>
                <td style="color: var(--danger);">${item.label}</td>
                <td>${item.value}</td>
                <td>${pct}%</td>
            </tr>
        `;
    });
    
    // Total row
    html += `
        <tr style="font-weight: 600; border-top: 2px solid var(--border);">
            <td>Total</td>
            <td>${totalErrors}</td>
            <td>100%</td>
        </tr>
    `;
    
    tbody.innerHTML = html;
}