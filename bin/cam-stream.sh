#!/usr/bin/env bash
# hillclimb-cam edge encoder: capture a USB webcam, encode H.264, and
# SRT-publish to a MediaMTX hub. All configuration comes from the systemd
# EnvironmentFile (/etc/default/cam-stream-<instance>); see README.md.
#
# Generalized from the van's gps-dashboard tools/picam encoder to run on any
# Pi + UVC camera: it picks the encoder from the input format and the host's
# hardware (H.264-native cam -> passthrough; Pi with a HW encoder -> v4l2m2m;
# otherwise software libx264).
set -euo pipefail

: "${CAM_DEVICE:?CAM_DEVICE required}" "${CAM_PATH:?CAM_PATH required}" "${HUB_HOST:?HUB_HOST required}"

CAM_INPUT_FORMAT="${CAM_INPUT_FORMAT:-yuyv422}"   # camera pixel format: yuyv422 | mjpeg | h264
CAM_ENCODER="${CAM_ENCODER:-auto}"                # auto | h264_v4l2m2m | libx264 | copy
CAM_W="${CAM_W:-1280}"
CAM_H="${CAM_H:-720}"
CAM_FPS="${CAM_FPS:-10}"
CAM_BITRATE="${CAM_BITRATE:-2500k}"
HUB_PORT="${HUB_PORT:-8890}"                      # MediaMTX SRT ingest port
HUB_RTSP_PORT="${HUB_RTSP_PORT:-8554}"            # MediaMTX RTSP port (used as a liveness proxy)
SRT_LATENCY="${SRT_LATENCY:-200}"                 # SRT receiver buffer, ms — loss tolerance vs. delay
HUB_WAIT="${HUB_WAIT:-30}"                         # cold-boot: wait up to this long for the hub

# Machine-readable progress for the frame-flow watchdog (cam-watchdog@%i). Under
# systemd RUNTIME_DIRECTORY=/run/cam-stream (tmpfs); /tmp when run by hand.
PROGRESS="${RUNTIME_DIRECTORY:-/tmp}/${CAM_PATH}.progress"

log() { echo "cam-stream[${CAM_PATH}]: $*"; }

# Resolve encoder=auto against the input format and the host's capability.
resolve_encoder() {
  case "$CAM_INPUT_FORMAT" in
    h264) echo copy ;;                              # camera already emits H.264 -> passthrough (cheapest)
    *) if [ -e /dev/video11 ]; then echo h264_v4l2m2m; else echo libx264; fi ;;
  esac
}
[ "$CAM_ENCODER" = auto ] && CAM_ENCODER="$(resolve_encoder)"

# Cold-boot readiness gate. The startup SRT connect can lose a handshake race if
# it fires before the network/hub are up, hard-failing ffmpeg (Restart=always
# recovers, but a live viewer sees the gap). Wait for the hub's RTSP TCP port as
# a liveness proxy first. Never fatal — fall through after HUB_WAIT and let
# ffmpeg + Restart=always take over.
wait_for_hub() {
  local deadline=$(( SECONDS + HUB_WAIT ))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if (exec 3<>"/dev/tcp/${HUB_HOST}/${HUB_RTSP_PORT}") 2>/dev/null; then
      log "hub ${HUB_HOST}:${HUB_RTSP_PORT} reachable"
      return 0
    fi
    sleep 1
  done
  log "hub ${HUB_HOST}:${HUB_RTSP_PORT} not reachable after ${HUB_WAIT}s; starting anyway"
}
wait_for_hub

# Build the ffmpeg pipeline.
in_args=(-f v4l2 -input_format "$CAM_INPUT_FORMAT"
         -video_size "${CAM_W}x${CAM_H}" -framerate "$CAM_FPS" -i "$CAM_DEVICE")

case "$CAM_ENCODER" in
  copy)
    enc_args=(-c:v copy) ;;
  h264_v4l2m2m)
    enc_args=(-c:v h264_v4l2m2m -b:v "$CAM_BITRATE" -g "$((CAM_FPS * 2))") ;;
  libx264)
    enc_args=(-c:v libx264 -preset veryfast -tune zerolatency
              -b:v "$CAM_BITRATE" -maxrate "$CAM_BITRATE" -bufsize "$CAM_BITRATE"
              -g "$((CAM_FPS * 2))" -pix_fmt yuv420p) ;;
  *)
    log "unknown CAM_ENCODER='$CAM_ENCODER'"; exit 64 ;;
esac

srt_url="srt://${HUB_HOST}:${HUB_PORT}?streamid=publish:${CAM_PATH}&pkt_size=1316&latency=${SRT_LATENCY}"
log "device=$CAM_DEVICE in=$CAM_INPUT_FORMAT enc=$CAM_ENCODER ${CAM_W}x${CAM_H}@${CAM_FPS} -> $srt_url"

exec ffmpeg -hide_banner -loglevel warning -nostdin \
  -progress "file:${PROGRESS}" -stats_period 2 \
  "${in_args[@]}" \
  "${enc_args[@]}" \
  -f mpegts "$srt_url"
