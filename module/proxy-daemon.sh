#!/system/bin/sh
# Watchdog for the proxy daemon.
#
# Does exactly three things: start the process, wait for it to die, and
# reconcile hosts through --sync-proxy. Adding or removing the hosts entries
# is left entirely to sync_proxy_hosts in bindhosts.sh; nothing is duplicated
# here (action() already covers the switch-off case).
#
# Design notes:
#   - wait blocks on the child: zero polling, zero CPU while healthy
#   - "failed start" is judged by uptime: dying before 10s counts as a failure,
#     10 consecutive failures disable the proxy and exit
#   - when the binary is gone, try bin/bindhosts-proxy.bak before giving up
#   - all text handling uses awk: the script PATH may pick up Termux's GNU grep,
#     whose -f file handling differs from toybox
#   - liveness is tracked with a pid file rather than pgrep/ps

MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -z "$MODDIR" ] && MODDIR=/data/adb/modules/bindhosts
PERSISTENT_DIR=/data/adb/bindhosts

BIN="$MODDIR/bin/bindhosts-proxy"
BAK="$MODDIR/bin/bindhosts-proxy.bak"
CERTDIR="$PERSISTENT_DIR/proxy/certs"
RULES="$PERSISTENT_DIR/proxy.rules"
STATE="$PERSISTENT_DIR/rules_state"
PIDFILE="$PERSISTENT_DIR/proxy-daemon.pid"

LOG="$PERSISTENT_DIR/proxy.log"
mkdir -p "$PERSISTENT_DIR" 2>/dev/null
exec >> "$LOG" 2>&1

log() { echo "$(date '+%m-%d %H:%M:%S') $*"; }

MAX_FAIL=10
MIN_UPTIME=10

# ---- State and binary ------------------------------------------------------

proxy_on() {
	awk -F= '$1 == "proxy" && $2 == "1" { f = 1 } END { exit !f }' "$STATE" 2>/dev/null
}

# Set proxy=0 in rules_state, leaving every other line untouched.
disable_proxy() {
	awk -F= '
		$1 == "proxy" { print "proxy=0"; found = 1; next }
		{ print }
		END { if (!found) print "proxy=0" }
	' "$STATE" > "$STATE.tmp" 2>/dev/null
	if [ -s "$STATE.tmp" ]; then
		cat "$STATE.tmp" > "$STATE"
		rm -f "$STATE.tmp"
		return 0
	fi
	rm -f "$STATE.tmp"
	return 1
}

ensure_binary() {
	[ -x "$BIN" ] && return 0
	if [ ! -f "$BAK" ]; then
		log "[x] binary missing and no backup: $BAK"
		return 1
	fi
	log "[!] binary missing, restoring from $BAK"
	cp -f "$BAK" "$BIN" 2>/dev/null || { log "[x] copy failed"; return 1; }
	chmod 755 "$BIN" 2>/dev/null
	if [ -x "$BIN" ]; then
		log "[+] binary restored"
		return 0
	fi
	log "[x] restored file is not executable"
	return 1
}

# Reconcile the proxy entries in hosts; the callee decides add or remove.
sync_hosts() {
	WEBUI_QUIET=1 sh "$MODDIR/bindhosts.sh" --sync-proxy 2>/dev/null
}

# ---- Main loop -------------------------------------------------------------

echo $$ > "$PIDFILE" 2>/dev/null
log "=== proxy watchdog start (pid $$) ==="

fail=0

while true; do
	# Proxy switched off: stop the daemon, drop the pid file, exit.
	if ! proxy_on; then
		if pidof bindhosts-proxy >/dev/null 2>&1; then
			log "proxy disabled, stopping daemon"
			pkill -f bindhosts-proxy 2>/dev/null
		fi
		log "watchdog exit (proxy off)"
		rm -f "$PIDFILE"
		exit 0
	fi

	# Try the backup before giving up on the binary.
	if ! ensure_binary; then
		log "[x] cannot run proxy daemon, disabling proxy"
		disable_proxy
		sync_hosts
		log "[x] watchdog exit (binary unavailable)"
		rm -f "$PIDFILE"
		exit 1
	fi

	# Something else already holds 443; do not start a second one.
	if pidof bindhosts-proxy >/dev/null 2>&1; then
		sleep 10
		continue
	fi

	started=$(date +%s)
	"$BIN" -listen 127.0.0.1:443 -certdir "$CERTDIR" -rules "$RULES" &
	pid=$!
	log "daemon started pid=$pid"

	# Daemon started and about to bind; this call takes long enough for the port to be ready.
	sync_hosts

	wait "$pid"
	rc=$?
	ran=$(( $(date +%s) - started ))

	if [ "$ran" -lt "$MIN_UPTIME" ]; then
		fail=$((fail + 1))
	else
		fail=0
	fi
	log "daemon exited rc=$rc after ${ran}s (fail=$fail/$MAX_FAIL)"

	# No daemon means nothing is listening; sync drops the entries.
	sync_hosts

	if [ "$fail" -ge "$MAX_FAIL" ]; then
		log "[x] giving up after $MAX_FAIL failed starts, disabling proxy"
		disable_proxy
		sync_hosts
		log "[x] watchdog exit (too many failures)"
		rm -f "$PIDFILE"
		exit 1
	fi
done
