#!/usr/bin/env python3
"""
Frigate Telegram Recorder - Web Dashboard Backend
Architecture: Flask API + SQLite (Standard Mode)
Description: Provides API endpoints for the Dashboard, handles SQLite data retrieval.
"""

import os
import sqlite3
import base64
import pytz
from datetime import datetime, timedelta
from flask import Flask, render_template, jsonify, request

app = Flask(__name__)

# System Configuration
# Ensure absolute path to avoid relative path issues
DB_FILE = os.path.abspath(os.environ.get('DB_FILE', '/app/data/video_history.sqlite'))
PORT = int(os.environ.get('WEB_PORT', '8080'))
LOCAL_TZ = pytz.timezone('Asia/Ho_Chi_Minh')

def get_db_connection():
    """
    Establishes a connection to the SQLite Database.
    Switched to standard connection (non-URI) to handle WAL mode locks better in Docker.
    """
    if not os.path.isfile(DB_FILE):
        return None

    conn = None
    try:
        # Change: Use standard path instead of URI to avoid strict RO/WAL permission conflicts
        # Increased timeout to 15s to wait for recorder locks to release
        conn = sqlite3.connect(DB_FILE, timeout=15.0)
        conn.row_factory = sqlite3.Row
        
        # Validation query
        conn.execute("SELECT 1")
        return conn
    except sqlite3.OperationalError:
        if conn:
            conn.close()
        return None

def format_timestamp(ts):
    """Converts Unix Timestamp (UTC) to Local Time string (GMT+7)."""
    if not ts: return ""
    dt_utc = datetime.fromtimestamp(ts, pytz.utc)
    dt_local = dt_utc.astimezone(LOCAL_TZ)
    return dt_local.strftime('%Y-%m-%d %H:%M:%S')

def decode_message(b64_msg):
    """Decodes Base64 log content to UTF-8, handles exceptions."""
    if not b64_msg: return ""
    try:
        return base64.b64decode(b64_msg).decode('utf-8', errors='replace')
    except Exception:
        return str(b64_msg)

# --- Routes ---

@app.route('/')
def index():
    """Renders the main Dashboard SPA interface."""
    return render_template('dashboard.html')

@app.route('/api/overview')
def get_overview():
    """
    API endpoint: Overview Tab
    Returns: General metrics, Stacked Bar Chart data, and Donut Chart data.
    """
    conn = get_db_connection()
    if not conn: return jsonify({'error': 'Database connect failed'}), 500
    
    cursor = conn.cursor()
    
    # Date filter (default 1 day)
    days = request.args.get('days', 1, type=int)
    cutoff_dt = datetime.now(pytz.utc) - timedelta(days=days)
    cutoff_ts = cutoff_dt.timestamp()

    try:
        # Aggregate Metrics
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
        
        # Get latest update timestamp
        last_update_row = cursor.execute("SELECT MAX(created_at) FROM events").fetchone()
        last_update = last_update_row[0] if last_update_row else None

        # Data for Stacked Bar Chart
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

        # Data for Donut Chart
        query_reasons = """
            SELECT fail_type, COUNT(*) as count 
            FROM events 
            WHERE status = 'FAILED' AND created_at > ? 
            GROUP BY fail_type
        """
        fail_reasons = cursor.execute(query_reasons, (cutoff_ts,)).fetchall()

        # Calculate success rate
        total = metrics['total_jobs'] or 0
        success_count = metrics['success_jobs'] or 0
        success_rate = round((success_count / total * 100), 1) if total > 0 else 0
        
        # Format storage unit
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
    Returns: Data for Gantt/Heatmap chart to visualize recording gaps.
    Include both SUCCESS (Green) and FAILED (Red) statuses.
    """
    conn = get_db_connection()
    if not conn: return jsonify({'error': 'Database connect failed'}), 500
    cursor = conn.cursor()

    date_str = request.args.get('date', datetime.now(LOCAL_TZ).strftime('%Y-%m-%d'))
    
    try:
        local_dt_start = datetime.strptime(date_str, '%Y-%m-%d')
        local_dt_start = LOCAL_TZ.localize(local_dt_start)
        ts_start = local_dt_start.timestamp()
        ts_end = (local_dt_start + timedelta(days=1)).timestamp()
    except ValueError:
        return jsonify({'error': 'Invalid date format'}), 400

    try:
        # Modified Query: Fetch both SUCCESS and FAILED to visualize status colors
        query = """
            SELECT camera, start_ts, end_ts, status
            FROM events 
            WHERE (status = 'SUCCESS' OR status = 'FAILED')
            AND start_ts >= ? AND end_ts <= ?
            ORDER BY camera, start_ts
        """
        rows = cursor.execute(query, (ts_start, ts_end)).fetchall()
        
        series_data = {}
        for r in rows:
            cam = r['camera']
            if cam not in series_data: series_data[cam] = []
            
            # Determine color based on status (Backend logic for consistency)
            # Success -> Green (#10b981), Failed -> Red (#ef4444)
            fill_color = '#10b981' if r['status'] == 'SUCCESS' else '#ef4444'

            series_data[cam].append({
                'x': cam,
                'y': [r['start_ts'] * 1000, r['end_ts'] * 1000],
                'fillColor': fill_color
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
    Supports: Filter, Search, and Pagination (Offset/Limit).
    """
    conn = get_db_connection()
    if not conn: return jsonify({'error': 'Database connect failed'}), 500
    cursor = conn.cursor()

    status = request.args.get('status', 'all')
    camera = request.args.get('camera', 'all')
    search = request.args.get('search', '')
    
    # Pagination parameters
    limit = request.args.get('limit', 50, type=int)
    offset = request.args.get('offset', 0, type=int)

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

    if search:
        base_query += " AND (camera LIKE ? OR fail_type LIKE ?)"
        params.extend([f"%{search}%", f"%{search}%"])

    # Apply pagination
    base_query += " ORDER BY created_at DESC LIMIT ? OFFSET ?"
    params.extend([limit, offset])

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
                'message': decode_message(r['message'])
            })
        return jsonify({'data': data, 'count': len(data)})
    finally:
        conn.close()

@app.route('/api/performance')
def get_performance():
    """
    API endpoint: Performance Tab
    Analyzes server performance (Processing Time vs Duration) and storage trends.
    """
    conn = get_db_connection()
    if not conn: return jsonify({'error': 'Database connect failed'}), 500
    cursor = conn.cursor()
    
    cutoff_ts = (datetime.now(pytz.utc) - timedelta(days=7)).timestamp()

    try:
        # Line Chart: Duration vs Processing Time
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

        # Bar Chart: Storage Usage Trend
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
    """Fetches unique camera names for filter dropdown."""
    conn = get_db_connection()
    if not conn: return jsonify([])
    try:
        cams = conn.execute("SELECT DISTINCT camera FROM events ORDER BY camera").fetchall()
        return jsonify([c[0] for c in cams])
    finally:
        conn.close()

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=PORT, debug=False)