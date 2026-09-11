#!/usr/bin/env bash
# The live falsifier for the liveness ladder (#3 #4; docs/2026-09-11-liveness-ladder-design.md § 4).
# Reproduces 2026-09-10 on this Mac — NE stays Connected while the fork's server is unreachable — by blocking
# the server's IP in a private pf anchor, then watches the fork's log for the ladder:
#   PASS = `[liveness] rung 1`, then `rung 2`, then a connection to a DIFFERENT server with 10.2.0.1 answering,
#          within LIMIT seconds; no rung inside the first 60 s.
# Attended: it asks you to click Disconnect / Quick Connect in the shipped app (never two tunnels) and for sudo
# (pf). The pf anchor and its enable token are removed on every exit path, Ctrl-C included.
set -euo pipefail

FORK_APP="/Applications/ProtonVPN Fork.app"
FORK_ID="io.github.colangelo.protonvpn.mac"
FORK_EXT="$FORK_ID.WireGuard-Extension"
FORK_LOG="$HOME/Library/Containers/$FORK_ID/Data/Library/Logs/ProtonVPN.log"
ANCHOR="com.apple/liveness-falsifier"
LIMIT="${LIMIT:-300}"

pf_token=""
blocked_ip=""

say() { printf '\n==> %s\n' "$*"; }
nc_status() { scutil --nc status "$1" 2>/dev/null | head -1; }
ext_pid() { pgrep -f "$FORK_EXT" | head -1 || true; }
last_connected_ip() { { grep -oE 'Connected to: [0-9.]+' "$FORK_LOG" || true; } | tail -1 | awk '{print $3}'; }
wait_for() { # wait_for <seconds> <description> <command…>
    local limit="$1" what="$2"; shift 2
    for ((i = 0; i < limit; i += 2)); do "$@" && return 0; sleep 2; done
    echo "timed out after ${limit}s waiting for: $what" >&2; return 1
}

cleanup() {
    if [[ -n "$blocked_ip" ]]; then
        sudo pfctl -a "$ANCHOR" -F all >/dev/null 2>&1 || true
        echo "pf: anchor $ANCHOR flushed ($blocked_ip unblocked)"
    fi
    if [[ -n "$pf_token" ]]; then
        sudo pfctl -X "$pf_token" >/dev/null 2>&1 || true
        echo "pf: enable token $pf_token released"
    fi
}
trap cleanup EXIT

[[ -d "$FORK_APP" ]] || { echo "not installed: $FORK_APP (ditto the DerivedData build first)" >&2; exit 1; }
[[ "$(defaults read "$FORK_ID" LivenessEnabled 2>/dev/null || echo 1)" != 0 ]] || { echo "LivenessEnabled is false in $FORK_ID" >&2; exit 1; }

say "1/6 Click Disconnect in the SHIPPED ProtonVPN window (never two tunnels), then press Enter."
read -r
wait_for 30 "shipped app Disconnected" bash -c '[[ "$(scutil --nc status ProtonVPN | head -1)" == Disconnected ]]'

say "2/6 Launching the fork by path and quick-connecting it"
open "$FORK_APP"
sleep 5
open -b "$FORK_ID" 'protonvpn://quick-connect'
wait_for 60 "fork Connected" bash -c '[[ "$(scutil --nc status "ProtonVPN Fork" | head -1)" == Connected ]]'
wait_for 30 "10.2.0.1 answering" ping -c1 -t2 10.2.0.1 >/dev/null
blocked_candidate="$(last_connected_ip)"
[[ -n "$blocked_candidate" ]] || { echo "no 'Connected to:' line in $FORK_LOG" >&2; exit 1; }
echo "fork on $blocked_candidate; exit IP $(curl -s --max-time 5 https://api.ipify.org || echo '?'); extension pid $(ext_pid)"

say "3/6 Blocking $blocked_candidate in pf anchor $ANCHOR (sudo)"
pf_token="$(sudo pfctl -E 2>&1 | awk '/Token/ {print $3}')"
printf 'block drop quick from any to %s\nblock drop quick from %s to any\n' "$blocked_candidate" "$blocked_candidate" \
    | sudo pfctl -a "$ANCHOR" -f -
blocked_ip="$blocked_candidate"
sudo pfctl -k 0.0.0.0/0 -k "$blocked_ip" >/dev/null 2>&1 || true
started=$(date +%s)
log_mark=$(wc -l <"$FORK_LOG")
echo "blocked at $(date '+%H:%M:%S'); NE: $(nc_status "ProtonVPN Fork")"

say "4/6 Watching for the ladder (up to ${LIMIT}s)"
verdict="FAIL"
pid_before="$(ext_pid)"; pid_after_rung1=""
while (($(date +%s) - started < LIMIT)); do
    sleep 10
    elapsed=$(($(date +%s) - started))
    new="$(tail -n +"$((log_mark + 1))" "$FORK_LOG")"
    if grep -q '\[liveness\] rung' <<<"$new" && ((elapsed < 60)); then
        first="$(grep -m1 '\[liveness\] rung' <<<"$new")"
        echo "a rung fired inside the first 60 s: $first"; break
    fi
    if [[ -z "$pid_after_rung1" ]] && grep -q '\[liveness\] rung 1' <<<"$new"; then
        sleep 5; pid_after_rung1="$(ext_pid)"
    fi
    now_ip="$(last_connected_ip)"
    printf '  +%3ss  NE=%-12s server=%-15s rungs=%s\n' "$elapsed" "$(nc_status "ProtonVPN Fork")" "$now_ip" \
        "$(grep -c '\[liveness\] rung' <<<"$new" || true)"
    if grep -q '\[liveness\] rung 2' <<<"$new" && [[ "$now_ip" != "$blocked_ip" ]] \
        && ping -c1 -t2 10.2.0.1 >/dev/null 2>&1; then
        verdict="PASS"; break
    fi
done

say "5/6 Verdict: $verdict after $(($(date +%s) - started))s"
echo "blocked server: $blocked_ip -> now: $(last_connected_ip); exit IP $(curl -s --max-time 5 https://api.ipify.org || echo '?')"
echo "extension pid: before $pid_before, ~5 s after rung 1 ${pid_after_rung1:-n/a}, now $(ext_pid)"
echo "--- fork log since the block ([liveness], Server selected, Connected to):"
tail -n +"$((log_mark + 1))" "$FORK_LOG" | grep -E '\[liveness\]|Server selected|Connected to' || true

cleanup
blocked_ip=""; pf_token=""

say "6/6 Restore: disconnecting the fork; then Quick Connect the SHIPPED app and quit the fork (Cmd-Q). Press Enter when done."
open -b "$FORK_ID" 'protonvpn://disconnect'
read -r
echo "shipped: $(nc_status ProtonVPN); fork: $(nc_status "ProtonVPN Fork")"
[[ "$verdict" == PASS ]]
