#!/usr/bin/env python3
"""
Frigate Telegram Record - Web Dashboard (Optimized)
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

# --- DATABASE INITIALIZATION ---
def init_db_if_missing():
    """Ensure database tables exist to prevent 500 errors on fresh start"""
    try:
        # Create dir if not exists
        os.makedirs(os.path.dirname(DB_FILE), exist_ok=True)
        
        conn = sqlite3.connect(DB_FILE)
        cursor = conn.cursor()
        
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS sent_ranges (
                camera TEXT, start_ts INTEGER, end_ts INTEGER, created_at INTEGER, msg_id INTEGER,
                PRIMARY KEY (camera, start_ts, end_ts)
            );
        """)
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS alert_history (
                id TEXT PRIMARY KEY, camera TEXT, created_at INTEGER, msg_id INTEGER, alert_text TEXT, duration INTEGER
            );
        """)
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS timelapse_history (
                camera TEXT, range_id TEXT, created_at INTEGER,
                PRIMARY KEY (camera, range_id)
            );
        """)
        conn.commit()
        conn.close()
    except Exception as e:
        print(f"Init DB Warning: {e}")

# Run init on startup
init_db_if_missing()

def get_db_connection():
    try:
        conn = sqlite3.connect(DB_FILE, timeout=10.0)
        conn.row_factory = sqlite3.Row
        return conn
    except Exception as e:
        print(f"DB Connection Error: {e}")
        return None

def parse_duration(duration_sec):
    if not duration_sec: return "N/A"
    h, r = divmod(duration_sec, 3600)
    m, s = divmod(r, 60)
    if h > 0: return f"{h}h {m:02d}m {s:02d}s"
    elif m > 0: return f"{m}m {s:02d}s"
    return f"{s}s"

@app.route('/')
def dashboard():
    return render_template('dashboard.html')

@app.route('/api/stats')
def get_stats():
    try:
        conn = get_db_connection()
        if not conn: return jsonify({'success': False, 'error': 'DB Error'}), 500
        cursor = conn.cursor()
        
        cameras = {}
        
        # 1. Get Success Stats
        cursor.execute("""
            SELECT camera, COUNT(*) as total, MAX(created_at) as last_ts, SUM(end_ts - start_ts) as dur
            FROM sent_ranges GROUP BY camera
        """)
        for row in cursor.fetchall():
            cam = row['camera']
            cameras[cam] = {
                'name': cam, 'success_count': row['total'], 'failed_count': 0, 'timelapse_count': 0,
                'total_duration': parse_duration(row['dur']),
                'last_record': datetime.fromtimestamp(row['last_ts']).strftime('%Y-%m-%d %H:%M:%S') if row['last_ts'] else '-'
            }
            
        # 2. Get Timelapse Stats
        cursor.execute("SELECT camera, COUNT(*) as total FROM timelapse_history GROUP BY camera")
        for row in cursor.fetchall():
            cam = row['camera']
            if cam not in cameras: cameras[cam] = {'name': cam, 'success_count': 0, 'failed_count': 0, 'timelapse_count': 0, 'total_duration': '0s', 'last_record': '-'}
            cameras[cam]['timelapse_count'] = row['total']

        # 3. Get Failure Stats
        cursor.execute("SELECT camera, COUNT(*) as total FROM alert_history GROUP BY camera")
        for row in cursor.fetchall():
            cam = row['camera']
            if cam not in cameras: cameras[cam] = {'name': cam, 'success_count': 0, 'failed_count': 0, 'timelapse_count': 0, 'total_duration': '0s', 'last_record': '-'}
            cameras[cam]['failed_count'] = row['total']

        # 4. Overall & Recent (24h)
        yesterday = int((datetime.now() - timedelta(days=1)).timestamp())
        
        stats = {
            'total_cameras': len(cameras),
            'total_records': cursor.execute("SELECT COUNT(*) FROM sent_ranges").fetchone()[0],
            'total_timelapses': cursor.execute("SELECT COUNT(*) FROM timelapse_history").fetchone()[0],
            'total_failures': cursor.execute("SELECT COUNT(*) FROM alert_history").fetchone()[0],
            'recent_records_24h': cursor.execute("SELECT COUNT(*) FROM sent_ranges WHERE created_at > ?", (yesterday,)).fetchone()[0],
            'recent_timelapses_24h': cursor.execute("SELECT COUNT(*) FROM timelapse_history WHERE created_at > ?", (yesterday,)).fetchone()[0],
            'recent_failures_24h': cursor.execute("SELECT COUNT(*) FROM alert_history WHERE created_at > ?", (yesterday,)).fetchone()[0],
        }
        
        conn.close()
        return jsonify({'success': True, 'cameras': list(cameras.values()), 'overall': stats})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/visualization')
