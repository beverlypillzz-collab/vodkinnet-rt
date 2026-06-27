#!/bin/sh
# vodkinnet-adguard uninstaller

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { printf "${CYAN}[*]${NC} %s\n" "$1"; }
ok()   { printf "${GREEN}[+]${NC} %s\n" "$1"; }
die()  { printf "${RED}[x]${NC} %s\n" "$1"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Запусти от root"

log "Остановка adblock..."
/etc/init.d/adblock stop 2>/dev/null || true
/etc/init.d/adblock disable 2>/dev/null || true

log "Удаление пакетов..."
if command -v apk >/dev/null 2>&1; then
    apk del luci-app-adblock adblock 2>/dev/null || true
else
    opkg remove luci-app-adblock adblock 2>/dev/null || true
fi

log "Очистка конфига..."
uci -q delete adblock.global 2>/dev/null || true
uci -q commit adblock 2>/dev/null || true
rm -f /etc/config/adblock
rm -f /var/log/adblock.log

log "Перезапуск dnsmasq..."
/etc/init.d/dnsmasq restart

ok "vodkinnet-adguard удалён"
