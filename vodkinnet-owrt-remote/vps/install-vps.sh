#!/bin/sh
set -u

APP_NAME="VodkinNet RT Hub"
INSTALLER_VERSION="2026-07-03-web-push-v1"
RAW_BASE="${RAW_URL:-https://raw.githubusercontent.com/beverlypillzz-collab/Vodkinnet-RT/main/vodkinnet-owrt-remote}"
STATE_DIR="${OWRT_REMOTE_STATE_DIR:-/var/lib/owrt-remote}"
HUB_LOGIN="${HUB_LOGIN:-admin}"
# VodkinNET: never default the password to "admin". If unset, generate a strong
# random one and print it once at the end. Prevents a public-VPS panel shipping
# with admin/admin.
if [ -z "${HUB_PASSWORD:-}" ]; then
	HUB_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-24)"
	HUB_PASSWORD_GENERATED=1
else
	HUB_PASSWORD_GENERATED=0
fi
RESET_LOGIN="${RESET_LOGIN:-1}"
AUTO_HTTPS="${AUTO_HTTPS:-1}"

if [ "$(id -u)" -eq 0 ]; then
	SUDO=""
else
	SUDO="sudo"
fi

info() {
	printf '%s\n' "$*"
}

warn() {
	printf 'WARN: %s\n' "$*" >&2
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "не найдена команда: $1"
}

detect_public_vps_host() {
	if command -v curl >/dev/null 2>&1; then
		host="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
		if [ -n "$host" ]; then
			printf '%s\n' "$host"
			return
		fi
	fi
	hostname -I 2>/dev/null | awk '{print $1}'
}

prompt_vps_host() {
	default_host="$(detect_public_vps_host)"
	host=""

	if [ -r /dev/tty ] && [ -w /dev/tty ]; then
		printf '\n' >/dev/tty
		printf 'IP или домен VPS для панели Hub\n' >/dev/tty
		if [ -n "$default_host" ]; then
			printf 'Нажми Enter, чтобы взять найденный IP: %s\n' "$default_host" >/dev/tty
		fi
		printf 'IP/домен VPS: ' >/dev/tty
		IFS= read -r host </dev/tty || host=""
	fi

	if [ -z "$host" ]; then
		host="$default_host"
	fi
	printf '%s\n' "$host"
}

detect_vps_host() {
	if [ -n "${VPS_HOST:-}" ]; then
		printf '%s\n' "$VPS_HOST"
		return
	fi
	if [ "${1:-}" != "" ]; then
		printf '%s\n' "$1"
		return
	fi
	prompt_vps_host
}

install_packages() {
	if command -v apt-get >/dev/null 2>&1; then
		$SUDO apt-get update
		$SUDO apt-get install -y curl wget unzip python3 python3-venv openssh-client ca-certificates ufw
		return
	fi
	die "поддерживается Ubuntu/Debian с apt-get"
}

install_xray_binary() {
	if command -v xray >/dev/null 2>&1 || command -v /usr/local/bin/xray >/dev/null 2>&1 || command -v /usr/bin/xray >/dev/null 2>&1; then
		return
	fi
	info "Ставлю Xray на VPS..."
	if ! $SUDO bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install; then
		warn "Xray не поставился автоматически. Панель Hub все равно будет работать, Xray можно поставить позже."
	fi
}

install_files() {
	cache_bust="$(date +%s)"
	$SUDO mkdir -p /opt/owrt-remote "$STATE_DIR" /etc/xray
	$SUDO wget -O /opt/owrt-remote/owrt-remote-hub.py "$RAW_BASE/vps/owrt-remote-hub.py?v=$cache_bust"
	$SUDO wget -O /opt/owrt-remote/owrt-remote-run.sh "$RAW_BASE/vps/owrt-remote-run.sh?v=$cache_bust"
	$SUDO wget -O /etc/systemd/system/owrt-remote.service "$RAW_BASE/vps/owrt-remote.service?v=$cache_bust"
	$SUDO wget -O /opt/owrt-remote/enable-https.sh "$RAW_BASE/vps/enable-https.sh?v=$cache_bust"
	$SUDO chmod +x /opt/owrt-remote/owrt-remote-hub.py /opt/owrt-remote/owrt-remote-run.sh /opt/owrt-remote/enable-https.sh
}

