#!/bin/bash

# ==============================================================================
# TELEGRAM MODULE
# Purpose: Handle all Telegram API interactions and error notifications.
# ==============================================================================

send_reaction() {
    local chat_id="$1"
    local msg_id="$2"
    local emoji="$3"
    
    if [ -z "$msg_id" ] || [ "$msg_id" == "0" ]; then return; fi

    curl -s -X POST "${TELEGRAM_API_URL}/bot${BOT_TOKEN}/setMessageReaction" \
        -H "Content-Type: application/json" \
        -d "{
            \"chat_id\": $chat_id,
            \"message_id\": $msg_id,
            \"reaction\": [{
                \"type\": \"emoji\",
                \"emoji\": \"$emoji\"
            }],
            \"is_big\": true
        }" > /dev/null
}

send_reply() {
    local chat_id="$1"
    local msg_id="$2"
    local text="$3"
    local thread_id="$4"

    if [ -z "$msg_id" ] || [ "$msg_id" == "0" ]; then return; fi

    local extra_params=""
    if [ -n "$thread_id" ]; then
        extra_params="\"message_thread_id\": $thread_id,"
    fi

    curl -s -X POST "${TELEGRAM_API_URL}/bot${BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{
            \"chat_id\": $chat_id,
            $extra_params
            \"text\": \"$text\",
            \"reply_parameters\": {
                \"message_id\": $msg_id
            }
        }" > /dev/null
}

edit_message_text() {
    local chat_id="$1"
    local msg_id="$2"
    local text="$3"
    local thread_id="$4"

    if [ -z "$msg_id" ] || [ "$msg_id" == "0" ]; then return; fi

    local args=(
        -s -X POST "${TELEGRAM_API_URL}/bot${BOT_TOKEN}/editMessageText"
        -d "chat_id=${chat_id}"
        -d "message_id=${msg_id}"
        -d "parse_mode=HTML"
        --data-urlencode "text=${text}"
    )
    if [ -n "$thread_id" ]; then args+=(-d "message_thread_id=${thread_id}"); fi

    curl "${args[@]}" > /dev/null
}

# Logs errors locally and sends a notification to Telegram if configured.
handle_error() {
    local msg="$1"
    local context="$2"
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    
    SENT_ERROR_MSG_ID=""

    # Clean HTML tags for local log file
    local clean_msg=$(echo "$msg" | sed 's/<[^>]*>//g')
    echo "[$ts] [ERROR] [$context] $clean_msg" | tee -a "$LOG_FILE"
    
    if [ -n "$ERROR_CHAT_ID" ]; then
        local alert_text=""
        
        # Use message as-is if it contains HTML tags, otherwise apply template
        if [[ "$msg" == *"<b>"* ]]; then
            alert_text="$msg"
        else
            alert_text="🚨 <b>EXECUTION FAILED</b>
<b>Time:</b> $ts
<b>Context:</b> $context
<b>Error:</b> $msg"
        fi

        local attempt=1
        local max_alert_retries=3
        local response_body=$(mktemp)

        while [ $attempt -le $max_alert_retries ]; do
            local args=(
                -s -o "$response_body" -w "%{http_code}"
                -X POST "${TELEGRAM_API_URL}/bot${BOT_TOKEN}/sendMessage"
                -d "chat_id=${ERROR_CHAT_ID}"
                -d "parse_mode=HTML"
                --data-urlencode "text=${alert_text}"
            )
            if [ -n "$ERROR_THREAD_ID" ]; then args+=(-d "message_thread_id=${ERROR_THREAD_ID}"); fi

            local http_code=$(curl "${args[@]}")
            local response_content=$(cat "$response_body")

            if [ "$http_code" == "200" ] && echo "$response_content" | grep -q '"ok":true'; then
                SENT_ERROR_MSG_ID=$(get_json_value "$response_content" "message_id")
                
                # Add visual reaction to indicate critical error
                if [ -n "$SENT_ERROR_MSG_ID" ]; then
                    send_reaction "$ERROR_CHAT_ID" "$SENT_ERROR_MSG_ID" "🔥"
                fi

                rm -f "$response_body"
                return 0
            fi

            if echo "$response_content" | grep -iq "retry after"; then
                local wait_sec=$(echo "$response_content" | grep -oE 'retry after [0-9]+' | awk '{print $3}')
                if [ -z "$wait_sec" ]; then wait_sec=5; fi
                local buffer=$(( ( RANDOM % 3 ) + 1 ))
                wait_sec=$((wait_sec + buffer))
                echo "[$ts] [WARN] Alert Rate Limited. Waiting ${wait_sec}s..." >> "$LOG_FILE"
                sleep "$wait_sec"
                attempt=$((attempt + 1))
                continue
            fi
            
            echo "[$ts] [CRITICAL] Alert Failed (HTTP $http_code). Response: $response_content" >> "$LOG_FILE"
            rm -f "$response_body"
            return 1
        done
        rm -f "$response_body"
    fi
}

