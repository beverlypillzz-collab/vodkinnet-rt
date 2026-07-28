#!/bin/sh
# netcraze-remote — удаление Hub с VPS.
# PURGE=0 sh uninstall-vps.sh        — оставить базу роутеров (/var/lib/netcraze-remote)
# REMOVE_XRAY=1 sh uninstall-vps.sh  — удалить и бинарь netcraze-remote-xray
# REMOVE_USER=1 sh uninstall-vps.sh  — удалить системного пользователя netcraze-remote

set -eu
PURGE="${PURGE:-1}"
REMOVE_XRAY="${REMOVE_XRAY:-0}"
REMOVE_USER="${REMOVE_USER:-0}"

systemctl stop netcraze-remote-hub 2>/dev/null || true
systemctl stop netcraze-remote-xray 2>/dev/null || true
systemctl disable netcraze-remote-hub 2>/dev/null || true
systemctl disable netcraze-remote-xray 2>/dev/null || true

rm -f /etc/systemd/system/netcraze-remote-hub.service
rm -f /etc/systemd/system/netcraze-remote-xray.service
systemctl daemon-reload

rm -rf /opt/netcraze-remote
rm -f /etc/netcraze-remote/xray.json
rm -f /etc/netcraze-remote/hub.env
rm -f /etc/netcraze-remote/cert-domain
rmdir /etc/netcraze-remote 2>/dev/null || true

rm -f /etc/sudoers.d/netcraze-remote
rm -f /etc/letsencrypt/renewal-hooks/deploy/netcraze-remote.sh

rm -f /etc/nginx/sites-enabled/netcraze-remote
rm -f /etc/nginx/sites-available/netcraze-remote
nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true

if [ "$PURGE" = "1" ]; then
	rm -rf /var/lib/netcraze-remote
	echo "[+] база роутеров тоже удалена (PURGE=1)"
else
	echo "[+] база роутеров оставлена: /var/lib/netcraze-remote (PURGE=1 чтобы удалить)"
fi

if [ "$REMOVE_XRAY" = "1" ]; then
	rm -f /usr/local/bin/netcraze-remote-xray
	echo "[+] бинарь netcraze-remote-xray удалён"
fi

if [ "$REMOVE_USER" = "1" ]; then
	userdel netcraze-remote 2>/dev/null && echo "[+] системный пользователь netcraze-remote удалён" || true
fi

echo "[+] netcraze-remote Hub удалён с этого VPS"
