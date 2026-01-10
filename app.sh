#!/bin/bash

# ==============================================================================
# CONFIGURATION LOADER
# ==============================================================================

# Load environment variables from config file if not already set
CONFIG_FILE="${CONFIG_FILE:-}"
if [ -z "$CONFIG_FILE" ]; then
    if [ -f "./config/config.env" ]; then
        CONFIG_FILE="./config/config.env"
    else
        CONFIG_FILE="/app/config/config.env"
    fi
fi

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        echo "[INFO] Loading config from file: $CONFIG_FILE"
        while IFS='=' read -r key value; do
            if [[ $key =~ ^# ]] || [[ -z $key ]]; then continue; fi
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            # Only export if not already set in environment
            if [ -z "${!key}" ]; then export "$key=$value"; fi
        done < "$CONFIG_FILE"
    fi
}
load_config

export TZ="${TZ:-Asia/Ho_Chi_Minh}"
FRIGATE_HOST="${FRIGATE_HOST:-http://127.0.0.1:5000}"
TELEGRAM_API_URL="${TELEGRAM_API_URL:-https://api.telegram.org}"

if [ -z "${DATA_DIR:-}" ]; then
    if [ -d "./data" ]; then DATA_DIR="./data"; else DATA_DIR="/app/data"; fi
fi

TEMP_DIR="${TEMP_DIR:-/dev/shm/frigate_clips}"
LOG_FILE="$DATA_DIR/execution.log"
DB_FILE="$DATA_DIR/video_history.sqlite"

# --- TUNING CONFIG ---
RETENTION_DAYS="${RETENTION_DAYS:-30}"
ALERT_RETENTION_HOURS="${ALERT_RETENTION_HOURS:-720}"
# Controls if alerts are resent for the same time slot
ALERT_REPEAT="${ALERT_REPEAT:-false}"
LOOKBACK_HOURS="${LOOKBACK_HOURS:-168}"
# Limit concurrent background jobs to prevent DB locks
MAX_CONCURRENT_TASKS="${MAX_CONCURRENT_TASKS:-5}" 
PADDING_SEC="${PADDING_SEC:-5}"
MAX_RETRIES="${MAX_RETRIES:-5}"

REC_DURATION_MIN="${REC_DURATION_MIN:-15}"
TEST_REC_DURATION_MIN="${TEST_REC_DURATION_MIN:-1}"
MODE="${MODE:-record}"

# Enable detailed debug logging
DEBUG="${DEBUG:-false}"

# Controls notification behavior upon recovery:
# true: Sends a reply, adds a reaction, and edits the original error message.
# false: Only edits the error message silently.
NOTIFY_ON_RECOVERY="${NOTIFY_ON_RECOVERY:-true}"

# Threshold to determine if a video is considered successful (percentage of expected duration).
MIN_DURATION_PERCENT="${MIN_DURATION_PERCENT:-90}"

# --- TIMELAPSE SETTINGS ---
TIMELAPSE_THREAD_ID="${TIMELAPSE_THREAD_ID:-33}" 
TIMELAPSE_HOURS="${TIMELAPSE_HOURS:-6}"    # Duration of one timelapse block in hours
TIMELAPSE_SPEED="${TIMELAPSE_SPEED:-600}"   # Speed multiplier
TIMELAPSE_FPS="${TIMELAPSE_FPS:-30}"       # Output FPS
TIMELAPSE_QUALITY="${TIMELAPSE_QUALITY:-24}" # Encoding Quality (QP)
VAAPI_DEVICE="${VAAPI_DEVICE:-/dev/dri/renderD128}"
TIMELAPSE_CHUNK_SIZE_SEC="${TIMELAPSE_CHUNK_SIZE_SEC:-3600}" # Process in chunks to maintain ffmpeg stability (default: 60 minutes)
TIMELAPSE_LOOKBACK_HOURS="${TIMELAPSE_LOOKBACK_HOURS:-720}"
TIMELAPSE_RETRY_SLEEP_SEC="${TIMELAPSE_RETRY_SLEEP_SEC:-3600}"

# Controls retry behavior for timelapse mode:
# true: Enters a retry loop with short sleep (TIMELAPSE_RETRY_SLEEP_SEC) immediately after failure.
# false: Logs the failure (with duration) to DB and proceeds to normal long sleep schedule.
TIMELAPSE_STRICT_RETRY="${TIMELAPSE_STRICT_RETRY:-false}"

# Global variables to store Telegram Message IDs for recovery logic
SENT_ERROR_MSG_ID=""
SENT_VIDEO_MSG_ID=""

# ==============================================================================
# SYSTEM PREP & LOGGING
# ==============================================================================

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

# Executes SQL with a timeout to prevent 'database is locked' errors during concurrency
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
# Ensures that all cameras process the same time slots regardless of when the script starts.
get_aligned_master_ts() {
    local duration_sec=$1
    local current_ts=$(date +%s)
    local tz_str=$(date +%z)
    local tz_sign=${tz_str:0:1}
    local tz_hour=${tz_str:1:2}
    local tz_min=${tz_str:3:2}
    local tz_offset_sec=$(( (tz_hour * 3600) + (tz_min * 60) ))
    
    if [ "$tz_sign" == "-" ]; then tz_offset_sec=$((tz_offset_sec * -1)); fi
    
    local local_ts=$((current_ts + tz_offset_sec))
    local aligned_local_end=$(( local_ts - (local_ts % duration_sec) ))
    local master_end_ts=$(( aligned_local_end - tz_offset_sec ))
    
    echo "$master_end_ts"
}

# --- TELEGRAM ACTIONS ---

send_reaction() {
    local chat_id="$1"
    local msg_id="$2"
    local emoji="$3"
    
    if [ -z "$msg_id" ] || [ "$msg_id" == "0" ]; then return; fi

    curl -s -X POST "${TELEGRAM_API_URL}/bot${BOT_TOKEN}/setMessageReaction" \
        -H "Content-Type: application/json" \
        -d "{
            \"chat_id\": $chat_id,
            \"message_id\": $msg_id,
            \"reaction\": [{
                \"type\": \"emoji\",
                \"emoji\": \"$emoji\"
            }],
            \"is_big\": true
        }" > /dev/null
}