install_python_deps() {
	info "РЎС‚Р°РІР»СЋ Web Push РґР»СЏ СЂРµР°Р»СЊРЅС‹С… push-СѓРІРµРґРѕРјР»РµРЅРёР№..."
	if ! $SUDO python3 -m venv /opt/owrt-remote/venv; then
		warn "РќРµ СЃРјРѕРі СЃРѕР·РґР°С‚СЊ Python venv. Hub Р·Р°РїСѓСЃС‚РёС‚СЃСЏ, РЅРѕ Web Push РЅСѓР¶РЅРѕ РґРѕСЃС‚Р°РІРёС‚СЊ РїРѕР·Р¶Рµ."
		return 0
	fi
	if ! $SUDO /opt/owrt-remote/venv/bin/python -m pip install --upgrade pip wheel >/dev/null; then
		warn "РќРµ СЃРјРѕРі РѕР±РЅРѕРІРёС‚СЊ pip РІ venv."
	fi
	if ! $SUDO /opt/owrt-remote/venv/bin/python -m pip install --upgrade pywebpush >/dev/null; then
		warn "РќРµ СЃРјРѕРі РїРѕСЃС‚Р°РІРёС‚СЊ pywebpush. РџСЂРѕРІРµСЂСЊ internet/DNS РЅР° VPS."
	fi
}

install_xray_service() {
	xray_bin="$(command -v xray || command -v /usr/local/bin/xray || command -v /usr/bin/xray || true)"
	[ -n "$xray_bin" ] || return 0
	$SUDO tee /etc/systemd/system/owrt-remote-xray.service >/dev/null <<EOF
[Unit]
Description=OpenWrt Remote Xray Reverse
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$xray_bin run -config /etc/xray/owrt-remote.json
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
	$SUDO systemctl enable owrt-remote-xray >/dev/null 2>&1 || true
}

open_firewall() {
	if command -v ufw >/dev/null 2>&1; then
		$SUDO ufw allow 80/tcp >/dev/null 2>&1 || true
		$SUDO ufw allow 443/tcp >/dev/null 2>&1 || true
		# VodkinNET: 8088 is the raw internal Hub port. It must stay bound to
		# 127.0.0.1 and reachable only via the nginx TLS vhost. Do NOT expose it.
		$SUDO ufw allow "${OWRT_REMOTE_VLESS_PORT:-8443}"/tcp >/dev/null 2>&1 || true
	fi
}

start_hub() {
	$SUDO /opt/owrt-remote/owrt-remote-hub.py init >/tmp/owrt-remote-init.log 2>&1 || {
		cat /tmp/owrt-remote-init.log >&2
		die "не смог создать базу Hub"
	}
	if [ "$RESET_LOGIN" = "1" ]; then
		$SUDO /opt/owrt-remote/owrt-remote-hub.py set-login --username "$HUB_LOGIN" --password "$HUB_PASSWORD" >/dev/null
	fi
	$SUDO systemctl daemon-reload
	$SUDO systemctl enable --now owrt-remote
	$SUDO systemctl restart owrt-remote
}

check_hub() {
	HUB_PORT80_OK=0
	info "Жду запуск Hub..."
	i=1
	while [ "$i" -le 20 ]; do
		if curl -fsS --max-time 2 http://127.0.0.1:8088/health >/tmp/owrt-remote-health.log 2>&1; then
			if curl -fsS --max-time 2 http://127.0.0.1/health >/dev/null 2>&1; then
				HUB_PORT80_OK=1
			fi
			return 0
		fi
		sleep 1
		i=$((i + 1))
	done
	warn "Hub не ответил на http://127.0.0.1:8088/health"
	$SUDO systemctl status owrt-remote --no-pager -l || true
	$SUDO journalctl -u owrt-remote -n 80 --no-pager || true
	return 1
}

enable_https() {
	host="$1"
	HTTPS_OK=0
	if [ "$AUTO_HTTPS" != "1" ]; then
		warn "HTTPS пропущен: AUTO_HTTPS=0"
		return 0
	fi
	if [ "$host" = "YOUR_VPS_IP" ]; then
		warn "HTTPS пропущен: не смог определить IP/домен VPS"
		return 0
	fi
	if [ ! -x /opt/owrt-remote/enable-https.sh ]; then
		warn "HTTPS пропущен: /opt/owrt-remote/enable-https.sh не найден"
		return 0
	fi
	info "Включаю HTTPS/SSL..."
	if $SUDO env RAW_URL="$RAW_BASE" /opt/owrt-remote/enable-https.sh "$host"; then
		HTTPS_OK=1
		return 0
	fi
	warn "HTTPS не включился автоматически. HTTP-панель уже работает, после проверки firewall можно запустить enable-https.sh вручную."
	return 0
}

