# Frigate Telegram Record

A lightweight containerised service that downloads clips from a Frigate instance and sends them to Telegram. It maintains a small SQLite history to avoid duplicates, validates clips, and alerts on failures.

Features
- Periodically checks Frigate for missing/unsent time slots and downloads corresponding clips.
- Validates clips (size, MIME, optional ffprobe) before sending to Telegram.
- Retries and exponential-style handling for Telegram rate limits.
- Keeps a local SQLite history (`sent_ranges`, `alert_history`) to prevent duplicate sends and to track failures.
- Modes: `test` (one-shot test cycle) and `record` (daemon continuous recording).

Repository files
- `docker-compose.yml` — example docker-compose service configuration.
- `Dockerfile` — image that installs `bash`, `curl`, `ffmpeg`, `sqlite`, and runs `app.sh`.
- `app.sh` — main script: configuration loader, database handling, download/send pipeline.
- `config.env` — example env file (optional; values can be injected by docker-compose).

How it works (brief)
- The service divides time into slots (configured by `REC_DURATION_MIN`). For each camera it checks the SQLite `sent_ranges` table to find gaps and requests clips from Frigate using:

	/api/<camera>/start/<start_ts>/end/<end_ts>/clip.mp4

- Downloaded clips are validated then sent to Telegram via `sendVideo`. Successful sends insert a record into `sent_ranges`. Failures insert into `alert_history` and, if configured, an error message is posted to `ERROR_CHAT_ID`.

Configuration (environment variables)
Place environment variables either in a mounted `config.env` (the container reads `/app/config/config.env`) or pass via `docker-compose`/`docker run`.

- `FRIGATE_HOST` — Frigate base URL (e.g. `http://127.0.0.1:5000`).
- `TELEGRAM_API_URL` — Telegram API endpoint or proxy (default `https://api.telegram.org`).
- `BOT_TOKEN` — Telegram bot token (keep secret).
- `CAMERAS` — Semicolon-separated camera entries in the format `Name|src|thread_id|chat_id`.
	- Example: `FrontDoor|frontdoor|2|-1001234567890;BackYard|backyard|3|-1001234567890`
- `ERROR_CHAT_ID` — Telegram chat ID to send error alerts.
- `ERROR_THREAD_ID` — Optional thread ID for grouped error messages.
- `NOTIFY_ON_RECOVERY` — When a previously-failed recording is later successfully sent, control how the script notifies the original error message:
	- `true` (default): send a reply, add a reaction, and edit the original error message to mark it resolved.
	- `false`: only edit the original error message (silent update; no reply/reaction).
- `REC_DURATION_MIN` — Recording/check slot length in minutes (default 15).
- `TEST_REC_DURATION_MIN` — Slot length used in `MODE=test` (default 1).
- `PADDING_SEC` — Seconds to pad before/after requested clip when downloading from Frigate (default 5).
- `MODE` — `record` (daemon) or `test` (single cycle).
- `RETENTION_DAYS`, `ALERT_RETENTION_HOURS`, `ALERT_REPEAT`, `LOOKBACK_HOURS`, `MAX_CONCURRENT_TASKS`, `MAX_RETRIES` — tuning and retention defaults available in the script. `ALERT_RETENTION_HOURS` uses hours (not days); `ALERT_REPEAT` controls whether an already-sent alert should be resent (true/false).

Example `config.env` (minimal)
```
TZ=Asia/Ho_Chi_Minh
FRIGATE_HOST=http://127.0.0.1:5000
TELEGRAM_API_URL=https://api.telegram.org
# BOT_TOKEN=<set via docker-compose or docker run>
ERROR_CHAT_ID=-1001234567890
NOTIFY_ON_RECOVERY=true
PADDING_SEC=5
REC_DURATION_MIN=15
MODE=record
```

Example `CAMERAS` format
```
CAMERAS=FrontDoor|frontdoor|2|-1001234567890;BackYard|backyard|3|-1001234567890
```

Quick deploy (recommended): docker-compose

1. Copy or edit `docker-compose.yml` and ensure volumes and env are correct. The provided `docker-compose.yml` mounts `./data` to `/app/data` and `./config.env` to `/app/config/config.env`.
2. Use `config.env.example` as a template: copy it to `config.env`, fill in values.
	Example:

```bash
cp config.env.example config.env
# edit config.env and set BOT_TOKEN and other values
```
3. Start the service:

```bash
docker-compose up -d
```

Check logs:

```bash
docker-compose logs -f frigate-telegram
```

Manual build & run

```bash
docker build -t frigate-telegram-record .

docker run -d \
	--name frigate_tele_bot \
	-v $(pwd)/data:/app/data \
	-v $(pwd)/config.env:/app/config/config.env:ro \
	-e TZ=Asia/Ho_Chi_Minh \
	-e BOT_TOKEN=your_token_here \
	-e FRIGATE_HOST=http://127.0.0.1:5000 \
	frigate-telegram-record
```

Running in `test` mode (one-shot)

Set `MODE=test` and optionally `TEST_REC_DURATION_MIN=1` to run a single quick cycle for a short slot. Example using `docker run`:

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