#!/bin/sh
PATH=/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:/data/data/com.termux/files/usr/bin:$PATH
MODDIR="/data/adb/modules/bindhosts"
PERSISTENT_DIR="/data/adb/bindhosts"
. $MODDIR/utils.sh
. $MODDIR/mode.sh

# bindhosts.sh
# bindhosts' processing backend

# grab own info (version)
versionCode=$(grep versionCode $MODDIR/module.prop | sed 's/versionCode=//g' )

# look for writable dir
rwdir=$MODDIR
[ -w /dev ] && rwdir=/dev

if [ -z "$WEBUI_QUIET" ]; then
	echo "[+] bindhosts v$versionCode"
	echo "[%] bindhosts.sh"
	echo "[%] standalone hosts-based-adblocking implementation"
	echo "[%] mode: $operating_mode | rwdir: $rwdir "
fi

[ -f $MODDIR/disable ] && {
	echo "[*] not running since module has been disabled"
	string="description=status: disabled ❌ | $(date)"
        sed -i "s/^description=.*/$string/g" $MODDIR/module.prop
	return
}

# just in case user deletes them
# persistence
[ ! -d /data/adb/bindhosts ] && mkdir -p $PERSISTENT_DIR
# Rule files are grouped by type; the old name prefixes are gone.
HOSTS_DIR="$PERSISTENT_DIR/hosts"
PROXY_DIR="$PERSISTENT_DIR/proxy"
HOSTS_IMPORTED="$HOSTS_DIR/imported"
PROXY_IMPORTED="$PROXY_DIR/imported"
# The product cannot share its name with proxy/, or mv drops the file inside it.
PROXY_PRODUCT="$PERSISTENT_DIR/proxy.rules"
mkdir -p "$HOSTS_IMPORTED" "$PROXY_IMPORTED" "$HOSTS_DIR/cache" "$PROXY_DIR/cache" 2>/dev/null

# These are already absolute paths; do not prepend $PERSISTENT_DIR/.
files="$HOSTS_DIR/custom.txt $HOSTS_DIR/blacklist.txt $HOSTS_DIR/sources.txt $HOSTS_DIR/whitelist.txt $HOSTS_DIR/sources_whitelist.txt $PROXY_DIR/sources.txt $PROXY_DIR/custom.txt"
for i in $files ; do
	[ ! -f "$i" ] && echo "#" > "$i"
done

adaway_warn() {
	pm path org.adaway > /dev/null 2>&1 && echo "[-] 🚨 Current operation mode may not work with AdAway 📛"
}

# impl def for changing variables
target_hostsfile="$MODDIR/system/etc/hosts"
helper_mode=""

# Record the real hosts path: it varies per operating mode and the watchdog needs it.
echo "$target_hostsfile" > "$PERSISTENT_DIR/hosts_target" 2>/dev/null

# we can just remove the other unmodified modes
# and have them fall to * but im gonna leave it 
# here for clarity
case $operating_mode in
	0) if [ -f /data/adb/ksu/modules.img ] || [ -f /data/adb/ap/modules.img ]; then adaway_warn ; fi ;;
	1) true ;;
	2) true ;;
	3) target_hostsfile="/data/adb/hosts" ; helper_mode="| hosts_file_redirect 💉" ; adaway_warn ;;
	4) target_hostsfile="/data/adb/hostsredirect/hosts" ; helper_mode="| ZN-hostsredirect 💉" ; adaway_warn ;;
	5) true ;;
	6) true ;;
	7) target_hostsfile="/system/etc/hosts" ;;
	8) target_hostsfile="/system/etc/hosts" ;;
	9) true ;;
	*) true ;; # catch invalid modes
esac

# check hosts file if writable, if not, warn and exit
if [ ! -w $target_hostsfile ] ; then
	# no fucking way
	echo "[x] unwritable hosts file 😭 needs correction 💢"
	string="description=status: unwritable hosts file 😭 needs correction 💢"
        sed -i "s/^description=.*/$string/g" $MODDIR/module.prop
	return
fi

##### functions
illusion () {
	x=$(($$%4 + 4)); while [ $x -gt 1 ] ; do echo '[.]' ; sleep 0.1 ; x=$((x-1)) ; done &
}

run_crond() {
	[ ! -d "$PERSISTENT_DIR/crontabs" ] && {
		mkdir "$PERSISTENT_DIR/crontabs"
		echo "[+] running crond"
		busybox crond -bc "$PERSISTENT_DIR/crontabs" -L /dev/null
	}
}

_month_txt2dec() {
	txt2dec_month="$1"
	case "$( echo "$txt2dec_month" | tr "[:lower:]" "[:upper:]" )" in
		JAN) echo 1 ;;
		FEB) echo 2 ;;
		MAR) echo 3 ;;
		APR) echo 4 ;;
		MAY) echo 5 ;;
		JUN) echo 6 ;;
		JUL) echo 7 ;;
		AUG) echo 8 ;;
		SEP) echo 9 ;;
		OCT) echo 10 ;;
		NOV) echo 11 ;;
		DEC) echo 12 ;;
		*) echo "$txt2dec_month" ;; # Return unconverted if parameter is not JAN-DEC
	esac
}

_day_txt2dec() {
	txt2dec_day="$1"
	case "$( echo "$txt2dec_day" | tr "[:lower:]" "[:upper:]" )" in
		SUN) echo 0 ;;
		MON) echo 1 ;;
		TUE) echo 2 ;;
		WED) echo 3 ;;
		THU) echo 4 ;;
		FRI) echo 5 ;;
		SAT) echo 6 ;;
		*) echo "$txt2dec_day" ;; # Return unconverted if parameter is not SUN-SAT
	esac
}

