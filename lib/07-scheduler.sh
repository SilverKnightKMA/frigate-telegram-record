#!/bin/bash

# ==============================================================================
# SCHEDULER MODULE
# Purpose: Manage time windows, batch processing, execution cycles, and daemon loops.
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

    # Query 'events' table for coverage gaps (type='RECORD')
    local existing_clips=$(sqlite3 -cmd ".timeout 30000" "$DB_FILE" "SELECT start_ts, end_ts FROM events WHERE camera='$src' AND type='RECORD' AND status='SUCCESS' AND end_ts > $master_start_ts AND start_ts < $master_end_ts ORDER BY start_ts ASC;")
    
    # [Debug] Log count of found clips to verify DB query results before processing
    if [ "${DEBUG}" == "true" ]; then
        local clip_count=0
        if [ -n "$existing_clips" ]; then
             clip_count=$(echo "$existing_clips" | grep -c "^")
        fi
        log_debug "[$src] Gap Analysis: Found $clip_count existing clips in window."
    fi

    local cursor=$master_start_ts

    for row in $existing_clips; do
        IFS='|' read -r ex_start ex_end <<< "$row"
        if [ "$ex_start" -gt "$cursor" ]; then
            # [CHANGE] Replaced hardcoded '10' with SCHEDULER_GAP_THRESHOLD_SEC env var
            if [ $((ex_start - cursor)) -gt $SCHEDULER_GAP_THRESHOLD_SEC ]; then
                log "[$src] 💡 Gap: $(date -d @$cursor '+%H:%M') -> $(date -d @$ex_start '+%H:%M')"
                local gap_start=$cursor
                local gap_end=$ex_start
                local gap_duration=$((gap_end - gap_start))
                local gap_start_human=$(date -d @${gap_start} '+%Y-%m-%d %H:%M:%S')
                local gap_end_human=$(date -d @${gap_end} '+%Y-%m-%d %H:%M:%S')
                log_debug "[$src] Gap metadata: start_ts=${gap_start} (${gap_start_human}), end_ts=${gap_end} (${gap_end_human}), duration=${gap_duration}s, master_window=${master_start_ts}-${master_end_ts}, run_mode=${run_mode}, tid=${tid}, chat_id=${chat_id}"
                execute_clip_pipeline "$cam_name" "$src" "$gap_start" "$gap_end" "$run_mode" "$tid" "$chat_id"
            fi
        fi
        if [ "$ex_end" -gt "$cursor" ]; then cursor=$ex_end; fi
    done

    # Check for tail gap
        if [ "$cursor" -lt "$master_end_ts" ]; then
                    # [CHANGE] Replaced hardcoded '10' with SCHEDULER_GAP_THRESHOLD_SEC env var
                    if [ $((master_end_ts - cursor)) -gt $SCHEDULER_GAP_THRESHOLD_SEC ]; then
                        log "[$src] 💡 Tail Gap: $(date -d @$cursor '+%H:%M') -> $(date -d @$master_end_ts '+%H:%M')"
                        local gap_start=$cursor
                        local gap_end=$master_end_ts
                        local gap_duration=$((gap_end - gap_start))
                        local gap_start_human=$(date -d @${gap_start} '+%Y-%m-%d %H:%M:%S')
                        local gap_end_human=$(date -d @${gap_end} '+%Y-%m-%d %H:%M:%S')
                        log_debug "[$src] Gap metadata: start_ts=${gap_start} (${gap_start_human}), end_ts=${gap_end} (${gap_end_human}), duration=${gap_duration}s, master_window=${master_start_ts}-${master_end_ts}, run_mode=${run_mode}, tid=${tid}, chat_id=${chat_id}"
                        execute_clip_pipeline "$cam_name" "$src" "$gap_start" "$gap_end" "$run_mode" "$tid" "$chat_id"
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
            # [Ops] Keep-Alive during intensive loops
            # Reason: Checking many slots for history can take time. Touching heartbeat here
            # ensures Docker knows the process is still active and not hung.
            touch "$DATA_DIR/.heartbeat"

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
        # [Ops] Heartbeat Refresh
        # Reason: Prevents healthcheck timeout if the cycle takes > 5 mins (due to multiple cameras).
        touch "$DATA_DIR/.heartbeat"

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
        # [Ops] Heartbeat Refresh
        # Reason: Timelapse generation is CPU/GPU intensive and slow. Touching heartbeat per camera
        # guarantees the container stays healthy during the long render process.
        touch "$DATA_DIR/.heartbeat"

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
            
            # Check 'events' table for existing timelapse success
            local exists=$(db_count "SELECT count(*) FROM events WHERE camera='$src' AND start_ts=$slot_start_ts AND end_ts=$slot_end_ts AND type='TIMELAPSE' AND status='SUCCESS';")
            
            if [ "$exists" -eq 0 ]; then
                # [LOGGING] Included Date in the log to identify which day the missing slot belongs to
                log "[$src] 🔍 Found missing slot: $(date -d @$slot_start_ts '+%Y-%m-%d %H:%M') - $(date -d @$slot_end_ts '+%H:%M')"
                
                # [Ops] Heartbeat Refresh (Deep)
                # Reason: If a single timelapse render takes a very long time, we touch heartbeat
                # right before execution to reset the healthcheck timer.
                touch "$DATA_DIR/.heartbeat"

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

