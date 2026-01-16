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
    if(tabId === 'perf') loadPerformance();
}

// --- Timeline Logic Helpers (Unchanged) ---
function syncTimelineInputs() {
    const toLocalISO = (ts) => {
        const date = new Date(ts);
        const offsetMs = date.getTimezoneOffset() * 60 * 1000;
        const localDate = new Date(date.getTime() - offsetMs);
        return localDate.toISOString().slice(0, 16);
    };
    document.getElementById('ts-start').value = toLocalISO(timelineState.start);
    document.getElementById('ts-end').value = toLocalISO(timelineState.end);
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
    const startVal = document.getElementById('ts-start').value;
    const endVal = document.getElementById('ts-end').value;
    if (startVal && endVal) {
        timelineState.start = new Date(startVal).getTime();
        timelineState.end = new Date(endVal).getTime();
        loadTimeline(timelineState.start, timelineState.end);
    }
}

// --- API Functions ---
async function loadOverview() {
    try {
        const res = await fetch('/api/overview?days=1');
        const data = await res.json();
        const m = data.metrics;

        document.getElementById('m-health').innerText = `${m.success_rate}%`;
        document.getElementById('m-health').style.color = m.success_rate > 95 ? 'var(--success)' : 'var(--danger)';
        document.getElementById('m-total').innerText = `trên tổng ${m.total} events`;
        document.getElementById('m-storage').innerText = m.storage;
        document.getElementById('m-process').innerText = m.avg_process;
        document.getElementById('last-updated').innerText = new Date().toLocaleTimeString('vi-VN');
        
        const statusEl = document.getElementById('m-status');
        statusEl.innerText = m.success_rate > 95 ? 'Ổn định' : 'Cần kiểm tra';
        statusEl.style.color = m.success_rate > 95 ? 'var(--success)' : 'var(--danger)';

        renderStackedBar(data.charts.daily);
        renderDonut(data.charts.reasons);
    } catch (e) { console.error("Load Overview Error", e); }
}

async function loadTimelineStats(minTs, maxTs) {
    try {
        const res = await fetch(`/api/timeline_stats?start=${minTs/1000}&end=${maxTs/1000}`);
        const m = await res.json();

        document.getElementById('tl-health').innerText = `${m.success_rate}%`;
        document.getElementById('tl-health').style.color = m.success_rate > 95 ? 'var(--success)' : 'var(--danger)';
        document.getElementById('tl-total').innerText = `${m.success} thành công / ${m.failed} thất bại`;
        document.getElementById('tl-storage').innerText = m.storage;
        document.getElementById('tl-process').innerText = `${m.avg_process}s`;
        document.getElementById('last-updated').innerText = new Date().toLocaleTimeString('vi-VN');
        
        const statusEl = document.getElementById('tl-status');
        if (m.total === 0) {
            statusEl.innerText = 'Không có dữ liệu';
            statusEl.style.color = 'var(--text-sub)';
            document.getElementById('tl-status-sub').innerText = '';
        } else if (m.success_rate > 95) {
            statusEl.innerText = 'Ổn định';
            statusEl.style.color = 'var(--success)';
            document.getElementById('tl-status-sub').innerText = `${m.total} events`;
        } else {
            statusEl.innerText = 'Cần kiểm tra';
            statusEl.style.color = 'var(--danger)';
            document.getElementById('tl-status-sub').innerText = `${m.total} events`;
        }

        // Render charts for timeline tab
        renderTimelineStackedBar(m.charts.daily);
        renderTimelineDonut(m.charts.reasons);
    } catch (e) { console.error("Load Timeline Stats Error", e); }
}

function renderTimelineStackedBar(data) {
    const categories = data.map(d => d.date);
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
            zoom: { enabled: false }
        },
        colors: ['#10b981', '#ef4444'],
        stroke: { curve: 'smooth', width: 2 },
        fill: { 
            type: 'gradient',
            gradient: { shadeIntensity: 1, opacityFrom: 0.4, opacityTo: 0.1 }
        },
        xaxis: { categories: categories },
        yaxis: { title: { text: 'Số lượng' } },
        legend: { position: 'top' },
        dataLabels: { enabled: false },
        markers: { size: 4, hover: { size: 6 } },
        tooltip: { shared: true, intersect: false }
    };

    if (charts.tlDaily) {
        charts.tlDaily.updateOptions(options);
    } else {
        charts.tlDaily = new ApexCharts(document.querySelector("#tl-chart-daily"), options);
        charts.tlDaily.render();
    }
}

