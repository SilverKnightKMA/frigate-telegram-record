#!/bin/bash

# ==============================================================================
# DATABASE MODULE
# Purpose: Initialize database schema, enable WAL mode for dashboard concurrency,
#          and perform cleanup/migrations.
# ==============================================================================

init_db() {
    # [Dashboard Req] Enable Write-Ahead Logging (WAL)
    # Reason: Allows the Web Dashboard to read (SELECT) statistics simultaneously
    # while the script is writing (INSERT/UPDATE) without locking the database.
    sqlite3 "$DB_FILE" "PRAGMA journal_mode=WAL;" >/dev/null 2>&1

    # [Schema Definition]
    # - fail_type: Categorizes errors for the 'Failure Analysis' chart.
    # - filesize: Used to calculate 'Total Storage' used metric.
    # - process_sec: Used to visualize 'System Performance' trends over time.
    # - search_text: Stores sanitized text for easier searching and error prevention.
    db_exec "CREATE TABLE IF NOT EXISTS events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        camera TEXT,
        type TEXT,        -- RECORD | TIMELAPSE
        status TEXT,      -- SUCCESS | FAILED
        start_ts INTEGER,
        end_ts INTEGER,
        created_at INTEGER,
        message TEXT,     -- Base64 Encoded
        msg_id INTEGER,
        duration INTEGER DEFAULT 0,
        fail_type TEXT,   -- DOWNLOAD, RENDER, DURATION, TELEGRAM, VALIDATION
        filesize INTEGER DEFAULT 0, -- Bytes
        process_sec INTEGER DEFAULT 0, -- Processing duration (Performance metric)
        search_text TEXT  -- Sanitized content for searching
    );"

    # [Migrations] Ensure schema compatibility with older DB versions
    sqlite3 "$DB_FILE" "ALTER TABLE events ADD COLUMN fail_type TEXT;" 2>/dev/null || true
    sqlite3 "$DB_FILE" "ALTER TABLE events ADD COLUMN filesize INTEGER DEFAULT 0;" 2>/dev/null || true
    sqlite3 "$DB_FILE" "ALTER TABLE events ADD COLUMN process_sec INTEGER DEFAULT 0;" 2>/dev/null || true
    
    # [New Migration] Add search_text column if missing
    sqlite3 "$DB_FILE" "ALTER TABLE events ADD COLUMN search_text TEXT;" 2>/dev/null || true

    # [Dashboard Indexes] Optimized for common Dashboard queries
    
    # Existing: Helps query specific events by camera/status
    db_exec "CREATE INDEX IF NOT EXISTS idx_cam_type_status ON events(camera, type, status);"
    
    # Existing: Helps in finding gaps/overlaps
    db_exec "CREATE INDEX IF NOT EXISTS idx_start_ts ON events(start_ts);"

    # [New] Reason: Dashboard creates time-series charts (e.g., "Last 24h"). 
    # Indexing created_at avoids full table scans during chart generation.
    db_exec "CREATE INDEX IF NOT EXISTS idx_created_at ON events(created_at);"

    # [New] Reason: Speeds up aggregation queries for the 'Failure Reason' donut chart.
    db_exec "CREATE INDEX IF NOT EXISTS idx_fail_type ON events(fail_type);"

    # [Dashboard Views] 
    # Reason: Pre-defined aggregations to simplify Dashboard Backend queries.
    
    # View 1: Daily Statistics by Camera & Type
    # Provides: Total Events, Success %, Total Size, Avg Process Time per day.
    db_exec "CREATE VIEW IF NOT EXISTS v_daily_stats AS
    SELECT 
        date(created_at, 'unixepoch', 'localtime') as day,
        camera,
        type,
        count(*) as total_events,
        sum(case when status='SUCCESS' then 1 else 0 end) as success_count,
        sum(case when status='FAILED' then 1 else 0 end) as fail_count,
        sum(filesize) as total_size_bytes,
        round(avg(process_sec), 1) as avg_process_sec
    FROM events 
    GROUP BY day, camera, type;"

    # View 2: Hourly Performance Timeline
    # Provides: Data for 'Activity Over Time' charts.
    db_exec "CREATE VIEW IF NOT EXISTS v_hourly_activity AS
    SELECT 
        date(created_at, 'unixepoch', 'localtime') as day,
        strftime('%H', created_at, 'unixepoch', 'localtime') as hour,
        camera,
        type,
        status,
        count(*) as count
    FROM events
    GROUP BY day, hour, camera, type, status;"

    # [Cleanup] Maintain DB size to keep Dashboard queries fast
    # CHANGE: Added conditional check. If retention is set to 0 or less, cleanup is skipped.
    # This prevents accidental data loss if the user wants to keep history or disable auto-cleanup.
    
    if [ "$RETENTION_DAYS" -gt 0 ]; then
        local sent_cleanup_ts=$(date -d "-$RETENTION_DAYS days" +%s)
        db_exec "DELETE FROM events WHERE type IN ('RECORD', 'TIMELAPSE') AND created_at < $sent_cleanup_ts;"
    fi

    if [ "$ALERT_RETENTION_HOURS" -gt 0 ]; then
        local alert_cleanup_ts=$(date -d "-$ALERT_RETENTION_HOURS hours" +%s)
        db_exec "DELETE FROM events WHERE status='FAILED' AND created_at < $alert_cleanup_ts;"
    fi
}