_is_valid_cron_arg() { # return value: 0 = true, 1 = false
(
	x="$1"
	valid_cron_arg="$2"
	len=${#valid_cron_arg}
	complex_check=false
	[ "$len" -lt 1 ] && return 1 # End check if arg is empty
	if [ "$len" -eq 1 ]; then
		# End check if 1-char arg is not * or digit
		[ "$(echo "$valid_cron_arg" | tr -d "\*[:digit:]" | wc -w)" -gt 0 ] && return 1
		# Additional check if arg is a number
		if (echo "$valid_cron_arg" | grep -q "[[:digit:]]"); then
			case "$x" in
				3) [ "$valid_cron_arg" -lt 1 ] && return 1 ;;
				4) [ "$valid_cron_arg" -lt 1 ] && return 1 ;;
				5) [ "$valid_cron_arg" -lt 0 ] || [ "$valid_cron_arg" -gt 7 ] && return 1 ;;
			esac
		fi
	elif [ "$len" -eq 2 ]; then
		# End check if 2-char arg is not a number
		[ "$(echo "$valid_cron_arg" | tr -d "[:digit:]" | wc -w)" -gt 0 ] && return 1
		case "$x" in
			1) [ "$valid_cron_arg" -lt 0 ] || [ "$valid_cron_arg" -gt 59 ] && return 1 ;;
			2) [ "$valid_cron_arg" -lt 0 ] || [ "$valid_cron_arg" -gt 23 ] && return 1 ;;
			3) [ "$valid_cron_arg" -lt 1 ] || [ "$valid_cron_arg" -gt 31 ] && return 1 ;;
			4) [ "$valid_cron_arg" -lt 1 ] || [ "$valid_cron_arg" -gt 12 ] && return 1 ;;
			*) return 1 ;;
		esac
	elif [ "$len" -gt 2 ]; then
		# Because the arg might be "1-6", "0,15,25" or even "1-7,7-21/3"
		# We'll need extra check for these long arg (>= 3 char) if the arg is:
		# - of the MONTH field but is not in JAN-DEC list
		# - of the DAY_OF_WEEK field but is not in SUN-SAT list
		# - of the MIN, HOUR or DAY_OF_MONTH fields
		case "$x" in
			4) (! echo "$valid_cron_arg" | grep -Eiqw "^(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)$") && complex_check=true ;;
			5) (! echo "$valid_cron_arg" | grep -Eiqw "^(SUN|MON|TUE|WED|THU|FRI|SAT)$") && complex_check=true ;;
			*) complex_check=true ;;
		esac
	fi

	if [ "$complex_check" = true ]; then
		# End check if long arg (>= 3 char) is a number
		[ "$(echo "$valid_cron_arg" | tr -d "[:digit:]" | wc -w)" -eq 0 ] && return 1

		delimiter=""
		# To split complex arg in the order from , > / > -
		if (echo "$valid_cron_arg" | grep -q "\," > /dev/null 2>&1 ); then
			delimiter=","
		elif (echo "$valid_cron_arg" | grep -q "\/" > /dev/null 2>&1 ); then
			delimiter="/"
		elif (echo "$valid_cron_arg" | grep -q "\-" > /dev/null 2>&1 ); then
			delimiter="-"
		else
			# End check if arg does not contain , / or -
			return 1
		fi

		substring=""
		prev_substring=0
		while [ "$valid_cron_arg" != "$substring" ] ;do
			# Extract the substring from start of arg up to delimiter
			# Example: substring="JAN" from "JAN,MAR,JUN,SEP,DEC"
			substring=${valid_cron_arg%%"$delimiter"*}
			# Delete this first "substring" AND its delimiter, from arg
			# Example: arg="MAR,JUN,SEP,DEC" from "JAN,MAR,JUN,SEP,DEC"
			valid_cron_arg="${valid_cron_arg#"$substring""$delimiter"}"

			is_arg_valid=false
			# Diving in from full arg (e.g. "0-59/5") into
			# individual value (e.g. "0", "59" "/2") for validation
			_is_valid_cron_arg "$x" "$substring" && is_arg_valid=true

			if [ "$delimiter" = "/" ] || [ "$delimiter" = "-" ]; then
				[ "${#valid_cron_arg}" -lt 1 ] && return 1 # End check if no arg is behind / or -

				# Test if arg behind / or - is JAN-DEC / SUN-SAT
				# arg will be converted to its respective number
				converted_arg="$valid_cron_arg"
				[ "$x" -eq 4 ] && converted_arg=$(_month_txt2dec "$valid_cron_arg")
				[ "$x" -eq 5 ] && converted_arg=$(_day_txt2dec "$valid_cron_arg")
				# End check if the arg behind / or - is not a number or not in the JAN-DEC, SUN-SAT lists
				[ "$(echo "$converted_arg" | tr -d "[:digit:]" | wc -w)" -gt 0 ] && return 1

				if [ "$delimiter" = "/" ]; then
					# Arg behind / must be a number larger than 0 or
					# if arg is of the MONTH or DAY_OF_WEEK fields, must be in JAN-DEC, SUN-SAT lists
					is_arg_valid=true
					# End check if arg behind / is less than 1
					[ "$converted_arg" -lt 1 ] && return 1
				elif [ "$delimiter" = "-" ]; then
					converted_substring="$substring"
					[ "$x" -eq 4 ] && converted_substring=$(_month_txt2dec "$substring")
					[ "$x" -eq 5 ] && converted_substring=$(_day_txt2dec "$substring")
					# End check if arg in front of - is greater than the arg behind -
					[ "$prev_substring" -gt "$converted_substring" ] && return 1
					prev_substring="$converted_substring"
				fi
			fi

			if [ "$is_arg_valid" = true ]; then
				echo "[>] field #$x value [ $substring ] passed"
			else
				echo "[!] field #$x value [ $substring ] failed"
				return 1
			fi
		done
	fi
	return 0
)
}

