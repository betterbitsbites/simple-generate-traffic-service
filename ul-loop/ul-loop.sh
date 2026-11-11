#!/usr/bin/env bash
# ul-loop.sh – endless upload loop (traffic generator)
# POSTs random payloads to upload endpoints from $URL_FILE (one per line,
# '#' = comment), $PARALLEL at a time, round after round.
#
# Self-tuning per server:
#   HTTP 413 (body too large) -> payload for that server is halved and
#                                remembered (down to MIN_PAYLOAD_SIZE)
#   other failures (5xx, timeout, DNS ...) -> server paused for COOLDOWN s
# State lives in $PAYLOAD_DIR (default /var/lib/ul-loop):
#   payload-<bytes>.bin  random payload files (one per size in use)
#   size/<key>           learned payload size per server
#   cooldown/<key>       timestamp of last failure per server
# Reset learning:  rm -rf /var/lib/ul-loop/size /var/lib/ul-loop/cooldown

set -u

URL_FILE="${URL_FILE:-/etc/ul-loop/urls.txt}"
PAYLOAD_SIZE="${PAYLOAD_SIZE:-20M}"           # start size per request
MIN_PAYLOAD_SIZE="${MIN_PAYLOAD_SIZE:-1M}"    # don't shrink below this
PAYLOAD_DIR="${STATE_DIRECTORY:-${PAYLOAD_DIR:-/var/lib/ul-loop}}"
PARALLEL="${PARALLEL:-2}"
ROUND_SIZE="${ROUND_SIZE:-20}"
ORDER="${ORDER:-random}"                      # random | shuffle | sequential
RATE_LIMIT="${RATE_LIMIT:-}"
COOLDOWN="${COOLDOWN:-1800}"                  # pause for failing servers (s)
PAUSE="${PAUSE:-10}"
MIN_ROUND="${MIN_ROUND:-20}"
BACKOFF="${BACKOFF:-60}"

DEFAULT_BYTES=$(numfmt --from=iec "$PAYLOAD_SIZE")   || { echo "Invalid PAYLOAD_SIZE=$PAYLOAD_SIZE"; exit 1; }
MIN_BYTES=$(numfmt --from=iec "$MIN_PAYLOAD_SIZE")   || { echo "Invalid MIN_PAYLOAD_SIZE=$MIN_PAYLOAD_SIZE"; exit 1; }
export PAYLOAD_DIR DEFAULT_BYTES MIN_BYTES COOLDOWN RATE_LIMIT

mkdir -p "$PAYLOAD_DIR/size" "$PAYLOAD_DIR/cooldown" || { echo "Cannot write to $PAYLOAD_DIR"; exit 1; }
rm -f "$PAYLOAD_DIR/payload.bin"                     # file name of older versions

url_key() { printf '%s' "$1" | md5sum | cut -c1-16; }

ensure_payload() {          # prints path of a payload file with exactly $1 bytes
    local b="$1" f="$PAYLOAD_DIR/payload-$1.bin" t
    if [[ "$(stat -c %s "$f" 2>/dev/null)" != "$b" ]]; then
        t=$(mktemp "$PAYLOAD_DIR/.payload.XXXXXX") || return 1
        head -c "$b" /dev/urandom > "$t" && mv -f "$t" "$f"
    fi
    printf '%s' "$f"
}

upload() {
    local url="$1" key sizef bytes file out rc code size speed new
    key=$(url_key "$url")
    # server failed earlier in this round -> skip silently
    [[ -e "$PAYLOAD_DIR/cooldown/$key" ]] && return
    sizef="$PAYLOAD_DIR/size/$key"
    bytes=$(cat "$sizef" 2>/dev/null || echo "$DEFAULT_BYTES")
    file=$(ensure_payload "$bytes") || { echo "ERROR cannot create payload"; return; }

    local opts=(-s -o /dev/null
                -X POST -T "$file"
                -H 'Content-Type: application/octet-stream'
                --connect-timeout 15 --max-time 900
                --speed-limit 10240 --speed-time 60
                -w '%{http_code} %{size_upload} %{speed_upload}')
    [[ -n "$RATE_LIMIT" ]] && opts+=(--limit-rate "$RATE_LIMIT")

    out=$(curl "${opts[@]}" "$url")
    rc=$?
    read -r code size speed <<<"$out"

    if [[ $rc -eq 0 && "${code:-0}" =~ ^2 ]]; then
        printf 'OK    %-55s %8s  %7.1f Mbit/s\n' "$url" \
            "$(numfmt --to=iec "${size:-0}")" \
            "$(awk -v s="${speed:-0}" 'BEGIN{print s*8/1e6}')"
    elif [[ "${code:-}" == 413 ]]; then
        new=$(( bytes / 2 ))
        if (( new >= MIN_BYTES )); then
            echo "$new" > "$sizef"
            printf 'SHRINK %-54s http=413 -> payload now %s\n' "$url" "$(numfmt --to=iec "$new")"
        else
            touch "$PAYLOAD_DIR/cooldown/$key"
            printf 'FAIL  %-55s http=413 even at %s – paused %ss\n' "$url" "$(numfmt --to=iec "$bytes")" "$COOLDOWN"
        fi
    else
        touch "$PAYLOAD_DIR/cooldown/$key"
        printf 'FAIL  %-55s curl=%s http=%s – paused %ss\n' "$url" "$rc" "${code:-000}" "$COOLDOWN"
    fi
}
export -f upload ensure_payload url_key

round=0
while true; do
    if [[ ! -r "$URL_FILE" ]]; then
        echo "URL file $URL_FILE not readable – waiting ${BACKOFF}s"; sleep "$BACKOFF"; continue
    fi
    mapfile -t urls < <(grep -Ev '^[[:space:]]*(#|$)' "$URL_FILE" | tr -d '\r' | awk '{print $1}')

    # drop servers that are in cooldown
    now=$(date +%s); avail=(); paused=0
    for u in "${urls[@]}"; do
        cf="$PAYLOAD_DIR/cooldown/$(url_key "$u")"
        if [[ -e "$cf" ]] && (( now - $(stat -c %Y "$cf") < COOLDOWN )); then
            paused=$((paused + 1))
        else
            rm -f "$cf"; avail+=("$u")
        fi
    done
    if (( ${#avail[@]} == 0 )); then
        echo "No usable servers (${#urls[@]} in file, $paused paused) – waiting ${BACKOFF}s"
        sleep "$BACKOFF"; continue
    fi

    case "$ORDER" in
        shuffle)    mapfile -t queue < <(printf '%s\n' "${avail[@]}" | shuf) ;;
        sequential) queue=("${avail[@]}") ;;
        *)          mapfile -t queue < <(printf '%s\n' "${avail[@]}" | shuf -r -n "$ROUND_SIZE") ;;
    esac

    round=$((round + 1))
    echo "=== Round $round: ${#queue[@]} uploads, ${#avail[@]} servers active, $paused paused ($ORDER), $PARALLEL parallel${RATE_LIMIT:+, limit $RATE_LIMIT/stream} ==="
    start=$SECONDS

    printf '%s\n' "${queue[@]}" | xargs -d '\n' -P "$PARALLEL" -I{} bash -c 'upload "$1"' _ {}

    duration=$((SECONDS - start))
    echo "=== Round $round finished in ${duration}s ==="
    if (( duration < MIN_ROUND )); then
        echo "Round was very short – backing off ${BACKOFF}s"; sleep "$BACKOFF"
    else
        sleep "$PAUSE"
    fi
done
