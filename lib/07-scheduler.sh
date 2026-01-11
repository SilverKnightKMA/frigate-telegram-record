#!/bin/bash

# ==============================================================================
# SCHEDULER MODULE
# Purpose: Manage time windows, batch processing, and execution cycles.
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
                execute_clip_pipeline "$cam_name" "$src" "$cursor" "$ex_start" "$run_mode" "$tid" "$chat_id"
            fi
        fi
        if [ "$ex_end" -gt "$cursor" ]; then cursor=$ex_end; fi
    done

    # Check for tail gap
    if [ "$cursor" -lt "$master_end_ts" ]; then
          # [CHANGE] Replaced hardcoded '10' with SCHEDULER_GAP_THRESHOLD_SEC env var
          if [ $((master_end_ts - cursor)) -gt $SCHEDULER_GAP_THRESHOLD_SEC ]; then
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