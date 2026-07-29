#!/bin/sh
# netcraze-remote — установка Hub-панели на VPS.
#
# v2: Hub и Xray-процесс работают от отдельного системного пользователя
# netcraze-remote (НЕ root) — единственное root-действие (рестарт
# netcraze-remote-xray после изменения списка роутеров) идёт через узкое
# sudoers-правило на один конкретный systemctl-вызов. Xray-бинарь
# проверяется по SHA256SUMS релиза перед установкой.
#
#   curl -fsSL "https://raw.githubusercontent.com/beverlypillzz-collab/vodkinnet-rt/main/vodkinnet-keenetic/netcraze-remote/vps/install-vps.sh?v=$(date +%s)" | sudo sh

set -eu

REPO_RAW="https://raw.githubusercontent.com/beverlypillzz-collab/vodkinnet-rt/main/vodkinnet-keenetic/netcraze-remote"
INSTALL_DIR="/opt/netcraze-remote"
XRAY_BIN="/usr/local/bin/netcraze-remote-xray"
XRAY_CONFIG_DIR="/etc/netcraze-remote"
XRAY_CONFIG="/etc/netcraze-remote/xray.json"
STATE_DIR="/var/lib/netcraze-remote"
ENV_FILE="/etc/netcraze-remote/hub.env"
SVC_USER="netcraze-remote"

C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[0;31m'; C_NC='\033[0m'
ok()   { printf '%b[+]%b %s\n' "$C_GREEN" "$C_NC" "$*"; }
info() { printf '%b[i]%b %s\n' "$C_YELLOW" "$C_NC" "$*"; }
err()  { printf '%b[!!]%b %s\n' "$C_RED" "$C_NC" "$*" >&2; }

[ "$(id -u)" = "0" ] || { err "запусти под root (sudo)"; exit 1; }

info "IP/домен VPS (для этой панели, ОТДЕЛЬНО от других панелей на этом сервере):"
read -r HUB_DOMAIN
[ -n "$HUB_DOMAIN" ] || HUB_DOMAIN="$(curl -fsS ifconfig.me || hostname -I | awk '{print $1}')"

VLESS_PORT="${NETCRAZE_REMOTE_VLESS_PORT:-8444}"
HUB_PORT="${NETCRAZE_REMOTE_HUB_PORT:-8099}"

# --- пакеты ---
if command -v apt-get >/dev/null 2>&1; then
	apt-get update -y
	apt-get install -y python3 curl nginx certbot python3-certbot-nginx unzip sudo
fi

# --- сервисный пользователь (НЕ root) ---
if ! id "$SVC_USER" >/dev/null 2>&1; then
	useradd --system --no-create-home --shell /usr/sbin/nologin "$SVC_USER"
	ok "создан системный пользователь $SVC_USER"
else
	ok "пользователь $SVC_USER уже существует"
fi
# доступ к сертификатам Let's Encrypt (обычно группа ssl-cert на Debian/Ubuntu)
if getent group ssl-cert >/dev/null 2>&1; then
	usermod -aG ssl-cert "$SVC_USER"
fi

mkdir -p "$INSTALL_DIR" "$XRAY_CONFIG_DIR" "$STATE_DIR" "$(dirname "$ENV_FILE")"
chown -R "$SVC_USER:$SVC_USER" "$STATE_DIR" "$XRAY_CONFIG_DIR" "$INSTALL_DIR"
chmod 750 "$STATE_DIR" "$XRAY_CONFIG_DIR"

# --- Xray binary (отдельная копия, отдельное имя бинаря, с проверкой checksum) ---
if [ ! -x "$XRAY_BIN" ]; then
	info "ставлю отдельный бинарь Xray для netcraze-remote (с проверкой .dgst релиза)..."
	TMP_DIR="$(mktemp -d)"
	ARCH="$(uname -m)"
	case "$ARCH" in
		x86_64) XRAY_ASSET="Xray-linux-64.zip" ;;
		aarch64) XRAY_ASSET="Xray-linux-arm64-v8a.zip" ;;
		*) err "неизвестная архитектура $ARCH, поставь Xray вручную в $XRAY_BIN"; exit 1 ;;
	esac

	XRAY_DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/latest/download/${XRAY_ASSET}"
	curl -fsSL -o "$TMP_DIR/xray.zip" "$XRAY_DOWNLOAD_URL"
	# VodkinNET: у Xray-core НЕТ единого SHA256SUMS на релиз — у каждого
	# ассета свой файл проверки "<имя>.dgst" с полями MD5=/SHA1=/SHA256=/
	# SHA512= (см. официальный XTLS/Xray-install/install-release.sh,
	# функция download_xray). Первая версия этого скрипта пыталась брать
	# несуществующий общий SHA256SUMS и падала 404 — это исправление.
	curl -fsSL -o "$TMP_DIR/xray.zip.dgst" "${XRAY_DOWNLOAD_URL}.dgst" || true

	if [ -s "$TMP_DIR/xray.zip.dgst" ] && ! grep -q "Not Found" "$TMP_DIR/xray.zip.dgst"; then
		EXPECTED_SUM="$(awk -F'= ' '/256=/{print $2}' "$TMP_DIR/xray.zip.dgst" | tr -d '[:space:]')"
		ACTUAL_SUM="$(sha256sum "$TMP_DIR/xray.zip" | awk '{print $1}')"
		if [ -n "$EXPECTED_SUM" ] && [ "$EXPECTED_SUM" = "$ACTUAL_SUM" ]; then
			ok "checksum Xray-core подтверждён (SHA256 из .dgst совпадает)"
		else
			err "checksum Xray-core НЕ совпадает — прерываю установку (supply-chain risk)"
			rm -rf "$TMP_DIR"
			exit 1
		fi
	else
		err "не удалось скачать/распарсить .dgst для этой версии релиза — не могу проверить целостность бинаря, прерываю"
		rm -rf "$TMP_DIR"
		exit 1
	fi

	unzip -q "$TMP_DIR/xray.zip" -d "$TMP_DIR"
	install -m 0755 "$TMP_DIR/xray" "$XRAY_BIN"
	rm -rf "$TMP_DIR"
	ok "Xray поставлен и проверен: $XRAY_BIN"
