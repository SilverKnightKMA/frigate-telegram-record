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

# Define Entrypoint
ENTRYPOINT ["/app/app.sh"]