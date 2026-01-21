FROM alpine:latest

# Declare TARGETARCH so Docker knows which architecture (amd64 or arm64) to build for
ARG TARGETARCH

# 1. Install COMMON libraries
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
    libva-utils

# 2. Only install the Intel driver when building for the amd64 architecture
RUN if [ "$TARGETARCH" = "amd64" ]; then \
        apk add --no-cache intel-media-driver intel-gmmlib; \
    fi

# Setup Application Directory
WORKDIR /app

# Copy Application Files
COPY lib /app/lib
COPY app.sh /app/app.sh

# Set Permissions & Create Data Directories
RUN chmod +x /app/app.sh && \
    chmod +x /app/lib/*.sh && \
    mkdir -p /app/data /app/config

# Healthcheck Configuration
ENV HEARTBEAT_MAX_AGE_SEC=300

HEALTHCHECK --interval=60s --timeout=10s --retries=3 \
  CMD [ $(($(date +%s) - $(stat -c %Y /app/data/.heartbeat))) -lt $HEARTBEAT_MAX_AGE_SEC ] || exit 1

# Define Entrypoint
ENTRYPOINT ["/bin/bash", "/app/app.sh"]