custom_cron() {
	shift
	echo "[+] validating custom cron expression"
	custom_cron_error=false
	# Has only 1 arg and it starts with @
	if [ "$(echo "$1" | wc -w)" -eq 1 ] && (echo "$1" | grep -q "^@"); then
		# End check if arg is not these accepted @strings (case-sensitive)
		(! echo "$1" | grep -Eqw "^(@reboot|@hourly|@midnight|@daily|@weekly|@monthly|@annually|@yearly)$") && custom_cron_error=true
	# Has 5 args
	elif [ "$(echo "$1" | wc -w)" -eq 5 ]; then
		x=1
		while [ $x -lt 6 ] ; do
			custom_cron_arg=$(echo "$1" | cut -d ' ' -f "$x")
			echo "[>] checking field #$x: [ $custom_cron_arg ]"
			is_arg_valid=false
			_is_valid_cron_arg "$x" "$custom_cron_arg" && is_arg_valid=true
			if [ "$is_arg_valid" = true ]; then
				echo "[+] field #$x passed"
			else
				echo "[!] field #$x failed"
				break
			fi
			x=$((x+1))
		done
		[ "$x" -lt 6 ] && custom_cron_error=true
	else
		custom_cron_error=true
	fi
	# this atleast will catch globbed
	if [ -z "$1" ] || [ ! -z "$2" ] || [ "$custom_cron_error" = true ]; then
		# shoutout to native test and holmes
		echo "[!] futile cronjob" 
		echo "[!] syntax: --custom-cron \"0 2 * * *\" " 
		echo "[!] syntax: --custom-cron \"@hourly\" " 
		exit 1
	fi
	# run crond
	run_crond
	# add entry
	echo "$1 sh $MODDIR/bindhosts.sh --force-update > $PERSISTENT_DIR/bindhosts_cron.log 2>&1 &" | busybox crontab -c $PERSISTENT_DIR/crontabs -
	echo "[>] $(head -n1 $PERSISTENT_DIR/crontabs/root) " 
	echo "[!] make sure entry is correct!"
	echo "[+] crontab entry added!"
}

enable_cron() {
	# run crond
	run_crond
	# add entry
	echo "0 10 * * * sh $MODDIR/bindhosts.sh --force-update > $PERSISTENT_DIR/bindhosts_cron.log 2>&1 &" | busybox crontab -c $PERSISTENT_DIR/crontabs -
	echo "[>] $(head -n1 $PERSISTENT_DIR/crontabs/root) " 
	echo "[+] crontab entry added!"
}

disable_cron() {
	# kill busybox crond that we enabled
	for i in $(busybox pidof busybox); do 
		# super leet gamma knife
		grep -q "bindhosts" "/proc/$i/cmdline" > /dev/null 2>&1 && {
		echo "[x] killing pid $i"
		busybox kill -9 "$i"
		}
	done
	# clean entry
	if grep -q "bindhosts.sh" $PERSISTENT_DIR/crontabs/root > /dev/null 2>&1; then
		rm -rf $PERSISTENT_DIR/crontabs
		echo "[x] crontab entry removed!"
	else
		echo "[x] no crontab entry found!"
	fi
}

toggle_updatejson() {
	if grep -q "^updateJson" $MODDIR/module.prop ; then
		sed -i 's/updateJson/xpdateJson/g' $MODDIR/module.prop 
		echo "[x] module updates disabled!" 
	else
		sed -i 's/xpdateJson/updateJson/g' $MODDIR/module.prop 
		echo "[+] module updates enabled!" 
	fi
}

# probe for downloaders
# wget = low pref, no ssl.
# curl, has ssl on android, we use it if found
# here we chant the https meme.
# https doesn't hide the fact that i'm using https so that's why i don't use encryption 
# because everyone is trying to crack encryption so i just don't use encryption because 
# no one is looking at unencrypted data because everyone wants encrypted data to crack
if curl --version > /dev/null 2>&1; then
	download() { curl --connect-timeout 10 --max-time 30 -Ls "$1"; }
else
	download() { busybox wget -T 10 --no-check-certificate -qO - "$1"; }
fi

# strip CR, leading/trailing whitespace, comments and blank lines,
# then drop entries marked as disabled with the "disabled|" prefix.
# keep this in one place so every rule file behaves identically.
rule_filter() {
	sed 's/\r$//; s/^[[:space:]]*//; s/#.*//; s/[[:space:]]*$//; /^$/d; /^disabled|/d' "$@"
}

# same as rule_filter, but keeps disabled entries (prefix stripped).
# used to know which lines hosts_custom*.txt owns, regardless of enabled state.
rule_filter_all() {
	sed 's/\r$//; s/^[[:space:]]*//; s/#.*//; s/[[:space:]]*$//; s/^disabled|//; /^$/d' "$@"
}

# --- rules_state ---------------------------------------------------------
# hosts=1|0
# proxy=0|1
# missing file falls back to the defaults passed in by the caller.

read_state() {
	state_val=$(grep "^$1=" "$PERSISTENT_DIR/rules_state" 2>/dev/null | head -n 1 | cut -d= -f2)
	echo "${state_val:-$2}"
}

write_state() {
	printf "hosts=%s\nproxy=%s\n" "$1" "$2" > "$PERSISTENT_DIR/rules_state"
}

# --- hashes --------------------------------------------------------------
# crc32 of a rule set, used to decide whether a rebuild is needed.
# file NAMES are part of the hash: renaming x.txt to x.txt.disabled changes no
# file content, so a content-only hash would miss the toggle entirely.

