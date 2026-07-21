#!/usr/bin/env bash
# Verify a published feed is live on the hub: pull it back over RTSP and report
# codec / resolution / frame rate. Run from the camera Pi or any machine with
# ffprobe that can reach the hub.
#
# Usage:  ./bin/test-publish.sh [CAM_PATH] [HUB_HOST]
# Args are optional — if omitted, they are read from a single installed
# /etc/default/cam-stream-* env file.
set -uo pipefail

CAM_PATH="${1:-${CAM_PATH:-}}"
HUB_HOST="${2:-${HUB_HOST:-}}"
HUB_RTSP_PORT="${HUB_RTSP_PORT:-8554}"

# Fall back to a single installed env file if not given on the command line.
if [ -z "$CAM_PATH" ] || [ -z "$HUB_HOST" ]; then
  shopt -s nullglob
  envs=(/etc/default/cam-stream-*)
  [ "${#envs[@]}" -eq 1 ] && . "${envs[0]}"
fi
: "${CAM_PATH:?need CAM_PATH (arg 1, or a single installed env file)}"
: "${HUB_HOST:?need HUB_HOST (arg 2, or a single installed env file)}"

url="rtsp://${HUB_HOST}:${HUB_RTSP_PORT}/${CAM_PATH}"
echo "Pulling $url ..."

if ! command -v ffprobe >/dev/null 2>&1; then
  echo "ffprobe not found (install ffmpeg). Try the URL in VLC/OBS instead:"
  echo "  $url"
  exit 0
fi

if timeout 25 ffprobe -v error -rtsp_transport tcp \
     -show_entries stream=codec_name,codec_type,width,height,avg_frame_rate \
     -of default=noprint_wrappers=1 "$url"; then
  echo "OK: '$CAM_PATH' is live on the hub."
else
  echo "FAILED: no stream on $url"
  echo "  - Is the encoder running?   systemctl status cam-stream@${CAM_PATH}"
  echo "  - Recent encoder logs:      journalctl -u cam-stream@${CAM_PATH} -e --no-pager"
  echo "  - Can this host reach the hub SRT port?  nc -zvu ${HUB_HOST} 8890"
  exit 1
fi
