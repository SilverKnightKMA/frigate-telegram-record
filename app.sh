#!/bin/bash

# ==============================================================================
# CONFIGURATION LOADER
# ==============================================================================

CONFIG_FILE="/app/config/config.env"

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        echo "[INFO] Loading config from file: $CONFIG_FILE"
        while IFS='=' read -r key value; do
            if [[ $key =~ ^# ]] || [[ -z $key ]]; then continue; fi
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            if [ -z "${!key}" ]; then export "$key=$value"; fi
        done < "$CONFIG_FILE"
    fi
}
load_config

export TZ="${TZ:-Asia/Ho_Chi_Minh}"
FRIGATE_HOST="${FRIGATE_HOST:-http://127.0.0.1:5000}"
TELEGRAM_API_URL="${TELEGRAM_API_URL:-https://api.telegram.org}"

DATA_DIR="/app/data"
TEMP_DIR="/dev/shm/frigate_clips"
LOG_FILE="$DATA_DIR/execution.log"
DB_FILE="$DATA_DIR/video_history.sqlite"

# --- TUNING CONFIG ---
RETENTION_DAYS="${RETENTION_DAYS:-30}"
ALERT_RETENTION_DAYS="${ALERT_RETENTION_DAYS:-3}"
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
# Keep low to avoid database locks
MAX_CONCURRENT_TASKS="${MAX_CONCURRENT_TASKS:-2}" 
PADDING_SEC="${PADDING_SEC:-5}"
MAX_RETRIES="${MAX_RETRIES:-5}"

REC_DURATION_MIN="${REC_DURATION_MIN:-15}"
TEST_REC_DURATION_MIN="${TEST_REC_DURATION_MIN:-1}"
MODE="${MODE:-record}"

# ==============================================================================
# SYSTEM PREP & LOGGING
# ==============================================================================

mkdir -p "$DATA_DIR"
mkdir -p "$TEMP_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [PID:$$] [INFO] $1"
}

# --- HELPER: SAFE DATABASE QUERY ---
# Timeout 30s to prevent 'database is locked' errors
db_exec() {
    sqlite3 -cmd ".timeout 30000" "$DB_FILE" "$1"
}

db_count() {
    local result=$(sqlite3 -cmd ".timeout 30000" "$DB_FILE" "$1" 2>/dev/null)
    if [[ ! "$result" =~ ^[0-9]+$ ]]; then
        echo "0"
    else
        echo "$result"
    fi
}

# --- ERROR HANDLER ---
handle_error() {
    local msg="$1"
    local context="$2"
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$ts] [ERROR] [$context] $msg" | tee -a "$LOG_FILE"
    
    if [ -n "$ERROR_CHAT_ID" ]; then
        local alert_text="🚨 <b>EXECUTION FAILED</b>
<b>Time:</b> $ts
<b>Context:</b> $context
<b>Error:</b> $msg"

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
            local curl_exit=$?
            local response_content=$(cat "$response_body")

            if [ "$http_code" == "200" ] && echo "$response_content" | grep -q '"ok":true'; then
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

# Parse Cameras
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
    
    local sent_cleanup_ts=$(date -d "-$RETENTION_DAYS days" +%s)
    db_exec "DELETE FROM sent_ranges WHERE created_at < $sent_cleanup_ts;"

    local alert_cleanup_ts=$(date -d "-$ALERT_RETENTION_DAYS days" +%s)
    db_exec "DELETE FROM alert_history WHERE created_at < $alert_cleanup_ts;"
}
init_db

validate_video() {
    local filepath="$1"
    if [ ! -s "$filepath" ]; then return 1; fi
    local filesize=$(stat -c%s "$filepath" 2>/dev/null || echo 0)
    if [ "$filesize" -lt 1024 ]; then return 1; fi
    local mime_type=$(file --brief --mime-type "$filepath")
    if [ "$mime_type" != "video/mp4" ] && [ "$mime_type" != "application/octet-stream" ]; then return 1; fi
    if command -v ffprobe &> /dev/null; then
        if ! ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$filepath" >/dev/null 2>&1; then return 1; fi
    fi
    return 0
}