hosts_hash() {
	(
		cd "$PERSISTENT_DIR" 2>/dev/null || exit 0
		ls -1 hosts/*.txt hosts/imported/*.txt hosts/imported/*.txt.disabled 2>/dev/null
		cat hosts/*.txt hosts/imported/*.txt hosts/imported/*.txt.disabled 2>/dev/null
		# hosts lines living in the proxy rule files also shape the hosts file
		grep -hE '^[[:space:]]*[0-9]' proxy/*.txt proxy/imported/*.txt 2>/dev/null
		echo "enabled=$(read_state hosts 1)"
		# The proxy switch decides whether hosts carries the 127.0.0.1 entry,
		# so it must be part of the hash; toggling it alone must rebuild hosts.
		echo "proxy=$(read_state proxy 0)"
		date +%F
	) | busybox crc32
}

proxy_hash() {
	(
		cd "$PERSISTENT_DIR" 2>/dev/null || exit 0
		ls -1 proxy/*.txt proxy/imported/*.txt proxy/imported/*.txt.disabled 2>/dev/null
		cat proxy/*.txt proxy/imported/*.txt proxy/imported/*.txt.disabled 2>/dev/null
		echo "enabled=$(read_state proxy 0)"
		date +%F
	) | busybox crc32
}

# --- proxy rules ---------------------------------------------------------

# hosts lines written inside the proxy rule files, e.g.
#   127.0.0.1 api.example.com
# they are merged into the hosts file, never into the proxy product.
proxy_hosts_lines() {
	(
		cd "$PERSISTENT_DIR" 2>/dev/null || exit 0
		grep -hE '^[[:space:]]*[0-9]' proxy/*.txt proxy/imported/*.txt 2>/dev/null
	) | sed 's/\r$//; s/^[[:space:]]*//; s/#.*//; s/[[:space:]]*$//; /^$/d'
}

# merge order decides priority (first match wins):
#   proxy_custom.txt  ->  imported proxy_custom_*.txt  ->  downloaded proxy_sources
proxy_merge() {
	rule_filter "$PROXY_DIR/custom.txt" 2>/dev/null
	for f in "$PROXY_IMPORTED"/*.txt ; do
		[ -f "$f" ] || continue
		rule_filter "$f"
	done
	[ -s "$rwdir/proxysrc" ] && rule_filter "$rwdir/proxysrc"
	return 0
}

# Keep the proxy entries in hosts in sync with the proxy switch and daemon state.
#
# Idempotent: returns without touching the file when already in sync.
# Hash-independent: whoever rewrote hosts, one reconcile fixes it.
#
# Expected state:
#   proxy on and daemon alive -> every line from proxy_hosts_lines must be present
#   otherwise                 -> none of them may be present
sync_proxy_hosts() {
	_want=$(proxy_hosts_lines)
	_tmp="$PERSISTENT_DIR/.proxysync"

	_on=0
	if [ "$(read_state proxy 0)" = "1" ] && pidof bindhosts-proxy >/dev/null 2>&1 ; then
		_on=1
	fi

	# Count with awk: the script PATH may pick up Termux's GNU grep, whose
	# handling of the -f file argument differs from toybox and never matches.
	_want_n=0
	_have=0
	if [ -n "$_want" ]; then
		printf '%s\n' "$_want" > "$_tmp"
		_want_n=$(awk 'NF { n++ } END { print n+0 }' "$_tmp")
		_have=$(awk '
			NR == FNR { want[$0] = 1; next }
			($0 in want) { n++ }
			END { print n+0 }
		' "$_tmp" "$target_hostsfile")
	fi

	# Already in sync, nothing to do.
	if [ "$_on" = "1" ] && [ "$_have" = "$_want_n" ] ; then
		rm -f "$_tmp"
		return 0
	fi
	if [ "$_on" = "0" ] && [ "$_have" = "0" ] ; then
		rm -f "$_tmp"
		return 0
	fi

	# Out of sync: strip every such line first, then append what is needed.
	if [ -s "$_tmp" ] ; then
		awk 'NR == FNR { want[$0] = 1; next } !($0 in want)' \
			"$_tmp" "$target_hostsfile" > "$_tmp.body"
	else
		cp -f "$target_hostsfile" "$_tmp.body"
	fi
	awk '!/^# bindhosts v/' "$_tmp.body" > "$_tmp.clean"

	{
		cat "$_tmp.clean"
		if [ "$_on" = "1" ] && [ "$_want_n" -gt 0 ] ; then
			printf '%s\n' "$_want"
		fi
		echo "# bindhosts v$versionCode"
	} > "$_tmp.out"

	# Safety valve: losing the localhost lines breaks name resolution system-wide.
	if awk '
		/^127\.0\.0\.1 localhost/ { a = 1 }
		/^::1 localhost/ { b = 1 }
		END { exit !(a && b) }
	' "$_tmp.out" ; then
		# Write in place; replacing the inode breaks Magisk's bind mount here.
		cat "$_tmp.out" > "$target_hostsfile"
		_state=off
		[ "$_on" = "1" ] && _state=on
		echo "[+] proxy entries synced: $_have/$_want_n (proxy $_state)"
	else
		echo "[x] sync skipped: localhost lines missing"
	fi

	rm -f "$_tmp" "$_tmp.body" "$_tmp.clean" "$_tmp.out"
}

# Build the rule product only; never touches the daemon.
# Split out so callers can order things: product -> daemon -> hosts.
build_proxy_product() {
	echo "[+] processing proxy rules"
	rm -f "$rwdir/proxysrc"
	# Only a configured source that failed may fall back to the cache.
	# Emptying sources.txt is not a download failure, so the stale cache
	# must not come back and resurrect rules the user just removed.
	proxy_urls=$(rule_filter "$PROXY_DIR/sources.txt" | grep http)
	proxy_ok=0
	for url in $proxy_urls ; do
		echo "[>] fetching $url"
		if download "$url" >> "$rwdir/proxysrc"; then
			proxy_ok=1
		else
			echo "[x] failed downloading $url"
		fi
	done
	if [ "$proxy_ok" = 1 ]; then
		cp -f "$rwdir/proxysrc" "$PROXY_DIR/cache/sources.txt" 2>/dev/null
	elif [ -n "$proxy_urls" ] && [ -s "$PROXY_DIR/cache/sources.txt" ]; then
		echo "[!] all proxy sources failed, using cache"
		cp -f "$PROXY_DIR/cache/sources.txt" "$rwdir/proxysrc"
	fi

	# keep one rule per path, first one wins; drop hosts lines and junk.
	# warnings go to a side file so they never pollute the product.
	rm -f "$rwdir/proxywarn"
	proxy_merge | awk -v warn="$rwdir/proxywarn" '
		$0 == "" { next }
		# Keep hosts lines in the product: the proxy uses them as its allowed list.
		$1 ~ /^[0-9]/ { print; next }
		$1 !~ /^(mock|forward|block)$/ {
			printf "[!] unknown action, skipped: %s\n", $0 >> warn
			next
		}
		$2 == "" { next }
		{
			if ($2 in seen) {
				printf "[!] conflict on %s, keeping the first rule\n", $2 >> warn
				next
			}
			seen[$2] = 1
			print
		}' > "$PERSISTENT_DIR/proxy.tmp"
	[ -s "$rwdir/proxywarn" ] && cat "$rwdir/proxywarn"
	rm -f "$rwdir/proxywarn"
	mv -f "$PERSISTENT_DIR/proxy.tmp" "$PROXY_PRODUCT"

	rm -f "$rwdir/proxysrc"
	proxy_hash > "$PERSISTENT_DIR/proxy_state"
	echo "[+] proxy rules: $(grep -c . "$PROXY_PRODUCT" 2>/dev/null) entries"
}

# Make sure the proxy is running. The daemon itself is only ever started by
# proxy-daemon.sh; this function is responsible for:
#   1. generating the local CA when missing and installing it into the trust store
#   2. starting the watchdog when it is not alive
#   3. sending SIGHUP to a running daemon when the product was rebuilt ($1=1)
# It does not wait for readiness: the watchdog adds the hosts entries itself.
ensure_proxy_running() {
	_reload="${1:-1}"
	PROXY_BIN="$MODDIR/bin/bindhosts-proxy"
	CERTDIR="$PROXY_DIR/certs"

	[ -x "$PROXY_BIN" ] || { echo "[x] proxy binary missing: $PROXY_BIN" ; return 1 ; }

	# Enabling at runtime skips boot-time CA generation, so do it here.
	if [ ! -f "$CERTDIR/ca.crt" ] || [ ! -f "$CERTDIR/ca.key" ] ; then
		echo "[+] generating local CA"
		mkdir -p "$CERTDIR"
		"$PROXY_BIN" -genca "$CERTDIR" >/dev/null 2>&1
	fi
	# Install the CA if it is not in the trust store yet.
	CAFILE=$(ls "$CERTDIR"/*.0 2>/dev/null | head -1)
	if [ -n "$CAFILE" ] && [ ! -f "/system/etc/security/cacerts/$(basename "$CAFILE")" ] ; then
		echo "[+] installing CA into trust store"
		sh "$MODDIR/proxy-cert.sh" >/dev/null 2>&1
	fi

	# Start the watchdog if absent; it owns the daemon process.
	if ! watchdog_alive ; then
		echo "[+] starting proxy watchdog"
		setsid sh "$MODDIR/proxy-daemon.sh" >/dev/null 2>&1 < /dev/null &
		return 0
	fi

	# Watchdog and daemon are both up; make the daemon reload if rules changed.
	if pidof bindhosts-proxy >/dev/null 2>&1 ; then
		if [ "$_reload" = "1" ] ; then
			echo "[+] reloading proxy rules"
			for _pid in $(pidof bindhosts-proxy) ; do
				kill -HUP "$_pid" 2>/dev/null
			done
		else
			echo "[+] proxy: daemon already running"
		fi
	fi
	return 0
}

# Watchdog liveness via its pid file, avoiding pgrep/ps.
watchdog_alive() {
	_wd=$(cat "$PERSISTENT_DIR/proxy-daemon.pid" 2>/dev/null)
	[ -n "$_wd" ] && kill -0 "$_wd" 2>/dev/null
}

# Compatibility wrapper: product and daemon in one call.
run_proxy() {
	build_proxy_product
	ensure_proxy_running
}

# rebuild hosts from custom rules only, while keeping previously downloaded entries.
# used when sources are unusable (hosts_sources.txt empty, or every download failed),
# so that toggling a custom rule still takes effect offline.
fallback_to_custom() {
	echo "[+] falling back to custom rules only (keeping existing entries)"
	rm -f "$rwdir/temphosts" "$rwdir/customlist"
	if [ -f "$target_hostsfile" ]; then
		# strip the two localhost lines and the version marker
		tail -n +3 "$target_hostsfile" | grep -v "^# bindhosts v" > "$rwdir/temphosts"
	fi
	# drop anything hosts_custom*.txt is responsible for, so a disabled rule does not
	# come back from the old hosts file
	if [ -s "$rwdir/temphosts" ]; then
		rule_filter_all "$HOSTS_DIR/custom.txt" "$HOSTS_IMPORTED"/*.txt "$HOSTS_IMPORTED"/*.txt.disabled > "$rwdir/customlist" 2>/dev/null
		if [ -s "$rwdir/customlist" ]; then
			grep -vxFf "$rwdir/customlist" "$rwdir/temphosts" > "$rwdir/temphosts.new"
			mv -f "$rwdir/temphosts.new" "$rwdir/temphosts"
		fi
		rm -f "$rwdir/customlist"
	fi
	printf "127.0.0.1 localhost\n::1 localhost\n" > "$target_hostsfile"
	rule_filter "$HOSTS_DIR/custom.txt" "$HOSTS_IMPORTED"/*.txt >> "$target_hostsfile" 2>/dev/null
	[ -s "$rwdir/temphosts" ] && sort -u "$rwdir/temphosts" >> "$target_hostsfile"
	rm -f "$rwdir/temphosts"
	echo "# bindhosts v$versionCode" >> "$target_hostsfile"
}

adblock() {
	illusion
	# source processing start!
	echo "[+] processing sources"
	sources=$(rule_filter $HOSTS_DIR/sources.txt | grep http)
	if [ -z "$sources" ]; then
		echo "[x] no sources found 😭"
		echo "[x] hosts_sources.txt needs correction 💢"
		fallback_to_custom
		return
	fi

	# download routine start!
	successful_downloads=0
	total_downloads=0
	for url in $sources ; do
		total_downloads=$((total_downloads + 1))
		echo "[>] fetching $url"
		if download "$url" >> "$rwdir/temphosts"; then
			successful_downloads=$((successful_downloads + 1))
			echo "" >> "$rwdir/temphosts"
		else
			echo "[x] failed downloading $url"
		fi
	done

	# Cache a successful download so an offline run can rebuild from it.
	if [ "$successful_downloads" -gt 0 ]; then
		cp -f "$rwdir/temphosts" "$HOSTS_DIR/cache/sources.txt" 2>/dev/null
	fi

	# if all downloads failed we are probably offline
	if [ "$successful_downloads" -eq 0 ] && [ "$total_downloads" -gt 0 ]; then
		if [ -s "$HOSTS_DIR/cache/sources.txt" ]; then
			echo "[!] all downloads failed, falling back to cached sources"
			cp -f "$HOSTS_DIR/cache/sources.txt" "$rwdir/temphosts"
		else
			echo "[!] all downloads failed, aborting update."
			echo "[!] keeping existing entries and applying custom rules."
			fallback_to_custom
			return
		fi
	fi

	# if temphosts is empty (can happen if sources were valid but returned no content)
	[ ! -s "$rwdir/temphosts" ] && {
		echo "[!] downloaded hosts content is empty"
		echo "[!] using old hosts file!"
		# strip first two lines since thats just localhost
		tail -n +3 $target_hostsfile > "$rwdir/temphosts"
		}
	# localhost
	printf "127.0.0.1 localhost\n::1 localhost\n" > $target_hostsfile
	# always restore user's custom rules
	rule_filter "$HOSTS_DIR/custom.txt" "$HOSTS_IMPORTED"/*.txt >> $target_hostsfile 2>/dev/null
	# hosts_blacklist.txt
	for i in $(rule_filter $HOSTS_DIR/blacklist.txt); do echo "0.0.0.0 $i" >> "$rwdir/temphosts"; done
	# hosts_whitelist.txt
	echo "[+] processing whitelist"
	# make sure tempwhitelist isnt empty
	# or it will grep out nothingness from everything
	# which actually greps out everything.
	echo "256.256.256.256 bindhosts" > "$rwdir/tempwhitelist"
	for url in $(rule_filter $HOSTS_DIR/sources_whitelist.txt | grep http) ; do
		echo "[>] fetching $url"
		download "$url" >> "$rwdir/remote_whitelist" || echo "[x] failed downloading $url"
	done
	# if there is a remote whitelist, we clean it up
	if [ -f "$rwdir/remote_whitelist" ]; then
		sed -i 's/#.*//; /!/d; s/  */ /g; /^$/d; s/\r$//' "$rwdir/remote_whitelist"
		for i in $(sort -u "$rwdir/remote_whitelist" ); do echo "$i" ; done >> "$rwdir/tempwhitelist"
	fi
	for i in $(rule_filter $HOSTS_DIR/whitelist.txt); do echo "$i" ; done >> "$rwdir/tempwhitelist"
	# sed strip out everything with # and !, double space to single space, delete empty lines, dos2unix (CRLF), replace all 127.0.0.1 to 0.0.0.0
	# then sort uniq, then grep out hosts_whitelist.txt from it
	sed -i 's/#.*//; /!/d; s/  */ /g; /^$/d; s/\r$//; s/127.0.0.1/0.0.0.0/g' "$rwdir/temphosts"
	# no need to -x on grep, allow wildmatches! bindhosts/issue #112
	sort -u "$rwdir/temphosts" | grep -Fvf "$rwdir/tempwhitelist" >> $target_hostsfile
	# mark it, will be read by service.sh to deduce
	echo "# bindhosts v$versionCode" >> $target_hostsfile
}

reset() {
	echo "[+] reset toggled!" 
	# localhost
	printf "127.0.0.1 localhost\n::1 localhost\n" > $target_hostsfile
	# always restore user's custom rules
	rule_filter "$HOSTS_DIR/custom.txt" "$HOSTS_IMPORTED"/*.txt >> $target_hostsfile 2>/dev/null
	sync_proxy_hosts
        string="description=status: reset 🤐 | $(date)"
        sed -i "s/^description=.*/$string/g" $MODDIR/module.prop
        echo "[+] hosts file reset!"
        # reset state
        rm $PERSISTENT_DIR/bindhosts_state > /dev/null 2>&1
}

run_hosts() {
	if [ "$(read_state hosts 1)" = "1" ]; then
		adblock
	else
		echo "[+] hosts disabled, writing localhost only"
		printf "127.0.0.1 localhost\n::1 localhost\n" > "$target_hostsfile"
		echo "# bindhosts v$versionCode" >> "$target_hostsfile"
	fi
	# proxy hosts lines follow the proxy switch, not the hosts switch
	sync_proxy_hosts
	# store these as variables
	# this way we dont do the grepping twice
	custom=$( grep -vEc "0.0.0.0| localhost|#" "$target_hostsfile")
	blocked=$(grep -c "0.0.0.0" "$target_hostsfile" )
	# now use them
	echo "[+] blocked: $blocked | custom: $custom "
	if [ "$(read_state hosts 1)" = "1" ]; then
		string="description=status: active ✅ | blocked: $blocked 🚫 | custom: $custom 🤖 $helper_mode"
	else
		string="description=status: hosts off 💤 | blocked: $blocked 🚫 | custom: $custom 🤖 $helper_mode"
	fi
	sed -i "s/^description=.*/$string/g" $MODDIR/module.prop
	# ready for reset again
	hosts_hash > $PERSISTENT_DIR/bindhosts_state
	# cleanup
	rm -f "$rwdir/remote_whitelist" "$rwdir/temphosts" "$rwdir/tempwhitelist" "$PERSISTENT_DIR/bindhosts_backup" > /dev/null 2>&1
}

run() {
	# Same order as action(): bring the proxy up before writing hosts.
	if [ "$(read_state proxy 0)" = "1" ]; then
		run_proxy
	else
		# Same as action(): empty the product, keep the file.
		: > "$PROXY_PRODUCT"
	fi
	run_hosts
	return 0
}

# adaway is installed and hosts are modified by adaway, dont overthrow
pm path org.adaway > /dev/null 2>&1 && grep -q "generated by AdAway" /system/etc/hosts && {
	# adaway coex
	string="description=status: active ✅ | 🛑 AdAway 🕊️"
	sed -i "s/^description=.*/$string/g" $MODDIR/module.prop
	echo "[*] 🚨 hosts modified by Adaway 🛑"
	echo "[*] assuming coexistence operation"
	echo "[*] please reset hosts in Adaway before continuing"
	case "$1" in
		--query|--toggle-updatejson|--setup-link) true ;;
		*) return ;;
	esac
}

