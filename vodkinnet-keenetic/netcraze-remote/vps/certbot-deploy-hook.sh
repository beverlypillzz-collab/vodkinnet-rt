#!/bin/sh
# netcraze-remote — certbot deploy-hook.
#
# certbot renew по умолчанию восстанавливает privkey.pem с правами 600
# root:root — Xray-процесс, работающий от отдельного пользователя (в группе
# ssl-cert), после этого перестаёт читать ключ. Хук чинит права и
# перезапускает ТОЛЬКО netcraze-remote-xray — не трогая другие
# сертификаты/панели на этом же сервере (проверяем RENEWED_LINEAGE, который
# certbot сам подставляет в окружение хука).
#
# Устанавливается install-vps.sh в:
#   /etc/letsencrypt/renewal-hooks/deploy/netcraze-remote.sh

set -eu

# certbot вызывает deploy-хуки уже от root — sudo тут не нужен.
[ -n "${RENEWED_LINEAGE:-}" ] || exit 0

EXPECTED_DOMAIN_FILE="/etc/netcraze-remote/cert-domain"
[ -f "$EXPECTED_DOMAIN_FILE" ] || exit 0
EXPECTED_DOMAIN="$(cat "$EXPECTED_DOMAIN_FILE")"

case "$RENEWED_LINEAGE" in
	*"/${EXPECTED_DOMAIN}") : ;;
	*) exit 0 ;;  # это renew какого-то ДРУГОГО сертификата на сервере — не наш
esac

chgrp ssl-cert "$RENEWED_LINEAGE/privkey.pem" 2>/dev/null || true
chmod 640 "$RENEWED_LINEAGE/privkey.pem" 2>/dev/null || true

systemctl restart netcraze-remote-xray 2>/dev/null || true
