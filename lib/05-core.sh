#!/bin/bash

# ==============================================================================
# CORE LOGIC MODULE
# Purpose: Video validation, duration checks, recovery actions, and alert triggers.
# ==============================================================================

# Retrieves a specific metric (duration or filesize) from the last failed event
# Purpose: Used to compare current attempt vs previous failure to decide on improvement
get_last_fail_metric() {
    local src="$1"
    local start_ts="$2"
    local end_ts="$3"
    local metric="$4" # 'duration' or 'filesize'

    local value=$(sqlite3 "$DB_FILE" "SELECT $metric FROM events WHERE camera='$src' AND start_ts=$start_ts AND end_ts=$end_ts AND status='FAILED' ORDER BY id DESC LIMIT 1;")
    echo "${value:-0}"
}

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

# Checks if the downloaded video meets duration requirements.
# Sets global variables: _actual, _fmt_actual, _fmt_expected, _percent, _status
check_duration_and_status() {
    local src="$1"
    local filepath="$2"
    local expected_sec="$3"
    local start_ts="$4"
    local end_ts="$5"

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
        
        # Helper call to get previous duration
        local prev_duration=$(get_last_fail_metric "$src" "$start_ts" "$end_ts" "duration")

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
    local start_ts="$2"
    local end_ts="$3"
    
    # Select from unified 'events' table
    local db_row=$(sqlite3 "$DB_FILE" "SELECT msg_id, message FROM events WHERE camera='$src' AND start_ts=$start_ts AND end_ts=$end_ts AND status='FAILED' ORDER BY id DESC LIMIT 1;")
    
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
            send_reaction "$ERROR_CHAT_ID" "$alert_msg_id" "❤️"
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

    # Delete failed event after recovery
    db_exec "DELETE FROM events WHERE camera='$src' AND start_ts=$start_ts AND end_ts=$end_ts AND status='FAILED';"
}