quick_reset_restore () {
	if [ -f $PERSISTENT_DIR/bindhosts_backup ]; then
		# force an update if bindhosts_backup == target_hostsfile
		# this can happen when hosts file got updated to blank
		# and user will just be reset/restoring hosts with a blank file
		if [ "$(busybox head -n -1 $PERSISTENT_DIR/bindhosts_backup | busybox crc32 )" = "$(cat $target_hostsfile | busybox crc32 )" ]; then
			run
			rm -rf $rwdir/bindhosts_lockfile $PERSISTENT_DIR/bindhosts_backup > /dev/null 2>&1
			exit 0
		fi
		echo "[+] restoring backed up hosts file!"
		cat $PERSISTENT_DIR/bindhosts_backup > $target_hostsfile
		rm $PERSISTENT_DIR/bindhosts_backup
		sync_proxy_hosts
		# store these as variables
		# this way we dont do the grepping twice
		custom=$( grep -vEc "0.0.0.0| localhost|#" $target_hostsfile)
		blocked=$(grep -c "0.0.0.0" $target_hostsfile )
		# now use them
		echo "[+] blocked: $blocked | custom: $custom "
		string="description=status: active ✅ | blocked: $blocked 🚫 | custom: $custom 🤖 $helper_mode"
	else
		echo "[+] backing up hosts file!"
		cat $target_hostsfile > $PERSISTENT_DIR/bindhosts_backup
		echo "[+] quick reset toggled!" 
		# localhost
		printf "127.0.0.1 localhost\n::1 localhost\n" > $target_hostsfile
		# always restore user's custom rules
		rule_filter "$HOSTS_DIR/custom.txt" "$HOSTS_IMPORTED"/*.txt >> $target_hostsfile 2>/dev/null
		sync_proxy_hosts
		string="description=status: reset 🤐 | $(date)"
		echo "[+] hosts file reset!"
	fi
	sed -i "s/^description=.*/$string/g" $MODDIR/module.prop
}

