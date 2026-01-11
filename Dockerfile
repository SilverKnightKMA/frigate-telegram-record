FROM alpine:latest

# Install system dependencies
RUN apk add --no-cache \
    bash \
    curl \
    ffmpeg \
    file \
    sqlite \
    tzdata \
    ca-certificates \
    coreutils \
    jq \
    libva-utils \
    intel-media-driver \
    intel-gmmlib

# Setup Application Directory
WORKDIR /app

# Copy Application Files
# We copy the lib directory and the main script
COPY lib /app/lib
COPY app.sh /app/app.sh

# Set Permissions & Create Data Directories
RUN chmod +x /app/app.sh && \
    chmod +x /app/lib/*.sh && \
    mkdir -p /app/data /app/config

# [Ops] Healthcheck Configuration
# Purpose: Monitor application liveness by checking the heartbeat file age.
# ENV HEARTBEAT_MAX_AGE_SEC: Threshold in seconds before declaring unhealthy (Default: 300s/5m).
# Note: --interval can only be set at build time, but the logic inside CMD uses the ENV var.
ENV HEARTBEAT_MAX_AGE_SEC=300

HEALTHCHECK --interval=60s --timeout=10s --retries=3 \
  CMD [ $(($(date +%s) - $(stat -c %Y /app/data/.heartbeat))) -lt $HEARTBEAT_MAX_AGE_SEC ] || exit 1

# Define Entrypoint
ENTRYPOINT ["/bin/bash", "/app/app.sh"]