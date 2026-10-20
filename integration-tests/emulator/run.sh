#!/usr/bin/env bash
# Drives the release APK on an Android emulator through every CrossDrop screen
# and collects screenshots, screen recordings (with contact sheets), frame
# timing (dumpsys gfxinfo) and logcat. CI only; see .github/workflows/build.yml.
#
#   run.sh <CrossDrop.apk> <crossdrop-cli> <out-dir>
#
# A Kotlin crossdrop-cli on the host plays the Mac: it reaches the app through
# `adb forward`, so the real pairing, incoming, transfer, done and failure
# screens appear. Each step is logged to steps.log as OK or FAIL; one failing
# step doesn't stop the rest.
set -u

APK=$1
CLI=$2
OUT=$3
PKG=com.crossdrop.app
ACTIVITY=com.crossdrop.MainActivity
HERE=$(cd "$(dirname "$0")" && pwd)
UI="python3 $HERE/ui.py"
mkdir -p "$OUT/shots" "$OUT/video" "$OUT/frames"
LOG="$OUT/steps.log"
: > "$LOG"

# Stop early (keeping what was collected) if the emulator goes away, rather
# than hanging on adb.
alive() {
  if [ "$(timeout 10 adb get-state 2>/dev/null)" != "device" ]; then
    echo "FAIL emulator is gone (crashed or disconnected)" | tee -a "$LOG"
    finish
  fi
}
finish() {
  [ -n "${LOGCAT_PID:-}" ] && kill "$LOGCAT_PID" 2>/dev/null
  grep -E "FATAL EXCEPTION|ReactNativeJS|E ReactNative|F libc|F DEBUG|SIGSEGV|SIGABRT" "$OUT/logcat.txt" > "$OUT/logcat-problems.txt" 2>/dev/null || true
  echo "logcat problems: $(wc -l < "$OUT/logcat-problems.txt")" | tee -a "$LOG"
  grep -c '^FAIL' "$LOG" | sed 's/^/failed steps: /' | tee -a "$LOG"
  exit 0
}
step() { alive; echo "== $*" | tee -a "$LOG"; }
ok() { echo "OK   $*" | tee -a "$LOG"; }
fail() { echo "FAIL $*" | tee -a "$LOG"; }
check() { local what=$1; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else fail "$what"; fi; }

shot() { adb exec-out screencap -p > "$OUT/shots/$1.png" && ok "screenshot $1"; }

REC_PID=""
REC_NAME=""
rec_start() {
  REC_NAME=$1
  adb shell screenrecord --time-limit "$2" --bit-rate 8000000 "/sdcard/$1.mp4" &
  REC_PID=$!
  sleep 0.5
}
rec_end() {
  wait "$REC_PID" 2>/dev/null
  sleep 1
  adb pull "/sdcard/$REC_NAME.mp4" "$OUT/video/$REC_NAME.mp4" >/dev/null 2>&1 || { fail "video $REC_NAME"; return; }
  adb shell rm -f "/sdcard/$REC_NAME.mp4"
  # Contact sheet: 6 frames a second, 6 per row, so motion can be checked frame by frame.
  ffmpeg -loglevel error -y -i "$OUT/video/$REC_NAME.mp4" \
    -vf "fps=6,scale=240:-1,tile=6x4:padding=4:color=white" -frames:v 1 "$OUT/video/$REC_NAME-sheet.png" \
    && ok "video $REC_NAME" || fail "contact sheet $REC_NAME"
}

frames_reset() { adb shell dumpsys gfxinfo "$PKG" reset >/dev/null; }
frames_save() {
  adb shell dumpsys gfxinfo "$PKG" \
    | sed -n '/Total frames rendered/,/Number Frame deadline missed/p' > "$OUT/frames/$1.txt"
  ok "frame stats $1: $(grep -E 'Janky frames:' "$OUT/frames/$1.txt" | head -1 | sed 's/^ *//')"
}

tap_xy() { adb shell input tap "$1" "$2"; }

# The engine logs its (random) listening port: "Receiving on port N".
listen_port() {
  adb logcat -d -s CrossDrop:I | grep -o 'Receiving on port [0-9]*' | tail -1 | awk '{print $4}'
}

