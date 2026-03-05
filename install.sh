#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

APP_LABEL="Kaeluxra"
APP_ZIP_URL="https://raw.githubusercontent.com/RicheeseCodes/kaeluxra/main/Kaeluxra.zip"
KEY_SITE_A_URL="https://your-domain.tld/site-a"
KEY_VALIDATE_API_URL="https://your-domain.tld/api/client/validate-key"
ROBLOX_DOWNLOAD_PAGE_URL="https://www.roblox.com/download/client?os=mac"

TEMP_DIR=$(mktemp -d)
TARGET_DIR="/Applications"
ENTITLEMENTS_FILE="$TEMP_DIR/entitlements.plist"

spinner() {
    local pid=$!
    local delay=0.1
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    
    printf "\033[?25l"
    
    while ps -p $pid &>/dev/null; do
        printf "\r${CYAN}[${spinstr:i++%${#spinstr}:1}] ${1}...${NC} "
        sleep $delay
    done
    
    wait $pid
    local exit_code=$?
    
    printf "\033[?25h"
    
    if [ $exit_code -eq 0 ]; then
        printf "\r${GREEN}[✔] ${1} - Done${NC}    \n"
    else
        printf "\r${RED}[✘] ${1} - Failed${NC}    \n"
        if [[ "$1" == *"Downloading"* ]]; then exit 1; fi
    fi
}

install_or_update_roblox() {
    local roblox_url roblox_dmg attach_output mount_point installer_app roblox_final_path
    roblox_url=$(
        curl -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" \
             -sSL -o /dev/null -w "%{url_effective}" "$ROBLOX_DOWNLOAD_PAGE_URL"
    )

    if [[ -z "$roblox_url" || "$roblox_url" != *.dmg ]]; then
        echo -e "\n${RED}[✘] Could not resolve latest Roblox macOS DMG URL.${NC}"
        return 1
    fi

    roblox_dmg="$TEMP_DIR/Roblox.dmg"
    curl -fsSL "$roblox_url" -o "$roblox_dmg"

    attach_output=$(hdiutil attach "$roblox_dmg" -nobrowse)
    mount_point=$(echo "$attach_output" | awk 'END {for (i=3; i<=NF; i++) printf (i==3 ? $i : " " $i); print ""}')

    installer_app=$(find "$mount_point" -maxdepth 2 -type d -name "RobloxPlayerInstaller.app" | head -n 1)
    if [[ -z "$installer_app" ]]; then
        installer_app=$(find "$mount_point" -maxdepth 2 -type d -name "*.app" | head -n 1)
    fi

    if [[ -z "$installer_app" ]]; then
        hdiutil detach "$mount_point" -quiet || true
        echo -e "\n${RED}[✘] Roblox installer app not found in mounted DMG.${NC}"
        return 1
    fi

    if [[ -d "/Applications/RobloxPlayerInstaller.app" ]]; then
        rsync -a --delete "$installer_app/" "/Applications/RobloxPlayerInstaller.app/"
    else
        cp -R "$installer_app" "/Applications/"
    fi

    hdiutil detach "$mount_point" -quiet || true

    # Trigger installer app to install/update Roblox.app.
    open -gj "/Applications/RobloxPlayerInstaller.app" || true

    roblox_final_path=""
    for _ in {1..60}; do
        if [[ -d "/Applications/Roblox.app" ]]; then
            roblox_final_path="/Applications/Roblox.app"
            break
        fi
        if [[ -d "$HOME/Applications/Roblox.app" ]]; then
            roblox_final_path="$HOME/Applications/Roblox.app"
            break
        fi
        sleep 1
    done

    if [[ -n "$roblox_final_path" ]]; then
        xattr -cr "$roblox_final_path" || true
        codesign --force --deep --sign - "$roblox_final_path" >/dev/null 2>&1 || true
    else
        echo -e "${YELLOW}[!] Roblox installer launched, but Roblox.app path not detected yet.${NC}"
        echo -e "${YELLOW}[!] Complete installer UI if prompted by macOS.${NC}"
    fi
}

