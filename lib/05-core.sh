#!/bin/bash

# ==============================================================================
# CORE LOGIC MODULE
# Purpose: Video validation, duration checks, recovery actions, and alert triggers.
# ==============================================================================

# [Ops] System Dependency Check
# Purpose: Performs a fail-fast verification of required binaries AND upstream connectivity.
# Prevents the application from running in a broken environment.
verify_system_dependencies() {
    local dependencies=("ffmpeg" "ffprobe" "curl" "sqlite3" "file" "jq")
    local missing_deps=0

    # 1. Check Binaries
    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log "CRITICAL: Required system dependency '$cmd' is missing."
            missing_deps=$((missing_deps + 1))
        fi
    done

    # [Ops] GPU Driver Validation
    # Purpose: Verify VAAPI hardware acceleration path is accessible to prevent 
    # 'Invalid Argument' errors during rendering.
    if [[ "$TIMELAPSE_CODEC" == *"vaapi"* ]]; then
        log_debug "Validating VAAPI status on $VAAPI_DEVICE..."
        if ! vainfo --display drm --device "$VAAPI_DEVICE" > /dev/null 2>&1; then
            log "WARNING: VAAPI hardware acceleration is not responding on $VAAPI_DEVICE."
        fi
    fi

    # 2. Check Upstream Connectivity (Frigate)
    # Purpose: Fail fast if the NVR host is unreachable, avoiding loop errors later.
    log_debug "Checking connectivity to Frigate at $FRIGATE_HOST..."
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${FRIGATE_HOST}/api/version")
    
    # Frigate API usually returns 200 for version endpoint, but we accept any valid HTTP response
    # to indicate the host is reachable.
    if [ "$http_code" == "000" ] || [ -z "$http_code" ]; then
        log "CRITICAL: Unable to connect to Frigate Host ($FRIGATE_HOST). Network unreachable."
        missing_deps=$((missing_deps + 1))
    elif [ "$http_code" -ge 500 ]; then
        log "WARNING: Frigate Host reachable but returning Server Error ($http_code)."
    else
        log_debug "Frigate connection verified (HTTP $http_code)."
    fi

    if [ "$missing_deps" -gt 0 ]; then
        exit 1
    fi
    log_debug "All system dependencies verified."
}

# Calculates the total duration of available footage for a given time range
# by querying Frigate's VOD playlist API without downloading the full video.
# Purpose: Used to pre-check if sufficient source data exists before expensive operations.
calculate_vod_source_duration() {
    local camera_name="$1"
    local start_ts="$2"
    local end_ts="$3"
    
    # Use a unique temporary directory for playlist chunks to verify connectivity/content
    local vod_check_dir="${TEMP_DIR}/vod_check_${camera_name}_${start_ts}_${RANDOM}"
    mkdir -p "$vod_check_dir"

    local cursor=$start_ts
    local total_duration=0
    local count=1
    
    log_debug "[$camera_name] VOD Check Start: $(date -d @$start_ts '+%H:%M') - $(date -d @$end_ts '+%H:%M')"

    # Iterate through time chunks to sum up available segments from HLS playlists
    while [ "$cursor" -lt "$end_ts" ]; do
        local next_cursor=$(($cursor + $TIMELAPSE_CHUNK_SIZE_SEC))
        if [ "$next_cursor" -gt "$end_ts" ]; then next_cursor=$end_ts; fi
        
        local vod_url="${FRIGATE_HOST}/vod/${camera_name}/start/${cursor}/end/${next_cursor}/index.m3u8"
        local playlist_file="$vod_check_dir/check_${count}.m3u8"
        
        # [Debug] Log current chunk being checked
        log_debug "[$camera_name] Checking VOD Chunk $count: $vod_url"

        # Fetch playlist header to extract segment durations
        local http_code=$(curl -s -o "$playlist_file" -w "%{http_code}" "$vod_url")
        
        if [ "$http_code" == "200" ] && [ -s "$playlist_file" ]; then
            # Use ffprobe to check the remote URL header to confirm if a 'video' stream actually exists.
            # Added a 5-second timeout to prevent hanging if the Frigate server is slow to respond.
            local has_video=$(timeout 5 ffprobe -v error -select_streams v:0 -show_entries stream=codec_type -of csv=p=0 "$vod_url" 2>/dev/null | grep -ic "video")
            has_video=${has_video:-0}
            
            if [ "$has_video" -eq 0 ]; then
                log_debug "[$camera_name] Chunk $count has a playlist but NO VIDEO stream (Audio-only). Skipping duration calculation."
                # Intentionally not adding to chunk_duration to exclude audio-only junk data
            else
                # Sum up EXTINF values to get accurate seconds for this chunk
                local chunk_duration=$(grep -o "#EXTINF:[0-9.]*" "$playlist_file" 2>/dev/null | awk -F: '{sum+=$2} END {print int(sum)}')
                chunk_duration=${chunk_duration:-0}
                total_duration=$((total_duration + chunk_duration))
                # [Debug] Log progress of duration accumulation
                log_debug "[$camera_name] Chunk $count Duration: ${chunk_duration}s (Total: ${total_duration}s)"
            fi
        else
            log_debug "[$camera_name] Chunk $count Failed/Empty (HTTP $http_code)"
        fi
        
        cursor=$next_cursor
        count=$((count + 1))
    done

    rm -rf "$vod_check_dir"
    echo "$total_duration"
}

