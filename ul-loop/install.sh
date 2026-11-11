#!/usr/bin/env bash
# install.sh – installs ul-loop into a Debian/Ubuntu LXC. Run as root
# from the directory containing the files.
set -euo pipefail
cd "$(dirname "$0")"

command -v curl >/dev/null || { apt-get update && apt-get install -y curl; }

id ul-loop &>/dev/null || useradd --system --no-create-home --home-dir /var/lib/ul-loop --shell /usr/sbin/nologin ul-loop
[[ -d /var/lib/ul-loop ]] && chown -R ul-loop:ul-loop /var/lib/ul-loop

install -m 0755 ul-loop.sh      /usr/local/bin/ul-loop.sh
install -d -m 0755              /etc/ul-loop
[[ -e /etc/ul-loop/ul-loop.conf ]] || install -m 0644 ul-loop.conf /etc/ul-loop/ul-loop.conf
[[ -e /etc/ul-loop/urls.txt     ]] || install -m 0644 urls.txt     /etc/ul-loop/urls.txt
install -m 0644 ul-loop.service /etc/systemd/system/ul-loop.service

systemctl daemon-reload
systemctl enable ul-loop.service
systemctl restart ul-loop.service

echo
echo "ul-loop installed and (re)started."
echo "  Logs:    journalctl -u ul-loop -f"
echo "  URLs:    /etc/ul-loop/urls.txt    (picked up next round)"
echo "  Config:  /etc/ul-loop/ul-loop.conf (then: systemctl restart ul-loop)"
echo "  State:   /var/lib/ul-loop  (reset learning: rm -rf /var/lib/ul-loop/{size,cooldown})"
echo "  Stop:    systemctl stop ul-loop   |  disable autostart: systemctl disable ul-loop"
