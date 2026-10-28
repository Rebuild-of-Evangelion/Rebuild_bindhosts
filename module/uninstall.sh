#!/bin/sh
# Stop the proxy watchdog first, or it keeps holding 127.0.0.1:443.
pkill -f bindhosts-proxy 2>/dev/null
for _p in $(pidof sh); do
	tr '\0' ' ' < /proc/$_p/cmdline 2>/dev/null | grep -q "proxy-daemon[.]sh" && kill $_p 2>/dev/null
done

# delete settings
rm -rf /data/adb/bindhosts
# delete symlink, ap/ksu
rm /data/adb/ap/bin/bindhosts 
rm /data/adb/ksu/bin/bindhosts
# cleanup for helper modes
# hfr
[ -f /data/adb/hosts ] && printf "127.0.0.1 localhost\n::1 localhost\n" > /data/adb/hosts
# znhr
[ -f /data/adb/hostsredirect/hosts ] && printf "127.0.0.1 localhost\n::1 localhost\n" > /data/adb/hostsredirect/hosts

# uninstall bindhosts app if installed
pm path "$APP_PACKAGE" > /dev/null 2>&1 && pm uninstall me.itejo443.bindhosts

# EOF
