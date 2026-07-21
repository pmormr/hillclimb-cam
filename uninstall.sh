#!/usr/bin/env bash
# Remove a hillclimb-cam instance. Run on the camera Pi:
#     sudo ./uninstall.sh <instance>      (e.g. cam2)
set -uo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root:  sudo ./uninstall.sh <instance>"; exit 1; }

INSTANCE="${1:-}"
if [ -z "$INSTANCE" ]; then
  echo "Usage: sudo ./uninstall.sh <instance>   (e.g. cam2)"
  echo "Installed instances:"
  shopt -s nullglob
  for f in /etc/default/cam-stream-*; do echo "  ${f##*/cam-stream-}"; done
  exit 1
fi

systemctl disable --now "cam-stream@${INSTANCE}" "cam-watchdog@${INSTANCE}" 2>/dev/null || true
rm -f "/etc/default/cam-stream-${INSTANCE}"
systemctl daemon-reload
echo "Removed instance '${INSTANCE}'."

echo
echo "Shared files were kept (other instances may use them). To fully remove:"
echo "  rm /usr/local/bin/cam-stream.sh /usr/local/bin/cam-watchdog.sh"
echo "  rm /etc/systemd/system/cam-stream@.service /etc/systemd/system/cam-watchdog@.service"
echo "  systemctl daemon-reload"
