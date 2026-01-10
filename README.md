# Frigate Telegram Record

A lightweight containerized service that automatically downloads video clips from your Frigate NVR and sends them to Telegram. The service intelligently manages recording history to prevent duplicates, validates video quality, and provides error notifications.

## 📋 Table of Contents

- [Features](#features)
- [How It Works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Operating Modes](#operating-modes)
- [Advanced Usage](#advanced-usage)
- [Troubleshooting](#troubleshooting)
- [Project Structure](#project-structure)

## ✨ Features

- **Automated Video Recording**: Periodically checks Frigate for missing time slots and downloads corresponding clips
- **Dual Operating Modes**: 
  - `record` mode: Sends regular video clips at configurable intervals
  - `timelapse` mode: Creates time-compressed videos from HLS streams
- **Smart Duplicate Prevention**: Uses SQLite database to track sent videos and avoid duplicates
- **Video Validation**: Verifies clip size, MIME type, and duration before sending
- **Intelligent Error Handling**: 
  - Retry mechanism with exponential backoff for Telegram rate limits
  - Error notifications to designated Telegram chat
  - Automatic recovery notifications when previously failed recordings succeed
- **Multi-Camera Support**: Configure multiple cameras with individual Telegram destinations
- **Topic/Thread Support**: Send videos to specific forum topics in Telegram groups
- **Hardware Acceleration**: VAAPI support for efficient timelapse generation

## 🔍 How It Works

The service operates on a time-slot based system:

1. **Time Division**: Divides time into configurable slots (e.g., 15 minutes per slot)
2. **Gap Detection**: Checks the SQLite database to find missing/unsent time slots
3. **Clip Download**: Requests clips from Frigate using the API endpoint:
   ```
   /api/<camera>/start/<start_ts>/end/<end_ts>/clip.mp4
   ```
4. **Validation**: Verifies the downloaded clip meets quality criteria
5. **Telegram Delivery**: Sends validated clips to configured Telegram chats/threads
6. **History Tracking**: Records successful sends in the `sent_ranges` table and failures in `alert_history`

## 📦 Prerequisites

Before you begin, ensure you have:

1. **Frigate NVR**: A running Frigate instance with configured cameras
2. **Telegram Bot**: 
   - Create a bot via [@BotFather](https://t.me/BotFather) and obtain the bot token
   - Add the bot to your target chat/group
   - Get your chat ID (use [@userinfobot](https://t.me/userinfobot) or check Telegram group settings)
3. **Docker**: Docker and Docker Compose installed on your system
4. **(Optional) Hardware Acceleration**: For timelapse mode, ensure `/dev/dri/renderD128` is accessible

## 🚀 Quick Start

### Method 1: Using Docker Compose (Recommended)

1. **Clone or download this repository**:
   ```bash
   git clone <repository-url>
   cd frigate-telegram-record
   ```

2. **Create your configuration file**:
   ```bash
   cp config.env.example config.env
   ```

3. **Edit `config.env` with your settings**:
   ```bash
   nano config.env
   ```
   
   Minimum required settings:
   - `BOT_TOKEN`: Your Telegram bot token
   - `CAMERAS`: Your camera configuration(s)
   - `ERROR_CHAT_ID`: Chat ID for error notifications
   - `FRIGATE_HOST`: Your Frigate server URL

4. **Review and customize** [docker-compose.yml](docker-compose.yml) if needed

5. **Start the service**:
   ```bash
   docker-compose up -d
   ```

6. **Check the logs**:
   ```bash
   docker-compose logs -f frigate-telegram-record
   ```

### Method 2: Using Docker Run

Build and run manually:

```bash
# Build the image
docker build -t frigate-telegram-record .

# Run the container
docker run -d \
  --name frigate-telegram-record \
  -v $(pwd)/data:/app/data \
  -e TZ=Asia/Ho_Chi_Minh \
  -e BOT_TOKEN=your_telegram_bot_token \
  -e FRIGATE_HOST=http://192.168.1.100:5000 \
  -e CAMERAS="Front Door|front_door|2|-1001234567890" \
  -e ERROR_CHAT_ID=-1001234567890 \
  frigate-telegram-record
```

## ⚙️ Configuration

### Essential Environment Variables

| Variable | Description | Example | Required |
|----------|-------------|---------|----------|
| `BOT_TOKEN` | Telegram bot token from @BotFather | `123456789:ABCdef...` | ✅ Yes |
| `CAMERAS` | Camera configurations (see format below) | `Front\|front_door\|2\|-100123` | ✅ Yes |
| `FRIGATE_HOST` | Frigate server URL | `http://192.168.1.100:5000` | ✅ Yes |
| `ERROR_CHAT_ID` | Chat ID for error notifications | `-1001234567890` | ✅ Yes |
| `MODE` | Operating mode | `record` or `timelapse` | No (default: `record`) |

### Camera Configuration Format

The `CAMERAS` variable uses a specific format to configure multiple cameras:

```
DisplayName|frigate_camera_name|thread_id|chat_id
```

- **DisplayName**: Human-readable name shown in Telegram
- **frigate_camera_name**: Camera name as configured in Frigate
- **thread_id**: Topic/thread ID in Telegram (leave empty if not using topics)
- **chat_id**: Telegram chat ID where videos will be sent

**Multiple cameras** are separated by semicolons (`;`):

```bash
CAMERAS=Front Door|front_door|2|-1001234567890;Back Yard|back_yard|3|-1001234567890;Garage|garage||-1009876543210
```

### Additional Configuration Options

For a complete list of available configuration options, see [config.env.example](config.env.example). Key options include:

- **Recording Settings**:
  - `REC_DURATION_MIN`: Duration of each clip in minutes (default: 15)
  - `LOOKBACK_HOURS`: How far back to scan for missing clips (default: 24)
  - `PADDING_SEC`: Extra seconds before/after each clip (default: 5)
  - `MIN_DURATION_PERCENT`: Minimum valid duration percentage (default: 90)

- **Timelapse Settings**:
  - `TIMELAPSE_HOURS`: Duration of each timelapse block (default: 6)
  - `TIMELAPSE_SPEED`: Speed multiplier (default: 60x)
  - `TIMELAPSE_FPS`: Output frame rate (default: 30)
  - `TIMELAPSE_QUALITY`: Encoding quality (default: 24, lower = better)

- **Notification Settings**:
  - `NOTIFY_ON_RECOVERY`: Send recovery notifications (default: true)
  - `ALERT_RETENTION_HOURS`: How long to keep alert history (default: 72)
  - `ALERT_REPEAT`: Resend alerts for same time slot (default: false)

- **Performance Tuning**:
  - `MAX_CONCURRENT_TASKS`: Maximum parallel operations (default: 2)
  - `MAX_RETRIES`: Maximum retry attempts (default: 5)
  - `RETENTION_DAYS`: Database record retention (default: 30)

## 🎮 Operating Modes

### Record Mode (Default)

Continuously monitors Frigate and sends video clips at regular intervals.

```bash
MODE=record
REC_DURATION_MIN=15  # Send 15-minute clips
```

### Timelapse Mode

Creates time-compressed videos from HLS streams.

```bash
MODE=timelapse
TIMELAPSE_HOURS=6     # 6 hours of footage
TIMELAPSE_SPEED=60    # 60x speed (1 hour = 1 minute)
```

### Test Modes

Run a single cycle and exit (useful for testing configuration):

- `MODE=test`: Test record mode
- `MODE=test_timelapse`: Test timelapse mode

## 🔧 Advanced Usage

### Running Both Record and Timelapse

You can run both modes simultaneously by using two separate containers. See the example in [docker-compose.yml](docker-compose.yml):

```bash
docker-compose up -d frigate-telegram-record frigate-telegram-timelapse
```

### Using Hardware Acceleration

For timelapse mode with Intel GPU acceleration:

1. Ensure your user has access to the GPU device:
   ```bash
   sudo usermod -a -G video $USER
   sudo chmod 666 /dev/dri/renderD128
   ```

2. Add device mapping in docker-compose.yml (already included in the example)

### Custom Telegram API Server

If you're using a local Telegram Bot API server:

```bash
TELEGRAM_API_URL=http://your-local-api-server:8081
```

## 🔧 Troubleshooting

### Common Issues

**1. "Database is locked" errors**
- Reduce `MAX_CONCURRENT_TASKS` in your configuration
- Ensure only one instance is accessing the database

**2. Videos not being sent**
- Check bot permissions in the target chat
- Verify chat ID is correct (should start with `-100` for supergroups)
- Check logs: `docker-compose logs -f`

**3. Frigate connection errors**
- Verify `FRIGATE_HOST` is accessible from the container
- Use the internal network IP, not `localhost`
- Check Frigate API is enabled

**4. Hardware acceleration not working**
- Verify device exists: `ls -la /dev/dri/renderD128`
- Check permissions: `groups` should include `video`
- Ensure correct device mapping in docker-compose.yml

### Viewing Logs

```bash
# All logs
docker-compose logs -f

# Specific service
docker-compose logs -f frigate-telegram-record

# Last 100 lines
docker-compose logs --tail=100 frigate-telegram-record
```

### Testing Configuration

Run a single test cycle:

```bash
docker run --rm \
  -v $(pwd)/data:/app/data \
  -e MODE=test \
  -e BOT_TOKEN=your_token \
  -e CAMERAS="Test|camera_name||-1001234567890" \
  -e FRIGATE_HOST=http://192.168.1.100:5000 \
  -e ERROR_CHAT_ID=-1001234567890 \
  -e TEST_REC_DURATION_MIN=1 \
  frigate-telegram-record
```

## 📁 Project Structure

- [app.sh](app.sh) — Main application script (configuration, database, download/send pipeline)
- [docker-compose.yml](docker-compose.yml) — Docker Compose configuration with examples for both modes
- [Dockerfile](Dockerfile) — Container image definition (Alpine Linux with required dependencies)
- [config.env.example](config.env.example) — Complete configuration template with detailed comments
- `data/` — Persistent data directory (created automatically)
  - `video_history.sqlite` — Recording history database
  - `execution.log` — Application logs

## 📝 License

See [LICENSE](LICENSE) for details.

## 🤝 Contributing

Issues and pull requests are welcome!

---

**Need help?** Check the logs first, review [config.env.example](config.env.example) for all available options, or open an issue

```bash
docker run --rm \
    -v $(pwd)/data:/app/data \
    -v $(pwd)/config.env:/app/config/config.env:ro \
    -e MODE=test \
    -e TEST_REC_DURATION_MIN=1 \
    -e BOT_TOKEN=your_token_here \
    frigate-telegram-record
```

Data and logs
- Data directory inside container: `/app/data` (bind this to host `./data`).
- Log file: `/app/data/execution.log`.
- SQLite DB: `/app/data/video_history.sqlite`.

Troubleshooting
- No clips are sent: verify `FRIGATE_HOST`, `CAMERAS`, and that Frigate clip URL pattern is reachable from the container.
- Clip download fails with 404: confirm Frigate has the camera `src` and the requested timestamps exist.
- Telegram failures / rate limits: check logs for `retry after`. Lower `MAX_CONCURRENT_TASKS` if hitting limits.
- Database locked errors: the script sets sqlite timeout; ensure `RETENTION_DAYS` and `MAX_CONCURRENT_TASKS` are reasonable.

Security notes
- Never commit `BOT_TOKEN` or `config.env` to source control. Use `config.env.example` in the repo and keep real secrets out of version control.
- Use a secrets manager or mount a file with restricted permissions for `config.env` when running in production.

Ignored files (recommended)
The repository contains a `.gitignore` that excludes common local/runtime files. Key entries:

- `config.env` — local config with secrets
- `data/` — runtime data (sqlite DB, logs, downloaded clips)
- `*.sqlite` and `*.log` — database and log files

Make sure you don't accidentally commit any sensitive files. See `.gitignore` in the repo.

Extending or customizing
- You can change validation rules (in `app.sh`) to require ffprobe, change padding, or alter how gaps are computed.

License
- See [LICENSE](LICENSE) for license details.