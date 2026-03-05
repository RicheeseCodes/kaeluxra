#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

APP_LABEL="Kaeluxra"
APP_ZIP_URL="https://raw.githubusercontent.com/RicheeseCodes/kaeluxra/main/Kaeluxra.zip"
KEYSYS_REPO_TARBALL_URL="https://codeload.github.com/RicheeseCodes/kaeluxra/tar.gz/refs/heads/main"
KEYSYS_PORT="5055"
KEY_SITE_A_URL="http://127.0.0.1:${KEYSYS_PORT}/site-a"
KEY_VALIDATE_API_URL="http://127.0.0.1:${KEYSYS_PORT}/api/client/validate-key"
ROBLOX_DOWNLOAD_PAGE_URL="https://www.roblox.com/download/client?os=mac"
KEYSYS_ADMIN_PASSWORD="${KEYSYS_ADMIN_PASSWORD:-Light@83}"

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
    local roblox_exec exec_path stable_count m1 m2
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

    # Wait for installer process to finish so later wrapper injection is not overwritten.
    for _ in {1..120}; do
        if ! pgrep -if "RobloxPlayerInstaller" >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

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
        roblox_exec=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$roblox_final_path/Contents/Info.plist" 2>/dev/null || true)
        if [[ -z "$roblox_exec" ]]; then
            roblox_exec="RobloxPlayer"
        fi
        exec_path="$roblox_final_path/Contents/MacOS/$roblox_exec"
        stable_count=0
        for _ in {1..20}; do
            if [[ ! -f "$exec_path" ]]; then
                sleep 1
                continue
            fi
            m1=$(stat -f "%m" "$exec_path" 2>/dev/null || echo 0)
            sleep 1
            m2=$(stat -f "%m" "$exec_path" 2>/dev/null || echo 1)
            if [[ "$m1" == "$m2" ]]; then
                stable_count=$((stable_count + 1))
            else
                stable_count=0
            fi
            if [[ $stable_count -ge 2 ]]; then
                break
            fi
        done

        xattr -cr "$roblox_final_path" || true
        codesign --force --deep --sign - "$roblox_final_path" >/dev/null 2>&1 || true
    else
        echo -e "${YELLOW}[!] Roblox installer launched, but Roblox.app path not detected yet.${NC}"
        echo -e "${YELLOW}[!] Complete installer UI if prompted by macOS.${NC}"
    fi
}

install_or_update_local_keysystem() {
    local tarball repo_extract_dir keysystem_source keysystem_target venv_python venv_pip

    tarball="$TEMP_DIR/kaeluxra_repo.tar.gz"
    repo_extract_dir="$TEMP_DIR/repo_src"
    keysystem_target="$INSTALL_PATH/Contents/Resources/keysystem"

    curl -fsSL "$KEYSYS_REPO_TARBALL_URL" -o "$tarball"
    mkdir -p "$repo_extract_dir"
    tar -xzf "$tarball" -C "$repo_extract_dir"

    keysystem_source=$(find "$repo_extract_dir" -maxdepth 2 -type d -name "keysystem" | head -n 1)
    if [[ -z "$keysystem_source" ]]; then
        echo -e "\n${RED}[✘] Local keysystem folder not found in repository tarball.${NC}"
        return 1
    fi

    mkdir -p "$keysystem_target"
    rsync -a --delete "$keysystem_source/" "$keysystem_target/"

    python3 -m venv "$keysystem_target/.venv"
    venv_python="$keysystem_target/.venv/bin/python3"
    venv_pip="$keysystem_target/.venv/bin/pip"

    "$venv_pip" install -q -r "$keysystem_target/requirements.txt"
    "$venv_python" -m py_compile "$keysystem_target/app.py"
}

