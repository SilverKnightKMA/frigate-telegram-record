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
# Purpose: Registers the cleanup handler defined in 02-utils.sh
trap cleanup_on_exit SIGTERM SIGINT

# [Ops] Startup Recovery & Cleanup
# Purpose: Cleans temp directory on boot ensuring a fresh state before validation starts.
rm -rf "$TEMP_DIR"/*

# [Ops] Status Update on Boot
update_service_status "STARTING" "Initializing application..."

# [Ops] Single Instance Enforcement
# Purpose: Prevents multiple script instances of the SAME MODE from running simultaneously.
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE")
    if kill -0 "$pid" > /dev/null 2>&1; then
        log "CRITICAL: Another instance of MODE=$MODE is running (PID: $pid). Exiting."
        exit 1
    fi
    # Remove stale lock file if process is dead
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"

# 2. Validation
log_debug "Starting validation process..."
verify_system_dependencies

if [ ${#CAMERA_ARRAY[@]} -eq 0 ]; then
    log "CRITICAL: No cameras configured."
    rm -f "$LOCK_FILE"
    exit 1
fi

log_debug "Environment check: MODE=$MODE, TZ=$TZ, DATA_DIR=$DATA_DIR"
echo "[INFO] System Timezone: $TZ"

# [Ops] Startup Log Maintenance
rotate_log_file

# 3. Init Database
log_debug "Initializing database schema..."
init_db

# 4. Main Execution Switch
case "$MODE" in
    "test")
        log ">>> STARTING TEST MODE <<<"
        update_service_status "RUNNING" "Test mode execution"
        log_debug "Executing single cycle for duration: ${TEST_REC_DURATION_MIN}m"
        execute_cycle "$TEST_REC_DURATION_MIN" "test"
        rm -f "$LOCK_FILE"
        exit 0
        ;;
    
    "record")
        # Logic moved to 07-scheduler.sh for modularity
        run_record_daemon
        ;;

    "test_timelapse")
        log ">>> STARTING TIMELAPSE TEST MODE (Last $TIMELAPSE_HOURS hours) <<<"
        update_service_status "RUNNING" "Test timelapse execution"
        execute_timelapse_cycle "test_timelapse" "$TIMELAPSE_HOURS"
        rm -f "$LOCK_FILE"
        exit 0
        ;;

    "timelapse")
        # Logic moved to 07-scheduler.sh for modularity
        run_timelapse_daemon
        ;;

    *)
        log "Invalid MODE: $MODE"
        rm -f "$LOCK_FILE"
        exit 1
        ;;
esac