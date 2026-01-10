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

@app.route('/api/timeline')
def get_timeline():
    """Get timeline data for all cameras showing recording blocks"""
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        # Get parameters from request
        duration_hours = int(request.args.get('duration', 24))  # Default 24 hours
        end_ts = int(request.args.get('end_ts', datetime.now().timestamp()))  # Default to now
        start_ts = end_ts - (duration_hours * 3600)
        
        timeline_data = {}
        
        # Get all cameras
        cursor.execute("SELECT DISTINCT camera FROM sent_ranges UNION SELECT DISTINCT camera FROM timelapse_history UNION SELECT DISTINCT camera FROM alert_history")
        cameras = [row['camera'] for row in cursor.fetchall()]
        
        for camera in cameras:
            timeline_data[camera] = {
                'camera': camera,
                'records': [],
                'timelapses': []
            }
            
            # Get successful records for this camera in time range
            cursor.execute("""
                SELECT start_ts, end_ts, created_at
                FROM sent_ranges
                WHERE camera = ? AND start_ts >= ? AND start_ts <= ?
                ORDER BY start_ts
            """, (camera, start_ts, end_ts))
            
            for row in cursor.fetchall():
                start_time = datetime.fromtimestamp(row['start_ts']).strftime('%Y-%m-%d %H:%M:%S')
                end_time = datetime.fromtimestamp(row['end_ts']).strftime('%Y-%m-%d %H:%M:%S')
                duration = row['end_ts'] - row['start_ts']
                timeline_data[camera]['records'].append({
                    'start': row['start_ts'],
                    'end': row['end_ts'],
                    'status': 'success',
                    'created_at': row['created_at'],
                    'type': 'Record',
                    'start_time': start_time,
                    'end_time': end_time,
                    'duration': parse_duration(duration)
                })
            
            # Get timelapses for this camera in time range
            cursor.execute("""
                SELECT range_id, created_at
                FROM timelapse_history
                WHERE camera = ? AND created_at >= ? AND created_at <= ?
                ORDER BY created_at
            """, (camera, start_ts, end_ts))
            
            for row in cursor.fetchall():
                # Parse range_id to get start and end timestamps
                # Format: camera_startts_endts
                try:
                    parts = row['range_id'].split('_')
                    if len(parts) >= 3:
                        tl_start = int(parts[-2])
                        tl_end = int(parts[-1])
                        created_time = datetime.fromtimestamp(row['created_at']).strftime('%Y-%m-%d %H:%M:%S')
                        start_time = datetime.fromtimestamp(tl_start).strftime('%Y-%m-%d %H:%M:%S')
                        end_time = datetime.fromtimestamp(tl_end).strftime('%Y-%m-%d %H:%M:%S')
                        duration = tl_end - tl_start
                        timeline_data[camera]['timelapses'].append({
                            'start': tl_start,
                            'end': tl_end,
                            'status': 'success',
                            'range_id': row['range_id'],
                            'created_at': row['created_at'],
                            'type': 'Timelapse',
                            'created_time': created_time,
                            'start_time': start_time,
                            'end_time': end_time,
                            'duration': parse_duration(duration)
                        })
                except:
                    pass
            
            # Get failed records from alert_history and categorize them
            cursor.execute("""
                SELECT alert_text, created_at
                FROM alert_history
                WHERE camera = ? AND created_at >= ? AND created_at <= ?
                ORDER BY created_at
            """, (camera, start_ts, end_ts))
            
            for row in cursor.fetchall():
                # Decode alert_text and extract slot time
                alert_text = row['alert_text'] if row['alert_text'] else ''
                try:
                    decoded = base64.b64decode(alert_text).decode('utf-8')
                    
                    # Check if it's RECORD or TIMELAPSE failure
                    is_timelapse = 'TIMELAPSE' in decoded or 'Timelapse' in decoded
                    
                    # Extract slot time from decoded text
                    # Format: <b>Slot:</b> 2026-01-04 01:00 - 01:15
                    slot_match = re.search(r'<b>Slot:</b>\s*(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})\s*-\s*(\d{2}:\d{2})', decoded)
                    if slot_match:
                        date_str = slot_match.group(1)
                        start_time_str = slot_match.group(2)
                        end_time_str = slot_match.group(3)
                        
                        # Parse to timestamps
                        start_dt = datetime.strptime(f"{date_str} {start_time_str}", "%Y-%m-%d %H:%M")
                        
                        # Handle end time that might be on next day
                        end_dt = datetime.strptime(f"{date_str} {end_time_str}", "%Y-%m-%d %H:%M")
                        if end_dt < start_dt:
                            end_dt += timedelta(days=1)
                        
                        fail_start = int(start_dt.timestamp())
                        fail_end = int(end_dt.timestamp())
                        
                        # Only add if within time range
                        if fail_start <= end_ts and fail_end >= start_ts:
                            failure_block = {
                                'start': fail_start,
                                'end': fail_end,
                                'status': 'failed',
                                'created_at': row['created_at'],
                                'type': 'Timelapse' if is_timelapse else 'Record',
                                'start_time': start_dt.strftime('%Y-%m-%d %H:%M:%S'),
                                'end_time': end_dt.strftime('%Y-%m-%d %H:%M:%S'),
                                'duration': parse_duration(fail_end - fail_start),
                                'error': decoded[:200] if decoded else 'Unknown error'
                            }
                            
                            # Add to appropriate timeline
                            if is_timelapse:
                                timeline_data[camera]['timelapses'].append(failure_block)
                            else:
                                timeline_data[camera]['records'].append(failure_block)
                except Exception as e:
                    # If parsing fails, skip this alert
                    pass
        
        conn.close()
        
        return jsonify({
            'success': True,
            'timeline': timeline_data,
            'time_range': {
                'start': start_ts,
                'end': end_ts
            }
        })
        
    except Exception as e:
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500

if __name__ == '__main__':
    print(f"Starting Frigate Telegram Record Dashboard on port {PORT}")
    print(f"Database: {DB_FILE}")
    app.run(host='0.0.0.0', port=PORT, debug=False)