else
	ok "Xray для netcraze-remote уже стоит: $XRAY_BIN"
fi

# --- Hub script ---
curl -fsSL "${REPO_RAW}/vps/netcraze-remote-hub.py?v=$(date +%s)" -o "${INSTALL_DIR}/netcraze-remote-hub.py"
chmod +x "${INSTALL_DIR}/netcraze-remote-hub.py"
chown "$SVC_USER:$SVC_USER" "${INSTALL_DIR}/netcraze-remote-hub.py"

# --- сертификат ---
if [ ! -f "/etc/letsencrypt/live/${HUB_DOMAIN}/fullchain.pem" ]; then
	info "получаю сертификат Let's Encrypt для ${HUB_DOMAIN} (нужна A-запись на этот IP)..."
	systemctl stop nginx 2>/dev/null || true
	certbot certonly --standalone -d "$HUB_DOMAIN" --agree-tos -m "admin@${HUB_DOMAIN}" --non-interactive || \
		info "certbot не смог получить сертификат автоматически — сделай позже вручную и укажи пути ниже"
	systemctl start nginx 2>/dev/null || true
fi

CERT_PATH="/etc/letsencrypt/live/${HUB_DOMAIN}/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/${HUB_DOMAIN}/privkey.pem"

if [ -f "$KEY_PATH" ] && getent group ssl-cert >/dev/null 2>&1; then
	chgrp ssl-cert "$KEY_PATH" 2>/dev/null || true
	chmod 640 "$KEY_PATH" 2>/dev/null || true
fi
echo "$HUB_DOMAIN" > "${XRAY_CONFIG_DIR}/cert-domain"

# --- certbot deploy-hook: чинит права ключа + рестартит ТОЛЬКО наш xray ---
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
curl -fsSL "${REPO_RAW}/vps/certbot-deploy-hook.sh?v=$(date +%s)" -o /etc/letsencrypt/renewal-hooks/deploy/netcraze-remote.sh
chmod +x /etc/letsencrypt/renewal-hooks/deploy/netcraze-remote.sh

# --- пароль администратора: НЕ передаём как argv (виден в ps/history) ---
if [ -z "${NETCRAZE_REMOTE_ADMIN_PASSWORD:-}" ]; then
	ADMIN_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 24)"
else
	ADMIN_PASSWORD="$NETCRAZE_REMOTE_ADMIN_PASSWORD"
fi
ADMIN_USER="${NETCRAZE_REMOTE_ADMIN_USER:-admin}"

# --- env для systemd ---
cat > "$ENV_FILE" <<EOF
NETCRAZE_REMOTE_STATE_DIR=${STATE_DIR}
NETCRAZE_REMOTE_XRAY_CONFIG=${XRAY_CONFIG}
NETCRAZE_REMOTE_XRAY_SERVICE=netcraze-remote-xray
NETCRAZE_REMOTE_BIND=127.0.0.1
NETCRAZE_REMOTE_PORT=${HUB_PORT}
NETCRAZE_REMOTE_VLESS_PORT=${VLESS_PORT}
NETCRAZE_REMOTE_TLS_CERT=${CERT_PATH}
NETCRAZE_REMOTE_TLS_KEY=${KEY_PATH}
NETCRAZE_REMOTE_TLS_SNI=${HUB_DOMAIN}
NETCRAZE_REMOTE_PUBLIC_HOST=${HUB_DOMAIN}
NETCRAZE_REMOTE_VPS_SSH_USER=root
NETCRAZE_REMOTE_VPS_SSH_PORT=22
NETCRAZE_REMOTE_SUDO_RESTART=1
EOF
chmod 640 "$ENV_FILE"
chown root:"$SVC_USER" "$ENV_FILE"

