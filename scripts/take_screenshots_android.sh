#!/bin/bash
# Play Store screenshot automation for Tibane.
# Boots an Android emulator, runs lib/screenshot_main.dart, and captures
# each screen by tailing the flutter logs for "SCREENSHOT_SIGNAL: Screen N
# ready" — the same coordination iOS uses, just over logcat instead of
# /tmp signal files.
#
# Usage:
#   ./scripts/take_screenshots_android.sh                                # Pixel 7 Pro phone
#   ./scripts/take_screenshots_android.sh Pixel_7_Pro_API_35
#   ./scripts/take_screenshots_android.sh Tablet_10in_API_33 tenInch     # tablet

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DEFAULT_EMU="Pixel_7_Pro_API_35"
EMU="${1:-$DEFAULT_EMU}"
KIND="${2:-phone}"
case "$KIND" in
    phone)   SUBDIR="phoneScreenshots" ;;
    tenInch) SUBDIR="tenInchScreenshots" ;;
    *) echo "Unknown kind: $KIND (use phone or tenInch)"; exit 1 ;;
esac
SCREENSHOTS_DIR="$PROJECT_DIR/android/fastlane/metadata/android/en-US/images/$SUBDIR"
LOG_FILE="$(mktemp -t tibane_screenshots).log"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}=== Tibane Play Store Screenshots ===${NC}"
echo -e "${BLUE}Emulator:${NC} $EMU  ${BLUE}Kind:${NC} $KIND"
echo -e "${BLUE}Log:${NC} $LOG_FILE"

# Kill any stale flutter run / dart processes left over from earlier runs.
# Without this, a stale device-side app instance keeps emitting SCREENSHOT_SIGNAL
# lines that contaminate the new log file via logcat.
pkill -f "flutter run --target=lib/screenshot_main.dart" 2>/dev/null || true
pkill -f "dart.*screenshot_main" 2>/dev/null || true

mkdir -p "$SCREENSHOTS_DIR"
cd "$PROJECT_DIR"

# Boot emulator if not already running
if ! adb devices | grep -q "emulator-.*device$"; then
    echo -e "${YELLOW}Booting $EMU...${NC}"
    flutter emulators --launch "$EMU" >/dev/null 2>&1 &
    for i in $(seq 1 90); do
        if adb devices | grep -q "emulator-.*device$"; then break; fi
        sleep 2
    done
fi

DEVICE_ID=$(adb devices | grep "emulator-" | grep "device$" | head -1 | awk '{print $1}')
if [ -z "$DEVICE_ID" ]; then
    echo "Error: no Android emulator detected after boot"
    exit 1
fi
echo "Device: $DEVICE_ID"

adb -s "$DEVICE_ID" wait-for-device
for i in $(seq 1 60); do
    BOOTED=$(adb -s "$DEVICE_ID" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || echo "")
    if [ "$BOOTED" = "1" ]; then break; fi
    sleep 1
done

# Force portrait (the Tibane app is portrait-locked anyway).
adb -s "$DEVICE_ID" shell settings put system accelerometer_rotation 0 || true
adb -s "$DEVICE_ID" shell settings put system user_rotation 0 || true

# Disable framework letterbox UI shown for portrait-locked apps on landscape
# tablets: the "See and do more" education modal and the bottom-right
# "Change this app's aspect ratio in Settings" hint bubble. They sit above
# the app where uiautomator can't see them and input taps don't reach.
adb -s "$DEVICE_ID" shell cmd window set-letterbox-style --isEducationEnabled false || true
adb -s "$DEVICE_ID" shell cmd window set-letterbox-style --isUserAppAspectRatioSettingsEnabled false || true

# Force-stop any prior app instance on the device and clear logcat so the
# new flutter run doesn't pick up stale "Screen N ready" lines from a
# previous session's process.
adb -s "$DEVICE_ID" shell am force-stop net.tibane.tibaneapp || true
adb -s "$DEVICE_ID" logcat -c || true

echo -e "${YELLOW}Building and launching screenshot app...${NC}"
flutter run --target=lib/screenshot_main.dart -d "$DEVICE_ID" --no-hot >"$LOG_FILE" 2>&1 &
FLUTTER_PID=$!

# Wait until we see the screen-N-ready signal in the log, then grab a frame.
wait_and_capture() {
    local n=$1
    local out=$2
    echo -e "${YELLOW}Waiting for screen $n signal...${NC}"
    for i in $(seq 1 1500); do  # 150 seconds timeout (covers slow first builds)
        if grep -q "SCREENSHOT_SIGNAL: Screen $n ready" "$LOG_FILE"; then
            sleep 1.0  # let the frame fully render
            adb -s "$DEVICE_ID" exec-out screencap -p > "$out"
            echo -e "${GREEN}Saved:${NC} $out"
            return 0
        fi
        sleep 0.1
    done
    echo "Timeout waiting for screen $n"
    return 1
}

wait_and_capture 1 "$SCREENSHOTS_DIR/1_home.png"
wait_and_capture 2 "$SCREENSHOTS_DIR/2_wallet.png"
wait_and_capture 3 "$SCREENSHOTS_DIR/3_staking_pools.png"
wait_and_capture 4 "$SCREENSHOTS_DIR/4_staking_detail.png"
wait_and_capture 5 "$SCREENSHOTS_DIR/5_incinerator.png"
wait_and_capture 6 "$SCREENSHOTS_DIR/6_token_info.png"

kill "$FLUTTER_PID" 2>/dev/null || true
pkill -f "flutter run" 2>/dev/null || true

echo -e "${GREEN}=== Done ===${NC}"
ls -la "$SCREENSHOTS_DIR"/*.png
