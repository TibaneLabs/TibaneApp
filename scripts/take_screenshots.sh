#!/bin/bash
# App Store screenshot automation for Tibane.
# Drives lib/screenshot_main.dart on an iOS Simulator and captures each
# screen via xcrun simctl + signal files.
#
# Usage:
#   ./scripts/take_screenshots.sh                                         # iPhone 16 Pro Max default
#   ./scripts/take_screenshots.sh "iPhone 16 Pro Max"
#   ./scripts/take_screenshots.sh "iPad Pro 13-inch (M4)"
#   ./scripts/take_screenshots.sh <UDID> ipad                             # explicit prefix when device is a UDID
#   ./scripts/take_screenshots.sh <UDID> iphone

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DEFAULT_DEVICE="iPhone 16 Pro Max"
DEVICE="${1:-$DEFAULT_DEVICE}"
PREFIX_OVERRIDE="${2:-}"   # optional: "ipad" or "iphone"
SCREENSHOTS_DIR="$PROJECT_DIR/fastlane/screenshots/en-US"
SIGNAL_DIR="/tmp/screenshot_signals"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}=== Tibane App Store Screenshots ===${NC}"
echo -e "${BLUE}Device:${NC} $DEVICE"

mkdir -p "$SCREENSHOTS_DIR"
rm -rf "$SIGNAL_DIR"

UDID=$(xcrun simctl list devices available | grep "$DEVICE" | head -1 | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}')

if [ -z "$UDID" ]; then
    echo "Error: simulator '$DEVICE' not found"
    exit 1
fi

echo "Simulator UDID: $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
open -a Simulator --args -CurrentDeviceUDID "$UDID"
sleep 2

cd "$PROJECT_DIR"

if [ -n "$PREFIX_OVERRIDE" ]; then
    PREFIX="${PREFIX_OVERRIDE}_"
elif [[ "$DEVICE" == *"iPad"* ]]; then
    PREFIX="ipad_"
else
    # Probe the device type via simctl when a UDID was passed.
    DEVICE_NAME=$(xcrun simctl list devices | grep -i "$UDID" | head -1)
    if [[ "$DEVICE_NAME" == *"iPad"* ]]; then
        PREFIX="ipad_"
    else
        PREFIX="iphone_"
    fi
fi

wait_and_capture() {
    local n=$1
    local out=$2
    local sig="$SIGNAL_DIR/ready_$n"
    echo -e "${YELLOW}Waiting for screen $n...${NC}"
    for i in $(seq 1 600); do
        if [ -f "$sig" ]; then
            sleep 0.4
            xcrun simctl io "$UDID" screenshot "$out"
            rm -f "$sig"
            echo -e "${GREEN}Saved:${NC} $out"
            return 0
        fi
        sleep 0.1
    done
    echo "Timeout waiting for screen $n"
    return 1
}

echo -e "${YELLOW}Building and launching screenshot app...${NC}"
flutter run --target=lib/screenshot_main.dart -d "$UDID" --no-hot 2>&1 &
FLUTTER_PID=$!

wait_and_capture 1 "$SCREENSHOTS_DIR/${PREFIX}01_home.png"
wait_and_capture 2 "$SCREENSHOTS_DIR/${PREFIX}02_wallet.png"
wait_and_capture 3 "$SCREENSHOTS_DIR/${PREFIX}03_staking_pools.png"
wait_and_capture 4 "$SCREENSHOTS_DIR/${PREFIX}04_staking_detail.png"
wait_and_capture 5 "$SCREENSHOTS_DIR/${PREFIX}05_incinerator.png"
wait_and_capture 6 "$SCREENSHOTS_DIR/${PREFIX}06_token_info.png"

kill "$FLUTTER_PID" 2>/dev/null || true
pkill -f "flutter run" 2>/dev/null || true
rm -rf "$SIGNAL_DIR"

echo -e "${GREEN}=== Done ===${NC}"
ls -la "$SCREENSHOTS_DIR"/${PREFIX}*.png