function renderTimelineDonut(data) {
    if (!data.labels || data.labels.length === 0) {
        if (charts.tlReasons) {
            charts.tlReasons.destroy();
            charts.tlReasons = null;
        }
        document.querySelector("#tl-chart-reasons").innerHTML = '<div style="text-align:center;color:var(--text-sub);padding:50px;">Không có lỗi trong khoảng thời gian này</div>';
        return;
    }

    // Reset container if was showing "no data" message
    const container = document.querySelector("#tl-chart-reasons");
    if (!charts.tlReasons && container.innerHTML.includes('Không có lỗi')) {
        container.innerHTML = '';
    }

    // Sort data by value descending (largest to smallest)
    const combined = data.labels.map((label, i) => ({ label, value: data.series[i] }));
    combined.sort((a, b) => b.value - a.value);
    const sortedLabels = combined.map(d => d.label);
    const sortedSeries = combined.map(d => d.value);

    const options = {
        series: [{ name: 'Errors', data: sortedSeries }],
        chart: { 
            type: 'bar', 
            height: 300, 
            toolbar: { show: false },
            fontFamily: 'inherit'
        },
        plotOptions: { 
            bar: { 
                horizontal: true, 
                borderRadius: 4,
                dataLabels: { position: 'end' }
            } 
        },
        colors: ['#ef4444'],
        xaxis: { 
            categories: sortedLabels,
            title: { text: 'Error Count', style: { fontFamily: 'inherit' } }
        },
        yaxis: {
            labels: { style: { fontFamily: 'inherit' } }
        },
        dataLabels: { 
            enabled: true,
            style: { fontSize: '12px', colors: ['#333'], fontFamily: 'inherit' },
            offsetX: -10
        },
        tooltip: {
            style: { fontFamily: 'inherit' },
            y: { formatter: (val) => `${val} errors` }
        }
    };

    if (charts.tlReasons) {
        charts.tlReasons.updateOptions(options);
    } else {
        charts.tlReasons = new ApexCharts(container, options);
        charts.tlReasons.render();
    }
}

async function loadTimeline(minTs, maxTs) {
    // Load both timeline chart and stats in parallel
    loadTimelineStats(minTs, maxTs);
    
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
                            time: new Date(dp.y[0]).toLocaleString('vi-VN'),
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
                const start = new Date(data.y[0]).toLocaleString('vi-VN');
                const end = new Date(data.y[1]).toLocaleString('vi-VN');
                const color = data.fillColor;
                const status = data.statusStr;
                const countInfo = data.meta ? `(${data.meta.count} events)` : '';
                return `
                    <div class="apexcharts-tooltip-custom" style="padding: 10px; font-size: 12px; line-height: 1.6;">
                        <div style="font-weight: 700; margin-bottom: 4px; border-bottom: 1px solid #eee; padding-bottom: 4px;">${data.x}</div>
                        <div><span style="color:#666">Bắt đầu:</span> ${start}</div>
                        <div><span style="color:#666">Kết thúc:</span> ${end}</div>
                        <div style="margin-top:4px;">
                            <span style="color:#666">Trạng thái:</span> 
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
    tbody.innerHTML = '<tr><td colspan="12" class="loading-row">Đang tải dữ liệu trang ' + page + '...</td></tr>';

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
            tbody.innerHTML = '<tr><td colspan="12" class="loading-row">Không tìm thấy dữ liệu</td></tr>';
            renderPagination(0);
            return;
        }

        json.data.forEach(row => {
            const tr = document.createElement('tr');
            tr.innerHTML = `
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
            `;
            tr.onclick = () => showModal(row);
            tbody.appendChild(tr);
        });

        renderPagination(totalRecords);
    } catch (e) {
        console.error(e);
        tbody.innerHTML = '<tr><td colspan="12" class="loading-row">Lỗi kết nối server</td></tr>';
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

async function loadPerformance() {
    const res = await fetch('/api/performance');
    const data = await res.json();
    // Chart rendering logic (unchanged)
    const optLine = {
        series: [
            { name: 'Duration (s)', type: 'line', data: data.performance.duration },
            { name: 'Processing (s)', type: 'line', data: data.performance.processing }
        ],
        chart: { height: 350, type: 'line', zoom: { enabled: false }, animations: { enabled: false } },
        stroke: { width: [2, 2], curve: 'smooth' },
        labels: data.performance.categories,
        xaxis: { type: 'category', labels: { show: false } },
        colors: ['#2563eb', '#f59e0b'],
        yaxis: [{ title: { text: "Video Duration" } }, { opposite: true, title: { text: "Processing Time" } }]
    };
    if(charts.perfLine) charts.perfLine.destroy();
    charts.perfLine = new ApexCharts(document.querySelector("#chart-perf-line"), optLine);
    charts.perfLine.render();

    const optBar = {
        series: [{ name: 'Storage (MB)', data: data.storage.sizes }],
        chart: { height: 350, type: 'bar', animations: { enabled: false } },
        xaxis: { categories: data.storage.dates },
        colors: ['#8b5cf6'],
        dataLabels: { enabled: false }
    };
    if(charts.storeBar) charts.storeBar.destroy();
    charts.storeBar = new ApexCharts(document.querySelector("#chart-storage-bar"), optBar);
    charts.storeBar.render();
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
            errorList += `- ${type}: ${count} lần\n`;
        }
        contentHtml = `<div class="raw-message-box">TỔNG QUAN LỖI (${data.meta.count} sự kiện):\n` + 
                      `--------------------------------------------------\n` +
                      `${errorList}\n\n` +
                      `MẪU LỖI ĐẦU TIÊN:\n${data.meta.sample_msg}</div>`;
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