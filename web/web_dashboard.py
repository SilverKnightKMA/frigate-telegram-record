import os
import sys
import sqlite3
import base64
import pytz
from datetime import datetime, timedelta
from flask import Flask, render_template, jsonify, request

app = Flask(__name__)

# System Configuration
DB_FILE = os.path.abspath(os.environ.get('DB_FILE', '/app/data/video_history.sqlite'))
PORT = int(os.environ.get('WEB_PORT', '8080'))
LOCAL_TZ = pytz.timezone('Asia/Ho_Chi_Minh')

def diagnose_db_issues(db_path, error_msg):
    try:
        sys.stderr.write(f"\n[DIAGNOSTICS] Connection failed: {error_msg}\n")
        if os.path.exists(db_path):
            st = os.stat(db_path)
            sys.stderr.write(f"[DIAGNOSTICS] DB File: {db_path} | Size: {st.st_size} bytes | Mode: {oct(st.st_mode)}\n")
            sys.stderr.write(f"[DIAGNOSTICS] Access: R_OK={os.access(db_path, os.R_OK)} | W_OK={os.access(db_path, os.W_OK)}\n")
        else:
            sys.stderr.write(f"[DIAGNOSTICS] CRITICAL: File not found at {db_path}\n")
        sys.stderr.flush()
    except Exception:
        pass

def get_db_connection():
    if not os.path.exists(DB_FILE):
        return None
    conn = None
    try:
        db_uri = f"file:{DB_FILE}?mode=ro&immutable=1"
        conn = sqlite3.connect(db_uri, uri=True, timeout=10.0)
        conn.row_factory = sqlite3.Row
        conn.execute("SELECT 1 FROM events LIMIT 1")
        return conn
    except sqlite3.OperationalError as e:
        diagnose_db_issues(DB_FILE, str(e))
        if conn: conn.close()
        return None
    except Exception as e:
        sys.stderr.write(f"Unexpected DB Error: {e}\n")
        if conn: conn.close()
        return None

def format_timestamp(ts):
    if not ts: return ""
    dt_utc = datetime.fromtimestamp(ts, pytz.utc)
    dt_local = dt_utc.astimezone(LOCAL_TZ)
    return dt_local.strftime('%Y-%m-%d %H:%M:%S')

def decode_message(b64_msg):
    # Still kept for display purposes if needed, 
    # or strictly for backward compatibility with old rows lacking search_text
    if not b64_msg: return ""
    try:
        return base64.b64decode(b64_msg).decode('utf-8', errors='replace')
    except Exception:
        return str(b64_msg)

# --- Routes ---

@app.route('/')
def index():
    return render_template('dashboard.html')

@app.route('/api/overview')
def get_overview():
    conn = get_db_connection()
    if not conn: return jsonify({'error': 'Database connect failed', 'details': 'Check logs'}), 500
    
    cursor = conn.cursor()
    days = request.args.get('days', 1, type=int)
    cutoff_ts = (datetime.now(pytz.utc) - timedelta(days=days)).timestamp()

    try:
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
        
        last_update_row = cursor.execute("SELECT MAX(created_at) FROM events").fetchone()
        last_update = last_update_row[0] if last_update_row else None

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

        query_reasons = """
            SELECT fail_type, COUNT(*) as count 
            FROM events 
            WHERE status = 'FAILED' AND created_at > ? 
            GROUP BY fail_type
        """
        fail_reasons = cursor.execute(query_reasons, (cutoff_ts,)).fetchall()

        total = metrics['total_jobs'] or 0
        success_count = metrics['success_jobs'] or 0
        success_rate = round((success_count / total * 100), 1) if total > 0 else 0
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
    conn = get_db_connection()
    if not conn: return jsonify({'error': 'Database connect failed'}), 500
    cursor = conn.cursor()

    start_ts_arg = request.args.get('start', type=float)
    end_ts_arg = request.args.get('end', type=float)
    date_str = request.args.get('date')

    if start_ts_arg and end_ts_arg:
        ts_start = start_ts_arg
        ts_end = end_ts_arg
    else:
        target_date = date_str if date_str else datetime.now(LOCAL_TZ).strftime('%Y-%m-%d')
        try:
            local_dt_start = datetime.strptime(target_date, '%Y-%m-%d')
            local_dt_start = LOCAL_TZ.localize(local_dt_start)
            ts_start = local_dt_start.timestamp()
            ts_end = (local_dt_start + timedelta(days=1)).timestamp()
        except ValueError:
            return jsonify({'error': 'Invalid date format'}), 400

    try:
        TARGET_BLOCKS = 300
        view_duration = ts_end - ts_start
        dynamic_threshold = max(30.0, view_duration / float(TARGET_BLOCKS))

        query = """
            SELECT camera, type, start_ts, end_ts, status, fail_type, message
            FROM events 
            WHERE (status = 'SUCCESS' OR status = 'FAILED')
            AND start_ts >= ? AND end_ts <= ?
            ORDER BY camera, type, start_ts
        """
        rows = cursor.execute(query, (ts_start, ts_end)).fetchall()
        
        grouped_data = {}
        
        for r in rows:
            cam = r['camera']
            evt_type = r['type'] if r['type'] else 'record'
            row_key = f"{cam} ({evt_type})"
            
            if row_key not in grouped_data:
                grouped_data[row_key] = []
            
            status_code = 1 if r['status'] == 'SUCCESS' else 0
            fail_type = (r['fail_type'] or "Unknown") if status_code == 0 else None
            
            meta = None
            if status_code == 0:
                meta = {
                    'count': 1,
                    'breakdown': {fail_type: 1},
                    'sample_msg': decode_message(r['message'])
                }

            current_block = [
                r['start_ts'] * 1000, 
                r['end_ts'] * 1000, 
                status_code,
                meta
            ]

            last_idx = len(grouped_data[row_key]) - 1
            if last_idx >= 0:
                last_block = grouped_data[row_key][last_idx]
                prev_status = last_block[2]
                prev_end = last_block[1] / 1000
                curr_start = r['start_ts']

                if status_code == prev_status and (curr_start - prev_end) <= dynamic_threshold:
                    last_block[1] = current_block[1]
                    if status_code == 0:
                        last_block[3]['count'] += 1
                        current_count = last_block[3]['breakdown'].get(fail_type, 0)
                        last_block[3]['breakdown'][fail_type] = current_count + 1
                else:
                    grouped_data[row_key].append(current_block)
            else:
                grouped_data[row_key].append(current_block)

        return jsonify({'data': grouped_data})
    finally:
        conn.close()