# Centralized gatekeeper to decide if a pipeline should proceed based on source availability.
# Purpose: Consolidate VOD checking and history comparison logic to decide whether to run the pipeline.
check_source_gatekeeper() {
    local src="$1"
    local start_ts="$2"
    local end_ts="$3"
    local mode="$4" # record | timelapse

    local expected_duration=$(( end_ts - start_ts ))
    local vod_duration=$(calculate_vod_source_duration "$src" "$start_ts" "$end_ts")
    
    # Retrieve previous failure info from the database (include retry_count)
    local prev_fail_row=$(sqlite3 "$DB_FILE" "SELECT duration, alert_sent, fail_type, COALESCE(retry_count,0) FROM events WHERE camera='$src' AND start_ts=$start_ts AND end_ts=$end_ts AND status='FAILED' ORDER BY id DESC LIMIT 1;")
    local prev_fail_duration=0
    local prev_alert_sent=0
    local prev_fail_type=""
    local prev_retry_count=0
    if [ -n "$prev_fail_row" ]; then
        prev_fail_duration=$(echo "$prev_fail_row" | awk -F'|' '{print $1}')
        prev_alert_sent=$(echo "$prev_fail_row" | awk -F'|' '{print $2}')
        prev_fail_type=$(echo "$prev_fail_row" | awk -F'|' '{print $3}')
        prev_retry_count=$(echo "$prev_fail_row" | awk -F'|' '{print $4}')
    fi
    prev_fail_duration=${prev_fail_duration:-0}
    prev_alert_sent=${prev_alert_sent:-0}
    prev_retry_count=${prev_retry_count:-0}

    # Calculate estimated output duration to ensure valid comparison with DB history
    # Timelapse duration is (Source / Speed), while Record is (Source).
    local estimated_output=$vod_duration
    if [ "$mode" == "timelapse" ]; then
        local speed=${TIMELAPSE_SPEED:-60}
        estimated_output=$(( vod_duration / speed ))
    fi

    _gatekeeper_estimated_output=$estimated_output

    # Immediate block if estimated output is 0s
    # Prevents "Best Effort" execution when result is guaranteed to be 0s.
    if [ "$estimated_output" -eq 0 ]; then
        # [FIX] Send alert if never sent before for this slot AND within lookback window
        if [ "$prev_alert_sent" -eq 0 ]; then
            # Check if slot is within lookback window (use mode-specific value)
            local current_ts=$(date +%s)
            local alert_window_hours=$LOOKBACK_HOURS
            if [ "$mode" == "timelapse" ]; then
                alert_window_hours=$TIMELAPSE_LOOKBACK_HOURS
            fi
            local alert_window_sec=$((alert_window_hours * 3600))
            local slot_age=$((current_ts - end_ts))
            
            if [ "$slot_age" -le "$alert_window_sec" ]; then
                log "[$src] [$mode] Gatekeeper: No source data (Est: 0s). Sending first-time alert."
                # Set global variables for caller to use (export gatekeeper failure info)
                _gatekeeper_fail="true"
                _gatekeeper_reason="No Recording Data Available (VOD: 0s)"
                _gatekeeper_prev_alert_sent=$prev_alert_sent
                return 1
            else
                log "[$src] [$mode] Gatekeeper: Skipping old slot (Age: $((slot_age/3600))h > ${alert_window_hours}h window)."
                return 1
            fi
        fi
        log "[$src] [$mode] Gatekeeper: Skipping (No valid source data found - Est: 0s, Alert already sent)."
        return 1
    fi
    
    # Reset gatekeeper fail flag
    _gatekeeper_fail="false"

    # [Debug] Comparison log for easier inspection
    if [ "$prev_fail_duration" -gt 0 ]; then
        log_debug "[$src] Gatekeeper Check: Est. Output ${estimated_output}s vs Prev Fail ${prev_fail_duration}s (VOD: ${vod_duration}s)"
    fi

    # Blocking logic: If an alert was already sent and the estimated output hasn't increased
    # Use estimated_output instead of vod_duration
    # Advanced pipeline loop prevention based on previous failure type
    local prev_type_uc=$(echo "${prev_fail_type:-}" | tr '[:lower:]' '[:upper:]')
    if [ "$prev_type_uc" == "TELEGRAM" ]; then
        log_debug "[$src] Gatekeeper: Previous fail_type=TELEGRAM, forcing retry."
    elif [ "$prev_type_uc" == "DURATION" ]; then
        # Data problem: if estimated output hasn't increased, skip permanently
        if [ "$estimated_output" -le "$prev_fail_duration" ]; then
            log "[$src] [$mode] Gatekeeper: DURATION fail confirmed (VOD unchanged). Skipping to prevent loop."
            return 1
        fi
    elif [ "$prev_type_uc" == "CRASH_PARTIAL" ]; then
        # System crash: allow limited retries or unlimited if configured
        local max_crash_retries=${CRASH_MAX_RETRIES:-3}

        # Interpret CRASH_MAX_RETRIES=0 as unlimited retries
        if [ "$max_crash_retries" -ne 0 ] && [ "$prev_retry_count" -ge "$max_crash_retries" ]; then
            log "[$src] [$mode] Gatekeeper: CRASH_PARTIAL limit reached ($max_crash_retries attempts). Skipping permanently."
            return 1
        fi

        if [ "$max_crash_retries" -eq 0 ]; then
            log "[$src] [$mode] Gatekeeper: Retrying CRASH_PARTIAL (Attempt $((prev_retry_count + 1))/unlimited)."
        else
            log "[$src] [$mode] Gatekeeper: Retrying CRASH_PARTIAL (Attempt $((prev_retry_count + 1))/$max_crash_retries)."
        fi
    else
        # Other error types: skip if no improvement and alert previously sent
        if [ "$prev_alert_sent" -eq 1 ] && [ "$estimated_output" -le "$prev_fail_duration" ]; then
            log "[$src] [$mode] Gatekeeper: Skipping (Est. ${estimated_output}s <= previous ${prev_fail_duration}s)."
            return 1
        fi
    fi

    # Determine threshold according to mode
    local threshold=0
    if [ "$mode" == "record" ]; then
        threshold=$(( expected_duration * MIN_DURATION_PERCENT / 100 ))
    else
        local speed=${TIMELAPSE_SPEED:-60}
        local ideal_timelapse_duration=$(( expected_duration / speed ))
        threshold=$(( ideal_timelapse_duration * MIN_DURATION_PERCENT / 100 ))
        
        # Compare based on raw VOD for Smart Skip (retain this logic as it checks the input)
        if [ "$vod_duration" -lt "$TIMELAPSE_MIN_DURATION_SEC" ]; then
            # [FIX] Compare with estimated output here to be safe
            if [ "$estimated_output" -le "$prev_fail_duration" ] && [ "$prev_fail_duration" -ge 0 ]; then
                log "[$src] [$mode] Gatekeeper: Smart Skip (Insufficient VOD & No Improvement)."
                return 1
            fi
        fi
    fi

    # [FIX] Use estimated_output for threshold comparison
    if [ "$estimated_output" -lt "$threshold" ]; then
        log "[$src] [$mode] Gatekeeper: Insufficient data (Est. ${estimated_output}s < ${threshold}s), proceeding best-effort."
    fi

    return 0
}

