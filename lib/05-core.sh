#!/bin/bash

# ==============================================================================
# CORE LOGIC MODULE
# Purpose: Video validation, duration checks, recovery actions, and alert triggers.
# ==============================================================================

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
        
        # Support partial success logic with new schema
        local prev_duration=$(sqlite3 "$DB_FILE" "SELECT duration FROM events WHERE camera='$src' AND start_ts=$start_ts AND end_ts=$end_ts AND status='FAILED' ORDER BY id DESC LIMIT 1;")
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

    # Delete failed event after recovery
    db_exec "DELETE FROM events WHERE camera='$src' AND start_ts=$start_ts AND end_ts=$end_ts AND status='FAILED';"
}

trigger_failure_alert() {
    local src="$1"
    local start_ts="$2"
    local end_ts="$3"
    local fail_type="$4"
    local reason="$5"
    local run_mode="$6"
    local duration="$7"

    # Determine Type based on run_mode
    local type_code="RECORD"
    if [[ "$run_mode" == *"timelapse"* ]]; then type_code="TIMELAPSE"; fi

    if [ "$run_mode" != "record" ] && [ "$run_mode" != "timelapse" ]; then
        log "[$src] $reason (Test Mode - No Alert)"
        return
    fi

    local existing_id=$(db_count "SELECT id FROM events WHERE camera='$src' AND start_ts=$start_ts AND end_ts=$end_ts AND type='$type_code' AND status='FAILED' LIMIT 1;")
    local alert_repeat=$(echo "${ALERT_REPEAT:-false}" | tr '[:upper:]' '[:lower:]')

    # Logic: Only update if it's a "Partial Update" or if repeat alerts are enabled.
    if [ "$existing_id" -gt 0 ] && [ "$alert_repeat" != "true" ]; then
        # If we sent a video (Partial Success), update the DB with new msg_id but don't re-alert.
        if [ -n "$SENT_VIDEO_MSG_ID" ] && [ "$SENT_VIDEO_MSG_ID" -ne 0 ]; then
             local current_ts=$(date +%s)
             local duration_val="${duration:-0}"
             # Update the existing record with new message ID and improved duration
             db_exec "UPDATE events SET msg_id=$SENT_VIDEO_MSG_ID, duration=$duration_val, created_at=$current_ts WHERE id=$existing_id;"
             log "[$src] Partial improvement: Updated event DB with new Video MsgID ($SENT_VIDEO_MSG_ID) and duration ($duration_val)."
             return
        fi

        log "[$src] Silent Fail (Already Alerted): $reason"
    else
        # Prepare Alert Text
        local mode_upper=$(echo "$run_mode" | tr '[:lower:]' '[:upper:]')
        
        # Use fail_type in the notification text for clarity
        local alert_text="🚨 <b>EXECUTION FAILED</b>
<b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')
<b>Context:</b> $mode_upper|$src
<b>Error:</b> [$fail_type] $reason
<b>Slot:</b> $(date -d @$start_ts '+%Y-%m-%d %H:%M') - $(date -d @$end_ts '+%H:%M')"

        # Send Alert
        local msg_id_to_save="0"
        
        if [ -n "$SENT_VIDEO_MSG_ID" ] && [ "$SENT_VIDEO_MSG_ID" -ne 0 ]; then
            msg_id_to_save="$SENT_VIDEO_MSG_ID"
        else
            handle_error "$alert_text" "$mode_upper|$src"
            msg_id_to_save="${SENT_ERROR_MSG_ID:-0}"
        fi
        
        # Save to DB (Insert new failure record)
        local current_ts=$(date +%s)
        local b64_text=$(echo "$alert_text" | base64 -w 0)
        local duration_val="${duration:-0}"

        if [ "$existing_id" -gt 0 ] && [ "$alert_repeat" == "true" ]; then
             # If repeat is on, we update timestamp and Msg ID (fail_type might change on retry)
             db_exec "UPDATE events SET created_at=$current_ts, msg_id=$msg_id_to_save, message='$b64_text', duration=$duration_val, fail_type='$fail_type' WHERE id=$existing_id;"
        else
             # Insert into 'events' with separate fail_type column
             db_exec "INSERT INTO events (camera, type, status, start_ts, end_ts, created_at, message, msg_id, duration, fail_type) VALUES ('$src', '$type_code', 'FAILED', $start_ts, $end_ts, $current_ts, '$b64_text', $msg_id_to_save, $duration_val, '$fail_type');"
        fi
    fi
}