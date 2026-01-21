# Frigate Record Web Dashboard

## How to Use the Dashboard

A simple web dashboard for monitoring camera statistics and recording history from the database.

### Start with Docker Compose

```bash
docker-compose up -d frigate-web-dashboard
```

### Access the Dashboard

Open your browser and navigate to: `http://localhost:8080`

![Dashboard](dashboard.png)

![Events](events.png)

### Features

The dashboard provides:

1. **Overview Statistics:**
   - Total number of cameras
   - Number of successful recordings
   - Number of timelapse videos
   - Number of errors/failures
   - Activity in the last 24 hours

2. **Detailed Camera Statistics Table:**
   - Camera name
   - Number of successful recordings
   - Number of timelapse videos
   - Number of errors
   - Total recording duration
   - First and most recent recording times

3. **Recent Activity List:**
   - The 100 most recent activities
   - Includes successful recordings, timelapse videos, and errors
   - Detailed information about each activity

### Configuration

You can change the port in `docker-compose.yml`:

```yaml
environment:
  - WEB_PORT=8080  # Change the port if needed
ports:
  - "8080:8080"    # Change the left-hand port
```

### Run Standalone (Without Docker)

```bash
# Install dependencies
pip install -r requirements.txt

# Run the app
export DB_FILE=./data/video_history.sqlite
python web_dashboard.py
```

The dashboard will automatically refresh every 30 seconds.
