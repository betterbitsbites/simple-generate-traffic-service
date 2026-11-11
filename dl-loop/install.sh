#!/usr/bin/env bash
# install.sh – installs dl-loop into a Debian/Ubuntu LXC. Run as root
# from the directory containing the files.
set -euo pipefail
cd "$(dirname "$0")"

command -v curl >/dev/null || { apt-get update && apt-get install -y curl; }

id dl-loop &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin dl-loop

install -m 0755 dl-loop.sh       /usr/local/bin/dl-loop.sh
install -d -m 0755               /etc/dl-loop
[[ -e /etc/dl-loop/dl-loop.conf ]] || install -m 0644 dl-loop.conf /etc/dl-loop/dl-loop.conf
[[ -e /etc/dl-loop/urls.txt     ]] || install -m 0644 urls.txt     /etc/dl-loop/urls.txt
install -m 0644 dl-loop.service  /etc/systemd/system/dl-loop.service

systemctl daemon-reload
systemctl enable dl-loop.service
systemctl restart dl-loop.service

echo
echo "dl-loop installed and (re)started."
echo "  Logs:    journalctl -u dl-loop -f"
echo "  URLs:    /etc/dl-loop/urls.txt   (picked up next round)"
echo "  Config:  /etc/dl-loop/dl-loop.conf (then: systemctl restart dl-loop)"
echo "  Stop:    systemctl stop dl-loop   |  disable autostart: systemctl disable dl-loop"
