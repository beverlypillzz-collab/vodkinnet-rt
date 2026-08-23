#!/bin/sh
# netcraze-remote — удаление агента с Keenetic/KNDMS.
# PURGE=1 sh uninstall.sh  — удалить также конфиг с секретами.

set -eu
C_GREEN='\033[0;32m'; C_NC='\033[0m'
ok() { printf '%b[+]%b %s\n' "$C_GREEN" "$C_NC" "$*"; }

[ -x /opt/sbin/netcraze-remote ] && /opt/sbin/netcraze-remote stop || true

# VodkinNET: убираем watchdog из cron ДО удаления самого файла — иначе
# следующий тик cron будет пытаться запустить уже несуществующий бинарник
# и молча логировать ошибку каждую минуту.
if [ -f /opt/etc/crontabs/root ] && grep -q "netcraze-remote-watchdog" /opt/etc/crontabs/root 2>/dev/null; then
	sed -i '/netcraze-remote-watchdog/d' /opt/etc/crontabs/root
	CRON_INITD="$(find /opt/etc/init.d -maxdepth 1 -name 'S*cron*' 2>/dev/null | head -n1 || true)"
	[ -n "$CRON_INITD" ] && [ -x "$CRON_INITD" ] && "$CRON_INITD" restart >/dev/null 2>&1 || true
fi

rm -f /opt/etc/init.d/S99netcraze-remote
rm -f /opt/etc/init.d/S99netcraze-remote.bak
rm -f /opt/sbin/netcraze-remote
rm -f /opt/sbin/netcraze-remote.bak
rm -f /opt/sbin/netcraze-remote-watchdog
rm -f /opt/etc/netcraze-remote/update-pending
rm -f /opt/var/log/netcraze-remote-rollback.log
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
