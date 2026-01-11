#!/usr/bin/env python3
"""
Frigate Telegram Recorder - Web Dashboard Backend
Architecture: Flask API + SQLite (Read-Only Mode)
Description: Cung cấp API endpoints phục vụ Dashboard, xử lý dữ liệu từ database SQLite.
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
    Thiết lập kết nối đến SQLite Database.
    Sử dụng chế độ URI 'mode=ro' để đảm bảo Read-Only, cho phép đọc song song với tiến trình ghi (WAL mode).
    """
    try:
        conn = sqlite3.connect(f"file:{DB_FILE}?mode=ro", uri=True, timeout=5.0)
        conn.row_factory = sqlite3.Row
        return conn
    except sqlite3.OperationalError:
        return None

def format_timestamp(ts):
    """
    Chuyển đổi Unix Timestamp (UTC) sang chuỗi thời gian định dạng Local (GMT+7).
    """
    if not ts: return ""
    dt_utc = datetime.fromtimestamp(ts, pytz.utc)
    dt_local = dt_utc.astimezone(LOCAL_TZ)
    return dt_local.strftime('%Y-%m-%d %H:%M:%S')

def decode_message(b64_msg):
    """
    Giải mã nội dung log từ Base64 sang UTF-8.
    Xử lý ngoại lệ nếu chuỗi input không hợp lệ.
    """
    if not b64_msg: return ""
    try:
        return base64.b64decode(b64_msg).decode('utf-8', errors='replace')
    except Exception:
        return str(b64_msg)

# --- Routes ---

@app.route('/')
def index():
    """Render giao diện Dashboard chính (SPA)."""
    return render_template('dashboard.html')

@app.route('/api/overview')
def get_overview():
    """
    API endpoint: Overview Tab
    Trả về: Metrics tổng quan, dữ liệu biểu đồ Stacked Bar và Donut Chart trong khoảng thời gian chỉ định.
    """
    conn = get_db_connection()
    if not conn: return jsonify({'error': 'Database connect failed'}), 500
    
    cursor = conn.cursor()
    
    # Filter theo số ngày (mặc định 1 ngày)
    days = request.args.get('days', 1, type=int)
    cutoff_dt = datetime.now(pytz.utc) - timedelta(days=days)
    cutoff_ts = cutoff_dt.timestamp()

    try:
        # Tổng hợp Metrics (Health, Storage, Processing Time)
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
        
        # Lấy thời gian cập nhật mới nhất
        last_update_row = cursor.execute("SELECT MAX(created_at) FROM events").fetchone()
        last_update = last_update_row[0] if last_update_row else None

        # Data cho Stacked Bar Chart (Success vs Failed theo ngày)
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

        # Data cho Donut Chart (Phân loại lỗi)
        query_reasons = """
            SELECT fail_type, COUNT(*) as count 
            FROM events 
            WHERE status = 'FAILED' AND created_at > ? 
            GROUP BY fail_type
        """
        fail_reasons = cursor.execute(query_reasons, (cutoff_ts,)).fetchall()

        # Tính toán tỷ lệ thành công
        total = metrics['total_jobs'] or 0
        success_count = metrics['success_jobs'] or 0
        success_rate = round((success_count / total * 100), 1) if total > 0 else 0
        
        # Convert Storage bytes -> MB/GB
        storage_bytes = metrics['total_storage'] or 0
        storage_fmt = f"{storage_bytes/1024**3:.2f} GB" if storage_bytes > 1024**3 else f"{storage_bytes/1024**2:.2f} MB"

        return jsonify({
            'metrics': {
                'total': total,
                'success_rate': success_rate,
                'storage': storage_fmt,
                'avg_process': round(metrics['avg_process'] or 0, 2),
                'last_update': format_timestamp(last_update)
            },
            'charts': {
                'daily': [{'date': r['day_str'], 'success': r['success'], 'failed': r['failed']} for r in daily_stats],
                'reasons': {
                    'labels': [r['fail_type'] or 'Unknown' for r in fail_reasons],
                    'series': [r['count'] for r in fail_reasons]
                }
            }
        })
    finally:
        conn.close()

