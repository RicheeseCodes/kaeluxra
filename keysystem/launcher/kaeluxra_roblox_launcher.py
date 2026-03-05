#!/usr/bin/env python3
"""
Kaeluxra Roblox Launcher (macOS)

What it does:
1. Shows key window with:
   - Submit Key
   - Get Key
   - Cancel
2. Validates key against your key server.
3. Opens Roblox only if key is valid.
4. If key has expiry, quits Roblox when key lifetime ends.

Environment variables:
- KEY_API_URL (default: http://127.0.0.1:5000/api/client/validate-key)
- KEY_SITE_A_URL (default: http://127.0.0.1:5000/site-a)
- ROBLOX_APP_NAME (default: Roblox)
"""

from __future__ import annotations

import json
import os
import subprocess
import threading
import time
import urllib.error
import urllib.request
import webbrowser
from tkinter import Button, Entry, Frame, Label, StringVar, Tk


KEY_API_URL = os.environ.get("KEY_API_URL", "http://127.0.0.1:5000/api/client/validate-key")
KEY_SITE_A_URL = os.environ.get("KEY_SITE_A_URL", "http://127.0.0.1:5000/site-a")
ROBLOX_APP_NAME = os.environ.get("ROBLOX_APP_NAME", "Roblox")


def call_validate_api(key_value: str) -> dict:
    payload = json.dumps({"key": key_value}).encode("utf-8")
    req = urllib.request.Request(
        KEY_API_URL,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            body = response.read().decode("utf-8")
            data = json.loads(body)
            return data
    except urllib.error.HTTPError as exc:
        try:
            body = exc.read().decode("utf-8")
            data = json.loads(body)
            return data
        except Exception:
            return {"valid": False, "reason": f"HTTP error: {exc.code}"}
    except Exception as exc:  # noqa: BLE001
        return {"valid": False, "reason": f"Network error: {exc}"}


def open_roblox() -> None:
    subprocess.Popen(["open", "-a", ROBLOX_APP_NAME])


def quit_roblox() -> None:
    script = f'tell application "{ROBLOX_APP_NAME}" to quit'
    subprocess.Popen(["osascript", "-e", script])


def monitor_expiry(seconds_remaining: int) -> None:
    if seconds_remaining <= 0:
        return
    time.sleep(seconds_remaining)
    quit_roblox()


def main() -> None:
    root = Tk()
    root.title("Kaeluxra Key System")
    root.geometry("430x220")
    root.resizable(False, False)

    status_var = StringVar(value="Enter your key to continue.")

    frame = Frame(root, padx=16, pady=16)
    frame.pack(fill="both", expand=True)

    Label(frame, text="Kaeluxra Roblox Access", font=("Arial", 14, "bold")).pack(anchor="w")
    Label(frame, text="Key (expires in 6 hours for normal keys):").pack(anchor="w", pady=(12, 4))

    key_input = Entry(frame, width=48)
    key_input.pack(anchor="w", fill="x")
    key_input.focus_set()

    Label(frame, textvariable=status_var, fg="#666666", wraplength=390, justify="left").pack(
        anchor="w", pady=(12, 8)
    )

    buttons = Frame(frame)
    buttons.pack(anchor="w")

    def on_submit() -> None:
        key_value = key_input.get().strip()
        if not key_value:
            status_var.set("Please enter a key first.")
            return

        status_var.set("Checking key...")
        root.update_idletasks()

        data = call_validate_api(key_value)
        if not data.get("valid"):
            status_var.set(f"Invalid key: {data.get('reason', 'Unknown reason')}")
            return

        status_var.set("Key valid. Opening Roblox...")
        open_roblox()

        remaining = data.get("seconds_remaining")
        if isinstance(remaining, int) and remaining > 0:
            watcher = threading.Thread(target=monitor_expiry, args=(remaining,), daemon=True)
            watcher.start()

        root.after(800, root.destroy)

    def on_get_key() -> None:
        webbrowser.open(KEY_SITE_A_URL, new=2)
        status_var.set("Opened key website in your browser.")

    def on_cancel() -> None:
        root.destroy()

    Button(buttons, text="Submit Key", command=on_submit, width=14).pack(side="left", padx=(0, 8))
    Button(buttons, text="Get Key", command=on_get_key, width=14).pack(side="left", padx=(0, 8))
    Button(buttons, text="Cancel", command=on_cancel, width=14).pack(side="left")

    root.mainloop()


if __name__ == "__main__":
    main()
