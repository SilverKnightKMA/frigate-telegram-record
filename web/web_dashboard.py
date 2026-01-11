#!/usr/bin/env python3
"""
Frigate Telegram Recorder - Dashboard Backend
Kiến trúc: Flask API + SQLite (Read-Only)
Chức năng: Cung cấp API endpoint cho Frontend, xử lý Timezone và Decoding.
"""

import os
import sqlite3
import base64
import pytz
from datetime import datetime, timedelta
from flask import Flask, render_template, jsonify, request

app = Flask(__name__)

# --- Cấu hình hệ thống ---
DB_FILE = os.environ.get('DB_FILE', '/app/data/video_history.sqlite')
PORT = int(os.environ.get('WEB_PORT', '8080'))
LOCAL_TZ = pytz.timezone('Asia/Ho_Chi_Minh')

def get_db_connection():
    """
    Thiết lập kết nối SQLite ở chế độ Read-Only (URI mode).
    Đảm bảo không lock database khi script ghi đang chạy.
    """
    try:
        # Sử dụng URI file:...?mode=ro để force read-only
        conn = sqlite3.connect(f"file:{DB_FILE}?mode=ro", uri=True, timeout=5.0)
        conn.row_factory = sqlite3.Row
        return conn
    except sqlite3.OperationalError:
        # Fallback nếu file chưa tồn tại
        return None

def format_timestamp(ts):
    """
    Chuyển đổi Unix Timestamp sang định dạng YYYY-MM-DD HH:MM:SS (Asia/Ho_Chi_Minh).
    """
    if not ts: return ""
    dt_utc = datetime.fromtimestamp(ts, pytz.utc)
    dt_local = dt_utc.astimezone(LOCAL_TZ)
    return dt_local.strftime('%Y-%m-%d %H:%M:%S')

def format_size(size_bytes):
    """
    Chuyển đổi Bytes sang MB hoặc GB.
    """
    if not size_bytes: return "0 MB"
    mb = size_bytes / (1024 * 1024)
    if mb >= 1024:
        return f"{mb/1024:.2f} GB"
    return f"{mb:.2f} MB"

def decode_message(b64_msg):
    """
    Giải mã nội dung log từ Base64 sang UTF-8 String.
    """
    if not b64_msg: return ""
    try:
        return base64.b64decode(b64_msg).decode('utf-8')
    except Exception:
        return str(b64_msg)

@app.route('/')
def index():
    """Render giao diện chính (SPA Container)."""
    return render_template('dashboard.html')

@app.route('/api/overview')
def get_overview():
    """
    API cho Tab A: Overview.
    Trả về: Metrics cards, Biểu đồ Success/Fail, Biểu đồ Failure Reasons.
    """
    conn = get_db_connection()
    if not conn: return jsonify({'error': 'Database not found'}), 500
    
    cursor = conn.cursor()
    
    # Lấy tham số filter thời gian (mặc định 24h)
    days = request.args.get('days', 1, type=int)
    cutoff_ts = (datetime.now(pytz.utc) - timedelta(days=days)).timestamp()

    try:
        # 1. Metrics tổng quan
        query_metrics = """
            SELECT 
                COUNT(*) as total_jobs,
                SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END) as success_jobs,
                SUM(filesize) as total_storage,
                AVG(process_sec) as avg_process
            FROM events 
            WHERE created_at > ?
        """
        metrics = cursor.execute(query_metrics, (cutoff_ts,)).fetchone()
        
        # 2. Last update check
        last_update = cursor.execute("SELECT MAX(created_at) FROM events").fetchone()[0]

        # 3. Chart: Success vs Failure theo ngày (cho Stacked Bar)
        # SQLite strftime %J là Julian day, ta group theo ngày local
        query_daily = """
            SELECT 
                date(created_at, 'unixepoch', 'localtime') as day_str,
                SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END) as success,
                SUM(CASE WHEN status = 'FAILED' THEN 1 ELSE 0 END) as failed
            FROM events
            WHERE created_at > ?
            GROUP BY day_str
            ORDER BY day_str ASC
        """
        daily_stats = cursor.execute(query_daily, (cutoff_ts,)).fetchall()

        # 4. Chart: Failure Reasons (cho Donut Chart)
        query_reasons = """
            SELECT fail_type, COUNT(*) as count 
            FROM events 
            WHERE status = 'FAILED' AND created_at > ? 
            GROUP BY fail_type
        """
        fail_reasons = cursor.execute(query_reasons, (cutoff_ts,)).fetchall()

        return jsonify({
            'metrics': {
                'total': metrics['total_jobs'] or 0,
                'success_rate': round((metrics['success_jobs'] or 0) / (metrics['total_jobs'] or 1) * 100, 1),
                'storage': format_size(metrics['total_storage']),
                'avg_process': round(metrics['avg_process'] or 0, 2),
                'last_update': format_timestamp(last_update)
            },
            'charts': {
                'daily': [{'date': r['day_str'], 'success': r['success'], 'failed': r['failed']} for r in daily_stats],
                'reasons': {'labels': [r['fail_type'] or 'Unknown' for r in fail_reasons], 'series': [r['count'] for r in fail_reasons]}
            }
        })
    finally:
        conn.close()

