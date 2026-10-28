#!/bin/sh
PATH=/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH
SUSFS_BIN=/data/adb/ksu/bin/ksu_susfs
. $MODPATH/utils.sh
PERSISTENT_DIR=/data/adb/bindhosts

export MODULE_HOT_INSTALL_REQUEST="true"
export MODULE_HOT_RUN_SCRIPT="hotinstall.sh"

# grab own info (version)
versionCode=$(grep versionCode "$MODPATH/module.prop" | sed 's/versionCode=//g' )

echo "[+] bindhosts v$versionCode "
echo "[%] customize.sh "

# Function to detect key press (Volume Up or Volume Down) or timeout
detect_key_press() {
    timeout_seconds=6  # Modify this to change the wait time

    # Read input with timeout using a pipe and capture the exit code
    read -r -t $timeout_seconds line < <(getevent -ql | awk '/KEY_VOLUME/ {print; exit}')

    # Check if input was read or timed out
    if [ $? -eq 142 ]; then  # Timeout exit code
        echo "[!] No key pressed within $timeout_seconds seconds. Skipping installation..."
        return 1
    fi

    # Process key press based on the detected input
    if echo "$line" | grep -q "KEY_VOLUMEUP"; then
        return 0  # Installing Bindhosts-app
    else
        echo "[+] Skipping installation..."
        return 1
    fi
}

# Installation prompt if bindhosts app is not installed
pm path me.itejo443.bindhosts > /dev/null 2>&1 || [ -f "$PERSISTENT_DIR/bindhosts_webui" ] || {
    # Install App Section
    echo "[+] BindHosts-app, Ref:github.com/itejo443/BindHosts-app"
    echo "[?] Do you want to install BindHosts-app"
    echo "[?] VOL [+]: YES"
    echo "[?] VOL [-]: NO"
    if detect_key_press; then
        echo "[+] Installing BindHosts-app..."
	busybox chmod +x "$MODPATH/bindhosts-app.sh"
# proxy: daemon binary and watchdog script
[ -f "$MODPATH/bin/bindhosts-proxy" ] && busybox chmod +x "$MODPATH/bin/bindhosts-proxy"
# Backup: the watchdog restores the main binary from here if it breaks.
[ -f "$MODPATH/bin/bindhosts-proxy.bak" ] && busybox chmod +x "$MODPATH/bin/bindhosts-proxy.bak"
[ -f "$MODPATH/proxy-cert.sh" ] && busybox chmod +x "$MODPATH/proxy-cert.sh"
[ -f "$MODPATH/proxy-daemon.sh" ] && busybox chmod +x "$MODPATH/proxy-daemon.sh"
        sh "$MODPATH/bindhosts-app.sh"
    fi
}

# persistence
[ ! -d $PERSISTENT_DIR ] && mkdir -p $PERSISTENT_DIR
# make our hosts file dir
mkdir -p "$MODPATH/system/etc"

# set permissions to bindhosts.sh
busybox chmod +x "$MODPATH/bindhosts.sh"
busybox chmod +x "$MODPATH/bindhosts-app.sh"
# proxy: daemon binary and watchdog script
[ -f "$MODPATH/bin/bindhosts-proxy" ] && busybox chmod +x "$MODPATH/bin/bindhosts-proxy"
# Backup: the watchdog restores the main binary from here if it breaks.
[ -f "$MODPATH/bin/bindhosts-proxy.bak" ] && busybox chmod +x "$MODPATH/bin/bindhosts-proxy.bak"
[ -f "$MODPATH/proxy-cert.sh" ] && busybox chmod +x "$MODPATH/proxy-cert.sh"
[ -f "$MODPATH/proxy-daemon.sh" ] && busybox chmod +x "$MODPATH/proxy-daemon.sh"
# symlink bindhosts to manager path
# for ez termux usage
manager_paths="/data/adb/ap/bin /data/adb/ksu/bin"
for i in $manager_paths; do
	if [ -d "$i" ]; then
		echo "[+] creating symlink in $i"
		ln -sf /data/adb/modules/bindhosts/bindhosts.sh "$i/bindhosts"
	fi
done

# check for other systemless hosts modules and disable them
disable_hosts_modules_verbose=1
disable_hosts_modules

