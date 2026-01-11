#!/bin/bash

# ==============================================================================
# UTILITIES MODULE
# Purpose: Helper functions for logging, DB access, and data formatting.
# ==============================================================================

# System preparation
mkdir -p "$DATA_DIR"
mkdir -p "$TEMP_DIR"

# [Ops] Enhanced Logging
# Purpose: Routes CRITICAL/ERROR messages to STDERR for container monitoring systems,
# while keeping standard INFO messages on STDOUT.
log() {
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    local msg="$1"
    
    if [[ "$msg" == *"CRITICAL"* ]] || [[ "$msg" == *"ERROR"* ]]; then
        echo "[$ts] [PID:$$] [ERROR] $msg" >&2
    else
        echo "[$ts] [PID:$$] [INFO] $msg"
    fi
}

log_debug() {
    if [ "${DEBUG}" == "true" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [PID:$$] [DEBUG] $1" >&2
    fi
}

# [Ops] Log Rotation Logic
# Purpose: Checks the main log file size and rotates it if it exceeds the configured limit 
# to ensure the file remains manageable and easy to open.
rotate_log_file() {
    if [ -f "$LOG_FILE" ]; then
        local current_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$current_size" -gt "$MAX_LOG_SIZE_BYTES" ]; then
            log "Log file size ($current_size bytes) exceeds limit ($MAX_LOG_SIZE_BYTES). Rotating..."
            mv "$LOG_FILE" "${LOG_FILE}.old"
            touch "$LOG_FILE"
            log "Log rotation complete. Previous log saved to ${LOG_FILE}.old"
        fi
    fi
}

# [Ops] Disk Space Check Logic
# Purpose: Verifies available storage in the Data Directory before starting intensive operations.
# Returns 0 if space is sufficient, 1 if critical.
check_disk_space() {
    # df -k output is in 1K blocks. We compare with MIN_DISK_SPACE_MB converted to KB.
    local available_kb=$(df -k "$DATA_DIR" | tail -n 1 | awk '{print $4}')
    local limit_kb=$(( MIN_DISK_SPACE_MB * 1024 ))

    if [ "$available_kb" -lt "$limit_kb" ]; then
        local avail_mb=$(( available_kb / 1024 ))
        log "CRITICAL: Disk space on $DATA_DIR is low! Available: ${avail_mb}MB (Threshold: ${MIN_DISK_SPACE_MB}MB)."
        return 1
    fi
    return 0
}

# Executes SQL with a timeout to prevent 'database is locked' errors
db_exec() {
    log_debug "DB_EXEC: $1"
    # [CHANGE] Replaced hardcoded '30000' with DB_TIMEOUT_MS env var
    sqlite3 -cmd ".timeout $DB_TIMEOUT_MS" "$DB_FILE" "$1"
}

# Returns a single numeric value from SQL, defaulting to 0 on failure
db_count() {
    log_debug "DB_COUNT: $1"
    # [CHANGE] Replaced hardcoded '30000' with DB_TIMEOUT_MS env var
    local result=$(sqlite3 -cmd ".timeout $DB_TIMEOUT_MS" "$DB_FILE" "$1" 2>/dev/null)
    if [[ ! "$result" =~ ^[0-9]+$ ]]; then
        log_debug "DB_COUNT result invalid: '$result', returning 0"
        echo "0"
    else
        log_debug "DB_COUNT result: $result"
        echo "$result"
    fi
}

# Extracts a specific key from a flat JSON string using grep/awk
get_json_value() {
    local json="$1"
    local key="$2"
    echo "$json" | grep -oE "\"$key\":[0-9]+" | head -n 1 | awk -F':' '{print $2}'
}

# Uses ffprobe to get the exact duration of a video file in seconds
get_video_duration() {
    local filepath="$1"
    log_debug "Getting video duration for: $filepath"
    if command -v ffprobe &> /dev/null; then
        local duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$filepath" 2>/dev/null | cut -d. -f1)
        # Ensure we return a valid number
        if [[ "$duration" =~ ^[0-9]+$ ]]; then
            log_debug "Video duration: ${duration}s"
            echo "$duration"
        else
            log_debug "ffprobe returned invalid duration: '$duration'"
            echo "0"
        fi
    else
        log_debug "ffprobe not available"
        echo "0"
    fi
}

format_duration() {
    local total_seconds=$1
    local hours=$((total_seconds / 3600))
    local minutes=$(( (total_seconds % 3600) / 60 ))
    local seconds=$((total_seconds % 60))

    if [ "$hours" -gt 0 ]; then
        printf "%dh %02dm %02ds" "$hours" "$minutes" "$seconds"
    elif [ "$minutes" -gt 0 ]; then
        printf "%dm %02ds" "$minutes" "$seconds"
    else
        printf "%ds" "$seconds"
    fi
}

# Calculates a master timestamp aligned to the nearest time block based on timezone.
get_aligned_master_ts() {
    local duration_sec=$1
    local current_ts=$(date +%s)
    local tz_str=$(date +%z)
    local tz_sign=${tz_str:0:1}
    local tz_hour=${tz_str:1:2}
    local tz_min=${tz_str:3:2}
    local tz_offset_sec=$(( (tz_hour * 3600) + (tz_min * 60) ))
    
    if [ "$tz_sign" == "-" ]; then tz_offset_sec=$((tz_offset_sec * -1)); fi
    
    # [Debug] Log calculation inputs to verify timezone offsets
    log_debug "Aligning TS: Current=$current_ts, Offset=$tz_offset_sec, Duration=$duration_sec"

    local local_ts=$((current_ts + tz_offset_sec))
    local aligned_local_end=$(( local_ts - (local_ts % duration_sec) ))
    local master_end_ts=$(( aligned_local_end - tz_offset_sec ))
    
    # [Debug] Log final result
    log_debug "Aligned Master TS: $master_end_ts ($(date -d @$master_end_ts '+%H:%M:%S'))"

    echo "$master_end_ts"
}