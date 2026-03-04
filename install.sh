#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

APP_LABEL="Kaeluxra"
APP_ZIP_URL="https://raw.githubusercontent.com/tp-handler/luna/main/Kaeluxra.zip"

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
}

main