action () {
	# single instance lock
	# as the script sometimes takes some time processing
	# we implement a simple lockfile logic around here to
	# prevent multiple instances.
	# if the file is there and pid is still up then thats shady
	if [ -f "$rwdir/bindhosts_lockfile" ]; then
		bindhosts_old_pid=$(cat $rwdir/bindhosts_lockfile)
		# now check and fucking kill old instance
		if [ -d "/proc/$bindhosts_old_pid" ] && grep -q "bindhosts" "/proc/$bindhosts_old_pid/cmdline" >/dev/null 2>&1; then
			echo "[*] bindhosts with pid: $bindhosts_old_pid is still running!"
			busybox kill -9 $bindhosts_old_pid
			echo "[*] killing $bindhosts_old_pid"
			rm "$rwdir/bindhosts_lockfile" >/dev/null 2>&1
			exit 1
		fi
	fi
	# now make sure its not there and write our own pid to it
	rm "$rwdir/bindhosts_lockfile" >/dev/null 2>&1 ; echo $$ > "$rwdir/bindhosts_lockfile"


	h_state=$(read_state hosts 1)
	p_state=$(read_state proxy 0)
	[ -n "$arg_hosts" ] && h_state="$arg_hosts"
	[ -n "$arg_proxy" ] && p_state="$arg_proxy"
	write_state "$h_state" "$p_state"
	echo "[*] state: hosts=$h_state proxy=$p_state"

	# The proxy block must run before the hosts block.
	# Order: product -> daemon -> hosts. The proxy has to be ready before the
	# domain starts pointing at 127.0.0.1. Done the other way round, the app hits
	# a dead port between the hosts write and the daemon bind, and stays offline
	# for good if the daemon never comes up.
	if [ "$p_state" = "1" ]; then
		if [ "$(cat "$PERSISTENT_DIR/proxy_state" 2>/dev/null)" != "$(proxy_hash)" ] \
			|| [ ! -s "$PROXY_PRODUCT" ] ; then
			echo "[+] proxy: rule or state changed, applying"
			build_proxy_product
			ensure_proxy_running 1 || echo "[x] proxy unavailable, hosts entry will be skipped"
		else
			echo "[+] proxy: no change"
			ensure_proxy_running 0 || echo "[x] proxy unavailable, hosts entry will be skipped"
		fi
	else
		# Switching off stops the daemon at once and releases 127.0.0.1:443.
		if pidof bindhosts-proxy >/dev/null 2>&1 ; then
			echo "[+] proxy: disabled, stopping daemon"
			pkill -f bindhosts-proxy 2>/dev/null
		else
			echo "[+] proxy: disabled"
		fi
		# Empty the product instead of deleting it, same as the hosts file:
		# disabled means no rules, not a missing file.
		: > "$PROXY_PRODUCT"
	fi

	# hosts block
	if [ "$(cat "$PERSISTENT_DIR/bindhosts_state" 2>/dev/null)" != "$(hosts_hash)" ]; then
		echo "[+] hosts: rule or state changed, applying"
		run_hosts
	else
		echo "[+] hosts: no change"
	fi

	# Reconcile the proxy entries regardless of whether hosts was rebuilt.
	# run_hosts calls this too, but it is skipped entirely when the hash is
	# unchanged, which would leave missing entries unrepaired forever.
	sync_proxy_hosts

	# cleanup lockfile
	[ -f "$rwdir/bindhosts_lockfile" ] && rm "$rwdir/bindhosts_lockfile" > /dev/null 2>&1
}