send_reply() {
    local chat_id="$1"
    local msg_id="$2"
    local text="$3"
    local thread_id="$4"

    if [ -z "$msg_id" ] || [ "$msg_id" == "0" ]; then return; fi

    local extra_params=""
    if [ -n "$thread_id" ]; then
        extra_params="\"message_thread_id\": $thread_id,"
    fi

    curl -s -X POST "${TELEGRAM_API_URL}/bot${BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{
            \"chat_id\": $chat_id,
            \" $extra_params
            \"text\": \"$text\",
            \"reply_parameters\": {
                \"message_id\": $msg_id
            }
        }" > /dev/null
}

edit_message_text() {
    local chat_id="$1"
    local msg_id="$2"
    local text="$3"
    local thread_id="$4"

    if [ -z "$msg_id" ] || [ "$msg_id" == "0" ]; then return; fi

    local args=(
        -s -X POST "${TELEGRAM_API_URL}/bot${BOT_TOKEN}/editMessageText"
        -d "chat_id=${chat_id}"
        -d "message_id=${msg_id}"
        -d "parse_mode=HTML"
        --data-urlencode "text=${text}"
    )
    if [ -n "$thread_id" ]; then args+=(-d "message_thread_id=${thread_id}"); fi

    curl "${args[@]}" > /dev/null
}

# --- ERROR HANDLER ---
# Logs errors locally and sends a notification to Telegram if configured.
# Handles rate limiting and updates the global SENT_ERROR_MSG_ID.
handle_error() {
    local msg="$1"
    local context="$2"
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    
    SENT_ERROR_MSG_ID=""

    # Clean HTML tags for local log file
    local clean_msg=$(echo "$msg" | sed 's/<[^>]*>//g')
    echo "[$ts] [ERROR] [$context] $clean_msg" | tee -a "$LOG_FILE"
    
    if [ -n "$ERROR_CHAT_ID" ]; then
        local alert_text=""
        
        # Use message as-is if it contains HTML tags, otherwise apply template
        if [[ "$msg" == *"<b>"* ]]; then
            alert_text="$msg"
        else
            alert_text="🚨 <b>EXECUTION FAILED</b>
<b>Time:</b> $ts
<b>Context:</b> $context
<b>Error:</b> $msg"
        fi

        local attempt=1
        local max_alert_retries=3
        local response_body=$(mktemp)

        while [ $attempt -le $max_alert_retries ]; do
            local args=(
                -s -o "$response_body" -w "%{http_code}"
                -X POST "${TELEGRAM_API_URL}/bot${BOT_TOKEN}/sendMessage"
                -d "chat_id=${ERROR_CHAT_ID}"
                -d "parse_mode=HTML"
                --data-urlencode "text=${alert_text}"
            )
            if [ -n "$ERROR_THREAD_ID" ]; then args+=(-d "message_thread_id=${ERROR_THREAD_ID}"); fi

            local http_code=$(curl "${args[@]}")
            local response_content=$(cat "$response_body")

            if [ "$http_code" == "200" ] && echo "$response_content" | grep -q '"ok":true'; then
                SENT_ERROR_MSG_ID=$(get_json_value "$response_content" "message_id")
                
                # Add visual reaction to indicate critical error
                if [ -n "$SENT_ERROR_MSG_ID" ]; then
                    send_reaction "$ERROR_CHAT_ID" "$SENT_ERROR_MSG_ID" "🔥"
                fi

                rm -f "$response_body"
                return 0
            fi

            if echo "$response_content" | grep -iq "retry after"; then
                local wait_sec=$(echo "$response_content" | grep -oE 'retry after [0-9]+' | awk '{print $3}')
                if [ -z "$wait_sec" ]; then wait_sec=5; fi
                local buffer=$(( ( RANDOM % 3 ) + 1 ))
                wait_sec=$((wait_sec + buffer))
                echo "[$ts] [WARN] Alert Rate Limited. Waiting ${wait_sec}s..." >> "$LOG_FILE"
                sleep "$wait_sec"
                attempt=$((attempt + 1))
                continue
            fi
            
            echo "[$ts] [CRITICAL] Alert Failed (HTTP $http_code). Response: $response_content" >> "$LOG_FILE"
            rm -f "$response_body"
            return 1
        done
        rm -f "$response_body"
    fi
}

IFS=';' read -ra CAMERA_ARRAY <<< "$CAMERAS"
if [ ${#CAMERA_ARRAY[@]} -eq 0 ]; then
    log "CRITICAL: No cameras configured."
    exit 1
fi

echo "[INFO] System Timezone: $TZ"

# ==============================================================================
# DATABASE INIT & CLEANUP
# ==============================================================================

init_db() {
    # Initialize tables for tracking sent videos and errors
    db_exec "CREATE TABLE IF NOT EXISTS sent_ranges (
        camera TEXT,
        start_ts INTEGER,
        end_ts INTEGER,
        created_at INTEGER,
        PRIMARY KEY (camera, start_ts, end_ts)
    );"
    
    db_exec "CREATE TABLE IF NOT EXISTS alert_history (
        id TEXT PRIMARY KEY, 
        camera TEXT,
        created_at INTEGER
    );"

    # Initialize table for timelapse tracking
    db_exec "CREATE TABLE IF NOT EXISTS timelapse_history (
        camera TEXT,
        range_id TEXT,
        created_at INTEGER,
        PRIMARY KEY (camera, range_id)
    );"

    # Schema updates (idempotent)
    db_exec "ALTER TABLE alert_history ADD COLUMN msg_id INTEGER;" 2>/dev/null
    db_exec "ALTER TABLE sent_ranges ADD COLUMN msg_id INTEGER;" 2>/dev/null
    db_exec "ALTER TABLE alert_history ADD COLUMN alert_text TEXT;" 2>/dev/null
    
    # Add duration column to track partial download improvements
    db_exec "ALTER TABLE alert_history ADD COLUMN duration INTEGER;" 2>/dev/null
    
    # Cleanup old records
    local sent_cleanup_ts=$(date -d "-$RETENTION_DAYS days" +%s)
    db_exec "DELETE FROM sent_ranges WHERE created_at < $sent_cleanup_ts;"
    db_exec "DELETE FROM timelapse_history WHERE created_at < $sent_cleanup_ts;"

    local alert_cleanup_ts=$(date -d "-$ALERT_RETENTION_HOURS hours" +%s)
    db_exec "DELETE FROM alert_history WHERE created_at < $alert_cleanup_ts;"
}
init_db

