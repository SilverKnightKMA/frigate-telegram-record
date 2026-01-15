import os
import sys
import sqlite3
import base64
import pytz
from datetime import datetime

# System Configuration
DB_FILE = os.path.abspath(os.environ.get('DB_FILE', '/app/data/video_history.sqlite'))
PORT = int(os.environ.get('WEB_PORT', '8080'))
env_tz = os.environ.get('TZ', 'Asia/Ho_Chi_Minh')
LOCAL_TZ = pytz.timezone(env_tz)

def diagnose_db_issues(db_path, error_msg):
    """
    Checks file permissions and existence to provide detailed error logs
    when DB connection fails.
    """
    try:
        sys.stderr.write(f"\n[DIAGNOSTICS] Connection failed: {error_msg}\n")
        if os.path.exists(db_path):
            st = os.stat(db_path)
            sys.stderr.write(f"[DIAGNOSTICS] DB File: {db_path} | Size: {st.st_size} bytes | Mode: {oct(st.st_mode)}\n")
            sys.stderr.write(f"[DIAGNOSTICS] Access: R_OK={os.access(db_path, os.R_OK)} | W_OK={os.access(db_path, os.W_OK)}\n")
        else:
            sys.stderr.write(f"[DIAGNOSTICS] CRITICAL: File not found at {db_path}\n")
        sys.stderr.flush()
    except Exception:
        pass

def get_db_connection():
    """
    Establishes a read-only connection to the SQLite database.
    Returns None if connection fails.
    """
    if not os.path.exists(DB_FILE):
        return None
    conn = None
    try:
        db_uri = f"file:{DB_FILE}?mode=ro&immutable=1"
        conn = sqlite3.connect(db_uri, uri=True, timeout=10.0)
        conn.row_factory = sqlite3.Row
        conn.execute("SELECT 1 FROM events LIMIT 1")
        return conn
    except sqlite3.OperationalError as e:
        diagnose_db_issues(DB_FILE, str(e))
        if conn: conn.close()
        return None
    except Exception as e:
        sys.stderr.write(f"Unexpected DB Error: {e}\n")
        if conn: conn.close()
        return None

def format_timestamp(ts):
    """Converts unix timestamp to local readable string."""
    if not ts: return ""
    dt_utc = datetime.fromtimestamp(ts, pytz.utc)
    dt_local = dt_utc.astimezone(LOCAL_TZ)
    return dt_local.strftime('%Y-%m-%d %H:%M:%S')

def decode_message(b64_msg):
    """Safely decodes base64 strings."""
    if not b64_msg: return ""
    try:
        return base64.b64decode(b64_msg).decode('utf-8', errors='replace')
    except Exception:
        return str(b64_msg)

def parse_frontend_datetime(iso_str):
    """Parses datetime string from frontend inputs to timestamp."""
    if not iso_str: return None
    try:
        dt = datetime.strptime(iso_str, "%Y-%m-%dT%H:%M")
        localized = LOCAL_TZ.localize(dt)
        return localized.timestamp()
    except ValueError:
        return None