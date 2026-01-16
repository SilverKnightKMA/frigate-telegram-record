from datetime import datetime, timedelta
import pytz
from flask import Flask, render_template, jsonify, request
import common

app = Flask(__name__)

# --- Routes ---

@app.route('/')
def index():
    return render_template('dashboard.html')

@app.route('/api/overview')
def get_overview():
    conn = common.get_db_connection()
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
                'last_update': common.format_timestamp(last_update)
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

@app.route('/api/timeline_stats')
def get_timeline_stats():
    """Get statistics for a specific time range (used by timeline tab)"""
    conn = common.get_db_connection()
    if not conn: return jsonify({'error': 'Database connect failed'}), 500
    cursor = conn.cursor()

    start_ts = request.args.get('start', type=float)
    end_ts = request.args.get('end', type=float)

    if not start_ts or not end_ts:
        return jsonify({'error': 'start and end parameters required'}), 400

    def get_time_grouping(start_ts, end_ts):
        duration_hours = (end_ts - start_ts) / 3600

        if duration_hours <= 6:
            sql_expr = "(start_ts / 900) * 900"
            label_format = "%H:%M"
            granularity = "15min"
        elif duration_hours <= 24:
            sql_expr = "strftime('%Y-%m-%d %H:00', start_ts, 'unixepoch', 'localtime')"
            label_format = "%H:00"
            granularity = "hour"
        elif duration_hours <= 720:
            sql_expr = "date(start_ts, 'unixepoch', 'localtime')"
            label_format = "%d/%m"
            granularity = "day"
        elif duration_hours <= 2160:
            sql_expr = "strftime('%Y-W%W', start_ts, 'unixepoch', 'localtime')"
            label_format = "W%W"
            granularity = "week"
        else:
            sql_expr = "strftime('%Y-%m', start_ts, 'unixepoch', 'localtime')"
            label_format = "%m/%Y"
            granularity = "month"

        return sql_expr, label_format, granularity

    try:
        sql_expr, label_format, granularity = get_time_grouping(start_ts, end_ts)

        query_daily = f"""
            SELECT 
                {sql_expr} as time_bucket,
                SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END) as success,
                SUM(CASE WHEN status = 'FAILED' THEN 1 ELSE 0 END) as failed
            FROM events
            WHERE start_ts >= ? AND start_ts <= ?
            GROUP BY time_bucket
            ORDER BY time_bucket ASC
        """
        daily_stats = cursor.execute(query_daily, (start_ts, end_ts)).fetchall()

        query_reasons = """
            SELECT fail_type, COUNT(*) as count 
            FROM events 
            WHERE status = 'FAILED' AND start_ts >= ? AND start_ts <= ?
            GROUP BY fail_type
        """
        fail_reasons = cursor.execute(query_reasons, (start_ts, end_ts)).fetchall()

        return jsonify({
            'charts': {
                'daily': [{'label': datetime.fromtimestamp(row['time_bucket']).strftime(label_format), 'success': row['success'], 'failed': row['failed']} for row in daily_stats],
                'granularity': granularity,
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
    conn = common.get_db_connection()
    if not conn: return jsonify({'error': 'Database connect failed'}), 500
    cursor = conn.cursor()

    start_ts_arg = request.args.get('start', type=float)
    end_ts_arg = request.args.get('end', type=float)
    date_str = request.args.get('date')

    if start_ts_arg and end_ts_arg:
        ts_start = start_ts_arg
        ts_end = end_ts_arg
    else:
        target_date = date_str if date_str else datetime.now(common.LOCAL_TZ).strftime('%Y-%m-%d')
        try:
            local_dt_start = datetime.strptime(target_date, '%Y-%m-%d')
            local_dt_start = common.LOCAL_TZ.localize(local_dt_start)
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
                    'sample_msg': common.decode_message(r['message'])
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
    conn = common.get_db_connection()
    if not conn: return jsonify({'error': 'Database connect failed'}), 500
    cursor = conn.cursor()

    # --- Filters ---
    statuses = request.args.getlist('status')
    cameras = request.args.getlist('camera')
    event_types = request.args.getlist('type')
    fail_types = request.args.getlist('error')
    alert_sent_vals = request.args.getlist('alert_sent')
    
    search_text = request.args.get('search', '')
    id_search = request.args.get('id_search', '')
    
    created_from = common.parse_frontend_datetime(request.args.get('created_from'))
    created_to = common.parse_frontend_datetime(request.args.get('created_to'))
    video_from = common.parse_frontend_datetime(request.args.get('video_from'))
    video_to = common.parse_frontend_datetime(request.args.get('video_to'))
    
    dur_min = request.args.get('dur_min', type=float)
    dur_max = request.args.get('dur_max', type=float)
    size_min_mb = request.args.get('size_min', type=float)
    size_max_mb = request.args.get('size_max', type=float)
    
    proc_min = request.args.get('process_min', type=float)
    proc_max = request.args.get('process_max', type=float)

    # Pagination
    limit = request.args.get('limit', 50, type=int)
    offset = request.args.get('offset', 0, type=int)

    # SQL Building
    where_clauses = ["1=1"]
    params = []

    # 1. Multi-selects
    if statuses and 'all' not in statuses:
        placeholders = ','.join(['?'] * len(statuses))
        where_clauses.append(f"status IN ({placeholders})")
        params.extend([s.upper() for s in statuses])
        
    if cameras and 'all' not in cameras:
        placeholders = ','.join(['?'] * len(cameras))
        where_clauses.append(f"camera IN ({placeholders})")
        params.extend(cameras)
        
    if event_types and 'all' not in event_types:
        placeholders = ','.join(['?'] * len(event_types))
        where_clauses.append(f"type IN ({placeholders})")
        params.extend(event_types)
        
    if fail_types and 'all' not in fail_types:
        placeholders = ','.join(['?'] * len(fail_types))
        where_clauses.append(f"fail_type IN ({placeholders})")
        params.extend(fail_types)

    if alert_sent_vals and 'all' not in alert_sent_vals:
        placeholders = ','.join(['?'] * len(alert_sent_vals))
        where_clauses.append(f"alert_sent IN ({placeholders})")
        params.extend(alert_sent_vals)

    # 2. Text Search
    if search_text:
        where_clauses.append("(camera LIKE ? OR fail_type LIKE ? OR search_text LIKE ?)")
        params.extend([f"%{search_text}%", f"%{search_text}%", f"%{search_text}%"])
        
    if id_search:
        where_clauses.append("(CAST(id AS TEXT) LIKE ? OR CAST(msg_id AS TEXT) LIKE ?)")
        params.extend([f"%{id_search}%", f"%{id_search}%"])

    # 3. Ranges
    if created_from:
        where_clauses.append("created_at >= ?")
        params.append(created_from)
    if created_to:
        where_clauses.append("created_at <= ?")
        params.append(created_to)
        
    if video_from:
        where_clauses.append("start_ts >= ?")
        params.append(video_from)
    if video_to:
        where_clauses.append("end_ts <= ?")
        params.append(video_to)

    if dur_min is not None:
        where_clauses.append("duration >= ?")
        params.append(dur_min)
    if dur_max is not None:
        where_clauses.append("duration <= ?")
        params.append(dur_max)
        
    if size_min_mb is not None:
        where_clauses.append("filesize >= ?")
        params.append(size_min_mb * 1024 * 1024)
    if size_max_mb is not None:
        where_clauses.append("filesize <= ?")
        params.append(size_max_mb * 1024 * 1024)
        
    if proc_min is not None:
        where_clauses.append("process_sec >= ?")
        params.append(proc_min)
    if proc_max is not None:
        where_clauses.append("process_sec <= ?")
        params.append(proc_max)

    where_str = " AND ".join(where_clauses)

    try:
        count_query = f"SELECT COUNT(*) FROM events WHERE {where_str}"
        total_records = cursor.execute(count_query, params).fetchone()[0]

        data_query = f"""
            SELECT id, camera, type, status, created_at, message, search_text, 
                   duration, filesize, fail_type, start_ts, end_ts, process_sec, msg_id, alert_sent
            FROM events 
            WHERE {where_str}
            ORDER BY created_at DESC LIMIT ? OFFSET ?
        """
        data_params = params + [limit, offset]
        
        rows = cursor.execute(data_query, data_params).fetchall()
        data = []
        for r in rows:
            size_mb = (r['filesize'] or 0) / (1024 * 1024)
            display_msg = r['search_text'] if r['search_text'] else common.decode_message(r['message'])

            data.append({
                'id': r['id'],
                'time': common.format_timestamp(r['created_at']),
                'camera': r['camera'],
                'type': r['type'],
                'status': r['status'],
                'video_start': common.format_timestamp(r['start_ts']),
                'video_end': common.format_timestamp(r['end_ts']),
                'duration': f"{r['duration']}s" if r['duration'] else "-",
                'size': f"{size_mb:.2f} MB",
                'process_sec': f"{r['process_sec']}s" if r['process_sec'] else "-",
                'error_type': r['fail_type'] or "-",
                'msg_id': r['msg_id'] or "-",
                'alert_sent': "Yes" if r['alert_sent'] else "No",
                'message': display_msg
            })
        
        return jsonify({'data': data, 'count': len(data), 'total': total_records})
    finally:
        conn.close()

@app.route('/api/performance')
def get_performance():
    conn = common.get_db_connection()
    if not conn: return jsonify({'error': 'Database connect failed'}), 500
    cursor = conn.cursor()
    
    start_ts = request.args.get('start', type=float)
    end_ts = request.args.get('end', type=float)
    
    # Fallback to last 7 days if no params provided
    if not start_ts or not end_ts:
        end_ts = datetime.now(pytz.utc).timestamp()
        start_ts = end_ts - (7 * 24 * 60 * 60)

    try:
        # Get aggregated performance stats by type
        query_perf = """
            SELECT 
                CASE WHEN type LIKE '%timelapse%' THEN 'Timelapse' ELSE 'Record' END as category,
                COUNT(*) as count,
                AVG(duration) as avg_duration,
                MIN(duration) as min_duration,
                MAX(duration) as max_duration,
                AVG(process_sec) as avg_process,
                MIN(process_sec) as min_process,
                MAX(process_sec) as max_process,
                AVG(CASE WHEN duration > 0 THEN process_sec * 1.0 / duration ELSE 0 END) as avg_ratio
            FROM events 
            WHERE status = 'SUCCESS' AND start_ts >= ? AND start_ts <= ?
            GROUP BY category
        """
        rows = cursor.execute(query_perf, (start_ts, end_ts)).fetchall()
        
        perf_data = {
            'categories': [],
            'count': [],
            'avg_duration': [],
            'avg_process': [],
            'ratio': []
        }
        for r in rows:
            perf_data['categories'].append(r['category'])
            perf_data['count'].append(r['count'])
            perf_data['avg_duration'].append(round(r['avg_duration'] or 0, 1))
            perf_data['avg_process'].append(round(r['avg_process'] or 0, 1))
            perf_data['ratio'].append(round((r['avg_ratio'] or 0) * 100, 2))  # ratio as percentage

        # Adaptive Storage Chart Query
        granularity = '15min'  # Example granularity, can be parameterized
        query_store = f"""
            SELECT 
                strftime('%H:%M', start_ts, 'unixepoch', 'localtime') as time_bucket,
                CASE WHEN type LIKE '%timelapse%' THEN 'timelapse' ELSE 'record' END as type,
                SUM(filesize) as total
            FROM events 
            WHERE start_ts >= ? AND start_ts <= ?
            GROUP BY time_bucket, type 
            ORDER BY time_bucket ASC
        """
        rows_store = cursor.execute(query_store, (start_ts, end_ts)).fetchall()

        # Aggregate by time bucket and type
        storage_data = {
            'labels': [],
            'record': [],
            'timelapse': [],
            'granularity': granularity
        }
        bucket_totals = {}
        for r in rows_store:
            bucket = r['time_bucket']
            if bucket not in bucket_totals:
                bucket_totals[bucket] = {'record': 0, 'timelapse': 0}
            size_mb = round((r['total'] or 0) / (1024 * 1024), 2)
            bucket_totals[bucket][r['type']] += size_mb

        storage_data['labels'] = list(bucket_totals.keys())
        storage_data['record'] = [round(v['record'], 2) for v in bucket_totals.values()]
        storage_data['timelapse'] = [round(v['timelapse'], 2) for v in bucket_totals.values()]

        return jsonify({'performance': perf_data, 'storage': storage_data})
    finally:
        conn.close()

@app.route('/api/filters')
def get_filters():
    conn = common.get_db_connection()
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

@app.route('/api/camera_performance')
def get_camera_performance():
    """Fetch camera performance data for the specified time range."""
    conn = common.get_db_connection()
    if not conn:
        return jsonify({'error': 'Database connect failed'}), 500

    cursor = conn.cursor()

    start_ts = request.args.get('start', type=float)
    end_ts = request.args.get('end', type=float)

    if not start_ts or not end_ts:
        return jsonify({'error': 'start and end parameters required'}), 400

    try:
        query = """
            SELECT 
                camera,
                COUNT(*) as total_jobs,
                SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END) as success_count,
                SUM(CASE WHEN status = 'FAILED' THEN 1 ELSE 0 END) as failed_count,
                ROUND(SUM(CASE WHEN status = 'SUCCESS' THEN 1.0 ELSE 0 END) / COUNT(*) * 100, 1) as success_rate,
                SUM(filesize) as total_bytes,
                ROUND(AVG(process_sec), 2) as avg_process_sec,
                ROUND(AVG(duration), 1) as avg_duration
            FROM events
            WHERE start_ts >= ? AND start_ts <= ?
            GROUP BY camera
            ORDER BY total_jobs DESC
        """
        
        results = cursor.execute(query, (start_ts, end_ts)).fetchall()

        cameras = [
            {
                'name': row['camera'],
                'total': row['total_jobs'],
                'success': row['success_count'],
                'failed': row['failed_count'],
                'success_rate': row['success_rate'],
                'storage_mb': round(row['total_bytes'] / 1024 / 1024, 2),
                'avg_process': row['avg_process_sec'],
                'avg_duration': row['avg_duration']
            }
            for row in results
        ]

        return jsonify({'cameras': cameras})
    finally:
        conn.close()

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=common.PORT, debug=False)