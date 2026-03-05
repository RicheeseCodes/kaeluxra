from __future__ import annotations

import os
import secrets
import sqlite3
import string
import time
from datetime import datetime, timezone
from functools import wraps
from pathlib import Path
from typing import Any, Optional

from flask import (
    Flask,
    flash,
    g,
    jsonify,
    redirect,
    render_template,
    request,
    session,
    url_for,
)


BASE_DIR = Path(__file__).resolve().parent
DB_PATH = BASE_DIR / "keysystem.db"

KEY_LIFETIME_SECONDS = 6 * 60 * 60
KEY_GENERATION_COOLDOWN_SECONDS = 4 * 60

SITE_A_DEFAULT = "https://localhost:5000/site-a"
SITE_B_DEFAULT = "https://localhost:5000/site-b"

DISCORD_VIP_URL = "https://discord.gg/VtDa5PB33X"
DISCORD_JOIN_URL = "https://discord.gg/KvGJvk4Rgv"


def utc_ts() -> int:
    return int(time.time())


def ts_to_utc_string(ts: Optional[int]) -> str:
    if not ts:
        return "Never"
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")


def seconds_to_human(seconds: Optional[int]) -> str:
    if seconds is None:
        return "Never expires"
    if seconds <= 0:
        return "Expired"
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    parts = []
    if h:
        parts.append(f"{h}h")
    if m:
        parts.append(f"{m}m")
    if s and not h:
        parts.append(f"{s}s")
    return " ".join(parts) if parts else "0s"


def remaining_seconds(expires_at: Optional[int]) -> Optional[int]:
    if expires_at is None:
        return None
    return max(0, expires_at - utc_ts())


def make_key(prefix: str = "KX") -> str:
    alphabet = string.ascii_uppercase + string.digits
    groups = ["".join(secrets.choice(alphabet) for _ in range(4)) for _ in range(4)]
    return f"{prefix}-{'-'.join(groups)}"


def normalize_key(value: str) -> str:
    return value.strip().upper()


def bool_to_int(value: bool) -> int:
    return 1 if value else 0


def to_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def parse_datetime_local(value: str) -> Optional[int]:
    value = value.strip()
    if not value:
        return None
    try:
        # HTML datetime-local format: YYYY-MM-DDTHH:MM
        dt = datetime.strptime(value, "%Y-%m-%dT%H:%M")
        # Treat input as UTC to keep logic explicit and stable.
        dt = dt.replace(tzinfo=timezone.utc)
        return int(dt.timestamp())
    except ValueError:
        return None


app = Flask(__name__, template_folder="templates", static_folder="static")
app.secret_key = os.environ.get("KEYSYS_SECRET_KEY", "change-me-in-production")
app.config["ADMIN_PASSWORD"] = os.environ.get("KEYSYS_ADMIN_PASSWORD", "Light@83")


SETTINGS_DEFAULTS = {
    "site_a_enabled": "1",
    "site_b_enabled": "1",
    "all_keys_paused": "0",
}


def get_db() -> sqlite3.Connection:
    if "db" not in g:
        conn = sqlite3.connect(DB_PATH)
        conn.row_factory = sqlite3.Row
        g.db = conn
    return g.db


@app.teardown_appcontext
def close_db(_: Optional[BaseException]) -> None:
    conn = g.pop("db", None)
    if conn is not None:
        conn.close()