validate_video() {
    local filepath="$1"
    log_debug "Validating video: $filepath"
    
    if [ ! -s "$filepath" ]; then 
        log_debug "Validation failed: File does not exist or is empty"
        return 1
    fi
    
    local filesize=$(stat -c%s "$filepath" 2>/dev/null || echo 0)
    log_debug "File size: ${filesize} bytes"
    
    if [ "$filesize" -lt 1024 ]; then 
        log_debug "Validation failed: File too small (< 1KB)"
        return 1
    fi
    
    local mime_type=$(file --brief --mime-type "$filepath")
    log_debug "MIME type: $mime_type"
    
    if [ "$mime_type" != "video/mp4" ] && [ "$mime_type" != "application/octet-stream" ]; then 
        log_debug "Validation failed: Invalid MIME type"
        return 1
    fi
    
    if command -v ffprobe &> /dev/null; then
        if ! ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$filepath" >/dev/null 2>&1; then 
            log_debug "Validation failed: ffprobe check failed"
            return 1
        fi
    fi
    
    log_debug "Validation passed"
    return 0
}

send_telegram_video() {
    local filepath="$1"
    local chat_id="$2"
    local thread_id="$3"
    local caption="$4"
    local src="$5"

    log_debug "[$src] send_telegram_video: chat_id=$chat_id, thread_id=$thread_id, file=$filepath"

    local attempt=1
    local response_body=$(mktemp)
    
    SENT_VIDEO_MSG_ID=""

    while [ $attempt -le $MAX_RETRIES ]; do
        if [ $attempt -gt 1 ]; then log "[$src] Retry $attempt/$MAX_RETRIES..."; fi

        local args=(
            -s -X POST "${TELEGRAM_API_URL}/bot${BOT_TOKEN}/sendVideo"
            -o "$response_body" -w "%{http_code}"
            -F "chat_id=${chat_id}"
            -F "video=@${filepath}"
            -F "caption=${caption}"
            -F "parse_mode=HTML"
        )
        if [ -n "$thread_id" ]; then args+=(-F "message_thread_id=${thread_id}"); fi

        log_debug "[$src] Sending video (attempt $attempt)..."
        local http_code=$(curl "${args[@]}")
        local curl_exit=$?
        local response_content=$(cat "$response_body")
        
        log_debug "[$src] HTTP Code: $http_code, Curl Exit: $curl_exit"
        if [ "${DEBUG}" == "true" ]; then
            log_debug "[$src] Response: ${response_content:0:200}..."
        fi
        
        if [ $curl_exit -ne 0 ]; then
            log "[$src] Curl failed (Exit Code: $curl_exit)."
            rm -f "$response_body"
            handle_error "Network Error (Curl Exit $curl_exit)" "SEND|$src"
            return 1
        fi

        if [ "$http_code" == "200" ] && echo "$response_content" | grep -q '"ok":true'; then
            SENT_VIDEO_MSG_ID=$(get_json_value "$response_content" "message_id")
            rm -f "$response_body"
            return 0
        fi

        # Handle rate limiting
        if echo "$response_content" | grep -iq "retry after"; then
            local wait_sec=$(echo "$response_content" | grep -oE 'retry after [0-9]+' | awk '{print $3}')
            if [ -z "$wait_sec" ]; then wait_sec=10; fi
            wait_sec=$((wait_sec + 1))
            log "[$src] ⚠️ Rate Limited. Waiting ${wait_sec}s."
            sleep "$wait_sec"
            attempt=$((attempt + 1))
            continue
        fi

        rm -f "$response_body"
        handle_error "API Error ($http_code): $response_content" "SEND|$src"
        return 1
    done
    rm -f "$response_body"
    handle_error "Timeout after $MAX_RETRIES retries" "SEND_TIMEOUT|$src"
    return 1
}

# ==============================================================================
# SHARED LOGIC (RECOVERY & CHECKS)
# ==============================================================================

# Checks if the downloaded video meets duration requirements.
# Sets global variables: _actual, _fmt_actual, _fmt_expected, _percent, _status
check_duration_and_status() {
    local src="$1"
    local filepath="$2"
    local expected_sec="$3"
    local record_id="$4"

    log_debug "[$src] check_duration_and_status: expected=${expected_sec}s, file=$filepath"

    local actual=$(get_video_duration "$filepath")
    
    # Ensure actual is a valid number, default to 0 if not
    if ! [[ "$actual" =~ ^[0-9]+$ ]]; then
        log_debug "[$src] actual duration not a number: '$actual', defaulting to 0"
        actual=0
    fi
    
    local threshold=$(( expected_sec * MIN_DURATION_PERCENT / 100 ))
    
    # Store result variables for caller use (GLOBAL VARIABLES)
    _actual=$actual
    _fmt_actual=$(format_duration "$actual")
    _fmt_expected=$(format_duration "$expected_sec")
    _percent=0
    if [ "$expected_sec" -gt 0 ] && [ "$actual" -gt 0 ]; then
        _percent=$(( actual * 100 / expected_sec ))
    fi

    log_debug "[$src] Duration check: actual=${actual}s, threshold=${threshold}s, percent=${_percent}%"
    log_debug "[$src] Formatted: ${_fmt_actual} / ${_fmt_expected}"

    if [ "$actual" -lt "$threshold" ]; then
        log "[$src] ⚠️ Duration Mismatch: ${actual}s (Expected > ${threshold}s, ${MIN_DURATION_PERCENT}%)"
        
        # Check against previous failure in DB
        local prev_duration=$(sqlite3 "$DB_FILE" "SELECT duration FROM alert_history WHERE id='$record_id' LIMIT 1;")
        prev_duration=${prev_duration:-0}

        # If current video is not better than previous attempt, skip it
        if [ "$actual" -le "$prev_duration" ] && [ "$prev_duration" -gt 0 ]; then
             log "[$src] 🚫 New video (${actual}s) not longer than previous fail (${prev_duration}s). Skipping."
             _status="skip"
             log_debug "[$src] Status set to: skip"
             return
        fi
        
        # If improvement, mark as partial success
        log "[$src] 📈 Improvement (${actual}s > ${prev_duration}s). Sending video but marking as FAILURE."
        _status="partial"
        log_debug "[$src] Status set to: partial"
        return
    fi

    _status="success"
    log_debug "[$src] Status set to: success"
}

