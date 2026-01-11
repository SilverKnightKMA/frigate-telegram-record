#!/usr/bin/env python3
"""
Frigate Telegram Record - Web Dashboard (Aggregated & Optimized)
"""

import os
import sqlite3
import base64
import re
from datetime import datetime, timedelta
from flask import Flask, render_template, jsonify

app = Flask(__name__)

# Configuration
DB_FILE = os.environ.get('DB_FILE', '/app/data/video_history.sqlite')
PORT = int(os.environ.get('WEB_PORT', '8080'))

# --- DB INIT ---
def init_db_if_missing():
    try:
        os.makedirs(os.path.dirname(DB_FILE), exist_ok=True)
        conn = sqlite3.connect(DB_FILE)
        cursor = conn.cursor()
        cursor.execute("""CREATE TABLE IF NOT EXISTS sent_ranges (camera TEXT, start_ts INTEGER, end_ts INTEGER, created_at INTEGER, msg_id INTEGER, PRIMARY KEY (camera, start_ts, end_ts));""")
        cursor.execute("""CREATE TABLE IF NOT EXISTS alert_history (id TEXT PRIMARY KEY, camera TEXT, created_at INTEGER, msg_id INTEGER, alert_text TEXT, duration INTEGER);""")
        cursor.execute("""CREATE TABLE IF NOT EXISTS timelapse_history (camera TEXT, range_id TEXT, created_at INTEGER, PRIMARY KEY (camera, range_id));""")
        conn.commit()
        conn.close()
    except: pass

init_db_if_missing()

def get_db_connection():
    try:
        conn = sqlite3.connect(DB_FILE, timeout=10.0)
        conn.row_factory = sqlite3.Row
        return conn
    except: return None

def parse_duration(duration_sec):
    if not duration_sec: return "N/A"
    h, r = divmod(duration_sec, 3600)
    m, s = divmod(r, 60)
    return f"{h}h {m:02d}m {s:02d}s" if h else (f"{m}m {s:02d}s" if m else f"{s}s")

@app.route('/')
def dashboard(): return render_template('dashboard.html')

@app.route('/api/stats')
def get_stats():
    """Lightweight stats endpoint"""
    try:
        conn = get_db_connection()
        if not conn: return jsonify({'success': False}), 500
        cursor = conn.cursor()
        
        cameras = {}
        # Simple aggregations
        cursor.execute("SELECT camera, COUNT(*) as total, MAX(created_at) as last_ts, SUM(end_ts - start_ts) as dur FROM sent_ranges GROUP BY camera")
        for row in cursor.fetchall():
            cameras[row['camera']] = {
                'name': row['camera'], 'success_count': row['total'], 'failed_count': 0, 'timelapse_count': 0,
                'total_duration': parse_duration(row['dur']),
                'last_record': datetime.fromtimestamp(row['last_ts']).strftime('%Y-%m-%d %H:%M') if row['last_ts'] else '-'
            }
            
        for table, key in [('timelapse_history', 'timelapse_count'), ('alert_history', 'failed_count')]:
            cursor.execute(f"SELECT camera, COUNT(*) as total FROM {table} GROUP BY camera")
            for row in cursor.fetchall():
                c = row['camera']
                if c not in cameras: cameras[c] = {'name': c, 'success_count':0, 'failed_count':0, 'timelapse_count':0, 'total_duration':'0s', 'last_record':'-'}
                cameras[c][key] = row['total']

        yesterday = int((datetime.now() - timedelta(days=1)).timestamp())
        stats = {
            'total_cameras': len(cameras),
            'recent_records_24h': cursor.execute("SELECT COUNT(*) FROM sent_ranges WHERE created_at > ?", (yesterday,)).fetchone()[0],
            'recent_failures_24h': cursor.execute("SELECT COUNT(*) FROM alert_history WHERE created_at > ?", (yesterday,)).fetchone()[0],
        }
        conn.close()
        return jsonify({'success': True, 'cameras': list(cameras.values()), 'overall': stats})
    except Exception as e: return jsonify({'success': False, 'error': str(e)}), 500

# --- CORE LOGIC: SERVER-SIDE DOWNSAMPLING ---
def compact_ranges(raw_rows, tolerance=30):
    """
    Gộp các block liên tiếp thành 1 block lớn.
    tolerance: Khoảng cách tối đa (giây) giữa 2 block để được coi là liền mạch.
    """
    if not raw_rows: return []
    
    # Sort by Start Time (Critical for merging)
    raw_rows.sort(key=lambda x: x['start_ts'])
    
    merged = []
    current_blk = None

    for row in raw_rows:
        start = row['start_ts']
        end = row['end_ts']
        
        if current_blk is None:
            current_blk = {'x': row['camera'], 'y': [start*1000, end*1000], 'fillColor': '#00E396'}
            continue
            
        # Check continuity: If (NewStart) <= (OldEnd + Tolerance) -> Merge
        prev_end_ms = current_blk['y'][1]
        if (start * 1000) <= (prev_end_ms + (tolerance * 1000)):
            # Update End Time
            current_blk['y'][1] = max(prev_end_ms, end * 1000)
        else:
            # Gap detected -> Push current and start new
            merged.append(current_blk)
            current_blk = {'x': row['camera'], 'y': [start*1000, end*1000], 'fillColor': '#00E396'}
            
    if current_blk: merged.append(current_blk)
    return merged

