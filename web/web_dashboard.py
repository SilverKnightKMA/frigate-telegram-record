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
        # First, get overall metrics for the time range
        query_metrics = """
            SELECT 
                COUNT(*) as total_jobs,
                SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END) as success_jobs,
                SUM(CASE WHEN status = 'FAILED' THEN 1 ELSE 0 END) as failed_jobs,
                SUM(filesize) as total_storage,
                AVG(process_sec) as avg_process,
                AVG(CASE WHEN type NOT LIKE '%timelapse%' THEN process_sec END) as avg_process_record,
                AVG(CASE WHEN type LIKE '%timelapse%' THEN process_sec END) as avg_process_timelapse
            FROM events 
            WHERE start_ts >= ? AND start_ts <= ?
        """
        metrics = cursor.execute(query_metrics, (start_ts, end_ts)).fetchone()
        
        total = metrics['total_jobs'] or 0
        success_count = metrics['success_jobs'] or 0
        failed_count = metrics['failed_jobs'] or 0
        success_rate = round((success_count / total * 100), 1) if total > 0 else 0
        storage_bytes = metrics['total_storage'] or 0
        storage_fmt = f"{storage_bytes/1024**3:.2f} GB" if storage_bytes > 1024**3 else f"{storage_bytes/1024**2:.2f} MB"

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

        # Storage data with same time grouping as daily stats
        query_storage = f"""
            SELECT 
                {sql_expr} as time_bucket,
                CASE WHEN type LIKE '%timelapse%' THEN 'timelapse' ELSE 'record' END as event_type,
                SUM(filesize) as total_bytes
            FROM events
            WHERE start_ts >= ? AND start_ts <= ?
            GROUP BY time_bucket, event_type
            ORDER BY time_bucket ASC
        """
        storage_rows = cursor.execute(query_storage, (start_ts, end_ts)).fetchall()
        
        # Aggregate storage by time bucket
        storage_by_bucket = {}
        for r in storage_rows:
            bucket = r['time_bucket']
            if bucket not in storage_by_bucket:
                storage_by_bucket[bucket] = {'record': 0, 'timelapse': 0}
            size_mb = round((r['total_bytes'] or 0) / (1024 * 1024), 2)
            storage_by_bucket[bucket][r['event_type']] += size_mb

        # Format labels based on granularity type
        def format_time_label(time_bucket, granularity, label_format):
            if granularity == "15min":
                # time_bucket is unix timestamp (integer)
                return datetime.fromtimestamp(time_bucket, tz=common.LOCAL_TZ).strftime(label_format)
            elif granularity == "hour":
                # time_bucket is "YYYY-MM-DD HH:00" string
                dt = datetime.strptime(time_bucket, "%Y-%m-%d %H:%M")
                return dt.strftime(label_format)
            elif granularity == "day":
                # time_bucket is "YYYY-MM-DD" string
                dt = datetime.strptime(time_bucket, "%Y-%m-%d")
                return dt.strftime(label_format)
            elif granularity == "week":
                # time_bucket is "YYYY-WWW" string, keep as-is
                return time_bucket.split('-')[1]  # Returns "W03" from "2026-W03"
            elif granularity == "month":
                # time_bucket is "YYYY-MM" string
                dt = datetime.strptime(time_bucket, "%Y-%m")
                return dt.strftime(label_format)
            return str(time_bucket)

        # Build aligned time labels for both charts
        time_labels = [format_time_label(row['time_bucket'], granularity, label_format) for row in daily_stats]
        
        # Build storage arrays aligned with time_labels
        storage_record = []
        storage_timelapse = []
        for row in daily_stats:
            bucket = row['time_bucket']
            bucket_data = storage_by_bucket.get(bucket, {'record': 0, 'timelapse': 0})
            storage_record.append(round(bucket_data['record'], 2))
            storage_timelapse.append(round(bucket_data['timelapse'], 2))

        return jsonify({
            'total': total,
            'success': success_count,
            'failed': failed_count,
            'success_rate': success_rate,
            'storage': storage_fmt,
            'avg_process': round(metrics['avg_process'] or 0, 2),
            'avg_process_record': round(metrics['avg_process_record'] or 0, 2),
            'avg_process_timelapse': round(metrics['avg_process_timelapse'] or 0, 2),
            'charts': {
                'daily': [{'label': format_time_label(row['time_bucket'], granularity, label_format), 'success': row['success'], 'failed': row['failed']} for row in daily_stats],
                'granularity': granularity,
                'time_labels': time_labels,
                'storage': {
                    'record': storage_record,
                    'timelapse': storage_timelapse
                },
                'reasons': {
                    'labels': [r['fail_type'] or 'Unknown' for r in fail_reasons],
                    'series': [r['count'] for r in fail_reasons]
                }
            }
        })
    finally:
        conn.close()