@app.route('/api/timeline')
def get_timeline():
    """
    API cho Tab B: Timeline & Gaps.
    Trả về dữ liệu để vẽ Gantt Chart/Heatmap xác định khoảng trống.
    """
    conn = get_db_connection()
    if not conn: return jsonify({'error': 'DB Error'}), 500
    cursor = conn.cursor()

    # Lấy dữ liệu 24h gần nhất mặc định
    date_str = request.args.get('date', datetime.now(LOCAL_TZ).strftime('%Y-%m-%d'))
    
    # Tính timestamp đầu ngày và cuối ngày theo Local Time
    local_dt = datetime.strptime(date_str, '%Y-%m-%d')
    local_dt = LOCAL_TZ.localize(local_dt)
    ts_start = local_dt.timestamp()
    ts_end = (local_dt + timedelta(days=1)).timestamp()

    try:
        # Chỉ lấy các sự kiện SUCCESS để vẽ vùng xanh
        query = """
            SELECT camera, start_ts, end_ts 
            FROM events 
            WHERE status = 'SUCCESS' 
            AND start_ts >= ? AND end_ts <= ?
            ORDER BY camera, start_ts
        """
        rows = cursor.execute(query, (ts_start, ts_end)).fetchall()
        
        # Format dữ liệu cho ApexCharts RangeBar
        series_data = {}
        for r in rows:
            cam = r['camera']
            if cam not in series_data: series_data[cam] = []
            # ApexCharts yêu cầu timestamp mili giây
            series_data[cam].append({
                'x': cam,
                'y': [r['start_ts'] * 1000, r['end_ts'] * 1000]
            })

        return jsonify({
            'series': [{'name': k, 'data': v} for k, v in series_data.items()]
        })
    finally:
        conn.close()

@app.route('/api/logs')
def get_logs():
    """
    API cho Tab C: Detailed Logs.
    Hỗ trợ Filter và Search.
    """
    conn = get_db_connection()
    if not conn: return jsonify({'error': 'DB Error'}), 500
    cursor = conn.cursor()

    # Nhận tham số filter
    status = request.args.get('status', 'all')
    camera = request.args.get('camera', 'all')
    search = request.args.get('search', '')
    limit = request.args.get('limit', 100, type=int)

    base_query = "SELECT id, camera, type, status, created_at, message, duration, filesize, fail_type FROM events WHERE 1=1"
    params = []

    if status != 'all':
        base_query += " AND status = ?"
        params.append(status.upper())
    
    if camera != 'all':
        base_query += " AND camera = ?"
        params.append(camera)

    # Search trong decoded text (lưu ý: search base64 trong SQL chậm, nên ở đây search metadata trước)
    # Để tối ưu, ở đây chỉ search fail_type hoặc camera. Search message cần xử lý ở client hoặc full-text search sau.
    if search:
        base_query += " AND (camera LIKE ? OR fail_type LIKE ?)"
        params.extend([f"%{search}%", f"%{search}%"])

    base_query += " ORDER BY created_at DESC LIMIT ?"
    params.append(limit)

    try:
        rows = cursor.execute(base_query, params).fetchall()
        
        # Xử lý dữ liệu hiển thị (Decode Base64 tại đây)
        data = []
        for r in rows:
            data.append({
                'id': r['id'],
                'time': format_timestamp(r['created_at']),
                'camera': r['camera'],
                'type': r['type'],
                'status': r['status'],
                'duration': f"{r['duration']}s" if r['duration'] else "-",
                'size': format_size(r['filesize']),
                'error_type': r['fail_type'] or "-",
                'message': decode_message(r['message']) # Decode base64 trước khi gửi xuống client
            })
        return jsonify({'data': data})
    finally:
        conn.close()

@app.route('/api/performance')
def get_performance():
    """
    API cho Tab D: Performance Analytics.
    """
    conn = get_db_connection()
    if not conn: return jsonify({'error': 'DB Error'}), 500
    cursor = conn.cursor()
    
    cutoff_ts = (datetime.now(pytz.utc) - timedelta(days=7)).timestamp()

    try:
        # Chart: Duration vs Processing Time
        query_perf = """
            SELECT created_at, duration, process_sec 
            FROM events 
            WHERE status = 'SUCCESS' AND created_at > ?
            ORDER BY created_at ASC
        """
        rows = cursor.execute(query_perf, (cutoff_ts,)).fetchall()
        
        perf_data = {
            'categories': [format_timestamp(r['created_at']) for r in rows],
            'duration': [r['duration'] for r in rows],
            'processing': [r['process_sec'] for r in rows]
        }

        # Chart: Storage Trend (Sum size by day)
        query_store = """
            SELECT date(created_at, 'unixepoch', 'localtime') as d, SUM(filesize) as total
            FROM events WHERE created_at > ?
            GROUP BY d ORDER BY d ASC
        """
        rows_store = cursor.execute(query_store, (cutoff_ts,)).fetchall()
        store_data = {
            'dates': [r['d'] for r in rows_store],
            'sizes': [round(r['total']/(1024*1024), 2) for r in rows_store] # MB
        }

        return jsonify({'performance': perf_data, 'storage': store_data})
    finally:
        conn.close()

# API phụ để lấy danh sách Camera cho Dropdown Filter
@app.route('/api/cameras')
def get_cameras():
    conn = get_db_connection()
    if not conn: return jsonify([])
    cams = conn.execute("SELECT DISTINCT camera FROM events ORDER BY camera").fetchall()
    conn.close()
    return jsonify([c[0] for c in cams])

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=PORT, debug=False)