# [Ops] Main Recording Daemon Loop
# Purpose: Encapsulates the infinite loop logic for standard recording mode.
run_record_daemon() {
    log ">>> STARTING DAEMON MODE (${REC_DURATION_MIN}m) <<<"
    while true; do
        log_debug "--- NEW RECORDING LOOP START ---"
        # [Ops] Status Update: Processing
        update_service_status "RUNNING" "Processing recording cycle"
        
        # [Ops] Pre-Flight System Checks
        rotate_log_file
        if ! check_disk_space; then
            log "⚠️ Pausing cycle due to storage issues. Retrying in 5 minutes..."
            update_service_status "ERROR" "Disk space critical. Paused."
            smart_wait 300
            continue
        fi

        # [Ops] Performance Monitoring - Start Timer
        local cycle_start_ts=$(date +%s)

        execute_cycle "$REC_DURATION_MIN" "record"
        
        # [Ops] Performance Monitoring - End Timer & Log
        local cycle_end_ts=$(date +%s)
        local cycle_duration=$((cycle_end_ts - cycle_start_ts))
        log "🔄 Record Cycle completed in ${cycle_duration}s."

        # [Ops] Update Heartbeat
        touch "$DATA_DIR/.heartbeat"

        local current_ts=$(date +%s)
        local duration_sec=$((REC_DURATION_MIN * 60))
        
        # Calculate sleep time to align with next interval
        local seconds_into_cycle=$(( current_ts % duration_sec ))
        local seconds_to_sleep=$(( duration_sec - seconds_into_cycle ))
        local final_sleep=$(( seconds_to_sleep + 20 ))
        
        log_debug "Cycle Math: current_ts=$current_ts, into_cycle=${seconds_into_cycle}s, to_sleep=${seconds_to_sleep}s"
        log "Sleeping ${final_sleep}s..."
        
        # [Ops] Status Update: Sleeping
        update_service_status "SLEEPING" "Waiting for next cycle (${final_sleep}s)"
        
        # [Ops] Smart Wait
        smart_wait "$final_sleep"
    done
}

