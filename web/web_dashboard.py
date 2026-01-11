#!/usr/bin/env python3
"""
Frigate Telegram Record - Web Dashboard
Simple web interface to monitor camera statistics and recording history
"""

import os
import sqlite3
import base64
import time
from datetime import datetime, timedelta
from flask import Flask, render_template, jsonify, request

app = Flask(__name__)

# Configuration
DB_FILE = os.environ.get('DB_FILE', '/app/data/video_history.sqlite')
PORT = int(os.environ.get('WEB_PORT', '8080'))

def get_db_connection():
    """Create a database connection with timeout"""
    try:
        conn = sqlite3.connect(DB_FILE, timeout=30.0)
        conn.row_factory = sqlite3.Row
        return conn
    except Exception as e:
        print(f"DB Connection Error: {e}")
        return None

def parse_duration(duration_sec):
    """Convert seconds to human-readable format"""
    if not duration_sec:
        return "N/A"
    hours = duration_sec // 3600
    minutes = (duration_sec % 3600) // 60
    seconds = duration_sec % 60
    if hours > 0:
        return f"{hours}h {minutes:02d}m {seconds:02d}s"
    elif minutes > 0:
        return f"{minutes}m {seconds:02d}s"
    else:
        return f"{seconds}s"

@app.route('/')
def dashboard():
    """Main dashboard page"""
    return render_template('dashboard.html')

@app.route('/api/stats')
def get_stats():
    """API endpoint to get database statistics"""
    try:
        conn = get_db_connection()
        if not conn:
            return jsonify({'success': False, 'error': 'Database connection failed'}), 500
        cursor = conn.cursor()
        
        # Get unique cameras and their counts
        cameras = {}
        
        # Get record statistics (sent_ranges table)
        cursor.execute("""
            SELECT 
                camera,
                COUNT(*) as total_records,
                MIN(created_at) as first_record,
                MAX(created_at) as last_record,
                SUM(end_ts - start_ts) as total_duration
            FROM sent_ranges
            GROUP BY camera
        """)
        
        for row in cursor.fetchall():
            camera = row['camera']
            cameras[camera] = {
                'name': camera,
                'total_records': row['total_records'],
                'first_record': datetime.fromtimestamp(row['first_record']).strftime('%Y-%m-%d %H:%M:%S') if row['first_record'] else 'N/A',
                'last_record': datetime.fromtimestamp(row['last_record']).strftime('%Y-%m-%d %H:%M:%S') if row['last_record'] else 'N/A',
                'total_duration': parse_duration(row['total_duration']),
                'success_count': row['total_records'],
                'timelapse_count': 0,
                'failed_count': 0
            }
        
        # Get timelapse statistics
        cursor.execute("""
            SELECT camera, COUNT(*) as timelapse_count
            FROM timelapse_history
            GROUP BY camera
        """)
        
        for row in cursor.fetchall():
            camera = row['camera']
            if camera not in cameras:
                cameras[camera] = {
                    'name': camera, 'total_records': 0, 'first_record': 'N/A', 'last_record': 'N/A',
                    'total_duration': 'N/A', 'success_count': 0, 'timelapse_count': 0, 'failed_count': 0
                }
            cameras[camera]['timelapse_count'] = row['timelapse_count']
        
        # Get failed records
        cursor.execute("""
            SELECT camera, COUNT(*) as failed_count
            FROM alert_history
            GROUP BY camera
        """)
        
        for row in cursor.fetchall():
            camera = row['camera']
            if camera not in cameras:
                cameras[camera] = {
                    'name': camera, 'total_records': 0, 'first_record': 'N/A', 'last_record': 'N/A',
                    'total_duration': 'N/A', 'success_count': 0, 'timelapse_count': 0, 'failed_count': 0
                }
            cameras[camera]['failed_count'] = row['failed_count']
        
        # Get overall statistics
        cursor.execute("SELECT COUNT(*) as total FROM sent_ranges")
        total_records = cursor.fetchone()['total']
        
        cursor.execute("SELECT COUNT(*) as total FROM timelapse_history")
        total_timelapses = cursor.fetchone()['total']
        
        cursor.execute("SELECT COUNT(*) as total FROM alert_history")
        total_failures = cursor.fetchone()['total']
        
        # Get recent activity (last 24 hours)
        yesterday_ts = int((datetime.now() - timedelta(days=1)).timestamp())
        
        cursor.execute("SELECT COUNT(*) as recent FROM sent_ranges WHERE created_at > ?", (yesterday_ts,))
        recent_records = cursor.fetchone()['recent']
        
        cursor.execute("SELECT COUNT(*) as recent FROM timelapse_history WHERE created_at > ?", (yesterday_ts,))
        recent_timelapses = cursor.fetchone()['recent']
        
        cursor.execute("SELECT COUNT(*) as recent FROM alert_history WHERE created_at > ?", (yesterday_ts,))
        recent_failures = cursor.fetchone()['recent']
        
        conn.close()
        
        return jsonify({
            'success': True,
            'cameras': list(cameras.values()),
            'overall': {
                'total_cameras': len(cameras),
                'total_records': total_records,
                'total_timelapses': total_timelapses,
                'total_failures': total_failures,
                'recent_records_24h': recent_records,
                'recent_timelapses_24h': recent_timelapses,
                'recent_failures_24h': recent_failures
            },
            'last_updated': datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        })
        
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/visualization')
def get_visualization_data():
    """API to get detailed data for charts (Last 24h)"""
    try:
        conn = get_db_connection()
        if not conn:
            return jsonify({'success': False, 'error': 'Database connection failed'}), 500
        cursor = conn.cursor()
        
        # Time filter: Last 24 hours
        start_time = int((datetime.now() - timedelta(hours=24)).timestamp())
        
        # 1. Timeline Data (Ranges)
        timeline_data = []
        cursor.execute("""
            SELECT camera, start_ts, end_ts 
            FROM sent_ranges 
            WHERE start_ts > ? 
            ORDER BY camera, start_ts
        """, (start_time,))
        
        raw_ranges = cursor.fetchall()
        
        # Group ranges by camera for ApexCharts RangeBar
        # Format: [{'x': 'CameraName', 'y': [start_ms, end_ms]}, ...]
        camera_ranges = {}
        for row in raw_ranges:
            cam = row['camera']
            if cam not in camera_ranges:
                camera_ranges[cam] = []
            # Convert to milliseconds for JS charts
            camera_ranges[cam].append({
                'x': cam,
                'y': [row['start_ts'] * 1000, row['end_ts'] * 1000],
                'fillColor': '#00E396' # Green for success
            })
            
        # 2. Error Points for Timeline
        cursor.execute("""
            SELECT camera, created_at, alert_text 
            FROM alert_history 
            WHERE created_at > ?
        """, (start_time,))
        raw_alerts = cursor.fetchall()
        
        error_distribution = {}
        
        for row in raw_alerts:
            cam = row['camera']
            ts = row['created_at']
            
            # Decode error for categorization
            try:
                alert_text = base64.b64decode(row['alert_text']).decode('utf-8')
            except:
                alert_text = str(row['alert_text'])

            # Add to timeline as a "point" (small range)
            if cam not in camera_ranges:
                camera_ranges[cam] = []
            
            camera_ranges[cam].append({
                'x': cam,
                'y': [ts * 1000, (ts + 60) * 1000], # Make a 1-minute block for visibility
                'fillColor': '#FF4560', # Red for error
                'meta': 'Error'
            })
            
            # Categorize Error
            category = "Unknown"
            if "404" in alert_text or "Not Found" in alert_text:
                category = "Frigate 404 (Not Found)"
            elif "Validation failed" in alert_text:
                category = "Validation Failed (File Size/Type)"
            elif "Partial" in alert_text:
                category = "Partial Video (Duration Mismatch)"
            elif "Network" in alert_text or "Curl" in alert_text:
                category = "Network/API Error"
            elif "Timelapse" in alert_text:
                 category = "Timelapse Generation Failed"
            else:
                category = "Other Errors"
                
            error_distribution[category] = error_distribution.get(category, 0) + 1

        # Format timeline series
        timeline_series = []
        for cam, data_points in camera_ranges.items():
            timeline_series.append({
                'name': cam,
                'data': data_points
            })

        # Format error donut chart
        error_labels = list(error_distribution.keys())
        error_values = list(error_distribution.values())

        conn.close()
        
        return jsonify({
            'success': True,
            'timeline': timeline_series,
            'errors': {
                'labels': error_labels,
                'series': error_values
            }
        })

    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/recent_activity')