# пароль передаём через переменную окружения дочернему процессу, а не argv —
# не остаётся в `ps aux`/shell-истории этой сессии. ВАЖНО: sudo по умолчанию
# сбрасывает окружение — переменные нужно объявлять ПОСЛЕ "sudo -u ... env",
# объявление перед sudo (env NAME=val sudo ...) до дочернего процесса не доходит.
sudo -u "$SVC_USER" env \
	NETCRAZE_REMOTE_STATE_DIR="$STATE_DIR" \
	NETCRAZE_REMOTE_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
	python3 "${INSTALL_DIR}/netcraze-remote-hub.py" set-admin-password "$ADMIN_USER"

# shellcheck disable=SC2046
sudo -u "$SVC_USER" env $(grep -v '^#' "$ENV_FILE" | xargs) NETCRAZE_REMOTE_SUDO_RESTART=0 \
	python3 "${INSTALL_DIR}/netcraze-remote-hub.py" regen-xray

# --- sudoers: узкое правило, только рестарт netcraze-remote-xray ---
SYSTEMCTL_PATH="$(command -v systemctl || echo /usr/bin/systemctl)"
curl -fsSL "${REPO_RAW}/vps/netcraze-remote.sudoers?v=$(date +%s)" -o /tmp/netcraze-remote.sudoers.tmp
sed "s#%SYSTEMCTL_PATH%#${SYSTEMCTL_PATH}#" /tmp/netcraze-remote.sudoers.tmp > /tmp/netcraze-remote.sudoers.final
if visudo -c -f /tmp/netcraze-remote.sudoers.final >/dev/null 2>&1; then
	install -m 0440 /tmp/netcraze-remote.sudoers.final /etc/sudoers.d/netcraze-remote
	ok "sudoers-правило установлено (только systemctl restart netcraze-remote-xray)"
else
	err "sudoers-файл не прошёл проверку visudo -c — НЕ установлен. Хаб не сможет рестартовать Xray сам, чини /etc/sudoers.d/netcraze-remote вручную."
fi
rm -f /tmp/netcraze-remote.sudoers.tmp /tmp/netcraze-remote.sudoers.final

# --- systemd units ---
curl -fsSL "${REPO_RAW}/vps/netcraze-remote-hub.service?v=$(date +%s)" -o /etc/systemd/system/netcraze-remote-hub.service
curl -fsSL "${REPO_RAW}/vps/netcraze-remote-xray.service?v=$(date +%s)" -o /etc/systemd/system/netcraze-remote-xray.service
sed -i "s#/usr/local/bin/netcraze-remote-xray#${XRAY_BIN}#" /etc/systemd/system/netcraze-remote-xray.service
sed -i "s#/etc/netcraze-remote/xray.json#${XRAY_CONFIG}#" /etc/systemd/system/netcraze-remote-xray.service

systemctl daemon-reload
systemctl enable --now netcraze-remote-xray
systemctl enable --now netcraze-remote-hub

# --- nginx vhost (отдельный файл, отдельный домен) ---
cat > "/etc/nginx/sites-available/netcraze-remote" <<EOF
server {
    listen 80;
    server_name ${HUB_DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name ${HUB_DOMAIN};

    ssl_certificate     ${CERT_PATH};
    ssl_certificate_key ${KEY_PATH};

    location / {
        proxy_pass http://127.0.0.1:${HUB_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
ln -sf /etc/nginx/sites-available/netcraze-remote /etc/nginx/sites-enabled/netcraze-remote
nginx -t && systemctl reload nginx

# --- firewall (ufw, если есть) ---
if command -v ufw >/dev/null 2>&1; then
	ufw allow "${VLESS_PORT}/tcp" || true
	ufw allow 80/tcp || true
	ufw allow 443/tcp || true
fi

echo
ok "Установка Hub завершена (процессы работают от пользователя ${SVC_USER}, не root)."
cat <<EOF

  URL панели : https://${HUB_DOMAIN}/
  Логин      : ${ADMIN_USER}
  Пароль     : ${ADMIN_PASSWORD}
  (пароль показывается один раз, смени его при первом входе)

  VLESS-порт реверс-канала: ${VLESS_PORT} (открой в firewall провайдера, если не ufw)

Дальше: зайди в панель -> "Добавить роутер" -> скопируй блок конфига в
/opt/etc/netcraze-remote/netcraze-remote.conf на Keenetic и запусти агент.
EOF