def get_visualization_data():
    """Optimized for performance: Limits data points to prevent browser freeze"""
    try:
        conn = get_db_connection()
        if not conn: return jsonify({'success': False}), 500
        cursor = conn.cursor()
        
        start_time = int((datetime.now() - timedelta(hours=24)).timestamp())
        
        # --- OPTIMIZATION: LIMIT 1000 ---
        # Prevent massive data payload
        cursor.execute("""
            SELECT camera, start_ts, end_ts FROM sent_ranges 
            WHERE start_ts > ? ORDER BY start_ts DESC LIMIT 1000
        """, (start_time,))
        
        camera_ranges = {}
        for row in cursor.fetchall():
            cam = row['camera']
            if cam not in camera_ranges: camera_ranges[cam] = []
            camera_ranges[cam].append({
                'x': cam,
                'y': [row['start_ts'] * 1000, row['end_ts'] * 1000],
                'fillColor': '#00E396'
            })

        # --- OPTIMIZATION: LIMIT 500 ---
        cursor.execute("""
            SELECT camera, created_at, alert_text FROM alert_history 
            WHERE created_at > ? ORDER BY created_at DESC LIMIT 500
        """, (start_time,))
        
        error_dist = {}
        for row in cursor.fetchall():
            cam = row['camera']
            ts = row['created_at']
            try: alert = base64.b64decode(row['alert_text']).decode('utf-8')
            except: alert = str(row['alert_text'])

            if cam not in camera_ranges: camera_ranges[cam] = []
            # Create a 1-minute red block for visibility
            camera_ranges[cam].append({
                'x': cam,
                'y': [ts * 1000, (ts + 60) * 1000],
                'fillColor': '#FF4560'
            })
            
            # Simple Categorization
            cat = "Other"
            if "404" in alert: cat = "Not Found (404)"
            elif "Validation" in alert: cat = "Validation Failed"
            elif "Partial" in alert: cat = "Partial Recording"
            elif "Network" in alert or "Curl" in alert: cat = "Network Error"
            elif "Timelapse" in alert: cat = "Timelapse Error"
            
            error_dist[cat] = error_dist.get(cat, 0) + 1

        timeline = [{'name': k, 'data': v} for k, v in camera_ranges.items()]
        conn.close()
        
        return jsonify({
            'success': True, 
            'timeline': timeline, 
            'errors': {'labels': list(error_dist.keys()), 'series': list(error_dist.values())}
        })
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/recent_activity')
def get_recent_activity():
    try:
        conn = get_db_connection()
        if not conn: return jsonify({'success': False}), 500
        cursor = conn.cursor()
        
        activities = []
        
        # Fetch Success
        cursor.execute("SELECT camera, created_at, 'Record' as type, 'success' as status, (start_ts || '-' || end_ts) as det FROM sent_ranges ORDER BY created_at DESC LIMIT 50")
        for r in cursor.fetchall():
            activities.append({'camera': r['camera'], 'type': r['type'], 'status': r['status'], 'timestamp': r['created_at'], 'details': 'Success'})

        # Fetch Failures
        cursor.execute("SELECT camera, created_at, 'Alert' as type, 'failed' as status, alert_text FROM alert_history ORDER BY created_at DESC LIMIT 50")
        for r in cursor.fetchall():
            try: txt = base64.b64decode(r['alert_text']).decode('utf-8')
            except: txt = "Error"
            clean = re.sub('<[^<]+?>', '', txt)[:80]
            activities.append({'camera': r['camera'], 'type': r['type'], 'status': r['status'], 'timestamp': r['created_at'], 'details': clean})
            
        # Sort and Format
        activities.sort(key=lambda x: x['timestamp'], reverse=True)
        final_list = []
        for act in activities[:100]:
            final_list.append({
                'camera': act['camera'],
                'type': act['type'],
                'status': act['status'],
                'timestamp': datetime.fromtimestamp(act['timestamp']).strftime('%H:%M:%S'),
                'details': act['details']
            })
            
        conn.close()
        return jsonify({'success': True, 'activities': final_list})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

if __name__ == '__main__':
    print(f"Starting Dashboard on port {PORT}...")
    app.run(host='0.0.0.0', port=PORT, debug=False)