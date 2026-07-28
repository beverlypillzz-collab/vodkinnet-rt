#!/bin/sh
# netcraze-remote — удаление агента с Keenetic/KNDMS.
# PURGE=1 sh uninstall.sh  — удалить также конфиг с секретами.

set -eu
C_GREEN='\033[0;32m'; C_NC='\033[0m'
ok() { printf '%b[+]%b %s\n' "$C_GREEN" "$C_NC" "$*"; }

[ -x /opt/sbin/netcraze-remote ] && /opt/sbin/netcraze-remote stop || true

rm -f /opt/etc/init.d/S99netcraze-remote
rm -f /opt/sbin/netcraze-remote
rm -f /opt/etc/netcraze-remote/xray-client.json
rm -rf /opt/var/run/netcraze-remote
rm -f /opt/var/log/netcraze-remote.log

if [ "${PURGE:-0}" = "1" ]; then
	rm -rf /opt/etc/netcraze-remote
	ok "конфиг тоже удалён (PURGE=1)"
else
	ok "конфиг оставлен: /opt/etc/netcraze-remote/netcraze-remote.conf (PURGE=1 чтобы удалить и его)"
fi

ok "netcraze-remote удалён с этого устройства"