@app.route('/api/duration_distribution')
def get_duration_distribution():
    """Get duration distribution histogram for videos - separated by Record and Timelapse
    Record uses dynamic buckets, Timelapse shows exact seconds (since there aren't many different durations)"""
    conn = common.get_db_connection()
    if not conn: return jsonify({'error': 'Database connect failed'}), 500
    cursor = conn.cursor()

    start_ts = request.args.get('start', type=float)
    end_ts = request.args.get('end', type=float)

    if not start_ts or not end_ts:
        return jsonify({'error': 'start and end parameters required'}), 400

    try:
        # First, get min/max duration for each category to calculate dynamic buckets
        stats_query = """
            SELECT 
                CASE WHEN type LIKE '%timelapse%' THEN 'Timelapse' ELSE 'Record' END as category,
                MIN(duration) as min_dur,
                MAX(duration) as max_dur,
                COUNT(*) as total
            FROM events
            WHERE start_ts >= ? AND start_ts <= ? AND duration > 0
            GROUP BY category
        """
        stats_rows = cursor.execute(stats_query, (start_ts, end_ts)).fetchall()
        
        def format_duration(seconds):
            """Format seconds into human-readable string with detailed breakdown"""
            hours = seconds // 3600
            minutes = (seconds % 3600) // 60
            secs = seconds % 60

            formatted = ""
            if hours > 0:
                formatted += f"{hours}h"
            if minutes > 0 or hours > 0:  # Include minutes if hours > 0
                formatted += f"{minutes}m"
            if secs > 0 or (hours == 0 and minutes == 0):  # Include seconds if no hours and minutes
                formatted += f"{secs}s"

            return formatted
        
        def calculate_buckets_weighted(data, num_buckets=6):
            """Calculate dynamic bucket boundaries based on data range and weights (counts)."""
            if not data or len(data) == 0:
                return []

            # Sort data by duration
            data = sorted(data, key=lambda x: x['duration'])

            # Calculate total count
            total_count = sum(item['count'] for item in data)

            # Calculate target count per bucket
            target_count = total_count / num_buckets

            buckets = []
            current_bucket = []
            current_count = 0

            for item in data:
                current_bucket.append(item['duration'])
                current_count += item['count']

                # If current bucket reaches target count, finalize the bucket
                if current_count >= target_count:
                    buckets.append((min(current_bucket), max(current_bucket)))
                    current_bucket = []
                    current_count = 0

            # Add remaining items to the last bucket
            if current_bucket:
                buckets.append((min(current_bucket), max(current_bucket)))

            return buckets
        
        def get_bucket_data(category, buckets):
            """Get count data for each bucket"""
            if not buckets:
                return []
            
            # Build CASE statement for buckets
            case_parts = []
            for i, (start, end) in enumerate(buckets):
                case_parts.append(f"WHEN duration >= {start} AND duration < {end} THEN {i}")
            
            case_sql = "CASE " + " ".join(case_parts) + " END"
            
            query = f"""
                SELECT 
                    {case_sql} as bucket_idx,
                    COUNT(*) as count,
                    SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END) as success,
                    SUM(CASE WHEN status = 'FAILED' THEN 1 ELSE 0 END) as failed
                FROM events
                WHERE start_ts >= ? AND start_ts <= ? 
                    AND duration > 0
                    AND (CASE WHEN type LIKE '%timelapse%' THEN 'Timelapse' ELSE 'Record' END) = ?
                GROUP BY bucket_idx
                HAVING bucket_idx IS NOT NULL
                ORDER BY bucket_idx
            """
            rows = cursor.execute(query, (start_ts, end_ts, category)).fetchall()
            
            # Build result with bucket labels
            result = []
            row_map = {r['bucket_idx']: r for r in rows}
            
            for i, (start, end) in enumerate(buckets):
                label = f"{format_duration(start)}-{format_duration(end)}"
                if i in row_map:
                    r = row_map[i]
                    result.append({
                        'range': label,
                        'total': r['count'],
                        'success': r['success'],
                        'failed': r['failed']
                    })
                # Skip empty buckets
            
            return result
        
        def get_exact_duration_data(category):
            """Get exact duration counts (grouped by each second)"""
            query = """
                SELECT 
                    CAST(ROUND(duration) AS INTEGER) as duration_sec,
                    COUNT(*) as count,
                    SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END) as success,
                    SUM(CASE WHEN status = 'FAILED' THEN 1 ELSE 0 END) as failed
                FROM events
                WHERE start_ts >= ? AND start_ts <= ? 
                    AND duration > 0
                    AND (CASE WHEN type LIKE '%timelapse%' THEN 'Timelapse' ELSE 'Record' END) = ?
                GROUP BY duration_sec
                ORDER BY duration_sec
            """
            rows = cursor.execute(query, (start_ts, end_ts, category)).fetchall()
            
            result = []
            for r in rows:
                result.append({
                    'duration': r['duration_sec'],  # Changed 'range' to 'duration'
                    'count': r['count'],
                    'success': r['success'],
                    'failed': r['failed']
                })
            
            return result
        
        def get_duration_data_smart(category, min_dur, max_dur, max_entries=6):
            """Get duration data - ensure buckets are distributed based on duration and count weights"""
            # First, check how many distinct durations exist
            exact_data = get_exact_duration_data(category)

            # If 6 or fewer distinct durations, return exact data
            if len(exact_data) <= max_entries:
                return exact_data

            # Otherwise, calculate weighted buckets
            buckets = calculate_buckets_weighted(exact_data, num_buckets=max_entries)

            return get_bucket_data(category, buckets)
        
        # Process each category
        record_buckets = []
        timelapse_buckets = []
        
        for row in stats_rows:
            category = row['category']
            
            if category == 'Record':
                record_buckets = get_duration_data_smart('Record', row['min_dur'], row['max_dur'])
            else:
                # For Timelapse, also use smart logic
                timelapse_buckets = get_duration_data_smart('Timelapse', row['min_dur'], row['max_dur'])

        return jsonify({
            'record': record_buckets,
            'timelapse': timelapse_buckets
        })
    finally:
        conn.close()