tcpdump () {
	if command -v tcpdump > /dev/null 2>&1; then
		# reset hosts
		[ ! -f $PERSISTENT_DIR/bindhosts_backup ] && quick_reset_restore || reset
		echo "[+] restore hosts as needed"
		echo "[+] make sure private dns is disabled!"
		echo "[+] spawning tcpdump"
		echo "[!] press ctrl+c to exit"
		sh -c "tcpdump -ltni any dst port 53"
	else
		echo "[!] tcpdump not found"
		echo "[x] bailing out"
		exit 1
	fi
}

stop_tcpdump() {
	for i in $(busybox pidof tcpdump); do
		kill $i
	done
	[ -f $PERSISTENT_DIR/bindhosts_backup ] && quick_reset_restore
}

hosts_lastmod () {
	echo "[+] Last update at: $(date -r $target_hostsfile)"
}

hosts_query () {
	shift
	if [ -z "$1" ]; then 
		echo "[!] empty query"
		echo "[!] example usage: bindhosts --query doubleclick.net"
		return
	fi
	printf "Hosts \tDomain\n"
	grep "$1" "$target_hostsfile" || echo "[!] no match found"
}

instant_whitelist() {
	# Backend for WebUI: whitelist domain instantly without re-run action
	shift
	[ -n "$1" ] || return
	cp $target_hostsfile $rwdir/temphosts
	sed "/0.0.0.0 $1/d" $rwdir/temphosts > $target_hostsfile
	grep -qx "$1" "$HOSTS_DIR/whitelist.txt" || echo "$1" >> "$HOSTS_DIR/whitelist.txt"
	rm $rwdir/temphosts
}