send_telegram_video() {
    local filepath="$1"
    local chat_id="$2"
    local thread_id="$3"
    local caption="$4"
    local src="$5"

    local attempt=1
    local response_body=$(mktemp)

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

        local http_code=$(curl "${args[@]}")
        local curl_exit=$?
        local response_content=$(cat "$response_body")
        
        if [ $curl_exit -ne 0 ]; then
            log "[$src] Curl failed (Exit Code: $curl_exit)."
            rm -f "$response_body"
            handle_error "Network Error (Curl Exit $curl_exit)" "SEND|$src"
            return 1
        fi

        if [ "$http_code" == "200" ] && echo "$response_content" | grep -q '"ok":true'; then
            rm -f "$response_body"
            return 0
        fi

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
# PIPELINE LOGIC
# ==============================================================================

trigger_failure_alert() {
    local src="$1"
    local start_ts="$2"
    local end_ts="$3"
    local reason="$4"
    local run_mode="$5"

    if [ "$run_mode" != "record" ]; then
        log "[$src] $reason (Test Mode - No Alert)"
        return
    fi

    local record_id="${src}_${start_ts}_${end_ts}"
    local alerted=$(db_count "SELECT count(*) FROM alert_history WHERE id='$record_id';")
    
    if [ "$alerted" -gt 0 ]; then
        log "[$src] Silent Fail (Already Alerted): $reason"
    else
        # --- FIX HIỂN THỊ NGÀY GIỜ TẠI ĐÂY ---
        handle_error "Failed to record/download video.
<b>Reason:</b> $reason
<b>Slot:</b> $(date -d @$start_ts '+%Y-%m-%d %H:%M') - $(date -d @$end_ts '+%H:%M')" "RECORDING|$src"
        
        local current_ts=$(date +%s)
        db_exec "INSERT OR IGNORE INTO alert_history (id, camera, created_at) VALUES ('$record_id', '$src', $current_ts);"
    fi
}

execute_clip_pipeline() {
    local src="$1"
    local start_ts="$2"
    local end_ts="$3"
    local run_mode="$4"
    local tid="$5"
    local chat_id="$6"

    local record_id="${src}_${start_ts}_${end_ts}"

    local display_date=$(date -d @$start_ts '+%Y-%m-%d')
    local display_start=$(date -d @$start_ts '+%H:%M')
    local display_end=$(date -d @$end_ts '+%H:%M')
    
    local date_file=$(date -d @$start_ts '+%Y%m%d')
    local start_file=$(date -d @$start_ts '+%H%M')
    local end_file=$(date -d @$end_ts '+%H%M')
    local filename="${src}_${date_file}_${start_file}_${end_file}_${run_mode}.mp4"
    local filepath="$TEMP_DIR/$filename"
    
    local dl_start_ts=$(( start_ts - PADDING_SEC ))
    local dl_end_ts=$(( end_ts + PADDING_SEC ))
    local url="${FRIGATE_HOST}/api/${src}/start/${dl_start_ts}/end/${dl_end_ts}/clip.mp4"

    local http_code=$(curl -s -o "$filepath" -w "%{http_code}" "$url")

    if [ "$http_code" == "200" ]; then
        if validate_video "$filepath"; then
            local caption="📷 <b>$src</b>
📅 $display_date
⏰ ${display_start} - ${display_end}
⏱️ Duration: $(( (end_ts - start_ts) / 60 ))m"

            if send_telegram_video "$filepath" "$chat_id" "$tid" "$caption" "$src"; then
                if [ "$run_mode" == "record" ]; then
                    local current_ts=$(date +%s)
                    db_exec "INSERT OR IGNORE INTO sent_ranges (camera, start_ts, end_ts, created_at) VALUES ('$src', $start_ts, $end_ts, $current_ts);"
                    db_exec "DELETE FROM alert_history WHERE id='$record_id';"
                    
                    log "[$src] ✅ Success."
                else
                    log "[$src] Sent (Test Mode)."
                fi
            fi
        else
            trigger_failure_alert "$src" "$start_ts" "$end_ts" "Validation failed (Size: $(stat -c%s "$filepath" 2>/dev/null)b)" "$run_mode"
        fi

    elif [ "$http_code" == "404" ]; then
        trigger_failure_alert "$src" "$start_ts" "$end_ts" "Frigate 404 (Video Not Found)" "$run_mode"
    else
        trigger_failure_alert "$src" "$start_ts" "$end_ts" "Download HTTP Error $http_code" "$run_mode"
    fi
    
    rm -f "$filepath"
}

process_time_window() {
    local src="$1"
    local master_start_ts="$2"
    local master_end_ts="$3"
    local run_mode="$4"
    local tid="$5"
    local chat_id="$6"

    if [ "$run_mode" == "test" ]; then
        execute_clip_pipeline "$src" "$master_start_ts" "$master_end_ts" "$run_mode" "$tid" "$chat_id"
        return
    fi

    # Timeout added to SELECT via -cmd
    local existing_clips=$(sqlite3 -cmd ".timeout 30000" "$DB_FILE" "SELECT start_ts, end_ts FROM sent_ranges WHERE camera='$src' AND end_ts > $master_start_ts AND start_ts < $master_end_ts ORDER BY start_ts ASC;")
    
    local cursor=$master_start_ts

    for row in $existing_clips; do
        IFS='|' read -r ex_start ex_end <<< "$row"
        if [ "$ex_start" -gt "$cursor" ]; then
            if [ $((ex_start - cursor)) -gt 10 ]; then
                log "[$src] 💡 Gap: $(date -d @$cursor '+%H:%M') -> $(date -d @$ex_start '+%H:%M')"
                execute_clip_pipeline "$src" "$cursor" "$ex_start" "$run_mode" "$tid" "$chat_id"
            fi
        fi
        if [ "$ex_end" -gt "$cursor" ]; then cursor=$ex_end; fi
    done

    if [ "$cursor" -lt "$master_end_ts" ]; then
         if [ $((master_end_ts - cursor)) -gt 10 ]; then
            log "[$src] 💡 Tail Gap: $(date -d @$cursor '+%H:%M') -> $(date -d @$master_end_ts '+%H:%M')"
            execute_clip_pipeline "$src" "$cursor" "$master_end_ts" "$run_mode" "$tid" "$chat_id"
         fi
    fi
}

execute_cycle() {
    local duration_min=$1
    local run_mode=$2
    local duration_sec=$((duration_min * 60))
    
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
    
    log "--- CYCLE START ($run_mode) ---"

    for cam_info in "${CAMERA_ARRAY[@]}"; do
        cam_info=$(echo "$cam_info" | xargs)
        while [ "$(jobs -r | wc -l)" -ge "$MAX_CONCURRENT_TASKS" ]; do sleep 1; done
        process_camera_batch "$cam_info" "$master_end_ts" "$duration_min" "$run_mode" &
        sleep 1
    done
    wait
    log "--- CYCLE END ---"
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
        process_time_window "$src" "$start_ts" "$master_end_ts" "$run_mode" "$tid" "$chat_id"
    else
        local total_slots=$(( (LOOKBACK_HOURS * 60) / duration_min ))
        log "[$src] Checking status..."
        for (( i=0; i<total_slots; i++ )); do
            local offset=$(( i * duration_sec ))
            local slot_end_ts=$(( master_end_ts - offset ))
            local slot_start_ts=$(( slot_end_ts - duration_sec ))
            process_time_window "$src" "$slot_start_ts" "$slot_end_ts" "$run_mode" "$tid" "$chat_id"
        done
        log "[$src] Check complete."
    fi
}

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
        seconds_into_cycle=$(( current_ts % duration_sec ))
        seconds_to_sleep=$(( duration_sec - seconds_into_cycle ))
        final_sleep=$(( seconds_to_sleep + 20 ))
        log "Sleeping ${final_sleep}s..."
        sleep "$final_sleep"
    done
else
    log "Invalid MODE: $MODE"
    exit 1
fi
