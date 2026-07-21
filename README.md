# hillclimb-cam

Turn a Raspberry Pi + USB webcam into a **live camera node** that publishes over
**SRT** to a MediaMTX hub. Built for the annual Vermont hill-climb live stream:
several camera Pis sit at course positions and stream back to the van, where
MediaMTX aggregates every feed and OBS mixes them out to YouTube.

If you're a friend setting up your own Pi to join the stream, this is everything
you need — clone it, run one installer, done.

```
 your Pi + USB cam                          the van
┌───────────────────┐                 ┌──────────────────────────┐
│ ffmpeg            │   SRT :8890     │ MediaMTX hub (pmpi1)      │   RTSP/WebRTC
│ capture → H.264 ──┼───────────────► │ path: cam2               ├──────────────► OBS → YouTube
│ (cam-stream.sh)   │  publish:cam2   │ (radio + all cam feeds)  │
└───────────────────┘                 └──────────────────────────┘
```

Each node encodes locally and pushes one H.264 feed (~2–3 Mbps at 720p) to a
MediaMTX **path** (`cam2`, `cam3`, …). SRT gives you retransmit (ARQ) and a
tunable latency buffer, so a lossy wireless link degrades gracefully instead of
stalling.

## What you need

- A **Raspberry Pi** (Pi 4 preferred — it has a hardware H.264 encoder; Pi 5
  works but encodes in software) running Raspberry Pi OS / Debian.
