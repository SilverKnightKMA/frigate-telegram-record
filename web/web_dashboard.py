#!/usr/bin/env python3
"""
Frigate Telegram Record - Web Dashboard
Simple web interface to monitor camera statistics and recording history
"""

import os
import sqlite3
import base64
import re
from datetime import datetime, timedelta
from flask import Flask, render_template, jsonify, request
from collections import defaultdict

app = Flask(__name__)

# Configuration
DB_FILE = os.environ.get('DB_FILE', '/app/data/video_history.sqlite')
PORT = int(os.environ.get('WEB_PORT', '8080'))

def get_db_connection():
    """Create a database connection with timeout"""
    conn = sqlite3.connect(DB_FILE, timeout=30.0)
    conn.row_factory = sqlite3.Row
    return conn

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
            SELECT 
                camera,
                COUNT(*) as timelapse_count
            FROM timelapse_history
            GROUP BY camera
        """)
        
        for row in cursor.fetchall():
            camera = row['camera']
            if camera not in cameras:
                cameras[camera] = {
                    'name': camera,
                    'total_records': 0,
                    'first_record': 'N/A',
                    'last_record': 'N/A',
                    'total_duration': 'N/A',
                    'success_count': 0,
                    'timelapse_count': 0,
                    'failed_count': 0
                }
            cameras[camera]['timelapse_count'] = row['timelapse_count']
        
        # Get failed records (alert_history table)
        cursor.execute("""
            SELECT 
                camera,
                COUNT(*) as failed_count
            FROM alert_history
            GROUP BY camera
        """)
        
        for row in cursor.fetchall():
            camera = row['camera']
            if camera not in cameras:
                cameras[camera] = {
                    'name': camera,
                    'total_records': 0,
                    'first_record': 'N/A',
                    'last_record': 'N/A',
                    'total_duration': 'N/A',
                    'success_count': 0,
                    'timelapse_count': 0,
                    'failed_count': 0
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
        
        cursor.execute("""
            SELECT COUNT(*) as recent 
            FROM sent_ranges 
            WHERE created_at > ?
        """, (yesterday_ts,))
        recent_records = cursor.fetchone()['recent']
        
        cursor.execute("""
            SELECT COUNT(*) as recent 
            FROM timelapse_history 
            WHERE created_at > ?
        """, (yesterday_ts,))
        recent_timelapses = cursor.fetchone()['recent']
        
        cursor.execute("""
            SELECT COUNT(*) as recent 
            FROM alert_history 
            WHERE created_at > ?
        """, (yesterday_ts,))
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
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500

@app.route('/api/recent_activity')
def get_recent_activity():
    """Get recent activity from all tables"""
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        activities = []
        
        # Get recent successful records
        cursor.execute("""
            SELECT 
                camera,
                start_ts,
                end_ts,
                created_at,
                'success' as type
            FROM sent_ranges
            ORDER BY created_at DESC
            LIMIT 50
        """)
        
        for row in cursor.fetchall():
            activities.append({
                'camera': row['camera'],
                'type': 'Record',
                'status': 'success',
                'timestamp': datetime.fromtimestamp(row['created_at']).strftime('%Y-%m-%d %H:%M:%S'),
                'details': f"{datetime.fromtimestamp(row['start_ts']).strftime('%H:%M:%S')} - {datetime.fromtimestamp(row['end_ts']).strftime('%H:%M:%S')}"
            })
        
        # Get recent timelapses
        cursor.execute("""
            SELECT 
                camera,
                range_id,
                created_at
            FROM timelapse_history
            ORDER BY created_at DESC
            LIMIT 50
        """)
        
        for row in cursor.fetchall():
            activities.append({
                'camera': row['camera'],
                'type': 'Timelapse',
                'status': 'success',
                'timestamp': datetime.fromtimestamp(row['created_at']).strftime('%Y-%m-%d %H:%M:%S'),
                'details': row['range_id']
            })
        
        # Get recent failures
        cursor.execute("""
            SELECT 
                camera,
                id,
                created_at,
                alert_text,
                duration
            FROM alert_history
            ORDER BY created_at DESC
            LIMIT 50
        """)
        
        for row in cursor.fetchall():
            duration_str = parse_duration(row['duration']) if row['duration'] else 'N/A'
            
            # Decode alert_text from base64 if it's encoded
            alert_text = row['alert_text'] if row['alert_text'] else 'Error'
            try:
                # Try to decode from base64
                decoded = base64.b64decode(alert_text).decode('utf-8')
                alert_text = decoded
            except:
                # If decoding fails, use the original text
                pass
            
            activities.append({
                'camera': row['camera'],
                'type': 'Alert',
                'status': 'failed',
                'timestamp': datetime.fromtimestamp(row['created_at']).strftime('%Y-%m-%d %H:%M:%S'),
                'details': f"{alert_text[:200] if alert_text else 'Error'} (Duration: {duration_str})"
            })
        
        # Sort all activities by timestamp
        activities.sort(key=lambda x: x['timestamp'], reverse=True)
        
        conn.close()
        
        return jsonify({
            'success': True,
            'activities': activities[:100]  # Limit to 100 most recent
        })
        
    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500