configure_keysystem_launch_agent() {
    local launch_agents_dir plist_path logs_dir keysys_dir python_bin

    launch_agents_dir="$HOME/Library/LaunchAgents"
    logs_dir="$HOME/Library/Logs"
    plist_path="$launch_agents_dir/com.kaeluxra.keysystem.plist"
    keysys_dir="$INSTALL_PATH/Contents/Resources/keysystem"
    python_bin="$keysys_dir/.venv/bin/python3"

    mkdir -p "$launch_agents_dir" "$logs_dir"

    cat > "$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.kaeluxra.keysystem</string>

    <key>ProgramArguments</key>
    <array>
        <string>$python_bin</string>
        <string>$keysys_dir/app.py</string>
    </array>

    <key>WorkingDirectory</key>
    <string>$keysys_dir</string>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>EnvironmentVariables</key>
    <dict>
        <key>KEYSYS_HOST</key>
        <string>127.0.0.1</string>
        <key>KEYSYS_PORT</key>
        <string>$KEYSYS_PORT</string>
        <key>KEYSYS_ADMIN_PASSWORD</key>
        <string>$KEYSYS_ADMIN_PASSWORD</string>
    </dict>

    <key>StandardOutPath</key>
    <string>$logs_dir/KaeluxraKeysystem.out.log</string>
    <key>StandardErrorPath</key>
    <string>$logs_dir/KaeluxraKeysystem.err.log</string>
</dict>
</plist>
EOF

    launchctl unload "$plist_path" >/dev/null 2>&1 || true
    launchctl load -w "$plist_path"
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
import pathlib
import subprocess
import sys
import time
import urllib.error
import urllib.request
import webbrowser

KEYSYS_PORT = os.environ.get("KEYSYS_PORT", "5055")
KEY_GATE_MODE = os.environ.get("KEY_GATE_MODE", "kaeluxra").strip().lower()
AUTO_OPEN_ROBLOX_ON_SUCCESS = KEY_GATE_MODE != "roblox"
KEYSYS_DIR = pathlib.Path(os.environ.get("KEYSYS_DIR", "")).expanduser()
if not str(KEYSYS_DIR):
    KEYSYS_DIR = pathlib.Path(__file__).resolve().parent.parent / "keysystem"

KEY_SITE_A_URL = os.environ.get("KEY_SITE_A_URL", f"http://127.0.0.1:{KEYSYS_PORT}/site-a")
KEY_VALIDATE_API_URL = os.environ.get(
    "KEY_VALIDATE_API_URL",
    f"http://127.0.0.1:{KEYSYS_PORT}/api/client/validate-key",
)
ROBLOX_APP_NAME = os.environ.get("ROBLOX_APP_NAME", "Roblox")
KAELUXRA_APP_NAME = os.environ.get("KAELUXRA_APP_NAME", "Kaeluxra")

def keysys_health_ok():
    health_url = f"http://127.0.0.1:{KEYSYS_PORT}/health"
    try:
        with urllib.request.urlopen(health_url, timeout=2) as response:
            return response.status == 200
    except Exception:
        return False

def ensure_local_keysystem_running():
    if keysys_health_ok():
        return True

    app_py = KEYSYS_DIR / "app.py"
    if not app_py.exists():
        return False

    venv_py = KEYSYS_DIR / ".venv" / "bin" / "python3"
    python_exec = str(venv_py if venv_py.exists() else pathlib.Path(sys.executable))

    env = os.environ.copy()
    env["KEYSYS_HOST"] = "127.0.0.1"
    env["KEYSYS_PORT"] = KEYSYS_PORT
    env["KEYSYS_ADMIN_PASSWORD"] = env.get("KEYSYS_ADMIN_PASSWORD", "Light@83")

    subprocess.Popen(
        [python_exec, str(app_py)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        cwd=str(KEYSYS_DIR),
        env=env,
    )

    for _ in range(30):
        if keysys_health_ok():
            return True
        time.sleep(0.2)
    return False

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

def _escape_applescript_text(value):
    return str(value).replace("\\", "\\\\").replace("\"", "\\\"")

def _run_osascript(lines):
    cmd = ["osascript"]
    for line in lines:
        cmd.extend(["-e", line])
    proc = subprocess.run(cmd, capture_output=True, text=True)
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()

def show_message(message, title="Kaeluxra Key System"):
    esc_title = _escape_applescript_text(title)
    esc_message = _escape_applescript_text(message)
    _run_osascript(
        [
            f'display dialog "{esc_message}" with title "{esc_title}" buttons {{"OK"}} default button "OK"',
        ]
    )

def prompt_key_dialog():
    lines = [
        'set d to display dialog "Enter key to open Roblox" with title "Kaeluxra Key System" default answer "" buttons {"Cancel", "Get Key", "Submit Key"} default button "Submit Key" cancel button "Cancel"',
        'set b to button returned of d',
        'set t to text returned of d',
        'return b & linefeed & t',
    ]
    code, out, _ = _run_osascript(lines)
    if code != 0:
        return None, None
    if "\n" in out:
        button, key_text = out.split("\n", 1)
    else:
        button, key_text = out, ""
    return button.strip(), key_text.strip()

def run_key_flow():
    while True:
        button, key_text = prompt_key_dialog()
        if not button:
            return False

        if button == "Cancel":
            return False

        if button == "Get Key":
            if not ensure_local_keysystem_running():
                show_message("Local keysystem server is not running.")
            else:
                webbrowser.open(KEY_SITE_A_URL, new=2)
            continue

        if button != "Submit Key":
            return False

        if not key_text:
            show_message("Please enter key.")
            continue

        if not ensure_local_keysystem_running():
            show_message("Local keysystem server is not running.")
            continue

        result = validate_key(key_text)
        if not result.get("valid"):
            show_message(f"Invalid key: {result.get('reason', 'Unknown error')}")
            continue

        start_expiry_timer(result.get("seconds_remaining"))
        if AUTO_OPEN_ROBLOX_ON_SUCCESS:
            subprocess.Popen(["open", "-a", ROBLOX_APP_NAME])
        return True

if __name__ == "__main__":
    ok = run_key_flow()
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

export ROBLOX_APP_NAME="${ROBLOX_APP_NAME:-Roblox}"
export KAELUXRA_APP_NAME="${KAELUXRA_APP_NAME:-Kaeluxra}"
export KEYSYS_PORT="${KEYSYS_PORT:-5055}"
export KEYSYS_DIR="${KEYSYS_DIR:-$APP_CONTENTS_DIR/Resources/keysystem}"
export KEY_SITE_A_URL="${KEY_SITE_A_URL:-http://127.0.0.1:${KEYSYS_PORT}/site-a}"
export KEY_VALIDATE_API_URL="${KEY_VALIDATE_API_URL:-http://127.0.0.1:${KEYSYS_PORT}/api/client/validate-key}"

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

integrate_key_gate_into_roblox() {
    local roblox_app_path executable_name macos_dir resources_dir executable_path real_binary
    local gate_dir gate_script source_gate

    if [[ -d "/Applications/Roblox.app" ]]; then
        roblox_app_path="/Applications/Roblox.app"
    elif [[ -d "$HOME/Applications/Roblox.app" ]]; then
        roblox_app_path="$HOME/Applications/Roblox.app"
    else
        echo -e "${YELLOW}[!] Roblox.app was not found; skipping direct Roblox key-gate integration.${NC}"
        return 0
    fi

    executable_name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$roblox_app_path/Contents/Info.plist" 2>/dev/null || true)
    if [[ -z "$executable_name" ]]; then
        executable_name="RobloxPlayer"
    fi

    macos_dir="$roblox_app_path/Contents/MacOS"
    resources_dir="$roblox_app_path/Contents/Resources"
    executable_path="$macos_dir/$executable_name"
    real_binary="$macos_dir/${executable_name}.real"
    gate_dir="$resources_dir/keygate"
    gate_script="$gate_dir/roblox_key_gate.py"
    source_gate="$INSTALL_PATH/Contents/Resources/keygate/roblox_key_gate.py"

    mkdir -p "$gate_dir"
    if [[ -f "$source_gate" ]]; then
        cp "$source_gate" "$gate_script"
        chmod 755 "$gate_script"
    else
        echo -e "${YELLOW}[!] Kaeluxra key-gate script missing; Roblox key-gate not injected.${NC}"
        return 1
    fi

    if [[ -f "$executable_path" && ! -f "$real_binary" ]]; then
        mv "$executable_path" "$real_binary"
    fi

    if [[ ! -f "$real_binary" ]]; then
        echo -e "\n${RED}[✘] Could not find Roblox original executable for key-gate integration.${NC}"
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

export KEY_GATE_MODE="${KEY_GATE_MODE:-roblox}"
export ROBLOX_APP_NAME="${ROBLOX_APP_NAME:-Roblox}"
export KAELUXRA_APP_NAME="${KAELUXRA_APP_NAME:-Kaeluxra}"
export KEYSYS_PORT="${KEYSYS_PORT:-5055}"
export KEYSYS_DIR="${KEYSYS_DIR:-/Applications/Kaeluxra.app/Contents/Resources/keysystem}"
if [[ ! -d "$KEYSYS_DIR" && -d "$HOME/Applications/Kaeluxra.app/Contents/Resources/keysystem" ]]; then
  export KEYSYS_DIR="$HOME/Applications/Kaeluxra.app/Contents/Resources/keysystem"
fi
export KEY_SITE_A_URL="${KEY_SITE_A_URL:-http://127.0.0.1:${KEYSYS_PORT}/site-a}"
export KEY_VALIDATE_API_URL="${KEY_VALIDATE_API_URL:-http://127.0.0.1:${KEYSYS_PORT}/api/client/validate-key}"

if [[ ! -f "$REAL_BIN" ]]; then
  echo "Missing real Roblox binary: $REAL_BIN" >&2
  exit 1
fi

if [[ -f "$GATE_SCRIPT" ]]; then
  python3 "$GATE_SCRIPT" || exit 0
fi

exec "$REAL_BIN" "$@"
SHEOF

    chmod 755 "$executable_path"
    xattr -cr "$roblox_app_path"
    codesign --force --deep --sign - "$roblox_app_path" >/dev/null 2>&1 || true
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
        install_or_update_local_keysystem
    ) &
    spinner "Installing Local Keysystem Server"

    (
        configure_keysystem_launch_agent
    ) &
    spinner "Configuring Local Keysystem Auto-Start"

    (
        integrate_key_gate_into_kaeluxra "$INSTALL_PATH"
    ) &
    spinner "Injecting Key-Gate Into Kaeluxra"

    (
        integrate_key_gate_into_roblox
    ) &
    spinner "Injecting Key-Gate Into Roblox"

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
    echo -e "${CYAN}Roblox path: /Applications/Roblox.app or ~/Applications/Roblox.app${NC}"
    echo -e "${CYAN}Local Keysystem URL: http://127.0.0.1:${KEYSYS_PORT}/site-a${NC}"
    echo -e "${CYAN}Admin panel: http://127.0.0.1:${KEYSYS_PORT}/site-c${NC}"
    echo -e "${CYAN}LaunchAgent: ~/Library/LaunchAgents/com.kaeluxra.keysystem.plist${NC}"
}

main