@app.route('/api/logs')
def get_logs():
    conn = get_db_connection()
    if not conn: return jsonify({'error': 'Database connect failed'}), 500
    cursor = conn.cursor()

    status = request.args.get('status', 'all')
    camera = request.args.get('camera', 'all')
    event_type = request.args.get('type', 'all')
    fail_type = request.args.get('error', 'all')
    search = request.args.get('search', '')
    limit = request.args.get('limit', 50, type=int)
    offset = request.args.get('offset', 0, type=int)

    # Note: Added search_text to the SELECT for potential use
    base_query = """
        SELECT id, camera, type, status, created_at, message, search_text, duration, filesize, fail_type 
        FROM events WHERE 1=1
    """
    params = []

    if status != 'all':
        base_query += " AND status = ?"
        params.append(status.upper())
    if camera != 'all':
        base_query += " AND camera = ?"
        params.append(camera)
    if event_type != 'all':
        base_query += " AND type = ?"
        params.append(event_type)
    if fail_type != 'all':
        base_query += " AND fail_type = ?"
        params.append(fail_type)
    
    if search:
        # PURE NATIVE SQL SEARCH
        # Using the plain text column 'search_text' instead of decoding on-the-fly
        base_query += " AND (camera LIKE ? OR fail_type LIKE ? OR search_text LIKE ?)"
        params.extend([f"%{search}%", f"%{search}%", f"%{search}%"])

    base_query += " ORDER BY created_at DESC LIMIT ? OFFSET ?"
    params.extend([limit, offset])

    try:
        rows = cursor.execute(base_query, params).fetchall()
        data = []
        for r in rows:
            size_mb = (r['filesize'] or 0) / (1024 * 1024)
            
            # Prioritize using search_text for display if available to avoid Python decoding
            display_msg = r['search_text'] if r['search_text'] else decode_message(r['message'])

            data.append({
                'id': r['id'],
                'time': format_timestamp(r['created_at']),
                'camera': r['camera'],
                'type': r['type'],
                'status': r['status'],
                'duration': f"{r['duration']}s" if r['duration'] else "-",
                'size': f"{size_mb:.2f} MB",
                'error_type': r['fail_type'] or "-",
                'message': display_msg
            })
        return jsonify({'data': data, 'count': len(data)})
    finally:
        conn.close()

@app.route('/api/performance')
def get_performance():
    conn = get_db_connection()
    if not conn: return jsonify({'error': 'Database connect failed'}), 500
    cursor = conn.cursor()
    
    cutoff_ts = (datetime.now(pytz.utc) - timedelta(days=7)).timestamp()

    try:
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

        query_store = """
            SELECT date(created_at, 'unixepoch', 'localtime') as d, SUM(filesize) as total
            FROM events WHERE created_at > ?
            GROUP BY d ORDER BY d ASC
        """
        rows_store = cursor.execute(query_store, (cutoff_ts,)).fetchall()
        store_data = {
            'dates': [r['d'] for r in rows_store],
            'sizes': [round((r['total'] or 0)/(1024*1024), 2) for r in rows_store]
        }
        return jsonify({'performance': perf_data, 'storage': store_data})
    finally:
        conn.close()

@app.route('/api/filters')
def get_filters():
    conn = get_db_connection()
    if not conn: return jsonify({'cameras': [], 'types': [], 'errors': []})
    try:
        cams = conn.execute("SELECT DISTINCT camera FROM events ORDER BY camera").fetchall()
        types = conn.execute("SELECT DISTINCT type FROM events ORDER BY type").fetchall()
        errors = conn.execute("SELECT DISTINCT fail_type FROM events WHERE fail_type IS NOT NULL ORDER BY fail_type").fetchall()
        
        return jsonify({
            'cameras': [c[0] for c in cams],
            'types': [t[0] for t in types if t[0]],
            'errors': [e[0] for e in errors]
        })
    finally:
        conn.close()

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=PORT, debug=False)