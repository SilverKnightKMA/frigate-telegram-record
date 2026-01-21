# Use Python 3.12 slim to optimize image size
FROM python:3.14-slim

WORKDIR /app

# Install timezone data and configure system timezone
RUN apt-get update && apt-get install -y tzdata && \
    ln -fs /usr/share/zoneinfo/Asia/Ho_Chi_Minh /etc/localtime && \
    dpkg-reconfigure -f noninteractive tzdata && \
    rm -rf /var/lib/apt/lists/*

# Copy dependency file and install libraries
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy source code and interface
COPY common.py .
COPY web_dashboard.py .
COPY templates/ ./templates/
COPY static/ ./static/

# Set environment variables
ENV TZ=Asia/Ho_Chi_Minh
ENV DB_FILE=/app/data/video_history.sqlite
ENV WEB_PORT=8080

EXPOSE 8080

# Launch the application
CMD ["python", "web_dashboard.py"]