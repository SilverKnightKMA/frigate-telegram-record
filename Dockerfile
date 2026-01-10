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
    jq

# Setup Application Directory
WORKDIR /app

# Copy Main Script
COPY app.sh /app/app.sh

# Set Permissions & Create Data Directories
RUN chmod +x /app/app.sh && \
    mkdir -p /app/data /app/config

# Define Entrypoint
ENTRYPOINT ["/app/app.sh"]