# ------------------------------------------------------------------ setup
step "device"
adb shell getprop ro.build.version.release | sed 's/^/android /' | tee -a "$LOG"
adb shell wm size | tee -a "$LOG"
adb shell wm density | tee -a "$LOG"
for key in animator_duration_scale transition_animation_scale window_animation_scale; do
  adb shell settings put global "$key" 1
done
adb shell settings put system font_scale 1.0
adb logcat -c
# Streamed to disk from the start, so the last lines before any crash are kept.
adb logcat -v threadtime > "$OUT/logcat.txt" 2>/dev/null &
LOGCAT_PID=$!

step "install"
check "install apk" adb install -r "$APK"
adb shell am start -W -n "$PKG/$ACTIVITY" >/dev/null
sleep 6
alive
shot 00-launch

# ------------------------------------------------------------------ welcome
step "welcome"
$UI wait "Get started" 40 >/dev/null && ok "welcome visible" || fail "welcome visible"
shot 01-welcome
rec_start 01-welcome 6; rec_end
$UI tap "Get started" >/dev/null && ok "get started" || fail "get started"
sleep 2.5

# ------------------------------------------------------------------ home
step "home (receiving off: napping)"
shot 02-home-napping
frames_reset
rec_start 02-home-napping 6; rec_end
frames_save 02-home-idle
# Same screen with motion paused (system animation scale 0 reads as Reduce Motion),
# to separate the cost of the animations from the emulator's baseline.
for key in animator_duration_scale transition_animation_scale window_animation_scale; do adb shell settings put global "$key" 0; done
sleep 2; frames_reset; sleep 6; frames_save 02-home-still
for key in animator_duration_scale transition_animation_scale window_animation_scale; do adb shell settings put global "$key" 1; done
sleep 2

step "turn on receiving"
$UI tap "Turn on Receiving" >/dev/null && ok "turn on receiving" || fail "turn on receiving"
sleep 2.5
shot 03-notification-explainer
$UI tap "Continue" 8 >/dev/null && ok "continue" || fail "continue (explainer)"
sleep 2
shot 04-permission-dialog
$UI tap "Allow" 8 >/dev/null && ok "allow notifications" || fail "allow notifications"
sleep 3
shot 05-home-searching
rec_start 05-home-searching 6; rec_end

# ------------------------------------------------------------------ tabs
step "tabs"
declare -A TAB
for t in Nearby Activity Devices Settings; do
  xy=$($UI find "$t") && TAB[$t]=$xy || fail "find tab $t"
done
frames_reset
rec_start 06-tab-switching 12
for t in Activity Devices Settings Nearby; do
  # shellcheck disable=SC2086
  [ -n "${TAB[$t]:-}" ] && tap_xy ${TAB[$t]}
  sleep 2.5
done
rec_end
frames_save 06-tab-switching
for t in Activity Devices Settings; do
  # shellcheck disable=SC2086
  [ -n "${TAB[$t]:-}" ] && tap_xy ${TAB[$t]}
  sleep 2
  shot "07-$(echo "$t" | tr 'A-Z' 'a-z')"
done
adb shell input swipe 540 1800 540 500 400
sleep 1.5
shot 07-settings-bottom
# shellcheck disable=SC2086
[ -n "${TAB[Nearby]:-}" ] && tap_xy ${TAB[Nearby]}
sleep 2

# ------------------------------------------------------------------ large text
step "large text (font scale 1.3)"
adb shell settings put system font_scale 1.3
sleep 3
shot 08-home-large-text
# shellcheck disable=SC2086
[ -n "${TAB[Settings]:-}" ] && tap_xy ${TAB[Settings]}
sleep 2
shot 08-settings-large-text
adb shell settings put system font_scale 1.0
sleep 2
# shellcheck disable=SC2086
[ -n "${TAB[Nearby]:-}" ] && tap_xy ${TAB[Nearby]}
sleep 2

# ------------------------------------------------------------------ no wi-fi
step "no wi-fi"
adb shell svc wifi disable
adb shell svc data disable
sleep 5
shot 09-no-wifi
rec_start 09-no-wifi 5; rec_end
adb shell svc wifi enable
adb shell svc data enable
sleep 8
shot 09-wifi-back

