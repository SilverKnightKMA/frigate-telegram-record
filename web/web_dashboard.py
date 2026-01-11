#!/usr/bin/env python3
"""
Frigate Telegram Record - Web Dashboard (High Performance)
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
    try:
        conn = get_db_connection()
        if not conn: return jsonify({'success': False}), 500
        cursor = conn.cursor()
        
        cameras = {}
        # Success Stats
        cursor.execute("SELECT camera, COUNT(*) as total, MAX(created_at) as last_ts, SUM(end_ts - start_ts) as dur FROM sent_ranges GROUP BY camera")
        for row in cursor.fetchall():
            cameras[row['camera']] = {
                'name': row['camera'], 'success_count': row['total'], 'failed_count': 0, 'timelapse_count': 0,
                'total_duration': parse_duration(row['dur']),
                'last_record': datetime.fromtimestamp(row['last_ts']).strftime('%Y-%m-%d %H:%M') if row['last_ts'] else '-'
            }
            
        # Fail/Timelapse Counts
        for table, key in [('timelapse_history', 'timelapse_count'), ('alert_history', 'failed_count')]:
            cursor.execute(f"SELECT camera, COUNT(*) as total FROM {table} GROUP BY camera")
            for row in cursor.fetchall():
                c = row['camera']
                if c not in cameras: cameras[c] = {'name': c, 'success_count':0, 'failed_count':0, 'timelapse_count':0, 'total_duration':'0s', 'last_record':'-'}
                cameras[c][key] = row['total']

        # Overall
        yesterday = int((datetime.now() - timedelta(days=1)).timestamp())
        stats = {
            'total_cameras': len(cameras),
            'recent_records_24h': cursor.execute("SELECT COUNT(*) FROM sent_ranges WHERE created_at > ?", (yesterday,)).fetchone()[0],
            'recent_failures_24h': cursor.execute("SELECT COUNT(*) FROM alert_history WHERE created_at > ?", (yesterday,)).fetchone()[0],
        }
        conn.close()
        return jsonify({'success': True, 'cameras': list(cameras.values()), 'overall': stats})
    except Exception as e: return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/visualization')
def get_visualization_data():
    try:
        conn = get_db_connection()
        if not conn: return jsonify({'success': False}), 500
        cursor = conn.cursor()
        
        # Lấy dữ liệu 24h qua
        start_time = int((datetime.now() - timedelta(hours=24)).timestamp())
        
        # 1. LẤY RAW DATA (Không LIMIT quá thấp nữa, vì ta sẽ gộp lại)
        # Lấy tối đa 5000 dòng để đảm bảo không bỏ sót, sau đó Python sẽ nén lại còn vài chục dòng
        cursor.execute("""
            SELECT camera, start_ts, end_ts 
            FROM sent_ranges 
            WHERE start_ts > ? 
            ORDER BY camera, start_ts ASC
            LIMIT 5000
        """, (start_time,))
        
        raw_rows = cursor.fetchall()
        
        # 2. THUẬT TOÁN GỘP (DOWNSAMPLING)
        # Logic: Nếu (Start hiện tại) <= (End trước đó + tolerance), thì gộp chung.
        merged_data = {}
        tolerance = 30 # Cho phép sai số 30 giây (gap nhỏ hơn 30s coi như liền mạch)

        for row in raw_rows:
            cam = row['camera']
            start = row['start_ts']
            end = row['end_ts']

            if cam not in merged_data:
                merged_data[cam] = []

            # Lấy block cuối cùng của cam này
            if merged_data[cam]:
                last_block = merged_data[cam][-1]
                # Kiểm tra tính liên tục
                if start <= (last_block['end'] + tolerance):
                    # Gộp: Chỉ cần cập nhật thời gian kết thúc của block cũ
                    # (Lấy max để đề phòng dữ liệu chồng lấn)
                    last_block['end'] = max(last_block['end'], end)
                else:
                    # Có gap lớn -> Tạo block mới
                    merged_data[cam].append({'start': start, 'end': end})
            else:
                # Block đầu tiên
                merged_data[cam].append({'start': start, 'end': end})

        # 3. CHUYỂN ĐỔI SANG FORMAT APEXCHARTS
        timeline_series = []
        for cam, blocks in merged_data.items():
            data_points = []
            for b in blocks:
                data_points.append({
                    'x': cam,
                    'y': [b['start'] * 1000, b['end'] * 1000],
                    'fillColor': '#00E396' # Xanh lá
                })
            timeline_series.append({'name': cam, 'data': data_points})

        # 4. XỬ LÝ LỖI (Vẫn giữ Limit thấp để highlight điểm lỗi)
        cursor.execute("""
            SELECT camera, created_at, alert_text 
            FROM alert_history 
            WHERE created_at > ?
            ORDER BY created_at DESC 
            LIMIT 200
        """, (start_time,))
        
        error_dist = {}
        
        # Thêm các điểm lỗi vào timeline (Màu đỏ)
        # Ta tìm series tương ứng để chèn vào
        for row in cursor.fetchall():
            cam = row['camera']
            ts = row['created_at']
            
            # Tìm series của camera này
            cam_series = next((item for item in timeline_series if item["name"] == cam), None)
            if not cam_series:
                cam_series = {'name': cam, 'data': []}
                timeline_series.append(cam_series)
            
            # Thêm điểm đỏ (độ rộng 1 phút để dễ nhìn)
            cam_series['data'].append({
                'x': cam,
                'y': [ts * 1000, (ts + 60) * 1000],
                'fillColor': '#FF4560'
            })

            # Phân loại lỗi cho biểu đồ tròn
            try: alert = base64.b64decode(row['alert_text']).decode('utf-8')
            except: alert = str(row['alert_text'])
            
            cat = "Other"
            if "404" in alert: cat = "404 Not Found"
            elif "Validation" in alert: cat = "Validation Failed"
            elif "Partial" in alert: cat = "Partial Recording"
            elif "Network" in alert: cat = "Network Error"
            elif "Timelapse" in alert: cat = "Timelapse Error"
            
            error_dist[cat] = error_dist.get(cat, 0) + 1

        conn.close()
        
        return jsonify({
            'success': True, 
            'timeline': timeline_series, 
            'errors': {
                'labels': list(error_dist.keys()), 
                'series': list(error_dist.values())
            }
        })

    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500

@app.route('/api/recent_activity')
def get_recent_activity():
    try:
        conn = get_db_connection()
        if not conn: return jsonify({'success': False}), 500
        cursor = conn.cursor()
        
        acts = []
        # Fetch more items (200) to allow client-side filtering
        cursor.execute("SELECT camera, created_at, 'Record' as type, 'success' as status, (start_ts || '-' || end_ts) as det FROM sent_ranges ORDER BY created_at DESC LIMIT 200")
        for r in cursor.fetchall(): acts.append(dict(r))

        cursor.execute("SELECT camera, created_at, 'Alert' as type, 'failed' as status, alert_text FROM alert_history ORDER BY created_at DESC LIMIT 200")
        for r in cursor.fetchall():
            d = dict(r)
            try: d['det'] = base64.b64decode(r['alert_text']).decode('utf-8')
            except: d['det'] = "Error content unreadable"
            acts.append(d)

        cursor.execute("SELECT camera, created_at, 'Timelapse' as type, 'success' as status, range_id as det FROM timelapse_history ORDER BY created_at DESC LIMIT 50")
        for r in cursor.fetchall(): acts.append(dict(r))
            
        acts.sort(key=lambda x: x['created_at'], reverse=True)
        
        # Format for frontend
        final = []
        for a in acts[:300]: # Return top 300 mixed
            final.append({
                'camera': a['camera'],
                'type': a['type'],
                'status': a['status'],
                'timestamp': datetime.fromtimestamp(a['created_at']).strftime('%Y-%m-%d %H:%M:%S'),
                'time_short': datetime.fromtimestamp(a['created_at']).strftime('%H:%M'),
                'details': a['det']
            })
            
        conn.close()
        return jsonify({'success': True, 'activities': final})
    except Exception as e: return jsonify({'success': False, 'error': str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=PORT, debug=False)