@app.route('/api/timeline')
def get_timeline():
    """
    API endpoint: Timeline Tab
    Mục tiêu: Cung cấp dữ liệu cho biểu đồ Gantt/Heatmap để phát hiện khoảng trống ghi hình (Gap).
    """
    conn = get_db_connection()
    if not conn: return jsonify({'error': 'Database connect failed'}), 500
    cursor = conn.cursor()

    # Nhận ngày từ client, mặc định là ngày hiện tại
    date_str = request.args.get('date', datetime.now(LOCAL_TZ).strftime('%Y-%m-%d'))
    
    # Tính toán khoảng start/end timestamp cho ngày đó (theo Local Time)
    try:
        local_dt_start = datetime.strptime(date_str, '%Y-%m-%d')
        local_dt_start = LOCAL_TZ.localize(local_dt_start)
        ts_start = local_dt_start.timestamp()
        ts_end = (local_dt_start + timedelta(days=1)).timestamp()
    except ValueError:
        return jsonify({'error': 'Invalid date format'}), 400

    try:
        # Query các sự kiện SUCCESS để vẽ timeline
        query = """
            SELECT camera, start_ts, end_ts 
            FROM events 
            WHERE status = 'SUCCESS' 
            AND start_ts >= ? AND end_ts <= ?
            ORDER BY camera, start_ts
        """
        rows = cursor.execute(query, (ts_start, ts_end)).fetchall()
        
        # Format dữ liệu theo cấu trúc ApexCharts RangeBar
        series_data = {}
        for r in rows:
            cam = r['camera']
            if cam not in series_data: series_data[cam] = []
            # ApexCharts yêu cầu timestamp dạng mili giây
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
    API endpoint: Logs Tab
    Hỗ trợ Filter (Status, Camera), Search và Pagination (Limit).
    """
    conn = get_db_connection()
    if not conn: return jsonify({'error': 'Database connect failed'}), 500
    cursor = conn.cursor()

    status = request.args.get('status', 'all')
    camera = request.args.get('camera', 'all')
    search = request.args.get('search', '')
    limit = request.args.get('limit', 100, type=int)

    base_query = """
        SELECT id, camera, type, status, created_at, message, duration, filesize, fail_type 
        FROM events WHERE 1=1
    """
    params = []

    if status != 'all':
        base_query += " AND status = ?"
        params.append(status.upper())
    
    if camera != 'all':
        base_query += " AND camera = ?"
        params.append(camera)

    # Tìm kiếm text trong Camera hoặc Loại lỗi (Fail Type)
    if search:
        base_query += " AND (camera LIKE ? OR fail_type LIKE ?)"
        params.extend([f"%{search}%", f"%{search}%"])

    base_query += " ORDER BY created_at DESC LIMIT ?"
    params.append(limit)

    try:
        rows = cursor.execute(base_query, params).fetchall()
        
        data = []
        for r in rows:
            size_mb = (r['filesize'] or 0) / (1024 * 1024)
            data.append({
                'id': r['id'],
                'time': format_timestamp(r['created_at']),
                'camera': r['camera'],
                'type': r['type'],
                'status': r['status'],
                'duration': f"{r['duration']}s" if r['duration'] else "-",
                'size': f"{size_mb:.2f} MB",
                'error_type': r['fail_type'] or "-",
                'message': decode_message(r['message']) # Decode tại backend
            })
        return jsonify({'data': data})
    finally:
        conn.close()

@app.route('/api/performance')
def get_performance():
    """
    API endpoint: Performance Tab
    Phân tích hiệu năng server (Thời gian xử lý vs Duration) và xu hướng lưu trữ.
    """
    conn = get_db_connection()
    if not conn: return jsonify({'error': 'Database connect failed'}), 500
    cursor = conn.cursor()
    
    # Lấy dữ liệu 7 ngày gần nhất
    cutoff_ts = (datetime.now(pytz.utc) - timedelta(days=7)).timestamp()

    try:
        # Chart Line: Tương quan Duration vs Processing Time
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

        # Chart Bar: Xu hướng tiêu thụ dung lượng theo ngày
        query_store = """
            SELECT date(created_at, 'unixepoch', 'localtime') as d, SUM(filesize) as total
            FROM events WHERE created_at > ?
            GROUP BY d ORDER BY d ASC
        """
        rows_store = cursor.execute(query_store, (cutoff_ts,)).fetchall()
        store_data = {
            'dates': [r['d'] for r in rows_store],
            'sizes': [round((r['total'] or 0)/(1024*1024), 2) for r in rows_store] # Unit: MB
        }

        return jsonify({'performance': perf_data, 'storage': store_data})
    finally:
        conn.close()

@app.route('/api/cameras')
def get_cameras():
    """Lấy danh sách Camera duy nhất để populate dropdown filter."""
    conn = get_db_connection()
    if not conn: return jsonify([])
    try:
        cams = conn.execute("SELECT DISTINCT camera FROM events ORDER BY camera").fetchall()
        return jsonify([c[0] for c in cams])
    finally:
        conn.close()

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=PORT, debug=False)