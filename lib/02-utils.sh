#!/bin/bash

# ==============================================================================
# UTILITIES MODULE
# Purpose: Helper functions for logging, DB access, and data formatting.
# ==============================================================================

# System preparation
mkdir -p "$DATA_DIR"
mkdir -p "$TEMP_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [PID:$$] [INFO] $1"
}

log_debug() {
    if [ "${DEBUG}" == "true" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [PID:$$] [DEBUG] $1" >&2
    fi
}

# Executes SQL with a timeout to prevent 'database is locked' errors
db_exec() {
    log_debug "DB_EXEC: $1"
    sqlite3 -cmd ".timeout 30000" "$DB_FILE" "$1"
}

# Returns a single numeric value from SQL, defaulting to 0 on failure
db_count() {
    log_debug "DB_COUNT: $1"
    local result=$(sqlite3 -cmd ".timeout 30000" "$DB_FILE" "$1" 2>/dev/null)
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