# [Dashboard Update] Added process_sec argument to track performance even on failures
trigger_failure_alert() {
    local src="$1"
    local start_ts="$2"
    local end_ts="$3"
    local fail_type="$4"
    local reason="$5"
    local run_mode="$6"
    local duration="$7"
    local filesize="$8"
    local process_sec="${9:-0}" # Default to 0 if not provided

    # Determine Type based on run_mode
    local type_code="RECORD"
    if [[ "$run_mode" == *"timelapse"* ]]; then type_code="TIMELAPSE"; fi

    if [ "$run_mode" != "record" ] && [ "$run_mode" != "timelapse" ]; then
        log "[$src] $reason (Test Mode - No Alert)"
        return
    fi

    local existing_id=$(db_count "SELECT id FROM events WHERE camera='$src' AND start_ts=$start_ts AND end_ts=$end_ts AND type='$type_code' AND status='FAILED' LIMIT 1;")
    local alert_repeat=$(echo "${ALERT_REPEAT:-false}" | tr '[:upper:]' '[:lower:]')
    local duration_val="${duration:-0}"
    local filesize_val="${filesize:-0}"
    local process_sec_val="${process_sec:-0}"

    # Optimization: Retrieve previous duration and alert_sent flag to decide on update policy
    local prev_duration=0
    # Reason: Retrieve alert_sent flag to determine if notification was already sent
    local prev_alert_sent=0
    if [ "$existing_id" -gt 0 ]; then
        prev_duration=$(sqlite3 "$DB_FILE" "SELECT duration FROM events WHERE id=$existing_id;")
        prev_duration=${prev_duration:-0}
        prev_alert_sent=$(sqlite3 "$DB_FILE" "SELECT alert_sent FROM events WHERE id=$existing_id;")
        prev_alert_sent=${prev_alert_sent:-0}
    fi

    # --- DECISION 1: SHOULD WE UPDATE DB? ---
    # We update DB if:
    # 1. New entry (First fail).
    # 2. Alert Repeat is ON.
    # 3. Video was sent (Partial Success) -> We need to record this even if duration is same.
    # 4. Improvement found.
    local should_update="false"
    if [ "$existing_id" -eq 0 ]; then should_update="true";
    elif [ "$alert_repeat" == "true" ]; then should_update="true";
    elif [ -n "$SENT_VIDEO_MSG_ID" ] && [ "$SENT_VIDEO_MSG_ID" -ne 0 ]; then should_update="true";
    elif [ "$duration_val" -gt "$prev_duration" ]; then should_update="true";
    fi

    if [ "$should_update" != "true" ]; then
          log "[$src] Silent Fail (No improvement & Alert Repeat off): $reason"
          return
    fi

    # Prepare Alert Text
    local mode_upper=$(echo "$run_mode" | tr '[:lower:]' '[:upper:]')
    local alert_text="🚨 <b>EXECUTION FAILED</b>
<b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')
<b>Context:</b> $mode_upper|$src
<b>Error:</b> [$fail_type] $reason
<b>Slot:</b> $(date -d @$start_ts '+%Y-%m-%d %H:%M') - $(date -d @$end_ts '+%H:%M')"

    # [CHANGE] Sanitize text for search_text column
    # Remove HTML tags, quotes, and newlines to prevent SQL errors and ensure clean text search
    local clean_search_text=$(echo "$alert_text" | sed 's/<[^>]*>//g' | sed "s/['\"]//g" | tr -d '\n\r')

    # --- DECISION 2: SHOULD WE SEND TELEGRAM ALERT? ---
    # Send alert if:
    # 1. New error.
    # 2. Improvement.
    # 3. Alert Repeat is ON.
    # 4. No alert was sent previously (alert_sent = 0).
    
    local should_send_alert="false"
    if [ "$existing_id" -eq 0 ]; then should_send_alert="true"; fi
    if [ "$duration_val" -gt "$prev_duration" ]; then should_send_alert="true"; fi
    if [ "$prev_alert_sent" -eq 0 ]; then should_send_alert="true"; fi
    if [ "$alert_repeat" == "true" ]; then should_send_alert="true"; fi

    # Reason: Track if alert was successfully sent in this execution
    local alert_sent_now=0
    if [ "$should_send_alert" == "true" ]; then
        handle_error "$alert_text" "$mode_upper|$src"
        if [ -n "$SENT_ERROR_MSG_ID" ] && [ "$SENT_ERROR_MSG_ID" -ne 0 ]; then
            alert_sent_now=1
        fi
    fi
    
    # Determine MSG_ID to save
    local msg_id_to_save="0"
    
    # Priority 1: The Alert Message ID (if we just sent it)
    if [ -n "$SENT_ERROR_MSG_ID" ] && [ "$SENT_ERROR_MSG_ID" -ne 0 ]; then
         msg_id_to_save="$SENT_ERROR_MSG_ID"
    # Priority 2: Keep existing ID if we didn't send a new alert (to avoid losing the thread)
    elif [ "$existing_id" -gt 0 ]; then
         msg_id_to_save=$(sqlite3 "$DB_FILE" "SELECT msg_id FROM events WHERE id=$existing_id;")
    # Priority 3: If new record but no alert sent (rare), use Video ID if available
    elif [ -n "$SENT_VIDEO_MSG_ID" ] && [ "$SENT_VIDEO_MSG_ID" -ne 0 ]; then
         msg_id_to_save="$SENT_VIDEO_MSG_ID"
    fi
    
    # Save/Update DB
    local current_ts=$(date +%s)
    local b64_text=$(echo "$alert_text" | base64 -w 0)

    # [Dashboard Update] Included process_sec in INSERT and UPDATE
    # [CHANGE] Added search_text to SQL queries
    # Reason: Preserve alert_sent flag across updates, set to 1 if alert sent in this execution
    local final_alert_sent=$prev_alert_sent
    if [ "$alert_sent_now" -eq 1 ]; then
        final_alert_sent=1
    fi

    if [ "$existing_id" -gt 0 ]; then
         # Update existing record
         db_exec "UPDATE events SET created_at=$current_ts, msg_id=$msg_id_to_save, message='$b64_text', duration=$duration_val, fail_type='$fail_type', filesize=$filesize_val, process_sec=$process_sec_val, search_text='$clean_search_text', alert_sent=$final_alert_sent WHERE id=$existing_id;"
    else
         # Insert new failure record
         db_exec "INSERT INTO events (camera, type, status, start_ts, end_ts, created_at, message, msg_id, duration, fail_type, filesize, process_sec, search_text, alert_sent) VALUES ('$src', '$type_code', 'FAILED', $start_ts, $end_ts, $current_ts, '$b64_text', $msg_id_to_save, $duration_val, '$fail_type', $filesize_val, $process_sec_val, '$clean_search_text', $final_alert_sent);"
    fi
}