# Handles post-success cleanup: deletes alert from DB, replies to error msg, edits status.
handle_recovery_actions() {
    local src="$1"
    local record_id="$2"
    
    # Check if the alert record actually exists first
    # This prevents executing recovery logic/deletion on slots that were never broken.
    local db_row=$(sqlite3 "$DB_FILE" "SELECT msg_id, alert_text FROM alert_history WHERE id='$record_id' LIMIT 1;")
    
    # If no record exists, exit immediately (No-op)
    if [ -z "$db_row" ]; then
        return
    fi

    local alert_msg_id=$(echo "$db_row" | awk -F'|' '{print $1}')
    local b64_alert_text=$(echo "$db_row" | awk -F'|' '{print $2}')
    
    if [ -n "$alert_msg_id" ] && [ "$alert_msg_id" -ne 0 ] && [ -n "$ERROR_CHAT_ID" ]; then
        log "[$src] Recovery detected. Updating alert $alert_msg_id..."
        
        local notify_rec=$(echo "${NOTIFY_ON_RECOVERY:-true}" | tr '[:upper:]' '[:lower:]')
        
        if [ "$notify_rec" == "true" ]; then
            send_reply "$ERROR_CHAT_ID" "$alert_msg_id" "✅ Retry successful! Video has been sent." "$ERROR_THREAD_ID"
            send_reaction "$ERROR_CHAT_ID" "$alert_msg_id" "❤"
        else
             log "[$src] NOTIFY_ON_RECOVERY=false. Skipping reply/reaction."
        fi

        if [ -n "$b64_alert_text" ]; then
            local original_text=$(echo "$b64_alert_text" | base64 -d)
            local body_text=$(echo "$original_text" | sed '1d')
            local updated_text="✅ <b>RESOLVED</b>
$body_text"
            edit_message_text "$ERROR_CHAT_ID" "$alert_msg_id" "$updated_text" "$ERROR_THREAD_ID"
        else
             edit_message_text "$ERROR_CHAT_ID" "$alert_msg_id" "✅ <b>RESOLVED</b> (Metadata unavailable)" "$ERROR_THREAD_ID"
        fi
    fi

    db_exec "DELETE FROM alert_history WHERE id='$record_id';"
}

trigger_failure_alert() {
    local src="$1"
    local start_ts="$2"
    local end_ts="$3"
    local reason="$4"
    local run_mode="$5"
    local duration="$6"

    if [ "$run_mode" != "record" ] && [ "$run_mode" != "timelapse" ]; then
        log "[$src] $reason (Test Mode - No Alert)"
        return
    fi

    local record_id="${src}_${start_ts}_${end_ts}"
    local alerted=$(db_count "SELECT count(*) FROM alert_history WHERE id='$record_id';")
    local alert_repeat=$(echo "${ALERT_REPEAT:-false}" | tr '[:upper:]' '[:lower:]')

    # Logic: Only update if it's a "Partial Update" or if repeat alerts are enabled.
    if [ "$alerted" -gt 0 ] && [ "$alert_repeat" != "true" ]; then
        # If we sent a video (Partial Success), update the DB with new msg_id but don't re-alert.
        if [ -n "$SENT_VIDEO_MSG_ID" ] && [ "$SENT_VIDEO_MSG_ID" -ne 0 ]; then
             local current_ts=$(date +%s)
             local duration_val="${duration:-0}"
             db_exec "UPDATE alert_history SET msg_id=$SENT_VIDEO_MSG_ID, duration=$duration_val, created_at=$current_ts WHERE id='$record_id';"
             log "[$src] Partial improvement: Updated alert DB with new Video MsgID ($SENT_VIDEO_MSG_ID) and duration ($duration_val)."
             return
        fi

        log "[$src] Silent Fail (Already Alerted): $reason"
    else
        # Prepare Alert Text
        local mode_upper=$(echo "$run_mode" | tr '[:lower:]' '[:upper:]')
        
        local alert_text="🚨 <b>EXECUTION FAILED</b>
<b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')
<b>Context:</b> $mode_upper|$src
<b>Error:</b> Failed to process video/timelapse.
<b>Reason:</b> $reason
<b>Slot:</b> $(date -d @$start_ts '+%Y-%m-%d %H:%M') - $(date -d @$end_ts '+%H:%M')"

        # Send Alert
        local msg_id_to_save="0"
        
        if [ -n "$SENT_VIDEO_MSG_ID" ] && [ "$SENT_VIDEO_MSG_ID" -ne 0 ]; then
            msg_id_to_save="$SENT_VIDEO_MSG_ID"
            # No text alert needed as the video itself acts as the notification
        else
            handle_error "$alert_text" "$mode_upper|$src"
            msg_id_to_save="${SENT_ERROR_MSG_ID:-0}"
        fi
        
        # Save to DB
        local current_ts=$(date +%s)
        local b64_text=$(echo "$alert_text" | base64 -w 0)
        local duration_val="${duration:-0}"

        if [ "$alert_repeat" == "true" ]; then
            db_exec "INSERT OR REPLACE INTO alert_history (id, camera, created_at, msg_id, alert_text, duration) VALUES ('$record_id', '$src', $current_ts, $msg_id_to_save, '$b64_text', $duration_val);"
        else
            db_exec "INSERT OR IGNORE INTO alert_history (id, camera, created_at, msg_id, alert_text, duration) VALUES ('$record_id', '$src', $current_ts, $msg_id_to_save, '$b64_text', $duration_val);"
        fi
    fi
}

