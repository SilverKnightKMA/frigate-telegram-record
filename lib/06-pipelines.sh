#!/bin/bash

# ==============================================================================
# PIPELINE MODULE
# Purpose: Orchestrates the download/rendering, validation, and sending process.
# ==============================================================================

# Calculates the total duration of available footage for a given time range
# by querying Frigate's VOD playlist API without downloading the full video.
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
    
    # Iterate through time chunks to sum up available segments from HLS playlists
    while [ "$cursor" -lt "$end_ts" ]; do
        local next_cursor=$(($cursor + $TIMELAPSE_CHUNK_SIZE_SEC))
        if [ "$next_cursor" -gt "$end_ts" ]; then next_cursor=$end_ts; fi
        
        local vod_url="${FRIGATE_HOST}/vod/${camera_name}/start/${cursor}/end/${next_cursor}/index.m3u8"
        local playlist_file="$vod_check_dir/check_${count}.m3u8"
        
        # Fetch playlist header to extract segment durations
        local http_code=$(curl -s -o "$playlist_file" -w "%{http_code}" "$vod_url")
        
        if [ "$http_code" == "200" ] && [ -s "$playlist_file" ]; then
            # Sum up EXTINF values to get accurate seconds for this chunk
            local chunk_duration=$(grep -o "#EXTINF:[0-9.]*" "$playlist_file" 2>/dev/null | awk -F: '{sum+=$2} END {print int(sum)}')
            chunk_duration=${chunk_duration:-0}
            total_duration=$((total_duration + chunk_duration))
        fi
        
        cursor=$next_cursor
        count=$((count + 1))
    done

    rm -rf "$vod_check_dir"
    echo "$total_duration"
}

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

    # [Dashboard Update] Start timer for performance tracking
    local pipe_start=$(date +%s)

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

    # === OPTIMIZATION: VOD Coverage Check ===
    # Check if enough footage exists in the playlist before attempting full download
    local expected_duration=$(( end_ts - start_ts ))
    local vod_duration=$(calculate_vod_source_duration "$src" "$start_ts" "$end_ts")
    local threshold=$(( expected_duration * MIN_DURATION_PERCENT / 100 ))

    log_debug "[$src] VOD Pre-check: Found ${vod_duration}s / Required ${threshold}s"

    if [ "$vod_duration" -lt "$threshold" ]; then
        # Logic: Check previous failure duration.
        # If current vod_duration <= previous failure, skip (no improvement).
        # If current vod_duration > previous failure, trigger alert (update DB).
        local prev_fail_duration=$(get_last_fail_metric "$src" "$start_ts" "$end_ts" "duration")
        
        # [Dashboard Update] Calculate elapsed time for early exit
        local pipe_duration=$(( $(date +%s) - pipe_start ))

        if [ "$vod_duration" -le "$prev_fail_duration" ] && [ "$prev_fail_duration" -gt 0 ]; then
             log "[$src] ⏭️ Skipping Download: Insufficient VOD (${vod_duration}s) & No improvement over last fail (${prev_fail_duration}s)."
             return
        fi

        log "[$src] ⚠️ Skipping Download: Insufficient VOD data (${vod_duration}s < ${threshold}s). Recording failure."
        trigger_failure_alert "$src" "$start_ts" "$end_ts" "DURATION" "Pre-check Insufficient VOD (${vod_duration}s)" "$run_mode" "$vod_duration" "0" "$pipe_duration"
        return
    fi
    # ========================================

    # === OPTIMIZATION: Check Remote Size Before Download ===
    # Attempt to get Content-Length via HEAD request. Added -L to follow redirects.
    local header_dump=$(curl -sI -L "$url")
    local remote_size=$(echo "$header_dump" | grep -i "Content-Length" | awk '{print $2}' | tr -d '\r')
    local header_status=$(echo "$header_dump" | head -n 1 | awk '{print $2}')

    # Check validity
    if [[ "$remote_size" =~ ^[0-9]+$ ]] && [ "$remote_size" -gt 0 ]; then
        # Retrieve the maximum filesize recorded in DB for this slot
        local db_max_size=$(sqlite3 "$DB_FILE" "SELECT MAX(filesize) FROM events WHERE camera='$src' AND start_ts=$start_ts AND end_ts=$end_ts;")
        db_max_size=${db_max_size:-0}

        if [ "$remote_size" -le "$db_max_size" ]; then
            log "[$src] ⏭️ Skipping Download: Remote size ($remote_size bytes) <= DB record ($db_max_size bytes)."
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

    # [Dashboard Update] Calc duration for later blocks
    local pipe_duration=$(( $(date +%s) - pipe_start ))

    if [ "$http_code" == "200" ]; then
        local current_filesize=$(stat -c%s "$filepath" 2>/dev/null || echo 0)

        if validate_video "$filepath"; then
            
            # 3. CHECK DURATION & STATUS
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
⏳ Duration: ${_fmt_actual} / ${_fmt_expected} (${_percent}%)"

            log_debug "[$src] Caption prepared, sending to Telegram..."

            if send_telegram_video "$filepath" "$chat_id" "$tid" "$caption" "$src"; then
                log_debug "[$src] Video sent successfully, msg_id: $SENT_VIDEO_MSG_ID"
                
                # Recalculate duration after send
                pipe_duration=$(( $(date +%s) - pipe_start ))

                if [ "$run_mode" == "record" ]; then
                    
                    # 5a. FAILURE HANDLING (Partial)
                    if [ "$_status" == "partial" ]; then
                        trigger_failure_alert "$src" "$start_ts" "$end_ts" "DURATION" "Partial Video (Duration: ${_fmt_actual})" "$run_mode" "$_actual" "$current_filesize" "$pipe_duration"
                    else
                        # 5b. SUCCESS HANDLING & RECOVERY
                        local current_ts=$(date +%s)
                        local sent_msg_id="${SENT_VIDEO_MSG_ID:-0}"
                        local msg_b64=$(echo "Record Sent" | base64 -w 0)
                        
                        handle_recovery_actions "$src" "$start_ts" "$end_ts"

                        # [Dashboard Update] Insert record with process_sec
                        db_exec "INSERT INTO events (camera, type, status, start_ts, end_ts, created_at, message, msg_id, duration, filesize, process_sec) VALUES ('$src', 'RECORD', 'SUCCESS', $start_ts, $end_ts, $current_ts, '$msg_b64', $sent_msg_id, $_actual, $current_filesize, $pipe_duration);"
                        log "[$src] ✅ Success (MsgID: $sent_msg_id, Size: $current_filesize, Process: ${pipe_duration}s)."
                    fi
                else
                    log "[$src] Sent (Test Mode)."
                fi
            else
                pipe_duration=$(( $(date +%s) - pipe_start ))
                trigger_failure_alert "$src" "$start_ts" "$end_ts" "TELEGRAM" "Failed to send Video" "$run_mode" "$_actual" "$current_filesize" "$pipe_duration"
            fi
        else
            pipe_duration=$(( $(date +%s) - pipe_start ))
            trigger_failure_alert "$src" "$start_ts" "$end_ts" "VALIDATION" "File Check Failed (Size: $current_filesize)" "$run_mode" "0" "$current_filesize" "$pipe_duration"
        fi
    elif [ "$http_code" == "404" ]; then
        trigger_failure_alert "$src" "$start_ts" "$end_ts" "DOWNLOAD" "Frigate 404 (Video Not Found)" "$run_mode" "0" "0" "$pipe_duration"
    else
        trigger_failure_alert "$src" "$start_ts" "$end_ts" "DOWNLOAD" "HTTP Error $http_code" "$run_mode" "0" "0" "$pipe_duration"
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
    log_debug "[$camera_name] Pre-checking all HLS chunks via helper..."
    
    # Use shared helper to get source duration
    local total_source_duration=$(calculate_vod_source_duration "$camera_name" "$start_ts" "$end_ts")
    
    # Calculate expected timelapse duration and check against threshold
    if [ "$total_source_duration" -lt 60 ]; then
        log "[$camera_name] ⚠️ Pre-check failed: Insufficient source data (${total_source_duration}s)"
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
    
    log "[$camera_name] ✓ Pre-check passed"
    
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

    # [Dashboard Update] Start timer
    local pipe_start=$(date +%s)

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
        local caption="🎞️ <b>TIMELAPSE ($total_hours h)</b>
