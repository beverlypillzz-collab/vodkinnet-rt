#!/bin/bash
# Установка / обновление AWG Panel на Debian/Ubuntu (z1-mgmt).
#   sudo ./install.sh 'ПАРОЛЬ_ПАНЕЛИ'    — первая установка (задаёт пароль)
#   sudo ./install.sh --update           — обновить код, пароль и ключи не трогать
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${DEST:-/opt/awg-panel}"
DATA="${DATA:-/var/lib/awg-panel}"
ENVFILE="${ENVFILE:-/etc/awg-panel.env}"
[ "$(id -u)" = 0 ] || { echo "запусти от root: sudo $0 ..."; exit 1; }

UPDATE=0; PW=""
if [ "${1:-}" = "--update" ]; then UPDATE=1; else PW="${1:-${AWG_PW:-}}"; fi
if [ "$UPDATE" = 0 ] && [ -z "$PW" ]; then
  echo "нужен пароль панели:  sudo $0 'ПАРОЛЬ'   (или  sudo $0 --update)"; exit 1
fi

if [ -z "${DRY:-}" ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq python3-flask python3-qrcode openssh-client
  id awgpanel >/dev/null 2>&1 || useradd --system --home "$DATA" --shell /usr/sbin/nologin awgpanel
fi

mkdir -p "$DEST/panel" "$DEST/router" "$DATA"
cp -r "$HERE/panel/." "$DEST/panel/"
cp "$HERE/router/awg-newpeer" "$DEST/router/awg-newpeer"

if [ "$UPDATE" = 0 ]; then
  HASH=$(python3 -c 'import sys; from werkzeug.security import generate_password_hash as g; print(g(sys.argv[1]))' "$PW")
  ( umask 077
    printf 'AWG_PANEL_PASSWORD_HASH=%s\nAWG_PANEL_DATA=%s\nAWG_PANEL_BIND=127.0.0.1:8080\n' "$HASH" "$DATA" > "$ENVFILE" )
fi
[ -f "$DATA/id_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C awg-panel -f "$DATA/id_ed25519"

if [ -z "${DRY:-}" ]; then
  chown -R awgpanel:awgpanel "$DATA"; chmod 700 "$DATA"
  cat > /etc/systemd/system/awg-panel.service <<'UNIT'
[Unit]
Description=AWG Panel (AmneziaWG client management)
After=network-online.target
Wants=network-online.target

[Service]
User=awgpanel
EnvironmentFile=/etc/awg-panel.env
ExecStart=/usr/bin/python3 /opt/awg-panel/panel/app.py
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/var/lib/awg-panel
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
  chmod 600 "$ENVFILE"
  systemctl daemon-reload
  systemctl enable awg-panel >/dev/null
  systemctl restart awg-panel
  sleep 2
  echo "служба: $(systemctl is-active awg-panel)"
fi

echo
echo "=== Готово. Панель: http://127.0.0.1:8080 (открывать на z1-mgmt) ==="
echo "=== Публичный SSH-ключ панели (в LuCI роутера: System → Administration → SSH-Keys): ==="
cat "$DATA/id_ed25519.pub"