@app.route('/api/peak_activity')
def get_peak_activity():
    """Get peak activity heatmap data"""
    conn = common.get_db_connection()
    if not conn: return jsonify({'error': 'Database connect failed'}), 500
    cursor = conn.cursor()

    start_ts = request.args.get('start', type=float)
    end_ts = request.args.get('end', type=float)

    if not start_ts or not end_ts:
        return jsonify({'error': 'start and end parameters required'}), 400

    try:
        duration_hours = (end_ts - start_ts) / 3600
        day_labels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        hour_labels = [f"{h:02d}:00" for h in range(24)]

        if duration_hours <= 24:
            # Group by hour only
            query = """
                SELECT 
                    CAST(strftime('%H', start_ts, 'unixepoch', 'localtime') AS INTEGER) as hour,
                    COUNT(*) as count,
                    SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END) as success,
                    SUM(CASE WHEN status = 'FAILED' THEN 1 ELSE 0 END) as failed
                FROM events
                WHERE start_ts >= ? AND start_ts <= ?
                GROUP BY hour
                ORDER BY hour
            """
            rows = cursor.execute(query, (start_ts, end_ts)).fetchall()
            data = [{'hour': r['hour'], 'count': r['count'], 'success': r['success'], 'failed': r['failed']} for r in rows]
            granularity = 'hour'
        else:
            # Group by day of week + hour for any time range >= 1 day
            # This shows the general pattern of activity
            query = """
                SELECT 
                    CAST(strftime('%w', start_ts, 'unixepoch', 'localtime') AS INTEGER) as day_of_week,
                    CAST(strftime('%H', start_ts, 'unixepoch', 'localtime') AS INTEGER) as hour,
                    COUNT(*) as count,
                    SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END) as success,
                    SUM(CASE WHEN status = 'FAILED' THEN 1 ELSE 0 END) as failed
                FROM events
                WHERE start_ts >= ? AND start_ts <= ?
                GROUP BY day_of_week, hour
                ORDER BY day_of_week, hour
            """
            rows = cursor.execute(query, (start_ts, end_ts)).fetchall()
            data = [{'day': r['day_of_week'], 'hour': r['hour'], 'count': r['count'], 'success': r['success'], 'failed': r['failed']} for r in rows]
            granularity = 'day_hour'

        return jsonify({
            'granularity': granularity,
            'data': data,
            'day_labels': day_labels,
            'hour_labels': hour_labels
        })
    finally:
        conn.close()

