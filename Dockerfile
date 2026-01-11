FROM alpine:latest

# [MỚI] Khai báo biến TARGETARCH để Docker biết đang build cho chip nào (amd64 hay arm64)
ARG TARGETARCH

# 1. Cài đặt các thư viện CHUNG (có trên cả Intel và ARM)
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

# 2. [QUAN TRỌNG] Chỉ cài driver Intel nếu đang build trên kiến trúc amd64
# Nếu là arm64 (như Raspberry Pi), đoạn này sẽ được bỏ qua -> Không còn lỗi.
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

# [Ops] Healthcheck Configuration
ENV HEARTBEAT_MAX_AGE_SEC=300

HEALTHCHECK --interval=60s --timeout=10s --retries=3 \
  CMD [ $(($(date +%s) - $(stat -c %Y /app/data/.heartbeat))) -lt $HEARTBEAT_MAX_AGE_SEC ] || exit 1

# Define Entrypoint
ENTRYPOINT ["/bin/bash", "/app/app.sh"]