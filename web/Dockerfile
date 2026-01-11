FROM python:3.12-slim

WORKDIR /app

# Cài đặt timezone data để đảm bảo convert giờ chính xác
RUN apt-get update && apt-get install -y tzdata && \
    ln -fs /usr/share/zoneinfo/Asia/Ho_Chi_Minh /etc/localtime && \
    dpkg-reconfigure -f noninteractive tzdata && \
    rm -rf /var/lib/apt/lists/*

# Copy dependency definition
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application source code
COPY web_dashboard.py .
COPY templates/ ./templates/

# Thiết lập biến môi trường
ENV TZ=Asia/Ho_Chi_Minh
ENV DB_FILE=/app/data/video_history.sqlite
ENV WEB_PORT=8080

EXPOSE 8080

CMD ["python", "web_dashboard.py"]