# ==============================================================================
# PIPELINE LOGIC (Unified Structure)
# ==============================================================================

download_clip() {
    local src="$1"
    local start_ts="$2"
    local end_ts="$3"
    local filepath="$4"
    
    local dl_start_ts=$(( start_ts - PADDING_SEC ))
    local dl_end_ts=$(( end_ts + PADDING_SEC ))
    local url="${FRIGATE_HOST}/api/${src}/start/${dl_start_ts}/end/${dl_end_ts}/clip.mp4"
    
    log_debug "[$src] Downloading clip from: $url"
    log_debug "[$src] Saving to: $filepath"
    
    curl -s -o "$filepath" -w "%{http_code}" "$url"
}

execute_clip_pipeline() {
    local cam_name="$1"
    local src="$2"
    local start_ts="$3"
    local end_ts="$4"
    local run_mode="$5"
    local tid="$6"
    local chat_id="$7"

    log_debug "[$src] execute_clip_pipeline START: $(date -d @$start_ts '+%Y-%m-%d %H:%M') - $(date -d @$end_ts '+%H:%M')"

    # 1. SETUP & IDENTIFICATION
    local record_id="${src}_${start_ts}_${end_ts}"
    local date_file=$(date -d @$start_ts '+%Y%m%d')
    local start_file=$(date -d @$start_ts '+%H%M')
    local end_file=$(date -d @$end_ts '+%H%M')
    local filename="${src}_${date_file}_${start_file}_${end_file}_${run_mode}.mp4"
    local filepath="$TEMP_DIR/$filename"
    local display_date=$(date -d @$start_ts '+%Y-%m-%d')
    local display_start=$(date -d @$start_ts '+%H:%M')
    local display_end=$(date -d @$end_ts '+%H:%M')

    log_debug "[$src] Record ID: $record_id"
    log_debug "[$src] File path: $filepath"

    # 2. GENERATE VIDEO (Download)
    local http_code=$(download_clip "$src" "$start_ts" "$end_ts" "$filepath")
    
    log_debug "[$src] Download HTTP code: $http_code"

    if [ "$http_code" == "200" ]; then
        if validate_video "$filepath"; then
            
            # 3. CHECK DURATION & STATUS
            local expected_duration=$(( end_ts - start_ts ))
            log_debug "[$src] Expected duration: ${expected_duration}s"
            
            check_duration_and_status "$src" "$filepath" "$expected_duration" "$record_id"
            
            log_debug "[$src] Status: $_status, actual: $_actual, formatted: ${_fmt_actual}/${_fmt_expected} (${_percent}%)"
            
            if [ "$_status" == "skip" ]; then
                log_debug "[$src] Skipping video due to status"
                rm -f "$filepath"
                return
            fi

            # 4. SEND TELEGRAM
            local caption="📷 <b>$cam_name</b>
📅 $display_date
⏰ ${display_start} - ${display_end}
⏱️ Duration: ${_fmt_actual} / ${_fmt_expected} (${_percent}%)"

            log_debug "[$src] Caption prepared, sending to Telegram..."

            if send_telegram_video "$filepath" "$chat_id" "$tid" "$caption" "$src"; then
                log_debug "[$src] Video sent successfully, msg_id: $SENT_VIDEO_MSG_ID"
                if [ "$run_mode" == "record" ]; then
                    
                    # 5a. FAILURE HANDLING (Partial)
                    if [ "$_status" == "partial" ]; then
                        trigger_failure_alert "$src" "$start_ts" "$end_ts" "Partial Video (Duration: ${_fmt_actual})" "$run_mode" "$_actual"
                    else
                        # 5b. SUCCESS HANDLING & RECOVERY
                        local current_ts=$(date +%s)
                        local sent_msg_id="${SENT_VIDEO_MSG_ID:-0}"
                        
                        handle_recovery_actions "$src" "$record_id"

                        db_exec "INSERT OR IGNORE INTO sent_ranges (camera, start_ts, end_ts, created_at, msg_id) VALUES ('$src', $start_ts, $end_ts, $current_ts, $sent_msg_id);"
                        log "[$src] ✅ Success (MsgID: $sent_msg_id)."
                    fi
                else
                    log "[$src] Sent (Test Mode)."
                fi
            fi
        else
            trigger_failure_alert "$src" "$start_ts" "$end_ts" "Validation failed (Size: $(stat -c%s "$filepath" 2>/dev/null)b)" "$run_mode" "0"
        fi
    elif [ "$http_code" == "404" ]; then
        trigger_failure_alert "$src" "$start_ts" "$end_ts" "Frigate 404 (Video Not Found)" "$run_mode" "0"
    else
        trigger_failure_alert "$src" "$start_ts" "$end_ts" "Download HTTP Error $http_code" "$run_mode" "0"
    fi
    
    rm -f "$filepath"
}