# warn about highly breaking modules
# just warn and tell user to uninstall it
# we would still proceed to install
# lets make the user wait for say 5 seconds
bad_module="HideMyRoot"
for i in $bad_module; do
	if [ -d "/data/adb/modules/$i" ] ; then
		echo "[!] 🚨 possible confliciting module found!"
		echo "[!] ⚠️ $i "
		echo "[!] 📢 uninstall for a flawless operation"
		echo "[!] ‼️ you have been warned"
		sleep 5
	fi
done

# copy our old hosts file
if [ -f /data/adb/modules/bindhosts/system/etc/hosts ] ; then
	echo "[+] migrating hosts file "
	cat /data/adb/modules/bindhosts/system/etc/hosts > "$MODPATH/system/etc/hosts"
fi

# normal flow for persistence
# move over our files, remove after

# Rule files are grouped by type.
mkdir -p "$PERSISTENT_DIR/hosts/imported" "$PERSISTENT_DIR/hosts/cache"
mkdir -p "$PERSISTENT_DIR/proxy/imported" "$PERSISTENT_DIR/proxy/cache"

# Migrate flat fixed rule files from older builds into hosts/.
for i in custom blacklist whitelist sources sources_whitelist ; do
	# Oldest layout used custom.txt.
	if [ -f "$PERSISTENT_DIR/$i.txt" ] && [ ! -f "$PERSISTENT_DIR/hosts/$i.txt" ] ; then
		mv -f "$PERSISTENT_DIR/$i.txt" "$PERSISTENT_DIR/hosts/$i.txt"
		echo "[+] migrated $i.txt -> hosts/$i.txt"
	fi
	# Intermediate builds used the hosts_ prefix.
	if [ -f "$PERSISTENT_DIR/hosts_$i.txt" ] && [ ! -f "$PERSISTENT_DIR/hosts/$i.txt" ] ; then
		mv -f "$PERSISTENT_DIR/hosts_$i.txt" "$PERSISTENT_DIR/hosts/$i.txt"
		echo "[+] migrated hosts_$i.txt -> hosts/$i.txt"
	fi
done

# Migrate imported rule files into hosts/imported/, stripping legacy prefixes.
for f in "$PERSISTENT_DIR"/custom_*.txt* "$PERSISTENT_DIR"/hosts_custom_*.txt* ; do
	[ -f "$f" ] || continue
	base="${f##*/}"
	name="${base#hosts_custom_}"
	[ "$name" = "$base" ] && name="${base#custom_}"
	if [ ! -f "$PERSISTENT_DIR/hosts/imported/$name" ] ; then
		mv -f "$f" "$PERSISTENT_DIR/hosts/imported/$name"
		echo "[+] migrated $base -> hosts/imported/$name"
	fi
done

# Default rule files: flat in the module root, copied to the persistent dir then removed.
for i in custom blacklist whitelist sources sources_whitelist ; do
	[ -f "$PERSISTENT_DIR/hosts/$i.txt" ] || cat "$MODPATH/$i.txt" > "$PERSISTENT_DIR/hosts/$i.txt"
	rm -f "$MODPATH/$i.txt"
done

[ -f "$PERSISTENT_DIR/proxy/custom.txt" ] || cat "$MODPATH/proxy_custom.txt" > "$PERSISTENT_DIR/proxy/custom.txt"
[ -f "$PERSISTENT_DIR/proxy/sources.txt" ] || cat "$MODPATH/proxy_sources.txt" > "$PERSISTENT_DIR/proxy/sources.txt"
rm -f "$MODPATH/proxy_custom.txt" "$MODPATH/proxy_sources.txt"

# webui custom css config
if [ ! -d "$PERSISTENT_DIR/.webui_config" ] || [ ! -f "$PERSISTENT_DIR/.webui_config/custom.css" ]; then
	mkdir -p "$PERSISTENT_DIR/.webui_config"
	mv "$MODPATH/custom.css" "$PERSISTENT_DIR/.webui_config/custom.css"
else
	rm "$MODPATH/custom.css"
fi

# if hosts file empty or just comments
# just copy real hosts file over
grep -qv "#" "$MODPATH/system/etc/hosts" > /dev/null 2>&1 || {
	echo "[+] creating hosts file"
	cat /system/etc/hosts > "$MODPATH/system/etc/hosts"
	printf "127.0.0.1 localhost\n::1 localhost\n" >> "$MODPATH/system/etc/hosts"
}

# set permissions always
hosts_set_perm "$MODPATH/system/etc/hosts"

# EOF
