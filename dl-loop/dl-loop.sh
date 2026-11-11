#!/usr/bin/env bash
# dl-loop.sh – endless download loop to /dev/null (traffic generator)
# Reads URLs from $URL_FILE (one per line, '#' = comment), downloads them
# with $PARALLEL concurrent streams, then starts over. The URL file is
# re-read every round, so you can edit it without restarting the service.

set -u

URL_FILE="${URL_FILE:-/etc/dl-loop/urls.txt}"
PARALLEL="${PARALLEL:-4}"        # concurrent downloads
RATE_LIMIT="${RATE_LIMIT:-}"     # per-stream curl limit, e.g. 20M (empty = unlimited)
PAUSE="${PAUSE:-5}"              # seconds between rounds
MIN_ROUND="${MIN_ROUND:-30}"     # round shorter than this = probably errors -> back off
BACKOFF="${BACKOFF:-60}"         # seconds to wait after a suspiciously short round
ORDER="${ORDER:-random}"         # random | shuffle | sequential
ROUND_SIZE="${ROUND_SIZE:-}"     # downloads per round in 'random' mode (empty = number of URLs)
export RATE_LIMIT

download() {
    local url="$1" out rc code size speed
    local opts=(-sS -L -o /dev/null
                --connect-timeout 15
                --speed-limit 10240 --speed-time 60   # abort if <10 KB/s for 60 s
                -w '%{http_code} %{size_download} %{speed_download}')
    [[ -n "$RATE_LIMIT" ]] && opts+=(--limit-rate "$RATE_LIMIT")

    out=$(curl "${opts[@]}" "$url")
    rc=$?
    read -r code size speed <<<"$out"

    if [[ $rc -eq 0 && "${code:-0}" =~ ^2 ]]; then
        printf 'OK    %-55s %8s  %7.1f Mbit/s\n' "$url" \
            "$(numfmt --to=iec "${size:-0}")" \
            "$(awk -v s="${speed:-0}" 'BEGIN{print s*8/1e6}')"
    else
        printf 'FAIL  %-55s curl=%s http=%s\n' "$url" "$rc" "${code:-000}"
    fi
}
export -f download

round=0
while true; do
    if [[ ! -r "$URL_FILE" ]]; then
        echo "URL file $URL_FILE not readable – waiting ${BACKOFF}s"
        sleep "$BACKOFF"; continue
    fi

    mapfile -t urls < <(grep -Ev '^[[:space:]]*(#|$)' "$URL_FILE" | tr -d '\r')
    if (( ${#urls[@]} == 0 )); then
        echo "No URLs in $URL_FILE – waiting ${BACKOFF}s"
        sleep "$BACKOFF"; continue
    fi

    # Build this round's download list according to ORDER
    case "$ORDER" in
        random)      # random picks with replacement (same URL can appear twice)
                     n="${ROUND_SIZE:-${#urls[@]}}"
                     mapfile -t queue < <(printf '%s\n' "${urls[@]}" | shuf -r -n "$n") ;;
        shuffle)     # every URL exactly once, random order
                     mapfile -t queue < <(printf '%s\n' "${urls[@]}" | shuf) ;;
        sequential)  queue=("${urls[@]}") ;;
        *)           echo "Unknown ORDER='$ORDER' – using random"
                     mapfile -t queue < <(printf '%s\n' "${urls[@]}" | shuf -r -n "${#urls[@]}") ;;
    esac

    round=$((round + 1))
    echo "=== Round $round: ${#queue[@]} downloads from ${#urls[@]} URLs ($ORDER), $PARALLEL parallel${RATE_LIMIT:+, limit $RATE_LIMIT/stream} ==="
    start=$SECONDS

    printf '%s\n' "${queue[@]}" | xargs -d '\n' -P "$PARALLEL" -I{} bash -c 'download "$1"' _ {}

    duration=$((SECONDS - start))
    echo "=== Round $round finished in ${duration}s ==="

    if (( duration < MIN_ROUND )); then
        echo "Round was very short (network down or URLs broken?) – backing off ${BACKOFF}s"
        sleep "$BACKOFF"
    else
        sleep "$PAUSE"
    fi
done