print_result() {
	host="$1"
	info ""
	info "============================================================"
	info "$APP_NAME установлен"
	info "============================================================"
	info "Панель:"
	if [ "${HTTPS_OK:-0}" = "1" ]; then
		info "  https://$host/"
	fi
	if [ "${HUB_PORT80_OK:-0}" = "1" ]; then
		info "  http://$host/"
	else
		info "  http://$host/       (порт 80 не ответил, проверь firewall или занятый порт)"
	fi
	info "  http://$host:8088/"
	info ""
	info "Вход:"
	info "  login:    $HUB_LOGIN"
	info "  password: $HUB_PASSWORD"
	info ""
	info "Проверка на VPS:"
	info "  sudo systemctl status owrt-remote --no-pager -l"
	info "  sudo ss -lntp | grep -E ':(80|443|8088|8443)'"
	info "  curl -sS http://127.0.0.1:8088/health"
	if [ "${HTTPS_OK:-0}" = "1" ]; then
		info "  curl -k https://127.0.0.1/health"
	fi
	info ""
	info "Если снаружи не открывается, открой в firewall VPS-провайдера:"
	info "  80/tcp, 443/tcp, ${OWRT_REMOTE_VLESS_PORT:-8443}/tcp"
	info "  (порт 8088 НЕ открывать наружу — он только для nginx/localhost)"
	if [ "${HTTPS_OK:-0}" != "1" ]; then
		info ""
		info "Включить HTTPS вручную:"
		info '  curl -fsSL "https://raw.githubusercontent.com/beverlypillzz-collab/Vodkinnet-RT/main/vodkinnet-owrt-remote/vps/enable-https.sh?v=$(date +%s)" | sudo sh -s -- '"$host"
	fi
	info "============================================================"
}

# VodkinNET: reverse-channel TLS cert setup. Xray (owrt-remote-xray.service)
# runs as root by design (see install_xray_service), so it can read the
# privkey without extra grants. This function additionally grants the
# ssl-cert group read access as a safety net for anyone who later moves the
# service off root, and installs a certbot deploy-hook: certbot renew
# regenerates the cert with default perms and does NOT restart other
# services, so without this hook the reverse channel silently starts serving
# a stale/unreadable cert after the next renewal.
setup_reverse_tls() {
	cert="${OWRT_REMOTE_TLS_CERT:-}"
	[ -n "$cert" ] || return 0
	cert_dir="$(dirname "$cert")"
	[ -d "$cert_dir" ] || return 0

	if ! getent group ssl-cert >/dev/null 2>&1; then
		$SUDO groupadd -f ssl-cert >/dev/null 2>&1 || true
	fi
	$SUDO chgrp -R ssl-cert "$cert_dir" >/dev/null 2>&1 || true
	$SUDO chmod -R g+rX "$cert_dir" >/dev/null 2>&1 || true

	hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
	if [ -d "/etc/letsencrypt" ]; then
		$SUDO mkdir -p "$hook_dir" >/dev/null 2>&1 || true
		# Certbot exports RENEWED_LINEAGE = the cert dir that was just renewed,
		# so this hook only touches OUR domain, never other certs on the box
		# (e.g. a Remnawave panel sharing the same server).
		$SUDO tee "$hook_dir/owrt-remote-xray.sh" >/dev/null <<EOF
#!/bin/sh
# VodkinNET: after certbot renews \$RENEWED_LINEAGE, restore ssl-cert group
# perms on that cert only and restart the reverse Xray service so it picks
# up the new key instead of silently serving a stale/unreadable one.
OWN_CERT_DIR="$cert_dir"
if [ "\${RENEWED_LINEAGE:-}" = "\$OWN_CERT_DIR" ]; then
	chgrp -R ssl-cert "\$RENEWED_LINEAGE" 2>/dev/null || true
	chmod -R g+rX "\$RENEWED_LINEAGE" 2>/dev/null || true
	systemctl restart owrt-remote-xray 2>/dev/null || true
fi
EOF
		$SUDO chmod +x "$hook_dir/owrt-remote-xray.sh" >/dev/null 2>&1 || true
		info "certbot renew-hook установлен: $hook_dir/owrt-remote-xray.sh (только для $cert_dir)"
	fi
}

main() {
	info "Ставлю $APP_NAME..."
	info "Installer: $INSTALLER_VERSION"
	install_packages
	need_cmd curl
	need_cmd wget
	need_cmd python3
	host="$(detect_vps_host "${1:-}")"
	[ -n "$host" ] || host="YOUR_VPS_IP"
	info "IP/домен VPS: $host"
	install_xray_binary
	install_files
	install_python_deps
	install_xray_service
	setup_reverse_tls
	open_firewall
	start_hub
	check_hub || die "Hub установлен, но сервис не поднялся. Лог выше."
	enable_https "$host"
	print_result "$host"
}

main "${1:-}"