send_telegram_video() {
    local filepath="$1"
    local chat_id="$2"
    local thread_id="$3"
    local caption="$4"
    local src="$5"

    log_debug "[$src] send_telegram_video: chat_id=$chat_id, thread_id=$thread_id, file=$filepath"

    local attempt=1
    local response_body=$(mktemp)
    
    SENT_VIDEO_MSG_ID=""

    while [ $attempt -le $MAX_RETRIES ]; do
        if [ $attempt -gt 1 ]; then log "[$src] Retry $attempt/$MAX_RETRIES..."; fi

        local args=(
            -s -X POST "${TELEGRAM_API_URL}/bot${BOT_TOKEN}/sendVideo"
            -o "$response_body" -w "%{http_code}"
            -F "chat_id=${chat_id}"
            -F "video=@${filepath}"
            -F "caption=${caption}"
            -F "parse_mode=HTML"
        )
        if [ -n "$thread_id" ]; then args+=(-F "message_thread_id=${thread_id}"); fi

        log_debug "[$src] Sending video (attempt $attempt)..."
        local http_code=$(curl "${args[@]}")
        local curl_exit=$?
        local response_content=$(cat "$response_body")
        
        log_debug "[$src] HTTP Code: $http_code, Curl Exit: $curl_exit"
        if [ "${DEBUG}" == "true" ]; then
            log_debug "[$src] Response: ${response_content:0:200}..."
        fi
        
        if [ $curl_exit -ne 0 ]; then
            log "[$src] Curl failed (Exit Code: $curl_exit)."
            rm -f "$response_body"
            # Note: handle_error here only logs, does NOT save to DB. 
            handle_error "[TELEGRAM] Network Error (Curl Exit $curl_exit)" "SEND|$src"
            return 1
        fi

        if [ "$http_code" == "200" ] && echo "$response_content" | grep -q '"ok":true'; then
            SENT_VIDEO_MSG_ID=$(get_json_value "$response_content" "message_id")
            rm -f "$response_body"
            return 0
        fi

        # Handle rate limiting
        if echo "$response_content" | grep -iq "retry after"; then
            local wait_sec=$(echo "$response_content" | grep -oE 'retry after [0-9]+' | awk '{print $3}')
            if [ -z "$wait_sec" ]; then wait_sec=10; fi
            wait_sec=$((wait_sec + 1))
            log "[$src] ⚠️ Rate Limited. Waiting ${wait_sec}s."
            sleep "$wait_sec"
            attempt=$((attempt + 1))
            continue
        fi

        rm -f "$response_body"
        handle_error "[TELEGRAM] API Error ($http_code): $response_content" "SEND|$src"
        return 1
    done
    rm -f "$response_body"
    handle_error "[TELEGRAM] Timeout after $MAX_RETRIES retries" "SEND_TIMEOUT|$src"
    return 1
}