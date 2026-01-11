#!/bin/bash

# ==============================================================================
# CONFIGURATION MODULE
# Purpose: Load environment variables and define global constants.
# ==============================================================================

# Load environment variables from config file if not already set
CONFIG_FILE="${CONFIG_FILE:-}"
if [ -z "$CONFIG_FILE" ]; then
    if [ -f "./config/config.env" ]; then
        CONFIG_FILE="./config/config.env"
    else
        CONFIG_FILE="/app/config/config.env"
    fi
fi

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        echo "[INFO] Loading config from file: $CONFIG_FILE"
        while IFS='=' read -r key value; do
            if [[ $key =~ ^# ]] || [[ -z $key ]]; then continue; fi
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            # Only export if not already set in environment
            if [ -z "${!key}" ]; then export "$key=$value"; fi
        done < "$CONFIG_FILE"
    fi
}
load_config

export TZ="${TZ:-Asia/Ho_Chi_Minh}"
FRIGATE_HOST="${FRIGATE_HOST:-http://127.0.0.1:5000}"
TELEGRAM_API_URL="${TELEGRAM_API_URL:-https://api.telegram.org}"

if [ -z "${DATA_DIR:-}" ]; then
    if [ -d "./data" ]; then DATA_DIR="./data"; else DATA_DIR="/app/data"; fi
fi

TEMP_DIR="${TEMP_DIR:-/dev/shm/frigate_clips}"
LOG_FILE="$DATA_DIR/execution.log"
DB_FILE="$DATA_DIR/video_history.sqlite"

# --- TUNING CONFIG ---
RETENTION_DAYS="${RETENTION_DAYS:-30}"
ALERT_RETENTION_HOURS="${ALERT_RETENTION_HOURS:-720}"
ALERT_REPEAT="${ALERT_REPEAT:-false}" # Controls if alerts are resent for the same time slot
LOOKBACK_HOURS="${LOOKBACK_HOURS:-168}"
MAX_CONCURRENT_TASKS="${MAX_CONCURRENT_TASKS:-5}" # Limit concurrent background jobs
PADDING_SEC="${PADDING_SEC:-5}"
MAX_RETRIES="${MAX_RETRIES:-5}" # Retries for Video Upload

# [NEW] Validation & System Tuning
MIN_FILESIZE_BYTES="${MIN_FILESIZE_BYTES:-1024}" # Minimum valid video size in bytes
DB_TIMEOUT_MS="${DB_TIMEOUT_MS:-30000}" # SQLite busy timeout in milliseconds
SCHEDULER_GAP_THRESHOLD_SEC="${SCHEDULER_GAP_THRESHOLD_SEC:-10}" # Min gap size to trigger gap-fill recording

# [Ops] Healthcheck & Heartbeat Tuning
# Purpose: Define how often the script updates its status and how lenient the check is.
# HEARTBEAT_INTERVAL_SEC: Max sleep duration in 'smart_wait' before waking up to touch .heartbeat
HEARTBEAT_INTERVAL_SEC="${HEARTBEAT_INTERVAL_SEC:-60}" 

# [Ops] Resource Monitoring Limits
# Purpose: Define thresholds for log rotation and disk space safety checks to prevent system exhaustion.
MAX_LOG_SIZE_BYTES="${MAX_LOG_SIZE_BYTES:-10485760}" # 10MB default limit for log file
MIN_DISK_SPACE_MB="${MIN_DISK_SPACE_MB:-500}"       # Minimum free space required (in MB) to start operations

REC_DURATION_MIN="${REC_DURATION_MIN:-15}"
TEST_REC_DURATION_MIN="${TEST_REC_DURATION_MIN:-1}"
MODE="${MODE:-record}"

DEBUG="${DEBUG:-false}" # Enable detailed debug logging
NOTIFY_ON_RECOVERY="${NOTIFY_ON_RECOVERY:-true}" # Controls notification behavior upon recovery
MIN_DURATION_PERCENT="${MIN_DURATION_PERCENT:-90}" # Threshold for success percentage

# --- TIMELAPSE SETTINGS ---
TIMELAPSE_THREAD_ID="${TIMELAPSE_THREAD_ID:-33}" 
TIMELAPSE_HOURS="${TIMELAPSE_HOURS:-6}"       
TIMELAPSE_SPEED="${TIMELAPSE_SPEED:-600}"     
TIMELAPSE_FPS="${TIMELAPSE_FPS:-30}"          
TIMELAPSE_QUALITY="${TIMELAPSE_QUALITY:-24}" 
VAAPI_DEVICE="${VAAPI_DEVICE:-/dev/dri/renderD128}"
TIMELAPSE_CHUNK_SIZE_SEC="${TIMELAPSE_CHUNK_SIZE_SEC:-3600}"
TIMELAPSE_LOOKBACK_HOURS="${TIMELAPSE_LOOKBACK_HOURS:-720}"
TIMELAPSE_RETRY_SLEEP_SEC="${TIMELAPSE_RETRY_SLEEP_SEC:-3600}"
TIMELAPSE_STRICT_RETRY="${TIMELAPSE_STRICT_RETRY:-false}"

# [NEW] Timelapse Advanced Tuning
TIMELAPSE_MIN_DURATION_SEC="${TIMELAPSE_MIN_DURATION_SEC:-60}" # Smart Skip threshold
TIMELAPSE_CODEC="${TIMELAPSE_CODEC:-h264_vaapi}" # Encoder codec (e.g., h264_vaapi, hevc_vaapi)
TIMELAPSE_PIXEL_FORMAT="${TIMELAPSE_PIXEL_FORMAT:-nv12}" # Pixel format for scaling filter

# [NEW] Telegram Tuning
TELEGRAM_MAX_ALERT_RETRIES="${TELEGRAM_MAX_ALERT_RETRIES:-3}" # Retries for Error Text Alerts

# Global variables to store Telegram Message IDs for recovery logic
SENT_ERROR_MSG_ID=""
SENT_VIDEO_MSG_ID=""

# Parse Cameras
IFS=';' read -ra CAMERA_ARRAY <<< "$CAMERAS"