# Generates timelapse using VAAPI hardware acceleration by concatenating HLS chunks
generate_timelapse_video() {
    local camera_name="$1"
    local start_ts="$2"
    local end_ts="$3"
    local output_file="$4"

    # Create a unique temporary directory to avoid file collisions
    local job_temp_dir="${TEMP_DIR}/timelapse_${camera_name}_${start_ts}"
    mkdir -p "$job_temp_dir"
    
    local concat_list="$job_temp_dir/concat_list.txt"
    local cursor=$start_ts
    local count=1
    local success=0

    log "[$camera_name] Processing Timelapse: $(date -d @$start_ts '+%H:%M') -> $(date -d @$end_ts '+%H:%M') (Speed: x$TIMELAPSE_SPEED)"

    # ========== PRE-CHECK: Download all playlists to calculate total source duration ==========
    log_debug "[$camera_name] Pre-checking all HLS chunks..."
    local pre_cursor=$start_ts
    local pre_count=1
    local total_source_duration=0
    local failed_chunks=0
    
    while [ "$pre_cursor" -lt "$end_ts" ]; do
        local pre_next_cursor=$(($pre_cursor + $TIMELAPSE_CHUNK_SIZE_SEC))
        if [ "$pre_next_cursor" -gt "$end_ts" ]; then pre_next_cursor=$end_ts; fi
        
        local pre_url="${FRIGATE_HOST}/vod/${camera_name}/start/${pre_cursor}/end/${pre_next_cursor}/index.m3u8"
        local pre_playlist="$job_temp_dir/precheck_${pre_count}.m3u8"
        local pre_response=$(curl -s -o "$pre_playlist" -w "%{http_code}" "$pre_url")
        
        if [ "$pre_response" == "200" ] && [ -s "$pre_playlist" ]; then
            local chunk_duration=$(grep -o "#EXTINF:[0-9.]*" "$pre_playlist" 2>/dev/null | awk -F: '{sum+=$2} END {print int(sum)}')
            chunk_duration=${chunk_duration:-0}
            total_source_duration=$((total_source_duration + chunk_duration))
            log_debug "[$camera_name] Chunk $pre_count: ${chunk_duration}s"
        else
            log_debug "[$camera_name] Chunk $pre_count: Failed (HTTP $pre_response)"
            failed_chunks=$((failed_chunks + 1))
        fi
        
        pre_cursor=$pre_next_cursor
        pre_count=$((pre_count + 1))
    done
    
    # Calculate expected timelapse duration and check against threshold
    if [ "$total_source_duration" -lt 60 ]; then
        log "[$camera_name] ⚠️ Pre-check failed: Insufficient source data (${total_source_duration}s, ${failed_chunks} failed chunks)"
        rm -rf "$job_temp_dir"
        return 1
    fi
    
    local speed=${TIMELAPSE_SPEED:-60}
    local expected_timelapse_duration=$(( total_source_duration / speed ))
    local requested_duration=$(( end_ts - start_ts ))
    local ideal_timelapse_duration=$(( requested_duration / speed ))
    local threshold=$(( ideal_timelapse_duration * MIN_DURATION_PERCENT / 100 ))
    
    log "[$camera_name] Pre-check: Source ${total_source_duration}s → Timelapse ~${expected_timelapse_duration}s (threshold: >${threshold}s, ${MIN_DURATION_PERCENT}%)"
    
    if [ "$expected_timelapse_duration" -lt "$threshold" ]; then
        log "[$camera_name] ⚠️ Pre-check failed: Expected timelapse (${expected_timelapse_duration}s) below threshold (${threshold}s)"
        rm -rf "$job_temp_dir"
        return 1
    fi
    
    log "[$camera_name] ✓ Pre-check passed (${failed_chunks} failed chunks tolerated)"
    
    # ========== RENDER: Process and concatenate chunks ==========
    cursor=$start_ts
    count=1

    while [ "$cursor" -lt "$end_ts" ]; do
        local next_cursor=$(($cursor + $TIMELAPSE_CHUNK_SIZE_SEC))
        if [ "$next_cursor" -gt "$end_ts" ]; then next_cursor=$end_ts; fi
        
        local chunk_file="$job_temp_dir/part_${count}.mp4"
        local url="${FRIGATE_HOST}/vod/${camera_name}/start/${cursor}/end/${next_cursor}/index.m3u8"

        # FFMPEG Command: VAAPI HW Accel, scaling, and timestamp modification
        ffmpeg -y -v error \
            -hwaccel vaapi \
            -hwaccel_device "$VAAPI_DEVICE" \
            -hwaccel_output_format vaapi \
            -i "$url" \
            -vf "setpts=PTS/$TIMELAPSE_SPEED,scale_vaapi=format=nv12" \
            -r "$TIMELAPSE_FPS" \
            -c:v h264_vaapi \
            -qp "$TIMELAPSE_QUALITY" \
            -an \
            "$chunk_file"

        if [ $? -eq 0 ] && [ -s "$chunk_file" ]; then
            echo "file '$chunk_file'" >> "$concat_list"
        else
            log "[$camera_name] Warning: Chunk $count failed or empty."
        fi

        cursor=$next_cursor
        count=$((count + 1))
    done

    # Concatenate all processed chunks into final file
    if [ -f "$concat_list" ]; then
        log "[$camera_name] Concatenating timelapse parts..."
        ffmpeg -y -v error -f concat -safe 0 -i "$concat_list" -c copy "$output_file"
        if [ $? -eq 0 ]; then success=1; fi
    fi

    rm -rf "$job_temp_dir"
    
    if [ $success -eq 1 ]; then return 0; else return 1; fi
}

