#!/usr/bin/env bash
# Probe attached USB cameras + this host's encode capability, to guide config.
# Read-only; safe to run any time. Run on the camera Pi:  ./bin/probe-camera.sh
set -uo pipefail

have() { command -v "$1" >/dev/null 2>&1; }

echo "== Platform =="
if [ -r /proc/device-tree/model ]; then tr -d '\0' </proc/device-tree/model; echo; fi
if [ -e /dev/video11 ]; then
  echo "Hardware H.264 encoder: PRESENT (/dev/video11) -> CAM_ENCODER=h264_v4l2m2m"
else
  echo "Hardware H.264 encoder: absent -> CAM_ENCODER=libx264 (software; watch CPU at 1080p)"
fi
echo

if ! have v4l2-ctl; then
  echo "v4l2-ctl not found. Install with:  sudo apt install -y v4l-utils"
  exit 0
fi

echo "== Capture devices (by USB port; stable across reboots) =="
shopt -s nullglob
found=0
for dev in /dev/v4l/by-path/*-video-index0; do
  found=1
  real="$(readlink -f "$dev")"
  card="$(v4l2-ctl -d "$real" --info 2>/dev/null | awk -F': ' '/Card type/{print $2; exit}')"
  echo
  echo "-- $dev"
  echo "   -> $real   ${card:+($card)}"
  v4l2-ctl -d "$real" --list-formats-ext 2>/dev/null \
    | grep -E "\[[0-9]+\]:|Size: Discrete" | sed 's/^/   /'
done
[ "$found" -eq 0 ] && echo "(no /dev/v4l/by-path/*-video-index0 capture devices found)"

echo
echo "Reading the formats:"
echo " - YUYV / YUV422 = uncompressed: heavy on USB2, so 720p often caps ~10 fps and"
echo "   two 720p cams can't share one Pi's USB2 bus.  ->  CAM_INPUT_FORMAT=yuyv422"
echo " - MJPG / Motion-JPEG: compressed, more fps + USB headroom.  ->  CAM_INPUT_FORMAT=mjpeg"
echo " - H264 listed: camera encodes on-board (cheapest).  ->  CAM_INPUT_FORMAT=h264 + CAM_ENCODER=copy"
