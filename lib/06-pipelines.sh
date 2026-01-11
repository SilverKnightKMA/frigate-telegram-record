#!/bin/bash

# ==============================================================================
# PIPELINE MODULE
# Purpose: Orchestrates the download/rendering, validation, and sending process.
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
    
    # Use --write-out to print status code to stdout while saving body to file
    local http_code=$(curl -s -L -o "$filepath" --write-out "%{http_code}" "$url")
    echo "$http_code"
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
    local date_file=$(date -d @$start_ts '+%Y%m%d')
    local start_file=$(date -d @$start_ts '+%H%M')
    local end_file=$(date -d @$end_ts '+%H%M')
    local filename="${src}_${date_file}_${start_file}_${end_file}_${run_mode}.mp4"
    local filepath="$TEMP_DIR/$filename"
    local display_date=$(date -d @$start_ts '+%Y-%m-%d')
    local display_start=$(date -d @$start_ts '+%H:%M')
    local display_end=$(date -d @$end_ts '+%H:%M')

    local dl_start_ts=$(( start_ts - PADDING_SEC ))
    local dl_end_ts=$(( end_ts + PADDING_SEC ))
    local url="${FRIGATE_HOST}/api/${src}/start/${dl_start_ts}/end/${dl_end_ts}/clip.mp4"

    # === OPTIMIZATION: Check Remote Size Before Download ===
    # Attempt to get Content-Length via HEAD request. Added -L to follow redirects.
    # We capture the full header to check status code as well.
    local header_dump=$(curl -sI -L "$url")
    local remote_size=$(echo "$header_dump" | grep -i "Content-Length" | awk '{print $2}' | tr -d '\r')
    local header_status=$(echo "$header_dump" | head -n 1 | awk '{print $2}')

    # Check validity
    if [[ "$remote_size" =~ ^[0-9]+$ ]] && [ "$remote_size" -gt 0 ]; then
        # Retrieve the maximum filesize recorded in DB for this slot
        local db_max_size=$(sqlite3 "$DB_FILE" "SELECT MAX(filesize) FROM events WHERE camera='$src' AND start_ts=$start_ts AND end_ts=$end_ts;")
        db_max_size=${db_max_size:-0}

        if [ "$remote_size" -le "$db_max_size" ]; then
            log "[$src] ⏩ Skipping Download: Remote size ($remote_size bytes) <= DB record ($db_max_size bytes)."
            return
        else
            log_debug "[$src] Remote size ($remote_size) > DB record ($db_max_size). Proceeding with download."
        fi
    else
        # Reason analysis for log
        if [ "$header_status" != "200" ] && [ -n "$header_status" ]; then
            log_debug "[$src] Pre-check skipped: HTTP Status $header_status"
        else
            log_debug "[$src] Pre-check skipped: Server using Chunked Encoding (No Content-Length)."
        fi
    fi
    # =======================================================

    log_debug "[$src] File path: $filepath"

    # 2. GENERATE VIDEO (Download)
    local http_code=$(download_clip "$src" "$start_ts" "$end_ts" "$filepath")
    
    log_debug "[$src] Download HTTP code: $http_code"

    if [ "$http_code" == "200" ]; then
        local current_filesize=$(stat -c%s "$filepath" 2>/dev/null || echo 0)

        if validate_video "$filepath"; then
            
            # 3. CHECK DURATION & STATUS
            local expected_duration=$(( end_ts - start_ts ))
            log_debug "[$src] Expected duration: ${expected_duration}s"
            
            check_duration_and_status "$src" "$filepath" "$expected_duration" "$start_ts" "$end_ts"
            
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
                        trigger_failure_alert "$src" "$start_ts" "$end_ts" "DURATION" "Partial Video (Duration: ${_fmt_actual})" "$run_mode" "$_actual" "$current_filesize"
                    else
                        # 5b. SUCCESS HANDLING & RECOVERY
                        local current_ts=$(date +%s)
                        local sent_msg_id="${SENT_VIDEO_MSG_ID:-0}"
                        local msg_b64=$(echo "Record Sent" | base64 -w 0)
                        
                        handle_recovery_actions "$src" "$start_ts" "$end_ts"

                        # Insert record into 'events' with type='RECORD' and filesize
                        db_exec "INSERT INTO events (camera, type, status, start_ts, end_ts, created_at, message, msg_id, duration, filesize) VALUES ('$src', 'RECORD', 'SUCCESS', $start_ts, $end_ts, $current_ts, '$msg_b64', $sent_msg_id, $_actual, $current_filesize);"
                        log "[$src] ✅ Success (MsgID: $sent_msg_id, Size: $current_filesize)."
                    fi
                else
                    log "[$src] Sent (Test Mode)."
                fi
            else
                trigger_failure_alert "$src" "$start_ts" "$end_ts" "TELEGRAM" "Failed to send Video" "$run_mode" "$_actual" "$current_filesize"
            fi
        else
            trigger_failure_alert "$src" "$start_ts" "$end_ts" "VALIDATION" "File Check Failed (Size: $current_filesize)" "$run_mode" "0" "$current_filesize"
        fi
    elif [ "$http_code" == "404" ]; then
        trigger_failure_alert "$src" "$start_ts" "$end_ts" "DOWNLOAD" "Frigate 404 (Video Not Found)" "$run_mode" "0" "0"
    else
        trigger_failure_alert "$src" "$start_ts" "$end_ts" "DOWNLOAD" "HTTP Error $http_code" "$run_mode" "0" "0"
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
    
    # DB Check #1: Prevent duplicate processing if already successful
    if [ "$run_mode" == "timelapse" ]; then
        local exists=$(db_count "SELECT count(*) FROM events WHERE camera='$src' AND start_ts=$start_ts AND end_ts=$end_ts AND type='TIMELAPSE' AND status='SUCCESS';")
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
        
        local current_filesize=$(stat -c%s "$filepath" 2>/dev/null || echo 0)

        # 3. CHECK DURATION & STATUS
        local total_real_seconds=$(( end_ts - start_ts ))
        local speed=${TIMELAPSE_SPEED:-60}
        local expected_duration=$(( total_real_seconds / speed ))
        
        check_duration_and_status "$src" "$filepath" "$expected_duration" "$start_ts" "$end_ts"

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
                      trigger_failure_alert "$src" "$start_ts" "$end_ts" "DURATION" "Partial Timelapse (Duration: ${_fmt_actual})" "$run_mode" "$_actual" "$current_filesize"
                      pipeline_success=0
                else
                    # 5b. SUCCESS HANDLING & RECOVERY
                    local current_ts=$(date +%s)
                    local msg_b64=$(echo "Timelapse Sent" | base64 -w 0)
                    
                    handle_recovery_actions "$src" "$start_ts" "$end_ts"

                    # Insert record into 'events' with type='TIMELAPSE' and filesize
                    db_exec "INSERT INTO events (camera, type, status, start_ts, end_ts, created_at, message, msg_id, duration, filesize) VALUES ('$src', 'TIMELAPSE', 'SUCCESS', $start_ts, $end_ts, $current_ts, '$msg_b64', 0, $_actual, $current_filesize);"
                    log "[$src] Timelapse saved to history."
                    pipeline_success=1
                fi
            else
                log "[$src] Timelapse Sent (Test Mode)."
                pipeline_success=1
            fi
        else
             trigger_failure_alert "$src" "$start_ts" "$end_ts" "TELEGRAM" "Failed to send Timelapse" "$run_mode" "$_actual" "$current_filesize"
             pipeline_success=0
        fi
    else
        trigger_failure_alert "$src" "$start_ts" "$end_ts" "RENDER" "Failed to generate Timelapse" "$run_mode" "0" "0"
        pipeline_success=0
    fi

    rm -f "$filepath"

    if [ $pipeline_success -eq 1 ]; then return 0; else return 1; fi
}