# [Ops] Main Timelapse Daemon Loop
# Purpose: Encapsulates the infinite loop logic for timelapse mode.
run_timelapse_daemon() {
    log ">>> STARTING TIMELAPSE DAEMON (Block: ${TIMELAPSE_HOURS}h) <<<"

    while true; do
        log_debug "--- NEW TIMELAPSE LOOP START ---"
        # [Ops] Status Update: Processing
        update_service_status "RUNNING" "Processing timelapse block"

        # [Ops] Pre-Flight System Checks
        rotate_log_file
        if ! check_disk_space; then
            log "⚠️ Pausing timelapse cycle due to storage issues. Retrying in 5 minutes..."
            update_service_status "ERROR" "Disk space critical. Paused."
            smart_wait 300
            continue
        fi

        # [Ops] Performance Monitoring - Start Timer
        local cycle_start_ts=$(date +%s)

        # Run cycle and capture exit status
        execute_timelapse_cycle "timelapse" "$TIMELAPSE_HOURS"
        local CYCLE_STATUS=$?
        log_debug "Timelapse cycle finished with exit status: $CYCLE_STATUS"

        # [Ops] Performance Monitoring - End Timer & Log
        local cycle_end_ts=$(date +%s)
        local cycle_duration=$((cycle_end_ts - cycle_start_ts))
        log "🔄 Timelapse Cycle completed in ${cycle_duration}s."

        # [Ops] Update Heartbeat
        touch "$DATA_DIR/.heartbeat"

        # === RETRY LOGIC ===
        if [ $CYCLE_STATUS -ne 0 ]; then
            if [ "$TIMELAPSE_STRICT_RETRY" == "true" ]; then
                log "⚠️ Cycle completed with ERRORS. Entering Retry Mode."
                log "Sleeping ${TIMELAPSE_RETRY_SLEEP_SEC}s before retrying missing slots..."
                
                update_service_status "RETRY" "Cycle error. Retrying in ${TIMELAPSE_RETRY_SLEEP_SEC}s"
                
                # [Ops] Smart Wait for Retry
                smart_wait "$TIMELAPSE_RETRY_SLEEP_SEC"
                
                continue # Skip long sleep and retry immediately
            else
                log "⚠️ Cycle completed with ERRORS. Strict retry disabled. Continuing to schedule..."
            fi
        fi

        # === SLEEP LOGIC (SUCCESS) ===
        
        local current_ts=$(date +%s)
        
        # Recalculate TZ offset dynamically
        local tz_str=$(date +%z)
        local tz_sign=${tz_str:0:1}
        local tz_hour=${tz_str:1:2}
        local tz_min=${tz_str:3:2}
        local tz_offset_sec=$(( (tz_hour * 3600) + (tz_min * 60) ))
        if [ "$tz_sign" == "-" ]; then tz_offset_sec=$((tz_offset_sec * -1)); fi
        
        local local_ts=$((current_ts + tz_offset_sec))
        local duration_sec=$((TIMELAPSE_HOURS * 3600))
        
        # Calculate sleep to wake up 30s after the next block finishes
        local seconds_into_cycle=$(( local_ts % duration_sec ))
        local seconds_to_sleep=$(( duration_sec - seconds_into_cycle ))
        local final_sleep=$(( seconds_to_sleep + 30 ))
        
        log_debug "Timelapse Sleep Math: local_ts=$local_ts, into_cycle=${seconds_into_cycle}s, final_sleep=${final_sleep}s"
        
        if [ "$final_sleep" -gt 43200 ]; then 
            log_debug "Final sleep exceeds 12h, capping to 1h per safety logic."
            final_sleep=3600 
        fi

        local sleep_h=$((final_sleep / 3600))
        local sleep_m=$(( (final_sleep % 3600) / 60 ))
        local sleep_s=$((final_sleep % 60))
        
        log "✅ All caught up. Sleeping ${sleep_h}h ${sleep_m}m ${sleep_s}s until next block..."
        
        # [Ops] Status Update: Sleeping
        update_service_status "SLEEPING" "Caught up. Waiting ${sleep_h}h ${sleep_m}m"
        
        # [Ops] Smart Wait until next block
        smart_wait "$final_sleep"
    done
}