@app.route('/api/type_comparison')
def get_type_comparison():
    """Compare metrics between RECORD and TIMELAPSE event types"""
    conn = common.get_db_connection()
    if not conn: return jsonify({'error': 'Database connect failed'}), 500
    cursor = conn.cursor()

    start_ts = request.args.get('start', type=float)
    end_ts = request.args.get('end', type=float)

    if not start_ts or not end_ts:
        return jsonify({'error': 'start and end parameters required'}), 400

    try:
        query = """
            SELECT 
                type,
                COUNT(*) as total,
                SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END) as success,
                SUM(CASE WHEN status = 'FAILED' THEN 1 ELSE 0 END) as failed,
                ROUND(SUM(CASE WHEN status = 'SUCCESS' THEN 1.0 ELSE 0 END) / COUNT(*) * 100, 1) as success_rate,
                SUM(filesize) as total_bytes,
                ROUND(AVG(duration), 1) as avg_duration,
                ROUND(AVG(process_sec), 2) as avg_process
            FROM events
            WHERE start_ts >= ? AND start_ts <= ?
            GROUP BY type
        """
        rows = cursor.execute(query, (start_ts, end_ts)).fetchall()

        types = []
        for r in rows:
            total_bytes = r['total_bytes'] or 0
            types.append({
                'type': r['type'] or 'UNKNOWN',
                'total': r['total'],
                'success': r['success'],
                'failed': r['failed'],
                'success_rate': r['success_rate'] or 0,
                'storage_mb': round(total_bytes / (1024 * 1024), 2),
                'avg_duration': r['avg_duration'] or 0,
                'avg_process': r['avg_process'] or 0
            })

        return jsonify({'types': types})
    finally:
        conn.close()

@app.route('/api/processing_efficiency')
def get_processing_efficiency():
    """Get processing efficiency ratio (process_sec / duration)"""
    conn = common.get_db_connection()
    if not conn: return jsonify({'error': 'Database connect failed'}), 500
    cursor = conn.cursor()

    start_ts = request.args.get('start', type=float)
    end_ts = request.args.get('end', type=float)

    if not start_ts or not end_ts:
        return jsonify({'error': 'start and end parameters required'}), 400

    # Calculate previous period for comparison
    period_duration = end_ts - start_ts
    prev_start = start_ts - period_duration
    prev_end = start_ts

    try:
        query = """
            SELECT 
                camera,
                type,
                COUNT(*) as count,
                AVG(duration) as avg_duration,
                AVG(process_sec) as avg_process,
                ROUND(AVG(CAST(process_sec AS FLOAT) / NULLIF(duration, 0)), 3) as process_ratio
            FROM events
            WHERE start_ts >= ? AND start_ts <= ?
                AND status = 'SUCCESS'
                AND duration > 0
            GROUP BY camera, type
            ORDER BY process_ratio DESC
        """
        rows = cursor.execute(query, (start_ts, end_ts)).fetchall()

        efficiency = []
        for r in rows:
            efficiency.append({
                'camera': r['camera'],
                'type': r['type'] or 'UNKNOWN',
                'count': r['count'],
                'avg_duration': round(r['avg_duration'] or 0, 1),
                'avg_process': round(r['avg_process'] or 0, 2),
                'ratio': r['process_ratio'] or 0
            })

        # Calculate ratio separately for Record and Timelapse
        ratio_by_type_query = """
            SELECT 
                CASE WHEN type LIKE '%timelapse%' THEN 'timelapse' ELSE 'record' END as category,
                COUNT(*) as count,
                ROUND(AVG(CAST(process_sec AS FLOAT) / NULLIF(duration, 0)), 3) as avg_ratio
            FROM events
            WHERE start_ts >= ? AND start_ts <= ?
                AND status = 'SUCCESS'
                AND duration > 0
            GROUP BY category
        """
        ratio_rows = cursor.execute(ratio_by_type_query, (start_ts, end_ts)).fetchall()
        
        record_ratio = None
        timelapse_ratio = None
        record_count = 0
        timelapse_count = 0
        
        for r in ratio_rows:
            if r['category'] == 'record':
                record_ratio = r['avg_ratio'] or 0
                record_count = r['count']
            else:
                timelapse_ratio = r['avg_ratio'] or 0
                timelapse_count = r['count']

        # Calculate previous period ratio for comparison
        prev_ratio_rows = cursor.execute(ratio_by_type_query, (prev_start, prev_end)).fetchall()
        
        prev_record_ratio = None
        prev_timelapse_ratio = None
        for r in prev_ratio_rows:
            if r['category'] == 'record':
                prev_record_ratio = r['avg_ratio'] or 0
            else:
                prev_timelapse_ratio = r['avg_ratio'] or 0

        # Calculate percentage change for record
        ratio_pct_change = None
        if record_ratio is not None and prev_record_ratio is not None and prev_record_ratio != 0:
            ratio_pct_change = round(((record_ratio - prev_record_ratio) / prev_record_ratio) * 100, 1)
        elif record_ratio is not None and prev_record_ratio is None:
            ratio_pct_change = None  # No previous data to compare

        # Calculate percentage change for timelapse
        timelapse_ratio_pct_change = None
        if timelapse_ratio is not None and prev_timelapse_ratio is not None and prev_timelapse_ratio != 0:
            timelapse_ratio_pct_change = round(((timelapse_ratio - prev_timelapse_ratio) / prev_timelapse_ratio) * 100, 1)
        elif timelapse_ratio is not None and prev_timelapse_ratio is None:
            timelapse_ratio_pct_change = None  # No previous data to compare

        # Use record ratio as primary metric since timelapse has very different characteristics
        primary_ratio = record_ratio if record_ratio is not None else (timelapse_ratio or 0)

        return jsonify({
            'efficiency': efficiency,
            'overall_ratio': primary_ratio,  # Use record ratio as primary
            'record_ratio': record_ratio,
            'record_count': record_count,
            'timelapse_ratio': timelapse_ratio,
            'timelapse_count': timelapse_count,
            'threshold_warning': 0.15,
            'prev_record_ratio': prev_record_ratio,
            'prev_timelapse_ratio': prev_timelapse_ratio,
            'ratio_pct_change': ratio_pct_change,
            'timelapse_ratio_pct_change': timelapse_ratio_pct_change
        })
    finally:
        conn.close()