- A **USB webcam** (UVC). Any works; see [Cameras](#cameras-what-to-expect).
- **Network reachability to the hub's SRT port** (`HUB_HOST:8890`). At the event
  that means being on the van LAN (via the 5 GHz point-to-point link, a switch
  port, or the van WiFi). Confirm with `nc -zvu <hub-ip> 8890`.
- The **hub IP** and a **free path name** (`cam2`/`cam3`/`cam4` — `cam1` is the
  van's own `picam1`). Ask whoever runs the hub which path to use.

`ffmpeg` and `v4l-utils` are installed for you by the installer if missing.

## Quick start

On the Pi:

```bash
git clone https://github.com/pmormr/hillclimb-cam.git
cd hillclimb-cam
sudo ./install.sh
```

The installer probes your camera, asks a handful of questions (path name, hub IP,
resolution/fps/bitrate — all with sensible defaults), writes the config, installs
two systemd services, and starts streaming. Then verify the feed reached the hub:

```bash
./bin/test-publish.sh cam2 <hub-ip>
# -> codec_name=h264, width=1280, height=720, avg_frame_rate=10/1  => OK
```

You can also open `rtsp://<hub-ip>:8554/cam2` in VLC or OBS.

## Cameras: what to expect

Run `./bin/probe-camera.sh` to see your camera's formats and this Pi's encoder.
The camera's **pixel format** drives the config:

| Camera outputs | Set `CAM_INPUT_FORMAT` | Notes |
|---|---|---|
| **YUYV / YUV422** (uncompressed — most cheap webcams) | `yuyv422` | Heavy on USB 2.0. 720p often caps at **10 fps**, and **two 720p cams can't share one Pi's USB2 bus** — one camera per Pi. |
| **MJPEG** | `mjpeg` | Compressed → higher fps and USB headroom. |
| **H.264** (some higher-end UVC cams) | `h264` + `CAM_ENCODER=copy` | Cheapest — the Pi just repackages, no transcode. |

**Encoder** (`CAM_ENCODER=auto` picks this for you):

- **Pi 4** → `h264_v4l2m2m` (hardware encode, near-zero CPU).
- **Pi 5** → `libx264` (software; fine at 720p, watch CPU at 1080p — the Pi 5 has
  no hardware H.264 encoder).
- **H.264 camera** → `copy` (passthrough).

## Configuration

Each camera is one env file at `/etc/default/cam-stream-<path>`. The installer
writes it; edit and `sudo systemctl restart cam-stream@<path>` to change. Every
knob is documented in [`examples/cam-stream.env.example`](examples/cam-stream.env.example).
The load-bearing ones: `CAM_DEVICE`, `CAM_PATH`, `HUB_HOST`, `CAM_INPUT_FORMAT`,
`CAM_ENCODER`, `CAM_W`/`CAM_H`/`CAM_FPS`/`CAM_BITRATE`, and `SRT_LATENCY`
(receiver buffer in ms — raise it on a flaky link).

`CAM_DEVICE` is pinned to a stable **USB-port path** (`/dev/v4l/by-path/…`) so it
survives `/dev/videoN` renumbering across reboots.

## Reliability

Two systemd services per camera, both installed for you:

- **`cam-stream@<path>`** — the encoder. `Restart=always`, so it re-establishes
  automatically after a network/SRT drop or a hub restart. On a cold boot it
  waits (up to `HUB_WAIT` s) for the hub to be reachable before the first connect,
  avoiding the startup handshake race that otherwise costs a brief no-stream gap.
- **`cam-watchdog@<path>`** — recovers a *wedged* encoder. It tracks ffmpeg's
  frame progress; a stall with a stable PID triggers a **restart**, or a
  **reboot** (rate-limited so it can never boot-loop) only for the unkillable
  `D`-state device wedge a restart can't clear. A flapping PID (an ordinary
  network drop, already handled by `Restart=always`) is ignored — an uplink
  outage never triggers a reboot.

The installer also offers to enable **persistent journald** so a reboot leaves a
log trail (Pis default to volatile logs that vanish on reboot).

Handy commands:

```bash
systemctl status cam-stream@cam2
journalctl -u cam-stream@cam2 -f            # live encoder log
journalctl -u cam-watchdog@cam2 -e          # watchdog decisions
cat /run/cam-stream/cam2.progress           # live ffmpeg frame/fps/drops
```

## Troubleshooting

- **`test-publish.sh` says no stream.** Check the encoder is up
  (`systemctl status cam-stream@<path>`) and that this Pi can reach the hub SRT
  port (`nc -zvu <hub-ip> 8890`). Read the encoder log
  (`journalctl -u cam-stream@<path> -e`).
- **SRT `CONFUSED: expected UMSG_HANDSHAKE … got: ack`** on startup — a handshake
  race when the hub/network wasn't ready yet. `Restart=always` recovers it; the
  `HUB_WAIT` gate minimizes it. Persistent past boot usually means the wrong
  `HUB_HOST`/port or the hub's SRT ingest is off.
- **Corrupted / no frames with two cameras on one Pi.** USB 2.0 can't carry two
  uncompressed (YUYV) 720p streams. One camera per Pi, drop to ~640×480, or use
  MJPEG/H.264 cameras.
- **Log timestamps jump (e.g. 09:43 → 19:30) within one boot.** A Pi has no
  real-time clock; it boots with a stale time, then NTP steps it. Normal.

## Manual install (advanced)

```bash
sudo install -m 0755 bin/cam-stream.sh bin/cam-watchdog.sh /usr/local/bin/
sudo cp examples/cam-stream.env.example /etc/default/cam-stream-cam2   # then edit
# replace __RUN_USER__ with your user (or delete the User=/SupplementaryGroups= lines to run as root)
sudo sed "s/__RUN_USER__/$USER/g" systemd/cam-stream@.service | sudo tee /etc/systemd/system/cam-stream@.service >/dev/null
sudo install -m 0644 systemd/cam-watchdog@.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now cam-stream@cam2 cam-watchdog@cam2
```

## Uninstall

```bash
sudo ./uninstall.sh cam2
```

## Provenance

Generalized from the van's [`gps-dashboard`](https://github.com/pmormr/gps-dashboard)
`tools/picam` edge encoder. This is the canonical home for the camera-node code;
the gps-dashboard hub side (MediaMTX config, OBS production) stays there. The
network/RF side of the hill-climb deployment is documented in the private
`paul-network-docs` vault.