execute_timelapse_pipeline() {
    local cam_name="$1"
    local src="$2"
    local start_ts="$3"
    local end_ts="$4"
    local run_mode="$5"
    local original_tid="$6"
    local chat_id="$7"

    # 1. SETUP & IDENTIFICATION
    local target_tid="${TIMELAPSE_THREAD_ID:-$original_tid}"
    local record_id="${src}_${start_ts}_${end_ts}"
    
    # DB Check #1: Prevent duplicate processing if already successful
    if [ "$run_mode" == "timelapse" ]; then
        local exists=$(db_count "SELECT count(*) FROM timelapse_history WHERE camera='$src' AND range_id='$record_id';")
        if [ "$exists" -gt 0 ]; then return 0; fi
    fi

    local date_str=$(date -d @$start_ts '+%Y%m%d_%H%M')
    local filename="timelapse_${src}_${date_str}.mp4"
    local filepath="$TEMP_DIR/$filename"
    local display_date=$(date -d @$start_ts '+%Y-%m-%d')
    local display_start=$(date -d @$start_ts '+%H:%M')
    local display_end=$(date -d @$end_ts '+%H:%M')
    local pipeline_success=0

    # 2. GENERATE VIDEO (Render)
    if generate_timelapse_video "$src" "$start_ts" "$end_ts" "$filepath"; then
        
        # 3. CHECK DURATION & STATUS
        local total_real_seconds=$(( end_ts - start_ts ))
        local speed=${TIMELAPSE_SPEED:-60}
        local expected_duration=$(( total_real_seconds / speed ))
        
        check_duration_and_status "$src" "$filepath" "$expected_duration" "$record_id"

        if [ "$_status" == "skip" ]; then
            rm -f "$filepath"
            return 1 # Fail status required for retry loop
        fi

        # 4. SEND TELEGRAM
        local total_hours=$(( total_real_seconds / 3600 ))
        local caption="🎞 <b>TIMELAPSE ($total_hours h)</b>
📷 $cam_name
📅 $display_date
⏰ $display_start - $display_end
⏩ Speed: x$speed
⏱️ Duration: ${_fmt_actual} / ${_fmt_expected} (${_percent}%)"

        if send_telegram_video "$filepath" "$chat_id" "$target_tid" "$caption" "$src"; then
            if [ "$run_mode" == "timelapse" ]; then
                
                # 5a. FAILURE HANDLING (Partial)
                if [ "$_status" == "partial" ]; then
                     trigger_failure_alert "$src" "$start_ts" "$end_ts" "Partial Timelapse (Duration: ${_fmt_actual})" "$run_mode" "$_actual"
                     pipeline_success=0
                else
                    # 5b. SUCCESS HANDLING & RECOVERY
                    local current_ts=$(date +%s)
                    
                    handle_recovery_actions "$src" "$record_id"

                    db_exec "INSERT OR IGNORE INTO timelapse_history (camera, range_id, created_at) VALUES ('$src', '$record_id', $current_ts);"
                    log "[$src] Timelapse saved to history."
                    pipeline_success=1
                fi
            else
                log "[$src] Timelapse Sent (Test Mode)."
                pipeline_success=1
            fi
        else
             trigger_failure_alert "$src" "$start_ts" "$end_ts" "Failed to send Timelapse" "$run_mode" "$_actual"
             pipeline_success=0
        fi
    else
        trigger_failure_alert "$src" "$start_ts" "$end_ts" "Failed to generate Timelapse" "$run_mode" "0"
        pipeline_success=0
    fi

    rm -f "$filepath"

    if [ $pipeline_success -eq 1 ]; then return 0; else return 1; fi
}

# ==============================================================================
# CYCLE MANAGEMENT
# ==============================================================================

process_time_window() {
    local cam_name="$1"
    local src="$2"
    local master_start_ts="$3"
    local master_end_ts="$4"
    local run_mode="$5"
    local tid="$6"
    local chat_id="$7"

    if [ "$run_mode" == "test" ]; then
        execute_clip_pipeline "$cam_name" "$src" "$master_start_ts" "$master_end_ts" "$run_mode" "$tid" "$chat_id"
        return
    fi

    # Query DB to find gaps in coverage within the master window
    local existing_clips=$(sqlite3 -cmd ".timeout 30000" "$DB_FILE" "SELECT start_ts, end_ts FROM sent_ranges WHERE camera='$src' AND end_ts > $master_start_ts AND start_ts < $master_end_ts ORDER BY start_ts ASC;")
    
    local cursor=$master_start_ts

    for row in $existing_clips; do
        IFS='|' read -r ex_start ex_end <<< "$row"
        if [ "$ex_start" -gt "$cursor" ]; then
            if [ $((ex_start - cursor)) -gt 10 ]; then
                log "[$src] 💡 Gap: $(date -d @$cursor '+%H:%M') -> $(date -d @$ex_start '+%H:%M')"
                execute_clip_pipeline "$cam_name" "$src" "$cursor" "$ex_start" "$run_mode" "$tid" "$chat_id"
            fi
        fi
        if [ "$ex_end" -gt "$cursor" ]; then cursor=$ex_end; fi
    done

    # Check for tail gap
    if [ "$cursor" -lt "$master_end_ts" ]; then
         if [ $((master_end_ts - cursor)) -gt 10 ]; then
            log "[$src] 💡 Tail Gap: $(date -d @$cursor '+%H:%M') -> $(date -d @$master_end_ts '+%H:%M')"
            execute_clip_pipeline "$cam_name" "$src" "$cursor" "$master_end_ts" "$run_mode" "$tid" "$chat_id"
         fi
    fi
}

process_camera_batch() {
    local cam_info="$1"
    local master_end_ts="$2"
    local duration_min="$3"
    local run_mode="$4"
    IFS='|' read -r name src tid chat_id <<< "$cam_info"
    local duration_sec=$((duration_min * 60))

    if [ "$run_mode" == "test" ]; then
        local start_ts=$(( master_end_ts - duration_sec ))
        process_time_window "$name" "$src" "$start_ts" "$master_end_ts" "$run_mode" "$tid" "$chat_id"
    else
        local total_slots=$(( (LOOKBACK_HOURS * 60) / duration_min ))
        log "[$src] Checking status..."
        for (( i=0; i<total_slots; i++ )); do
            local offset=$(( i * duration_sec ))
            local slot_end_ts=$(( master_end_ts - offset ))
            local slot_start_ts=$(( slot_end_ts - duration_sec ))
            process_time_window "$name" "$src" "$slot_start_ts" "$slot_end_ts" "$run_mode" "$tid" "$chat_id"
        done
        log "[$src] Check complete."
    fi
}

execute_cycle() {
    local duration_min=$1
    local run_mode=$2
    local duration_sec=$((duration_min * 60))
    
    local master_end_ts=$(get_aligned_master_ts "$duration_sec")
    
    log "--- CYCLE START ($run_mode) ---"

    for cam_info in "${CAMERA_ARRAY[@]}"; do
        cam_info=$(echo "$cam_info" | xargs)
        # Limit background jobs
        while [ "$(jobs -r | wc -l)" -ge "$MAX_CONCURRENT_TASKS" ]; do sleep 1; done
        process_camera_batch "$cam_info" "$master_end_ts" "$duration_min" "$run_mode" &
        sleep 1
    done
    wait
    log "--- CYCLE END ---"
}

