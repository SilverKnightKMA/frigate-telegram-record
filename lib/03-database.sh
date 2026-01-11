#!/bin/bash

# ==============================================================================
# DATABASE MODULE
# Purpose: Initialize database schema and perform cleanup/migrations.
# ==============================================================================

init_db() {
    # CHANGE: Added 'expected_duration' to store target video length for accuracy analysis
    # CHANGE: Added 'processing_time' to track pipeline performance (job execution time)
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
        duration INTEGER DEFAULT 0,          -- Actual duration
        expected_duration INTEGER DEFAULT 0, -- New column: Target duration
        fail_type TEXT,   -- DOWNLOAD, RENDER, DURATION, etc.
        filesize INTEGER DEFAULT 0,
        processing_time INTEGER DEFAULT 0    -- New column: Time taken to process logic
    );"

    # Auto-migration for existing databases
    # Adding columns safely if they do not exist
    sqlite3 "$DB_FILE" "ALTER TABLE events ADD COLUMN fail_type TEXT;" 2>/dev/null || true
    sqlite3 "$DB_FILE" "ALTER TABLE events ADD COLUMN filesize INTEGER DEFAULT 0;" 2>/dev/null || true
    sqlite3 "$DB_FILE" "ALTER TABLE events ADD COLUMN expected_duration INTEGER DEFAULT 0;" 2>/dev/null || true
    sqlite3 "$DB_FILE" "ALTER TABLE events ADD COLUMN processing_time INTEGER DEFAULT 0;" 2>/dev/null || true

    # Added indexes for performance on frequent SELECT queries
    db_exec "CREATE INDEX IF NOT EXISTS idx_cam_type_status ON events(camera, type, status);"
    db_exec "CREATE INDEX IF NOT EXISTS idx_start_ts ON events(start_ts);"

    # Cleanup old records based on type (Retains successful records for RETENTION_DAYS)
    local sent_cleanup_ts=$(date -d "-$RETENTION_DAYS days" +%s)
    db_exec "DELETE FROM events WHERE type IN ('RECORD', 'TIMELAPSE') AND created_at < $sent_cleanup_ts;"

    # Cleanup old failures (Retains failed records for ALERT_RETENTION_HOURS)
    local alert_cleanup_ts=$(date -d "-$ALERT_RETENTION_HOURS hours" +%s)
    db_exec "DELETE FROM events WHERE status='FAILED' AND created_at < $alert_cleanup_ts;"
}