#!/system/bin/sh
# Install the locally generated CA into the system trust store.
#
# The private key never ships with the module: the first enable generates it
# on-device with bindhosts-proxy -genca under /data/adb/bindhosts/proxy/certs/.
#
# Same approach as reqable-magisk: a separate tmpfs, copy the existing certs,
# add ours, bind mount over the target and propagate to zygote's namespace.
# Must run in post-fs-data, or processes started earlier miss the new certs.

MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -z "$MODDIR" ] && MODDIR=/data/adb/modules/bindhosts
PERSISTENT_DIR=/data/adb/bindhosts
CERTDIR="$PERSISTENT_DIR/proxy/certs"
BIN="$MODDIR/bin/bindhosts-proxy"

LOG="$PERSISTENT_DIR/proxy.log"
mkdir -p "$PERSISTENT_DIR" 2>/dev/null
exec >> "$LOG" 2>&1

log() { echo "$(date '+%m-%d %H:%M:%S') $*"; }

# Only install the CA when proxy is enabled.
state=$(grep '^proxy=' "$PERSISTENT_DIR/rules_state" 2>/dev/null | head -1 | cut -d= -f2)
if [ "$state" != "1" ]; then
	log "proxy disabled, skip certificate"
	exit 0
fi

[ -x "$BIN" ] || { log "binary missing, skip certificate"; exit 1; }

# Generate a local CA when missing.
mkdir -p "$CERTDIR"
if [ ! -f "$CERTDIR/ca.crt" ] || [ ! -f "$CERTDIR/ca.key" ]; then
	log "generating local CA in $CERTDIR"
	"$BIN" -genca "$CERTDIR" >/dev/null 2>&1 || { log "genca failed"; exit 1; }
fi

# The trust store needs a copy named by subject_hash_old.
HASHFILE=$(ls "$CERTDIR"/*.0 2>/dev/null | head -1)
if [ -z "$HASHFILE" ]; then
	log "no hash-named CA copy, regenerating"
	"$BIN" -genca "$CERTDIR" >/dev/null 2>&1
	HASHFILE=$(ls "$CERTDIR"/*.0 2>/dev/null | head -1)
fi
[ -n "$HASHFILE" ] || { log "cannot prepare CA file"; exit 1; }
log "using CA $(basename "$HASHFILE")"

set_context() {
	[ "$(getenforce)" = "Enforcing" ] || return 0
	default_ctx=u:object_r:system_file:s0
	ctx=$(ls -Zd "$1" 2>/dev/null | awk '{print $1}')
	if [ -n "$ctx" ] && [ "$ctx" != "?" ]; then
		chcon -R "$ctx" "$2"
	else
		chcon -R "$default_ctx" "$2"
	fi
}

merge_ca_certs() {
	target_path="$1"
	tmpfs_path="$2"

	rm -rf "$tmpfs_path"
	mkdir -p "$tmpfs_path"
	mount -t tmpfs tmpfs "$tmpfs_path" || return 1

	cp -f "$target_path"/* "$tmpfs_path"/ 2>/dev/null
	cp -f "$HASHFILE" "$tmpfs_path"/
	chown -R 0:0 "$tmpfs_path"
	set_context "$target_path" "$tmpfs_path"

	count=$(ls -1 "$tmpfs_path" | wc -l)
	log "certs after merge: $count"

	# Safety valve: too few certs means the copy failed. Skip the mount rather than break all HTTPS.
	if [ "$count" -le 10 ]; then
		log "cancelling: too few certs"
		umount "$tmpfs_path" 2>/dev/null
		rmdir "$tmpfs_path" 2>/dev/null
		return 1
	fi

	mount --bind "$tmpfs_path" "$target_path" || return 1
	for pid in 1 $(pidof zygote) $(pidof zygote64); do
		nsenter --mount=/proc/$pid/ns/mnt -- \
			mount --bind "$tmpfs_path" "$target_path" 2>/dev/null
	done
	log "mounted on $target_path"
}

# Android 14+ keeps the trust store in APEX; Magisk does not inject there, merge manually.
[ -d /apex/com.android.conscrypt/cacerts ] && \
	merge_ca_certs /apex/com.android.conscrypt/cacerts /data/local/tmp/bindhosts-ca-apex

[ -d /system/etc/security/cacerts ] && \
	merge_ca_certs /system/etc/security/cacerts /data/local/tmp/bindhosts-ca-sys