@app.route('/api/trend_comparison')
def get_trend_comparison():
    """Compare current period metrics with previous period of same duration"""
    conn = common.get_db_connection()
    if not conn: return jsonify({'error': 'Database connect failed'}), 500
    cursor = conn.cursor()

    start_ts = request.args.get('start', type=float)
    end_ts = request.args.get('end', type=float)

    if not start_ts or not end_ts:
        return jsonify({'error': 'start and end parameters required'}), 400

    # Calculate previous period
    duration = end_ts - start_ts
    previous_start = start_ts - duration
    previous_end = start_ts

    try:
        query = """
            SELECT 
                COUNT(*) as total_jobs,
                SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END) as success_count,
                SUM(filesize) as total_bytes,
                AVG(process_sec) as avg_process,
                AVG(CASE WHEN type NOT LIKE '%timelapse%' THEN process_sec END) as avg_process_record,
                AVG(CASE WHEN type LIKE '%timelapse%' THEN process_sec END) as avg_process_timelapse
            FROM events
            WHERE start_ts >= ? AND start_ts <= ?
        """

        # Current period
        current = cursor.execute(query, (start_ts, end_ts)).fetchone()
        current_total = current['total_jobs'] or 0
        current_success = current['success_count'] or 0
        current_bytes = current['total_bytes'] or 0
        current_process = current['avg_process'] or 0
        current_process_record = current['avg_process_record'] or 0
        current_process_timelapse = current['avg_process_timelapse'] or 0
        current_success_rate = round((current_success / current_total * 100), 1) if current_total > 0 else 0

        # Previous period
        previous = cursor.execute(query, (previous_start, previous_end)).fetchone()
        previous_total = previous['total_jobs'] or 0
        previous_success = previous['success_count'] or 0
        previous_bytes = previous['total_bytes'] or 0
        previous_process = previous['avg_process'] or 0
        previous_process_record = previous['avg_process_record'] or 0
        previous_process_timelapse = previous['avg_process_timelapse'] or 0
        previous_success_rate = round((previous_success / previous_total * 100), 1) if previous_total > 0 else 0

        # Calculate changes
        def calc_pct_change(current_val, previous_val):
            if previous_val == 0:
                return 100.0 if current_val > 0 else 0.0
            return round(((current_val - previous_val) / previous_val) * 100, 1)

        return jsonify({
            'current': {
                'total': current_total,
                'success_rate': current_success_rate,
                'storage_bytes': current_bytes,
                'avg_process': round(current_process, 2),
                'avg_process_record': round(current_process_record, 2),
                'avg_process_timelapse': round(current_process_timelapse, 2)
            },
            'previous': {
                'total': previous_total,
                'success_rate': previous_success_rate,
                'storage_bytes': previous_bytes,
                'avg_process': round(previous_process, 2),
                'avg_process_record': round(previous_process_record, 2),
                'avg_process_timelapse': round(previous_process_timelapse, 2)
            },
            'changes': {
                'total_pct': calc_pct_change(current_total, previous_total),
                'success_rate_diff': round(current_success_rate - previous_success_rate, 1),
                'storage_pct': calc_pct_change(current_bytes, previous_bytes),
                'process_pct': calc_pct_change(current_process, previous_process),
                'process_record_pct': calc_pct_change(current_process_record, previous_process_record),
                'process_timelapse_pct': calc_pct_change(current_process_timelapse, previous_process_timelapse)
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
        # Get aggregated performance stats by type (including failed events for success rate)
        query_perf = """
            SELECT 
                CASE WHEN type LIKE '%timelapse%' THEN 'Timelapse' ELSE 'Record' END as category,
                COUNT(*) as total_count,
                SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END) as success_count,
                AVG(CASE WHEN status = 'SUCCESS' THEN duration ELSE NULL END) as avg_duration,
                MIN(CASE WHEN status = 'SUCCESS' THEN duration ELSE NULL END) as min_duration,
                MAX(CASE WHEN status = 'SUCCESS' THEN duration ELSE NULL END) as max_duration,
                AVG(CASE WHEN status = 'SUCCESS' THEN process_sec ELSE NULL END) as avg_process,
                MIN(CASE WHEN status = 'SUCCESS' THEN process_sec ELSE NULL END) as min_process,
                MAX(CASE WHEN status = 'SUCCESS' THEN process_sec ELSE NULL END) as max_process,
                AVG(CASE WHEN status = 'SUCCESS' AND duration > 0 THEN process_sec * 1.0 / duration ELSE NULL END) as avg_ratio,
                SUM(filesize) as total_bytes
            FROM events 
            WHERE start_ts >= ? AND start_ts <= ?
            GROUP BY category
        """
        rows = cursor.execute(query_perf, (start_ts, end_ts)).fetchall()
        
        perf_data = {
            'categories': [],
            'count': [],
            'avg_duration': [],
            'avg_process': [],
            'ratio': [],
            'success_rate': [],
            'storage_mb': []
        }
        for r in rows:
            total = r['total_count'] or 0
            success = r['success_count'] or 0
            success_rate = round((success / total * 100), 1) if total > 0 else 0
            storage_mb = round((r['total_bytes'] or 0) / (1024 * 1024), 2)
            
            perf_data['categories'].append(r['category'])
            perf_data['count'].append(total)
            perf_data['avg_duration'].append(round(r['avg_duration'] or 0, 1))
            perf_data['avg_process'].append(round(r['avg_process'] or 0, 1))
            perf_data['ratio'].append(round((r['avg_ratio'] or 0) * 100, 2))  # ratio as percentage
            perf_data['success_rate'].append(success_rate)
            perf_data['storage_mb'].append(storage_mb)

        # Adaptive Storage Chart Query - choose granularity based on time range
        duration_hours = (end_ts - start_ts) / 3600
        
        if duration_hours <= 6:
            time_sql = "strftime('%H:%M', start_ts, 'unixepoch', 'localtime')"
            granularity = '15min'
        elif duration_hours <= 24:
            time_sql = "strftime('%H:00', start_ts, 'unixepoch', 'localtime')"
            granularity = 'hour'
        elif duration_hours <= 720:  # Up to 30 days
            time_sql = "strftime('%d/%m', start_ts, 'unixepoch', 'localtime')"
            granularity = 'day'
        elif duration_hours <= 2160:  # Up to 90 days
            time_sql = "strftime('%Y-W%W', start_ts, 'unixepoch', 'localtime')"
            granularity = 'week'
        else:
            time_sql = "strftime('%m/%Y', start_ts, 'unixepoch', 'localtime')"
            granularity = 'month'

        query_store = f"""
            SELECT 
                {time_sql} as time_bucket,
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