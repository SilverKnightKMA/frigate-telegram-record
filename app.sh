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

# [Ops] Signal Trap for Graceful Shutdown
# Purpose: Terminates background jobs and cleans resources to ensure safe container stop.
cleanup_on_exit() {
    log "Received termination signal. Stopping background tasks..."
    # Send SIGTERM to all active background jobs spawned by this shell
    jobs -p | xargs -r kill -SIGTERM
    wait
    rm -rf "$TEMP_DIR"/*
    log "Shutdown complete."
    exit 0
}
trap cleanup_on_exit SIGTERM SIGINT

# [Ops] Startup Recovery & Cleanup
# Purpose: Cleans temp directory on boot to remove artifacts from previous crashes (OOM kills, power loss),
# ensuring a fresh state before validation starts.
rm -rf "$TEMP_DIR"/*

# 2. Validation
log_debug "Starting validation process..."

# [Ops] Fail-Fast Dependency Check
# Purpose: Verify all required tools exist before proceeding to main loops.
verify_system_dependencies

if [ ${#CAMERA_ARRAY[@]} -eq 0 ]; then
    log "CRITICAL: No cameras configured."
    exit 1
fi

log_debug "Environment check: MODE=$MODE, TZ=$TZ, DATA_DIR=$DATA_DIR"
echo "[INFO] System Timezone: $TZ"

# [Ops] Startup Log Maintenance
# Purpose: Perform an initial log rotation check when the container starts.
rotate_log_file

# 3. Init Database
log_debug "Initializing database schema..."
init_db

# 4. Main Execution Switch
if [ "$MODE" == "test" ]; then
    log ">>> STARTING TEST MODE <<<"
    log_debug "Executing single cycle for duration: ${TEST_REC_DURATION_MIN}m"
    execute_cycle "$TEST_REC_DURATION_MIN" "test"
    exit 0

elif [ "$MODE" == "record" ]; then
    log ">>> STARTING DAEMON MODE (${REC_DURATION_MIN}m) <<<"
    while true; do
        log_debug "--- NEW RECORDING LOOP START ---"
        
        # [Ops] Pre-Flight System Checks
        # Purpose: Validate resources (log size, disk space/writability) before starting a new cycle.
        rotate_log_file
        if ! check_disk_space; then
            log "⚠️ Pausing cycle due to storage issues. Retrying in 5 minutes..."
            sleep 300
            continue
        fi

        execute_cycle "$REC_DURATION_MIN" "record"
        
        # [Ops] Update Heartbeat
        # Purpose: Updates timestamp for Docker Healthcheck to confirm loop is active.
        touch "$DATA_DIR/.heartbeat"

        current_ts=$(date +%s)
        duration_sec=$((REC_DURATION_MIN * 60))
        
        # Calculate sleep time to align with next interval
        seconds_into_cycle=$(( current_ts % duration_sec ))
        seconds_to_sleep=$(( duration_sec - seconds_into_cycle ))
        final_sleep=$(( seconds_to_sleep + 20 ))
        
        log_debug "Cycle Math: current_ts=$current_ts, into_cycle=${seconds_into_cycle}s, to_sleep=${seconds_to_sleep}s"
        log "Sleeping ${final_sleep}s..."
        
        # Wait with background signal processing
        sleep "$final_sleep" &
        wait $!
    done

# --- TIMELAPSE MODES ---

elif [ "$MODE" == "test_timelapse" ]; then
    log ">>> STARTING TIMELAPSE TEST MODE (Last $TIMELAPSE_HOURS hours) <<<"
    execute_timelapse_cycle "test_timelapse" "$TIMELAPSE_HOURS"
    exit 0

elif [ "$MODE" == "timelapse" ]; then
    log ">>> STARTING TIMELAPSE DAEMON (Block: ${TIMELAPSE_HOURS}h) <<<"

    while true; do
        log_debug "--- NEW TIMELAPSE LOOP START ---"

        # [Ops] Pre-Flight System Checks
        # Purpose: Validate resources (log size, disk space/writability) before starting intensive rendering tasks.
        rotate_log_file
        if ! check_disk_space; then
            log "⚠️ Pausing timelapse cycle due to storage issues. Retrying in 5 minutes..."
            sleep 300
            continue
        fi

        # Run cycle and capture exit status
        execute_timelapse_cycle "timelapse" "$TIMELAPSE_HOURS"
        CYCLE_STATUS=$?
        log_debug "Timelapse cycle finished with exit status: $CYCLE_STATUS"

        # [Ops] Update Heartbeat
        # Purpose: Updates timestamp for Docker Healthcheck to confirm loop is active.
        touch "$DATA_DIR/.heartbeat"

        # === RETRY LOGIC ===
        if [ $CYCLE_STATUS -ne 0 ]; then
            if [ "$TIMELAPSE_STRICT_RETRY" == "true" ]; then
                log "⚠️ Cycle completed with ERRORS. Entering Retry Mode."
                log "Sleeping ${TIMELAPSE_RETRY_SLEEP_SEC}s before retrying missing slots..."
                sleep "$TIMELAPSE_RETRY_SLEEP_SEC" &
                wait $!
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
        
        log_debug "Timelapse Sleep Math: local_ts=$local_ts, into_cycle=${seconds_into_cycle}s, final_sleep=${final_sleep}s"
        
        if [ "$final_sleep" -gt 43200 ]; then 
            log_debug "Final sleep exceeds 12h, capping to 1h per safety logic."
            final_sleep=3600 
        fi

        sleep_h=$((final_sleep / 3600))
        sleep_m=$(( (final_sleep % 3600) / 60 ))
        sleep_s=$((final_sleep % 60))
        
        log "✅ All caught up. Sleeping ${sleep_h}h ${sleep_m}m ${sleep_s}s until next block..."
        
        # Wait with background signal processing
        sleep "$final_sleep" &
        wait $!
    done

else
    log "Invalid MODE: $MODE"
    exit 1
fi