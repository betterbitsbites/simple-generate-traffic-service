# simple-generate-traffic-service

Two small systemd services that generate continuous network traffic –
useful for testing traffic shaping / QoS (e.g. pfSense ALTQ queues or
limiters) or for saturating a line on purpose. Both run fine in a tiny
Debian/Ubuntu LXC (1 core, 256 MB RAM, ~1 GB disk) and start
automatically when the container boots.

| Tool | Direction | Disk usage |
|---|---|---|
| [`dl-loop`](dl-loop/) | Download | none – everything goes to `/dev/null` |
| [`ul-loop`](ul-loop/) | Upload | a few random payload files (≤ ~40 MB) in `/var/lib/ul-loop` |

## Install

```bash
git clone https://github.com/betterbitsbites/simple-generate-traffic-service.git
cd simple-generate-traffic-service

# download generator
bash dl-loop/install.sh

# upload generator
bash ul-loop/install.sh
```

Each installer creates a dedicated system user, installs the script to
`/usr/local/bin`, the config to `/etc/<tool>/` (existing config is never
overwritten) and enables + (re)starts the service.

## Usage

```bash
journalctl -u dl-loop -f          # live log
journalctl -u ul-loop -f
systemctl stop ul-loop            # pause
systemctl disable ul-loop         # no autostart
```

Config: `/etc/<tool>/<tool>.conf` (restart after changes).
URL list: `/etc/<tool>/urls.txt` – re-read every round, no restart needed.

### Common options

| Option | Meaning |
|---|---|
| `PARALLEL` | concurrent transfers |
| `ORDER` | `random` (picks with replacement), `shuffle` (each URL once, random order), `sequential` |
| `ROUND_SIZE` | transfers per round in `random` mode |
| `RATE_LIMIT` | per-stream limit in curl syntax (`2M`, `500K`), empty = unlimited |
| `PAUSE` | seconds between rounds |
| `MIN_ROUND` / `BACKOFF` | if a round ends faster than `MIN_ROUND` s (network down, dead URLs) wait `BACKOFF` s |

### dl-loop

Downloads large speed-test files (Hetzner, OVH …) to `/dev/null`.
Stalled downloads (< 10 KB/s for 60 s) are aborted.

### ul-loop

POSTs incompressible random data to public upload endpoints
(Cloudflare `speed.cloudflare.com/__up`, LibreSpeed servers). The payload is
streamed from disk (`curl -T`), not loaded into RAM.

Self-tuning per server:

- **HTTP 413** (body too large) → payload for that server is halved and
  remembered, down to `MIN_PAYLOAD_SIZE` (default 1M).
- **Other failures** (5xx, timeout, DNS) → server is skipped for
  `COOLDOWN` seconds (default 1800).

Reset what was learned: `rm -rf /var/lib/ul-loop/{size,cooldown}`

## Fair use

The default URLs are free public speed-test servers. They are fine for
test windows, but please don't saturate them 24/7. For continuous load use
your own endpoint, e.g. a small VPS:

- download: any large static file served by nginx
- upload: `location = /up { client_max_body_size 0; return 200; }`

## Requirements

`bash`, `curl`, coreutils (`shuf`, `numfmt`, `md5sum`), `systemd`.