@app.route('/api/visualization')
def get_visualization_data():
    """Heavy logic handled here, returning lightweight JSON"""
    try:
        conn = get_db_connection()
        if not conn: return jsonify({'success': False}), 500
        cursor = conn.cursor()
        
        # Load last 48h to support zoom out
        start_time = int((datetime.now() - timedelta(hours=48)).timestamp())
        
        # 1. Fetch RAW (Might be 5000+ rows)
        cursor.execute("SELECT camera, start_ts, end_ts FROM sent_ranges WHERE start_ts > ? ORDER BY camera, start_ts", (start_time,))
        raw_data = cursor.fetchall()
        
        # 2. GROUP & COMPACT (Reduce to ~50-100 rows)
        grouped_by_cam = {}
        for row in raw_data:
            c = row['camera']
            if c not in grouped_by_cam: grouped_by_cam[c] = []
            grouped_by_cam[c].append(row)
            
        final_timeline = []
        for cam, rows in grouped_by_cam.items():
            # Apply Downsampling Algorithm
            merged_blocks = compact_ranges(rows)
            final_timeline.append({'name': cam, 'data': merged_blocks})

        # 3. Add Errors (Keep them distinct points)
        cursor.execute("SELECT camera, created_at, alert_text FROM alert_history WHERE created_at > ? ORDER BY created_at DESC LIMIT 200", (start_time,))
        
        error_dist = {}
        for row in cursor.fetchall():
            c = row['camera']
            ts = row['created_at']
            
            # Find Series
            series = next((s for s in final_timeline if s['name'] == c), None)
            if not series:
                series = {'name': c, 'data': []}
                final_timeline.append(series)
            
            # Add Error Point (1 min width)
            series['data'].append({
                'x': c, 
                'y': [ts*1000, (ts+60)*1000], 
                'fillColor': '#FF4560' # Red
            })
            
            try: alert = base64.b64decode(row['alert_text']).decode('utf-8')
            except: alert = str(row['alert_text'])
            
            cat = "Other"
            if "404" in alert: cat = "404 Not Found"
            elif "Validation" in alert: cat = "Validation Failed"
            elif "Network" in alert: cat = "Network Err"
            elif "Partial" in alert: cat = "Partial Rec"
            
            error_dist[cat] = error_dist.get(cat, 0) + 1

        conn.close()
        return jsonify({
            'success': True, 
            'timeline': final_timeline, 
            'errors': {'labels': list(error_dist.keys()), 'series': list(error_dist.values())}
        })
    except Exception as e: return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/recent_activity')
def get_recent_activity():
    """Separate endpoint for text logs"""
    try:
        conn = get_db_connection()
        if not conn: return jsonify({'success': False}), 500
        cursor = conn.cursor()
        
        # Optimized query: Just get last 100 items mixed
        # Avoid heavy base64 decoding loop for huge datasets
        
        acts = []
        # Get Failures
        cursor.execute("SELECT camera, created_at, 'failed' as status, alert_text FROM alert_history ORDER BY created_at DESC LIMIT 50")
        for r in cursor.fetchall():
            try: txt = base64.b64decode(r['alert_text']).decode('utf-8')
            except: txt = "Error"
            # Truncate text on server to save bandwidth
            acts.append({
                'camera': r['camera'], 'type': 'Alert', 'status': 'failed',
                'ts': r['created_at'], 'det': txt[:200]
            })

        # Get Success (Just a sample)
        cursor.execute("SELECT camera, created_at, (start_ts || '-' || end_ts) as val FROM sent_ranges ORDER BY created_at DESC LIMIT 50")
        for r in cursor.fetchall():
            acts.append({
                'camera': r['camera'], 'type': 'Record', 'status': 'success',
                'ts': r['created_at'], 'det': 'Success'
            })
            
        acts.sort(key=lambda x: x['ts'], reverse=True)
        
        final = []
        for a in acts:
            final.append({
                'camera': a['camera'],
                'type': a['type'],
                'status': a['status'],
                'timestamp': datetime.fromtimestamp(a['ts']).strftime('%Y-%m-%d %H:%M:%S'),
                'time_short': datetime.fromtimestamp(a['ts']).strftime('%H:%M'),
                'details': a['det']
            })
            
        conn.close()
        return jsonify({'success': True, 'activities': final})
    except Exception as e: return jsonify({'success': False, 'error': str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=PORT, debug=False)