execute_timelapse_cycle() {
    local run_mode="$1"
    local hours_to_process="$2"
    local duration_sec=$((hours_to_process * 3600))
    local cycle_has_error=0

    local master_end_ts=$(get_aligned_master_ts "$duration_sec")

    log "--- TIMELAPSE CYCLE START ($run_mode) ---"

    for cam_info in "${CAMERA_ARRAY[@]}"; do
        cam_info=$(echo "$cam_info" | xargs)
        IFS='|' read -r name src tid chat_id <<< "$cam_info"
        
        local current_ts=$(date +%s)
        
        if [ "$run_mode" == "test_timelapse" ]; then
            local end_ts=$current_ts
            local start_ts=$((end_ts - duration_sec))
            execute_timelapse_pipeline "$name" "$src" "$start_ts" "$end_ts" "$run_mode" "$tid" "$chat_id"
            continue
        fi

        local total_slots=$(( TIMELAPSE_LOOKBACK_HOURS / hours_to_process ))
        
        log "[$src] Checking missing timelapses..."

        for (( i=0; i<total_slots; i++ )); do
            local offset=$(( i * duration_sec ))
            local slot_end_ts=$(( master_end_ts - offset ))
            local slot_start_ts=$(( slot_end_ts - duration_sec ))
            local range_id="${src}_${slot_start_ts}_${slot_end_ts}"

            # DB Check #2 - redundancy check before attempting generation
            local exists=$(db_count "SELECT count(*) FROM timelapse_history WHERE camera='$src' AND range_id='$range_id';")
            
            if [ "$exists" -eq 0 ]; then
                log "[$src] 🔍 Found missing slot: $(date -d @$slot_start_ts '+%H:%M') - $(date -d @$slot_end_ts '+%H:%M')"
                
                if ! execute_timelapse_pipeline "$name" "$src" "$slot_start_ts" "$slot_end_ts" "timelapse" "$tid" "$chat_id"; then
                    log "[$src] ❌ Failed to process slot. Will retry later."
                    cycle_has_error=1
                fi
            fi
        done
    done
    
    log "--- TIMELAPSE CYCLE END ---"
    
    return $cycle_has_error
}

# ==============================================================================
# MAIN EXECUTION SWITCH
# ==============================================================================

if [ "$MODE" == "test" ]; then
    log ">>> STARTING TEST MODE <<<"
    execute_cycle "$TEST_REC_DURATION_MIN" "test"
    exit 0

elif [ "$MODE" == "record" ]; then
    log ">>> STARTING DAEMON MODE (${REC_DURATION_MIN}m) <<<"
    while true; do
        execute_cycle "$REC_DURATION_MIN" "record"
        current_ts=$(date +%s)
        duration_sec=$((REC_DURATION_MIN * 60))
        # Calculate sleep time to align with next interval
        seconds_into_cycle=$(( current_ts % duration_sec ))
        seconds_to_sleep=$(( duration_sec - seconds_into_cycle ))
        final_sleep=$(( seconds_to_sleep + 20 ))
        log "Sleeping ${final_sleep}s..."
        sleep "$final_sleep"
    done

# --- TIMELAPSE MODES ---

elif [ "$MODE" == "test_timelapse" ]; then
    log ">>> STARTING TIMELAPSE TEST MODE (Last $TIMELAPSE_HOURS hours) <<<"
    execute_timelapse_cycle "test_timelapse" "$TIMELAPSE_HOURS"
    exit 0

elif [ "$MODE" == "timelapse" ]; then
    log ">>> STARTING TIMELAPSE DAEMON (Block: ${TIMELAPSE_HOURS}h) <<<"

    while true; do
        # Run cycle and capture exit status
        execute_timelapse_cycle "timelapse" "$TIMELAPSE_HOURS"
        CYCLE_STATUS=$?

        # === RETRY LOGIC ===
        if [ $CYCLE_STATUS -ne 0 ]; then
            if [ "$TIMELAPSE_STRICT_RETRY" == "true" ]; then
                log "⚠️ Cycle completed with ERRORS. Entering Retry Mode."
                log "Sleeping ${TIMELAPSE_RETRY_SLEEP_SEC}s before retrying missing slots..."
                sleep "$TIMELAPSE_RETRY_SLEEP_SEC"
                continue # Skip long sleep and retry immediately
            else
                log "⚠️ Cycle completed with ERRORS. Strict retry disabled. Continuing to schedule..."
            fi
        fi

        # === SLEEP LOGIC (SUCCESS) ===
        # Only reached if CYCLE_STATUS = 0 (Success) or TIMELAPSE_STRICT_RETRY = false
        
        current_ts=$(date +%s)
        
        # Recalculate TZ offset dynamically
        tz_str=$(date +%z)
        tz_sign=${tz_str:0:1}
        tz_hour=${tz_str:1:2}
        tz_min=${tz_str:3:2}
        tz_offset_sec=$(( (tz_hour * 3600) + (tz_min * 60) ))
        if [ "$tz_sign" == "-" ]; then tz_offset_sec=$((tz_offset_sec * -1)); fi
        
        local_ts=$((current_ts + tz_offset_sec))
        duration_sec=$((TIMELAPSE_HOURS * 3600))
        
        # Calculate sleep to wake up 30s after the next block finishes
        seconds_into_cycle=$(( local_ts % duration_sec ))
        seconds_to_sleep=$(( duration_sec - seconds_into_cycle ))
        final_sleep=$(( seconds_to_sleep + 30 ))
        
        if [ "$final_sleep" -gt 43200 ]; then final_sleep=3600; fi

        sleep_h=$((final_sleep / 3600))
        sleep_m=$(( (final_sleep % 3600) / 60 ))
        sleep_s=$((final_sleep % 60))
        
        log "✅ All caught up. Sleeping ${sleep_h}h ${sleep_m}m ${sleep_s}s until next block..."
        sleep "$final_sleep"
    done

else
    log "Invalid MODE: $MODE"
    exit 1
fi