setup_link() {
	# Backend for WebUI: locate target hosts file for querying and file fetching
	rm -rf $MODDIR/webroot/link
	mkdir $MODDIR/webroot/link
	ln -sf "$target_hostsfile" "$MODDIR/webroot/link/hosts.txt"
	ln -s "$MODDIR" "$MODDIR/webroot/link/MODDIR"
	ln -s "$PERSISTENT_DIR" "$MODDIR/webroot/link/PERSISTENT_DIR"
}

manager_install_zip() {
	# sanity check	
	if [ -z "$1" ] || [ ! -f "$1" ] || [ ! -f "$PERSISTENT_DIR/root_manager.sh" ]; then 
		echo "[!] no manager logged, nothing specified or file not found"
		return
	fi
	# webui flag
	[ -n "$KSU_WEBUI" ] && touch "$PERSISTENT_DIR/bindhosts_webui"
	# read which manager
	. "$PERSISTENT_DIR/root_manager.sh"
	case $manager in
		APatch) 
			echo "[+] installing via apd" 
			apd module install "$1" 
			;;
		KernelSU) 
			echo "[+] installing via ksud" 
			ksud module install "$1" 
			;;
		Magisk) 
			echo "[+] installing via magisk" 
			magisk --install-module "$1" 
			;;
		*) # catch invalid
			echo "[!] root manager unknown??"
			exit 1
			;;
	esac
	# cleanup
	rm -f "$PERSISTENT_DIR/bindhosts_webui"
}

update_locales() {
	link1="https://raw.githubusercontent.com/bindhosts/bindhosts/bot/locales.zip"
	link2="https://gh.sevencdn.com/$link1"
	error=0
	echo "[+] downloading: $link1"
	download "$link1" > "$rwdir/locales.zip" || download "$link2" > "$rwdir/locales.zip"
	[ -s "$rwdir/locales.zip" ] || error=1
	unzip -o "$rwdir/locales.zip" -d "$MODDIR/webroot/locales" || error=1
	rm -f "$rwdir/locales.zip"
	[ "$error" -eq 0 ] || exit 1
}

install_latest_artifact() {
	# likely won't happen but lets be defensive
	if [ ! -f "$PERSISTENT_DIR/root_manager.sh" ]; then
		echo "[!] root manager not detected"
		exit 1
	fi

	# via nightly.link
	latest_zip_url=$(download "https://nightly.link/bindhosts/bindhosts/workflows/release/master?preview" | sed 's/>/\n/g; s/</\n/g' | busybox grep -E "^https.*\.zip$" | head -n1)
	latest_zip_local="$rwdir/bindhosts_latest.zip"

	# download
	if echo "$latest_zip_url" | grep -q "^https"; then
		echo "[+] downloading: $latest_zip_url "
		download "$latest_zip_url" > "$latest_zip_local"
		# check if empty
		if [ ! -s "$latest_zip_local" ]; then
			echo "[!] artifact download failed or file is empty"
			rm "$latest_zip_local"
			exit 1
		fi
	else
		echo "[!] failure grabbing latest artifact" 
		exit 1
	fi

	# install
	if [ -f "$latest_zip_local" ] ; then
		echo "[+] zip: $latest_zip_local" 
		manager_install_zip "$latest_zip_local"
		update_locales || true
	else
		echo "[x] artifact download fail"
		exit 1
	fi
	[ -f "$latest_zip_local" ] && rm "$latest_zip_local"
}

show_help () {
	echo "[%] $( grep '^description=' $MODDIR/module.prop | sed 's/description=//' )"
	echo "usage:"
	printf " --action \t\tsimulate action.sh\n"
	printf " --tcpdump \t\tsniff dns requests via tcpdump\n"
	printf " --query <URL> \t\tcheck hosts file for pattern\n"
	printf " --force-update \tforce an update\n" 
	printf " --force-reset \t\tforce a reset\n"
	printf " --custom-cron \t\tcustom update schedule\n"
	printf "\t\t\tif you do NOT know this, use --enable-cron\n"
	printf " --enable-cron \t\tenables scheduled updates (10AM daily)\n"
	printf " --disable-cron \tdisables scheduled updates\n"
	printf " --help \t\tdisplays this message\n"
}

# add arguments
case "$1" in 
	# Reconcile only the proxy entries in hosts: no rebuild, no source download.
	# Used by the watchdog after the daemon starts, exits, or gives up.
	--sync-proxy)
		sync_proxy_hosts
		exit 0
		;;
	--action)
		shift
		while [ $# -gt 0 ]; do
			case "$1" in
				--hosts) arg_hosts="$2"; shift 2 ;;
				--proxy) arg_proxy="$2"; shift 2 ;;
				*) shift ;;
			esac
		done
		action
		exit ;;
	--tcpdump) tcpdump; exit ;;
	--stop-tcpdump) stop_tcpdump; exit ;;
	--query) hosts_query "$@"; exit ;;
	--force-update) run; exit ;;
	--force-reset) reset; exit ;;
	--custom-cron) custom_cron "$@"; exit ;;
	--enable-cron) enable_cron; exit ;;
	--disable-cron) disable_cron; exit ;;
	--toggle-updatejson) toggle_updatejson; exit ;;
	--hosts-lastmod) hosts_lastmod; exit ;;
	--whitelist) instant_whitelist "$@"; exit ;;
	--install-canary) install_latest_artifact; exit;;
	--update-locales) update_locales; exit;;
	--setup-link) setup_link; exit;;
	--help|*) show_help; exit ;;
esac

# EOF
