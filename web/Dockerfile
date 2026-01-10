FROM python:3.11-slim

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application files
COPY web_dashboard.py .
COPY templates/ ./templates/

# Expose port
EXPOSE 8080

# Run the application
CMD ["python", "web_dashboard.py"]
