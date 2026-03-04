#!/bin/bash

# ==============================================================================
# DATABASE MODULE
# Purpose: Initialize database schema, enable WAL mode for dashboard concurrency,
#          and perform cleanup/migrations.
# ==============================================================================

init_db() {
    # [Dashboard Req] Enable Write-Ahead Logging (WAL)
    # Reason: Allows the Web Dashboard to read (SELECT) simultaneously
    # while the script is writing (INSERT/UPDATE) without locking the database.
    sqlite3 "$DB_FILE" "PRAGMA journal_mode=WAL;" >/dev/null 2>&1

    # [Schema Definition]
    # - fail_type: Categorizes errors for the 'Failure Analysis' chart.
    # - filesize: Used to calculate 'Total Storage' used metric.
    # - process_sec: Used to visualize 'System Performance' trends over time.
    # - search_text: Stores sanitized text for easier searching and error prevention.
    # - alert_sent: Tracks if Telegram alert was sent to prevent duplicate notifications.
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
        search_text TEXT, -- Sanitized content for searching
        retry_count INTEGER DEFAULT 0,
        alert_sent INTEGER DEFAULT 0 -- 0=Not sent, 1=Sent (prevents duplicate alerts)
    );"

    # [Migrations] Ensure schema compatibility with older DB versions
    sqlite3 "$DB_FILE" "ALTER TABLE events ADD COLUMN fail_type TEXT;" 2>/dev/null || true
    sqlite3 "$DB_FILE" "ALTER TABLE events ADD COLUMN filesize INTEGER DEFAULT 0;" 2>/dev/null || true
    sqlite3 "$DB_FILE" "ALTER TABLE events ADD COLUMN process_sec INTEGER DEFAULT 0;" 2>/dev/null || true
    sqlite3 "$DB_FILE" "ALTER TABLE events ADD COLUMN search_text TEXT;" 2>/dev/null || true
    # Reason: Track alert notification status to prevent duplicate alerts for same failure
    sqlite3 "$DB_FILE" "ALTER TABLE events ADD COLUMN alert_sent INTEGER DEFAULT 0;" 2>/dev/null || true
    # Reason: Track number of retries for failure slots (prevents infinite retry loops)
    sqlite3 "$DB_FILE" "ALTER TABLE events ADD COLUMN retry_count INTEGER DEFAULT 0;" 2>/dev/null || true

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

    # [Cleanup] Maintain DB size to keep Dashboard queries fast
    
    if [ "$RETENTION_DAYS" -gt 0 ]; then
        local sent_cleanup_ts=$(date -d "-$RETENTION_DAYS days" +%s)
        db_exec "DELETE FROM events WHERE type IN ('RECORD', 'TIMELAPSE') AND end_ts < $sent_cleanup_ts;"
    fi

    if [ "$ALERT_RETENTION_HOURS" -gt 0 ]; then
        local alert_cleanup_ts=$(date -d "-$ALERT_RETENTION_HOURS hours" +%s)
        db_exec "DELETE FROM events WHERE status='FAILED' AND end_ts < $alert_cleanup_ts;"
    fi

    # [Ops] Database Maintenance (VACUUM)
    # Reason: Reclaims unused disk space from deleted rows and defragments the DB file.
    # This prevents the SQLite file from growing indefinitely and maintains query performance.
    if [ "$RETENTION_DAYS" -gt 0 ] || [ "$ALERT_RETENTION_HOURS" -gt 0 ]; then
        sqlite3 "$DB_FILE" "VACUUM;" >/dev/null 2>&1
    fi
}