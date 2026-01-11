#!/bin/bash

# ==============================================================================
# MAIN APPLICATION ENTRYPOINT
# ==============================================================================

# 1. Load Libraries (Order Matters)
source /app/lib/01-config.sh
source /app/lib/02-utils.sh
source /app/lib/03-database.sh
source /app/lib/04-telegram.sh
source /app/lib/05-core.sh
source /app/lib/06-pipelines.sh
source /app/lib/07-scheduler.sh

# 2. Validation
if [ ${#CAMERA_ARRAY[@]} -eq 0 ]; then
    log "CRITICAL: No cameras configured."
    exit 1
fi

echo "[INFO] System Timezone: $TZ"

# 3. Init Database
init_db

# 4. Main Execution Switch
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