def init_db() -> None:
    conn = sqlite3.connect(DB_PATH)
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS settings (
            name TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS keys (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            key_value TEXT UNIQUE NOT NULL,
            key_type TEXT NOT NULL CHECK (key_type IN ('normal', 'vip')),
            created_at INTEGER NOT NULL,
            expires_at INTEGER,
            revoked INTEGER NOT NULL DEFAULT 0,
            created_by TEXT NOT NULL DEFAULT 'site_b',
            note TEXT NOT NULL DEFAULT '',
            last_seen_at INTEGER
        );

        CREATE TABLE IF NOT EXISTS generation_cooldowns (
            client_id TEXT PRIMARY KEY,
            last_generated_at INTEGER NOT NULL
        );
        """
    )
    for key, value in SETTINGS_DEFAULTS.items():
        conn.execute(
            "INSERT OR IGNORE INTO settings (name, value) VALUES (?, ?)",
            (key, value),
        )
    conn.commit()
    conn.close()


def get_setting(name: str) -> str:
    row = get_db().execute("SELECT value FROM settings WHERE name = ?", (name,)).fetchone()
    if row:
        return row["value"]
    return SETTINGS_DEFAULTS.get(name, "0")


def set_setting(name: str, value: str) -> None:
    db = get_db()
    db.execute(
        """
        INSERT INTO settings (name, value)
        VALUES (?, ?)
        ON CONFLICT(name) DO UPDATE SET value = excluded.value
        """,
        (name, value),
    )
    db.commit()


def admin_required(fn):
    @wraps(fn)
    def wrapped(*args, **kwargs):
        if not session.get("is_admin"):
            return redirect(url_for("site_c_login"))
        return fn(*args, **kwargs)

    return wrapped


def client_fingerprint() -> str:
    ip = request.headers.get("X-Forwarded-For", request.remote_addr or "unknown").split(",")[0].strip()
    ua = request.headers.get("User-Agent", "")
    return f"{ip}|{ua[:200]}"


def validate_key(key_value: str) -> dict[str, Any]:
    normalized = normalize_key(key_value)
    db = get_db()

    row = db.execute(
        """
        SELECT id, key_value, key_type, created_at, expires_at, revoked, last_seen_at
        FROM keys
        WHERE key_value = ?
        """,
        (normalized,),
    ).fetchone()

    if row is None:
        return {"valid": False, "reason": "Key not found."}

    if int(row["revoked"]) == 1:
        return {"valid": False, "reason": "Key was manually expired."}

    if to_bool(get_setting("all_keys_paused")):
        return {"valid": False, "reason": "All keys are temporarily disabled by admin."}

    expires_at = row["expires_at"]
    if expires_at is not None and utc_ts() >= int(expires_at):
        return {"valid": False, "reason": "Key expired."}

    db.execute(
        "UPDATE keys SET last_seen_at = ? WHERE id = ?",
        (utc_ts(), row["id"]),
    )
    db.commit()

    expires_at_int = int(expires_at) if expires_at is not None else None
    return {
        "valid": True,
        "key": row["key_value"],
        "key_type": row["key_type"],
        "expires_at": expires_at_int,
        "expires_at_utc": ts_to_utc_string(expires_at_int),
        "seconds_remaining": remaining_seconds(expires_at_int),
    }


@app.route("/")
def root():
    return redirect(url_for("site_a"))


@app.route("/site-a")
def site_a():
    if not to_bool(get_setting("site_a_enabled")):
        return render_template("maintenance.html", site_name="Website A")
    return render_template(
        "site_a.html",
        website_b_url=url_for("site_b"),
        discord_vip_url=DISCORD_VIP_URL,
        discord_join_url=DISCORD_JOIN_URL,
    )


@app.route("/site-b")
def site_b():
    if not to_bool(get_setting("site_b_enabled")):
        return render_template("maintenance.html", site_name="Website B")
    return render_template("site_b.html", cooldown_seconds=KEY_GENERATION_COOLDOWN_SECONDS)


@app.post("/api/generate-key")
def api_generate_key():
    if not to_bool(get_setting("site_b_enabled")):
        return jsonify({"ok": False, "error": "Website B is currently disabled by admin."}), 403

    db = get_db()
    fingerprint = client_fingerprint()
    now = utc_ts()

    row = db.execute(
        "SELECT last_generated_at FROM generation_cooldowns WHERE client_id = ?",
        (fingerprint,),
    ).fetchone()

    if row is not None:
        elapsed = now - int(row["last_generated_at"])
        if elapsed < KEY_GENERATION_COOLDOWN_SECONDS:
            wait_for = KEY_GENERATION_COOLDOWN_SECONDS - elapsed
            return (
                jsonify(
                    {
                        "ok": False,
                        "error": f"Cooldown active. Try again in {seconds_to_human(wait_for)}.",
                        "cooldown_remaining": wait_for,
                    }
                ),
                429,
            )

    key_value = make_key("KX")
    expires_at = now + KEY_LIFETIME_SECONDS

    db.execute(
        """
        INSERT INTO keys (key_value, key_type, created_at, expires_at, revoked, created_by)
        VALUES (?, 'normal', ?, ?, 0, 'site_b')
        """,
        (key_value, now, expires_at),
    )
    db.execute(
        """
        INSERT INTO generation_cooldowns (client_id, last_generated_at)
        VALUES (?, ?)
        ON CONFLICT(client_id) DO UPDATE SET last_generated_at = excluded.last_generated_at
        """,
        (fingerprint, now),
    )
    db.commit()

    return jsonify(
        {
            "ok": True,
            "key": key_value,
            "expires_at": expires_at,
            "expires_at_utc": ts_to_utc_string(expires_at),
            "seconds_remaining": KEY_LIFETIME_SECONDS,
            "cooldown_seconds": KEY_GENERATION_COOLDOWN_SECONDS,
        }
    )


@app.post("/api/client/validate-key")
def api_client_validate_key():
    payload = request.get_json(silent=True) or {}
    key_value = payload.get("key") or request.form.get("key", "")
    key_value = str(key_value)
    if not key_value.strip():
        return jsonify({"valid": False, "reason": "Missing key."}), 400

    result = validate_key(key_value)
    code = 200 if result["valid"] else 401
    return jsonify(result), code


@app.route("/site-c", methods=["GET", "POST"])
def site_c_login():
    if request.method == "POST":
        password = request.form.get("password", "")
        if password == app.config["ADMIN_PASSWORD"]:
            session["is_admin"] = True
            return redirect(url_for("site_c_dashboard"))
        flash("Wrong password.", "error")
    return render_template("admin_login.html")


@app.post("/site-c/logout")
@admin_required
def site_c_logout():
    session.clear()
    return redirect(url_for("site_c_login"))


@app.route("/site-c/dashboard")
@admin_required
def site_c_dashboard():
    db = get_db()
    now = utc_ts()
    active_keys_rows = db.execute(
        """
        SELECT id, key_value, key_type, created_at, expires_at, revoked, created_by, note, last_seen_at
        FROM keys
        WHERE revoked = 0 AND (expires_at IS NULL OR expires_at > ?)
        ORDER BY created_at DESC
        """,
        (now,),
    ).fetchall()

    vip_rows = db.execute(
        """
        SELECT id, key_value, key_type, created_at, expires_at, revoked, created_by, note, last_seen_at
        FROM keys
        WHERE key_type = 'vip'
        ORDER BY created_at DESC
        """
    ).fetchall()

    def map_row(row: sqlite3.Row) -> dict[str, Any]:
        exp = int(row["expires_at"]) if row["expires_at"] is not None else None
        return {
            "id": int(row["id"]),
            "key_value": row["key_value"],
            "key_type": row["key_type"],
            "created_at_utc": ts_to_utc_string(int(row["created_at"])),
            "expires_at_utc": ts_to_utc_string(exp),
            "remaining": seconds_to_human(remaining_seconds(exp)),
            "revoked": bool(int(row["revoked"])),
            "created_by": row["created_by"],
            "note": row["note"],
            "last_seen_at_utc": ts_to_utc_string(int(row["last_seen_at"])) if row["last_seen_at"] else "Never",
        }

    active_keys = [map_row(r) for r in active_keys_rows]
    vip_keys = [map_row(r) for r in vip_rows]

    return render_template(
        "admin_dashboard.html",
        active_keys=active_keys,
        vip_keys=vip_keys,
        site_a_enabled=to_bool(get_setting("site_a_enabled")),
        site_b_enabled=to_bool(get_setting("site_b_enabled")),
        all_keys_paused=to_bool(get_setting("all_keys_paused")),
        now_utc=ts_to_utc_string(utc_ts()),
    )


@app.post("/admin/settings/site-a")
@admin_required
def admin_toggle_site_a():
    enabled = to_bool(request.form.get("enabled", "0"))
    set_setting("site_a_enabled", str(bool_to_int(enabled)))
    flash(f"Website A is now {'ON' if enabled else 'OFF'}.", "ok")
    return redirect(url_for("site_c_dashboard"))


@app.post("/admin/settings/site-b")
@admin_required
def admin_toggle_site_b():
    enabled = to_bool(request.form.get("enabled", "0"))
    set_setting("site_b_enabled", str(bool_to_int(enabled)))
    flash(f"Website B is now {'ON' if enabled else 'OFF'}.", "ok")
    return redirect(url_for("site_c_dashboard"))


@app.post("/admin/settings/all-keys-pause")
@admin_required
def admin_toggle_all_keys_pause():
    enabled = to_bool(request.form.get("enabled", "0"))
    set_setting("all_keys_paused", str(bool_to_int(enabled)))
    flash(
        "All keys were force-expired for users."
        if enabled
        else "All keys were re-activated (subject to normal expiry/revocation).",
        "ok",
    )
    return redirect(url_for("site_c_dashboard"))


@app.post("/admin/key/<int:key_id>/expire")
@admin_required
def admin_expire_key(key_id: int):
    db = get_db()
    db.execute("UPDATE keys SET revoked = 1 WHERE id = ?", (key_id,))
    db.commit()
    flash("Key expired.", "ok")
    return redirect(url_for("site_c_dashboard"))


@app.post("/admin/key/<int:key_id>/restore")
@admin_required
def admin_restore_key(key_id: int):
    db = get_db()
    db.execute("UPDATE keys SET revoked = 0 WHERE id = ?", (key_id,))
    db.commit()
    flash("Key restored.", "ok")
    return redirect(url_for("site_c_dashboard"))


@app.post("/admin/vip/create")
@admin_required
def admin_create_vip_key():
    raw_custom = request.form.get("custom_key", "").strip().upper()
    custom_expiry_hours = request.form.get("expires_in_hours", "").strip()
    custom_expiry_datetime = request.form.get("expires_at_datetime", "").strip()

    key_value = normalize_key(raw_custom) if raw_custom else make_key("VIP")
    expires_at: Optional[int] = None

    if custom_expiry_datetime:
        parsed = parse_datetime_local(custom_expiry_datetime)
        if parsed is None:
            flash("Invalid custom datetime format.", "error")
            return redirect(url_for("site_c_dashboard"))
        expires_at = parsed
    elif custom_expiry_hours:
        try:
            hours = float(custom_expiry_hours)
            if hours <= 0:
                raise ValueError
            expires_at = utc_ts() + int(hours * 3600)
        except ValueError:
            flash("`expires_in_hours` must be a positive number.", "error")
            return redirect(url_for("site_c_dashboard"))

    db = get_db()
    try:
        db.execute(
            """
            INSERT INTO keys (key_value, key_type, created_at, expires_at, revoked, created_by, note)
            VALUES (?, 'vip', ?, ?, 0, 'site_c', 'vip')
            """,
            (key_value, utc_ts(), expires_at),
        )
        db.commit()
    except sqlite3.IntegrityError:
        flash("That key already exists.", "error")
        return redirect(url_for("site_c_dashboard"))

    if expires_at is None:
        flash(f"VIP key created: {key_value} (never expires).", "ok")
    else:
        flash(f"VIP key created: {key_value} (expires {ts_to_utc_string(expires_at)}).", "ok")
    return redirect(url_for("site_c_dashboard"))


@app.post("/admin/vip/<int:key_id>/set-expiry")
@admin_required
def admin_set_vip_expiry(key_id: int):
    expires_in_hours = request.form.get("expires_in_hours", "").strip()
    expires_at_datetime = request.form.get("expires_at_datetime", "").strip()

    expires_at: Optional[int] = None
    if expires_at_datetime:
        parsed = parse_datetime_local(expires_at_datetime)
        if parsed is None:
            flash("Invalid datetime format.", "error")
            return redirect(url_for("site_c_dashboard"))
        expires_at = parsed
    elif expires_in_hours:
        try:
            hours = float(expires_in_hours)
            if hours <= 0:
                raise ValueError
            expires_at = utc_ts() + int(hours * 3600)
        except ValueError:
            flash("`expires_in_hours` must be a positive number.", "error")
            return redirect(url_for("site_c_dashboard"))

    db = get_db()
    db.execute("UPDATE keys SET expires_at = ? WHERE id = ? AND key_type = 'vip'", (expires_at, key_id))
    db.commit()
    flash("VIP expiry updated.", "ok")
    return redirect(url_for("site_c_dashboard"))


@app.route("/health")
def health():
    return jsonify({"ok": True, "time_utc": ts_to_utc_string(utc_ts())})


if __name__ == "__main__":
    init_db()
    host = os.environ.get("KEYSYS_HOST", "0.0.0.0")
    port = int(os.environ.get("KEYSYS_PORT", "5000"))
    app.run(host=host, port=port, debug=False)
