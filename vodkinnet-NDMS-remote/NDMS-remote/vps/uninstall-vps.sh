#!/bin/sh
# NDMS-remote — удаление Hub с VPS.
# PURGE=0 sh uninstall-vps.sh        — оставить базу роутеров (/var/lib/NDMS-remote)
# REMOVE_XRAY=1 sh uninstall-vps.sh  — удалить и бинарь NDMS-remote-xray
# REMOVE_USER=1 sh uninstall-vps.sh  — удалить системного пользователя NDMS-remote

set -eu
PURGE="${PURGE:-1}"
REMOVE_XRAY="${REMOVE_XRAY:-0}"
REMOVE_USER="${REMOVE_USER:-0}"

systemctl stop NDMS-remote-hub 2>/dev/null || true
systemctl stop NDMS-remote-xray 2>/dev/null || true
systemctl disable NDMS-remote-hub 2>/dev/null || true
systemctl disable NDMS-remote-xray 2>/dev/null || true

rm -f /etc/systemd/system/NDMS-remote-hub.service
rm -f /etc/systemd/system/NDMS-remote-xray.service
systemctl daemon-reload

rm -rf /opt/NDMS-remote
rm -f /etc/NDMS-remote/xray.json
rm -f /etc/NDMS-remote/hub.env
rm -f /etc/NDMS-remote/cert-domain
rmdir /etc/NDMS-remote 2>/dev/null || true

rm -f /etc/sudoers.d/NDMS-remote
rm -f /etc/letsencrypt/renewal-hooks/deploy/NDMS-remote.sh

rm -f /etc/nginx/sites-enabled/NDMS-remote
rm -f /etc/nginx/sites-available/NDMS-remote
nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true

if [ "$PURGE" = "1" ]; then
	rm -rf /var/lib/NDMS-remote
	echo "[+] база роутеров тоже удалена (PURGE=1)"
else
	echo "[+] база роутеров оставлена: /var/lib/NDMS-remote (PURGE=1 чтобы удалить)"
fi

if [ "$REMOVE_XRAY" = "1" ]; then
	rm -f /usr/local/bin/NDMS-remote-xray
	echo "[+] бинарь NDMS-remote-xray удалён"
fi

if [ "$REMOVE_USER" = "1" ]; then
	userdel NDMS-remote 2>/dev/null && echo "[+] системный пользователь NDMS-remote удалён" || true
fi

echo "[+] NDMS-remote Hub удалён с этого VPS"