📷 $cam_name
📅 $display_date
⏰ $display_start - $display_end
⏩ Speed: x$speed
⏳ Duration: ${_fmt_actual} / ${_fmt_expected} (${_percent}%)"

        if send_telegram_video "$filepath" "$chat_id" "$target_tid" "$caption" "$src"; then
            
            # Recalculate duration after send
            local pipe_duration=$(( $(date +%s) - pipe_start ))

            if [ "$run_mode" == "timelapse" ]; then
                
                # 5a. FAILURE HANDLING (Partial)
                if [ "$_status" == "partial" ]; then
                        trigger_failure_alert "$src" "$start_ts" "$end_ts" "DURATION" "Partial Timelapse (Duration: ${_fmt_actual})" "$run_mode" "$_actual" "$current_filesize" "$pipe_duration"
                        pipeline_success=0
                else
                    # 5b. SUCCESS HANDLING & RECOVERY
                    local current_ts=$(date +%s)
                    local msg_b64=$(echo "Timelapse Sent" | base64 -w 0)
                    
                    handle_recovery_actions "$src" "$start_ts" "$end_ts"

                    # [Dashboard Update] Insert record with process_sec
                    db_exec "INSERT INTO events (camera, type, status, start_ts, end_ts, created_at, message, msg_id, duration, filesize, process_sec) VALUES ('$src', 'TIMELAPSE', 'SUCCESS', $start_ts, $end_ts, $current_ts, '$msg_b64', 0, $_actual, $current_filesize, $pipe_duration);"
                    log "[$src] Timelapse saved to history (Process: ${pipe_duration}s)."
                    pipeline_success=1
                fi
            else
                log "[$src] Timelapse Sent (Test Mode)."
                pipeline_success=1
            fi
        else
            local pipe_duration=$(( $(date +%s) - pipe_start ))
            trigger_failure_alert "$src" "$start_ts" "$end_ts" "TELEGRAM" "Failed to send Timelapse" "$run_mode" "$_actual" "$current_filesize" "$pipe_duration"
            pipeline_success=0
        fi
    else
        local pipe_duration=$(( $(date +%s) - pipe_start ))
        trigger_failure_alert "$src" "$start_ts" "$end_ts" "RENDER" "Failed to generate Timelapse" "$run_mode" "0" "0" "$pipe_duration"
        pipeline_success=0
    fi

    rm -f "$filepath"

    if [ $pipeline_success -eq 1 ]; then return 0; else return 1; fi
}