# Retrieves a specific metric (duration or filesize) from the last failed event
# Purpose: Used to compare current attempt vs previous failure to decide on improvement
get_last_fail_metric() {
    local src="$1"
    local start_ts="$2"
    local end_ts="$3"
    local metric="$4" # 'duration' or 'filesize'

    # [CHANGE] Updated SQL formatting from script 2 for readability
    local value=$(sqlite3 "$DB_FILE" \
        "SELECT $metric FROM events \
         WHERE camera='$src' \
           AND start_ts=$start_ts \
           AND end_ts=$end_ts \
           AND status='FAILED' \
         ORDER BY id DESC \
         LIMIT 1;")
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
    
    # [CHANGE] Replaced hardcoded '1024' with MIN_FILESIZE_BYTES env var
    if [ "$filesize" -lt "$MIN_FILESIZE_BYTES" ]; then 
        log_debug "Validation failed: File too small (< $MIN_FILESIZE_BYTES bytes)"
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

    # [FIX] Block immediately if video is empty/corrupt (0s)
    # Reason: Prevents logic flow from considering 0s as a valid partial success.
    if [ "$actual" -eq 0 ]; then
        log "[$src] 🚫 Video duration is 0s (Corrupt/Empty). Skipping immediately."
        _status="skip"
        _actual=0
        _fmt_actual="0s"
        _percent=0
        return
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
    
    # [CHANGE] Updated SQL formatting from script 2
    local db_row=$(sqlite3 "$DB_FILE" \
        "SELECT msg_id, message FROM events \
         WHERE camera='$src' \
           AND start_ts=$start_ts \
           AND end_ts=$end_ts \
           AND status='FAILED' \
         ORDER BY id DESC \
         LIMIT 1;")
    
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
    # [CHANGE] Updated SQL formatting
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

    local existing_id=$(db_count \
        "SELECT id FROM events \
         WHERE camera='$src' \
           AND start_ts=$start_ts \
           AND end_ts=$end_ts \
           AND type='$type_code' \
           AND status='FAILED' \
         LIMIT 1;")

    local alert_repeat=$(echo "${ALERT_REPEAT:-false}" | tr '[:upper:]' '[:lower:]')
    local duration_val="${duration:-0}"
    local filesize_val="${filesize:-0}"
    local process_sec_val="${process_sec:-0}"

    local prev_duration=0
    local prev_alert_sent=0
    local prev_retry_count=0
    if [ "$existing_id" -gt 0 ]; then
        prev_duration=$(sqlite3 "$DB_FILE" "SELECT duration FROM events WHERE id=$existing_id;")
        prev_duration=${prev_duration:-0}
        prev_alert_sent=$(sqlite3 "$DB_FILE" "SELECT alert_sent FROM events WHERE id=$existing_id;")
        prev_alert_sent=${prev_alert_sent:-0}
        prev_retry_count=$(sqlite3 "$DB_FILE" "SELECT COALESCE(retry_count,0) FROM events WHERE id=$existing_id;")
        prev_retry_count=${prev_retry_count:-0}
    fi

    # [Debug] Log key variables affecting alert decision logic
    log_debug "[$src] Failure Analysis: ExistingID=$existing_id, PrevDur=$prev_duration, CurrDur=$duration_val, Repeat=$alert_repeat"

    # --- DECISION 1: SHOULD WE UPDATE DB? ---
    # [CHANGE] Applied logic from script 2: Removed check for SENT_VIDEO_MSG_ID
    local should_update="false"
    if [ "$existing_id" -eq 0 ]; then should_update="true";
    elif [ "$alert_repeat" == "true" ]; then should_update="true";
    elif [ "$duration_val" -gt "$prev_duration" ]; then should_update="true";
    elif [ "$prev_alert_sent" -eq 0 ]; then should_update="true"; # [FIX] Allow update if alert never sent
    fi

    if [ "$should_update" != "true" ]; then
          log "[$src] Silent Fail (No improvement & Alert Repeat off): $reason"
          return
    fi

    # [CHANGE] Clean search text is now derived only from $reason (from script 2)
    local clean_search_text=$(echo "$reason" | sed 's/<[^>]*>//g' | sed "s/['\"]//g" | tr -d '\n\r')

    # --- DECISION 2: SHOULD WE SEND TELEGRAM ALERT? ---
    # [CHANGE] Logic flow updated to match script 2
    local should_send_alert="false"
    if [ "$existing_id" -eq 0 ]; then should_send_alert="true"; 
    elif [ "$duration_val" -gt "$prev_duration" ]; then should_send_alert="true";
    elif [ "$prev_alert_sent" -eq 0 ]; then should_send_alert="true";
    elif [ "$alert_repeat" == "true" ]; then should_send_alert="true"; 
    fi

    # [Debug] Log final decisions
    log_debug "[$src] Failure Decision: UpdateDB=$should_update, SendAlert=$should_send_alert"

    local alert_sent_now=0
    local msg_id_to_save="0"
    local b64_alert_text=""

    # [CHANGE] Prepare Alert Text only if sending alert (Optimization from script 2)
    if [ "$should_send_alert" == "true" ]; then
        local mode_upper=$(echo "$run_mode" | tr '[:lower:]' '[:upper:]')
        local alert_text="🚨 <b>EXECUTION FAILED</b>
<b>Time:</b> $(date '+%Y-%m-%d %H:%M:%S')
<b>Context:</b> $mode_upper|$src
<b>Error:</b> [$fail_type] $reason
<b>Slot:</b> $(date -d @$start_ts '+%Y-%m-%d %H:%M') - $(date -d @$end_ts '+%H:%M')"
        
        # [Data Persistence] Encode alert text to Base64 for database storage.
        # Required for 'handle_recovery_actions' to reconstruct the message later.
        b64_alert_text=$(echo "$alert_text" | base64 -w 0)

        handle_error "$alert_text" "$mode_upper|$src"
        
        if [ -n "$SENT_ERROR_MSG_ID" ] && [ "$SENT_ERROR_MSG_ID" -ne 0 ]; then
            alert_sent_now=1
            msg_id_to_save="$SENT_ERROR_MSG_ID"
        fi
    else
        # If not sending new alert, try to preserve existing ID
        if [ "$existing_id" -gt 0 ]; then
             msg_id_to_save=$(sqlite3 "$DB_FILE" "SELECT msg_id FROM events WHERE id=$existing_id;")
             # [Data Persistence] Retrieve existing message from DB to prevent data loss on update
             b64_alert_text=$(sqlite3 "$DB_FILE" "SELECT message FROM events WHERE id=$existing_id;")
        fi
    fi
    
    # Save/Update DB
    local current_ts=$(date +%s)
    # [CHANGE] Restored Base64 storage logic for 'message' column

    local final_alert_sent=$prev_alert_sent
    if [ "$alert_sent_now" -eq 1 ]; then
        final_alert_sent=1
    fi

    # Compute new retry count (increment when updating existing failure record)
    local new_retry_count=1
    if [ "$existing_id" -gt 0 ]; then
        new_retry_count=$((prev_retry_count + 1))
    fi

    if [ "$existing_id" -gt 0 ]; then
         # [Database] Update record including 'message' persistence
         db_exec \
            "UPDATE events \
             SET created_at=$current_ts, \
                 msg_id=$msg_id_to_save, \
                 message='$b64_alert_text', \
                 duration=$duration_val, \
                 fail_type='$fail_type', \
                 filesize=$filesize_val, \
                 process_sec=$process_sec_val, \
                 search_text='$clean_search_text', \
                 alert_sent=$final_alert_sent, \
                 retry_count=$new_retry_count \
             WHERE id=$existing_id;"
    else
         # [Database] Insert new record with 'message' column
         db_exec \
            "INSERT INTO events \
             (camera, type, status, start_ts, end_ts, created_at, \
              message, msg_id, duration, fail_type, filesize, process_sec, \
              search_text, alert_sent, retry_count) \
             VALUES \
             ('$src', '$type_code', 'FAILED', $start_ts, $end_ts, $current_ts, \
              '$b64_alert_text', $msg_id_to_save, $duration_val, '$fail_type', $filesize_val, $process_sec_val, \
              '$clean_search_text', $final_alert_sent, $new_retry_count);"
    fi
}