integrate_key_gate_into_kaeluxra() {
    local app_path="$1"
    local macos_dir resources_dir keygate_dir executable_name executable_path real_binary gate_script

    executable_name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$app_path/Contents/Info.plist" 2>/dev/null || true)
    if [[ -z "$executable_name" ]]; then
        executable_name="LunaOWO"
    fi

    macos_dir="$app_path/Contents/MacOS"
    resources_dir="$app_path/Contents/Resources"
    keygate_dir="$resources_dir/keygate"
    executable_path="$macos_dir/$executable_name"
    real_binary="$macos_dir/${executable_name}.real"
    gate_script="$keygate_dir/roblox_key_gate.py"

    mkdir -p "$keygate_dir"

    cat > "$gate_script" <<'PYEOF'
#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import tkinter as tk
import urllib.error
import urllib.request
import webbrowser

KEY_SITE_A_URL = os.environ.get("KEY_SITE_A_URL", "https://your-domain.tld/site-a")
KEY_VALIDATE_API_URL = os.environ.get("KEY_VALIDATE_API_URL", "https://your-domain.tld/api/client/validate-key")
ROBLOX_APP_NAME = os.environ.get("ROBLOX_APP_NAME", "Roblox")
KAELUXRA_APP_NAME = os.environ.get("KAELUXRA_APP_NAME", "Kaeluxra")

def validate_key(key_value):
    payload = json.dumps({"key": key_value}).encode("utf-8")
    req = urllib.request.Request(
        KEY_VALIDATE_API_URL,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        try:
            return json.loads(exc.read().decode("utf-8"))
        except Exception:
            return {"valid": False, "reason": f"HTTP {exc.code}"}
    except Exception as exc:
        return {"valid": False, "reason": f"Network error: {exc}"}

def start_expiry_timer(seconds_remaining):
    if not isinstance(seconds_remaining, int) or seconds_remaining <= 0:
        return
    cmd = (
        f"sleep {seconds_remaining}; "
        f"osascript -e 'tell application \"{ROBLOX_APP_NAME}\" to quit' >/dev/null 2>&1; "
        f"osascript -e 'tell application \"{KAELUXRA_APP_NAME}\" to quit' >/dev/null 2>&1"
    )
    subprocess.Popen(["/bin/bash", "-c", cmd], start_new_session=True)

class KeyWindow:
    def __init__(self):
        self.root = tk.Tk()
        self.root.title("Kaeluxra Key System")
        self.root.geometry("470x230")
        self.root.resizable(False, False)
        self.success = False

        frame = tk.Frame(self.root, padx=16, pady=16)
        frame.pack(fill="both", expand=True)

        tk.Label(frame, text="Kaeluxra Key Verification", font=("Arial", 14, "bold")).pack(anchor="w")
        tk.Label(frame, text="Enter key to open Roblox").pack(anchor="w", pady=(10, 4))

        self.key_entry = tk.Entry(frame, width=54)
        self.key_entry.pack(fill="x")
        self.key_entry.focus_set()

        self.status = tk.StringVar(value="Key required to continue.")
        tk.Label(frame, textvariable=self.status, fg="#666666", wraplength=430, justify="left").pack(anchor="w", pady=(12, 10))

        btn_row = tk.Frame(frame)
        btn_row.pack(anchor="w")
        tk.Button(btn_row, text="Submit Key", width=14, command=self.on_submit).pack(side="left", padx=(0, 8))
        tk.Button(btn_row, text="Get Key", width=14, command=self.on_get_key).pack(side="left", padx=(0, 8))
        tk.Button(btn_row, text="Cancel", width=14, command=self.on_cancel).pack(side="left")

    def on_submit(self):
        value = self.key_entry.get().strip()
        if not value:
            self.status.set("Please enter key.")
            return
        self.status.set("Checking key...")
        self.root.update_idletasks()

        result = validate_key(value)
        if not result.get("valid"):
            self.status.set(f"Invalid key: {result.get('reason', 'Unknown error')}")
            return

        start_expiry_timer(result.get("seconds_remaining"))
        subprocess.Popen(["open", "-a", ROBLOX_APP_NAME])
        self.success = True
        self.root.destroy()

    def on_get_key(self):
        webbrowser.open(KEY_SITE_A_URL, new=2)
        self.status.set("Opened key website.")

    def on_cancel(self):
        self.success = False
        self.root.destroy()

    def run(self):
        self.root.mainloop()
        return self.success

if __name__ == "__main__":
    ui = KeyWindow()
    ok = ui.run()
    sys.exit(0 if ok else 1)
PYEOF
    chmod 755 "$gate_script"

    if [[ -f "$executable_path" && ! -f "$real_binary" ]]; then
        mv "$executable_path" "$real_binary"
    fi

    if [[ ! -f "$real_binary" ]]; then
        echo -e "\n${RED}[✘] Could not find original executable for key-gate integration.${NC}"
        return 1
    fi

    cat > "$executable_path" <<'SHEOF'
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_CONTENTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
EXECUTABLE_NAME="$(basename "$0")"
REAL_BIN="$SCRIPT_DIR/${EXECUTABLE_NAME}.real"
GATE_SCRIPT="$APP_CONTENTS_DIR/Resources/keygate/roblox_key_gate.py"

export KEY_SITE_A_URL="${KEY_SITE_A_URL:-https://your-domain.tld/site-a}"
export KEY_VALIDATE_API_URL="${KEY_VALIDATE_API_URL:-https://your-domain.tld/api/client/validate-key}"
export ROBLOX_APP_NAME="${ROBLOX_APP_NAME:-Roblox}"
export KAELUXRA_APP_NAME="${KAELUXRA_APP_NAME:-Kaeluxra}"

if [[ ! -f "$REAL_BIN" ]]; then
  echo "Missing real app binary: $REAL_BIN" >&2
  exit 1
fi

if [[ -f "$GATE_SCRIPT" ]]; then
  python3 "$GATE_SCRIPT" || exit 0
fi

exec "$REAL_BIN" "$@"
SHEOF
    chmod 755 "$executable_path"
    xattr -cr "$app_path"
}

main() {

    clear
    echo -e "${CYAN}Starting installation...${NC}\n"

    if [ -w "/Applications" ]; then
        TARGET_DIR="/Applications"
        echo -e "${CYAN}Global permissions detected. Installing to: $TARGET_DIR${NC}${NC}"
    else
        TARGET_DIR="$HOME/Applications"
        echo -e "${YELLOW}Local user detected (no global write access). Installing to: $TARGET_DIR${NC}${NC}"
    fi

    curl -fsSL "$APP_ZIP_URL" -o "$TEMP_DIR/Kaeluxra.zip" &
    spinner "Downloading $APP_LABEL"

    if ! unzip -tq "$TEMP_DIR/Kaeluxra.zip" > /dev/null 2>&1; then
         echo -e "\n${RED}[✘] Critical Error: Downloaded file is not a valid ZIP.${NC}"
         rm -rf "$TEMP_DIR"
         exit 1
    fi

    unzip -oq "$TEMP_DIR/Kaeluxra.zip" -d "$TEMP_DIR" &
    spinner "Unzipping archive"

    APP_PATH=$(find "$TEMP_DIR" -maxdepth 1 -type d -name "*.app" | head -n 1)

    if [[ -z "$APP_PATH" ]]; then
        echo -e "\n${RED}[✘] Error: No .app bundle found inside the ZIP archive.${NC}"
        echo -e "${YELLOW}Make sure you zipped the folder 'Kaeluxra.app', not just the binary.${NC}"
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    APP_NAME=$(basename "$APP_PATH")
    INSTALL_PATH="$TARGET_DIR/$APP_NAME"

    if [ ! -d "$TARGET_DIR" ]; then
        mkdir -p "$TARGET_DIR"
    fi
    
    if [ -d "$INSTALL_PATH" ]; then
        (
            rsync -a --delete "$APP_PATH/" "$INSTALL_PATH/"
        ) &
        spinner "Updating existing version"
    else
        mv "$APP_PATH" "$TARGET_DIR/"
    fi

    (
        install_or_update_roblox
    ) &
    spinner "Installing/Updating Roblox"

    (
        integrate_key_gate_into_kaeluxra "$INSTALL_PATH"
    ) &
    spinner "Injecting Key-Gate Into Kaeluxra"

    cat > "$ENTITLEMENTS_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.get-task-allow</key>
    <true/>
    <key>com.apple.security.cs.debugger</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
</dict>
</plist>
EOF
    (
        chmod -R 755 "$INSTALL_PATH"
        xattr -cr "$INSTALL_PATH"
        codesign --force --deep --options runtime --sign - --entitlements "$ENTITLEMENTS_FILE" "$INSTALL_PATH"
    ) &
    spinner "Finalizing & Securing app"
    rm -rf "$TEMP_DIR"
    echo -e "\n${GREEN}✨ Success!${NC}"
    echo -e "${CYAN}Installed to: $INSTALL_PATH${NC}"
    echo -e "${CYAN}Roblox path: /Applications/Roblox.app${NC}"
    echo -e "${YELLOW}Set KEY_SITE_A_URL and KEY_VALIDATE_API_URL in this installer before release.${NC}"
}

main