# ------------------------------------------------------------------ share sheet
step "share sheet"
python3 - "$OUT/Holiday.png" <<'EOF'
import sys
from PIL import Image
Image.new("RGB", (800, 600), (120, 200, 160)).save(sys.argv[1])
EOF
adb push "$OUT/Holiday.png" /sdcard/Download/Holiday.png >/dev/null
adb shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///sdcard/Download/Holiday.png >/dev/null
sleep 3
MEDIA_ID=$(adb shell content query --uri content://media/external/images/media --projection _id:_display_name \
  | grep 'Holiday.png' | head -1 | sed -E 's/.*_id=([0-9]+).*/\1/')
if [ -n "$MEDIA_ID" ]; then
  adb shell am start -a android.intent.action.SEND -t image/png \
    --eu android.intent.extra.STREAM "content://media/external/images/media/$MEDIA_ID" \
    --grant-read-uri-permission -n "$PKG/$ACTIVITY" >/dev/null
  sleep 4
  shot 10-share
  $UI tap "Cancel sharing" 8 >/dev/null && ok "cancel sharing" || fail "cancel sharing"
  sleep 2
else
  fail "media id for share test"
fi

# ------------------------------------------------------------------ incoming from a "Mac"
step "incoming transfer from the CLI"
PORT=$(listen_port)
echo "app listening on ${PORT:-?}" | tee -a "$LOG"
if [ -n "$PORT" ]; then
  adb forward tcp:47123 "tcp:$PORT" >/dev/null
  WORK=$(mktemp -d)
  head -c 160000000 /dev/urandom > "$WORK/Holiday-Video.mp4"
  head -c 3200000 /dev/urandom > "$WORK/IMG_2041.HEIC"

  rec_start 11-pairing 10
  "$CLI" send --host 127.0.0.1 --port 47123 --identity "$WORK/id" --name "Daksh’s MacBook Pro" --platform macos \
    "$WORK/Holiday-Video.mp4" "$WORK/IMG_2041.HEIC" > "$OUT/cli-send-1.log" 2>&1 &
  CLI_PID=$!
  sleep 5
  shot 11-pairing
  rec_end
  $UI tap "Codes match" 20 >/dev/null && ok "codes match" || fail "codes match"
  $UI wait "Files are on their way" 30 >/dev/null && ok "incoming offer" || fail "incoming offer"
  sleep 1.5
  shot 12-incoming
  xy=$($UI find "Accept") || fail "find accept"
  frames_reset
  rec_start 13-receiving 20
  # shellcheck disable=SC2086
  [ -n "${xy:-}" ] && tap_xy $xy
  sleep 3
  shot 13-receiving
  sleep 4
  shot 13-receiving-later
  rec_end
  frames_save 13-receiving
  $UI wait "All done!" 120 >/dev/null && ok "done screen" || fail "done screen"
  shot 14-done
  rec_start 14-done 5; rec_end
  timeout 60 tail --pid="$CLI_PID" -f /dev/null; echo "cli finished" | tee -a "$LOG"
  $UI tap "Done" 10 >/dev/null || $UI tap "Not now" 5 >/dev/null
  sleep 2

  step "failed transfer (sender goes away)"
  "$CLI" send --host 127.0.0.1 --port 47123 --identity "$WORK/id" --name "Daksh’s MacBook Pro" --platform macos \
    "$WORK/Holiday-Video.mp4" > "$OUT/cli-send-2.log" 2>&1 &
  CLI_PID=$!
  $UI tap "Accept" 30 >/dev/null && ok "accept second" || fail "accept second"
  sleep 2
  kill "$CLI_PID" 2>/dev/null
  $UI wait "That didn’t go through" 40 >/dev/null && ok "failed screen" || fail "failed screen"
  shot 15-failed
  rec_start 15-failed 4; rec_end
  $UI tap "Not now" 10 >/dev/null
  sleep 2
  # shellcheck disable=SC2086
  [ -n "${TAB[Activity]:-}" ] && tap_xy ${TAB[Activity]}
  sleep 2
  shot 16-activity-after
else
  fail "find listening port"
fi

# ------------------------------------------------------------------ logs
step "logs"
sleep 2
finish