def get_recent_activity():
    """Get recent activity from all tables"""
    try:
        conn = get_db_connection()
        if not conn:
             return jsonify({'success': False, 'error': 'Database connection failed'}), 500
        cursor = conn.cursor()
        
        activities = []
        
        # Get recent successful records
        cursor.execute("""
            SELECT camera, start_ts, end_ts, created_at, 'success' as type
            FROM sent_ranges ORDER BY created_at DESC LIMIT 50
        """)
        for row in cursor.fetchall():
            activities.append({
                'camera': row['camera'], 'type': 'Record', 'status': 'success',
                'timestamp': datetime.fromtimestamp(row['created_at']).strftime('%Y-%m-%d %H:%M:%S'),
                'details': f"{datetime.fromtimestamp(row['start_ts']).strftime('%H:%M:%S')} - {datetime.fromtimestamp(row['end_ts']).strftime('%H:%M:%S')}"
            })
        
        # Get recent timelapses
        cursor.execute("""
            SELECT camera, range_id, created_at
            FROM timelapse_history ORDER BY created_at DESC LIMIT 50
        """)
        for row in cursor.fetchall():
            activities.append({
                'camera': row['camera'], 'type': 'Timelapse', 'status': 'success',
                'timestamp': datetime.fromtimestamp(row['created_at']).strftime('%Y-%m-%d %H:%M:%S'),
                'details': row['range_id']
            })
        
        # Get recent failures
        cursor.execute("""
            SELECT camera, id, created_at, alert_text, duration
            FROM alert_history ORDER BY created_at DESC LIMIT 50
        """)
        for row in cursor.fetchall():
            duration_str = parse_duration(row['duration']) if row['duration'] else 'N/A'
            alert_text = row['alert_text'] if row['alert_text'] else 'Error'
            try:
                decoded = base64.b64decode(alert_text).decode('utf-8')
                alert_text = decoded
            except:
                pass
            
            # Clean HTML tags for display
            clean_text = re.sub('<[^<]+?>', '', alert_text)
            
            activities.append({
                'camera': row['camera'], 'type': 'Alert', 'status': 'failed',
                'timestamp': datetime.fromtimestamp(row['created_at']).strftime('%Y-%m-%d %H:%M:%S'),
                'details': f"{clean_text[:100]}... (Dur: {duration_str})"
            })
        
        activities.sort(key=lambda x: x['timestamp'], reverse=True)
        conn.close()
        
        return jsonify({'success': True, 'activities': activities[:100]})
        
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

if __name__ == '__main__':
    print(f"Starting Dashboard on port {PORT}")
    app.run(host='0.0.0.0', port=PORT, debug=False)