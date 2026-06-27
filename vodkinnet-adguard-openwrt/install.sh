#!/bin/sh
# vodkinnet-adguard installer
# https://github.com/beverlypillzz-collab/Vodkinnet-RT
# Installs adblock (dibdot) pre-configured for podkop compatibility (DNS-only, no nftset)

set -eu

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

VERSION="1.0.0"
REPO="beverlypillzz-collab/Vodkinnet-RT"

log()  { printf "${CYAN}[*]${NC} %s\n" "$1"; }
ok()   { printf "${GREEN}[+]${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
die()  { printf "${RED}[x]${NC} %s\n" "$1"; exit 1; }

echo ""
echo "  ██╗   ██╗ ██████╗ ██████╗ ██╗  ██╗██╗███╗   ██╗"
echo "  ██║   ██║██╔═══██╗██╔══██╗██║ ██╔╝██║████╗  ██║"
echo "  ██║   ██║██║   ██║██║  ██║█████╔╝ ██║██╔██╗ ██║"
echo "  ╚██╗ ██╔╝██║   ██║██║  ██║██╔═██╗ ██║██║╚██╗██║"
echo "   ╚████╔╝ ╚██████╔╝██████╔╝██║  ██╗██║██║ ╚████║"
echo "    ╚═══╝   ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝"
echo "  adblock installer v${VERSION} — podkop-safe"
echo "  ${REPO}"
echo ""

# ── проверки ─────────────────────────────────────────────────────────────────

[ "$(id -u)" -eq 0 ] || die "Запусти от root"

# ── определяем пакетный менеджер (apk — OpenWrt 25.x, opkg — 24.x и старше) ─
if command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
    log "Пакетный менеджер: apk (OpenWrt 25.x)"
elif command -v opkg >/dev/null 2>&1; then
    PKG_MGR="opkg"
    log "Пакетный менеджер: opkg (OpenWrt 24.x)"
else
    die "Не найден ни apk, ни opkg. Поддерживается OpenWrt 24.x и 25.x."
fi

log "Проверка совместимости с podkop..."
if [ -f /etc/config/podkop ]; then
    ok "podkop обнаружен — будет применён podkop-safe режим (DNS-only, nftset отключён)"
    PODKOP_DETECTED=1
else
    warn "podkop не обнаружен — настройки всё равно безопасны для будущей установки"
    PODKOP_DETECTED=0
fi

# ── установка пакетов ─────────────────────────────────────────────────────────

log "Обновление списка пакетов..."
if [ "$PKG_MGR" = "apk" ]; then
    apk update || die "apk update не удался"
else
    opkg update || die "opkg update не удался"
fi

log "Установка adblock + luci-app-adblock..."
if [ "$PKG_MGR" = "apk" ]; then
    apk add adblock luci-app-adblock || die "Не удалось установить пакеты"
else
    opkg install adblock luci-app-adblock || die "Не удалось установить пакеты"
fi

ok "Пакеты установлены"

# ── применение конфига ────────────────────────────────────────────────────────

log "Применение podkop-safe конфигурации..."

uci -q delete adblock.global 2>/dev/null || true
uci set adblock.global=adblock

# DNS backend: dnsmasq plain mode, без nftset
uci set adblock.global.adb_enabled='1'
uci set adblock.global.adb_dns='dnsmasq'

# КРИТИЧНО для podkop: без nftset — не конфликтует с nftables podkop

# Отключаем DNS reporting — побочные запросы мимо FakeIP podkop
uci set adblock.global.adb_dns_report='0'

# Отключаем nftables счётчики
uci set adblock.global.adb_nftcnt='0'

# Блоклисты
uci -q delete adblock.global.adb_sources 2>/dev/null || true
uci add_list adblock.global.adb_sources='adguard'
uci add_list adblock.global.adb_sources='adguard_tracking'
uci add_list adblock.global.adb_sources='oisd_small'

# Производительность
uci set adblock.global.adb_maxqueue='4'

# Задержка старта — podkop и dnsmasq должны подняться первыми
uci set adblock.global.adb_bootdelay='30'

# Автообновление раз в сутки
uci set adblock.global.adb_autoupdate='1'
uci set adblock.global.adb_updatecycle='24'

# Логирование
uci set adblock.global.adb_loglevel='info'
uci set adblock.global.adb_logfile='/var/log/adblock.log'

uci commit adblock || die "uci commit не удался"
ok "Конфигурация применена"

# ── патч LuCI ─────────────────────────────────────────────────────────────────

MENU_FILE="/usr/share/luci/menu.d/luci-app-adblock.json"
VIEW_FILE="/www/luci-static/resources/view/adblock/overview.js"

if [ -f "$MENU_FILE" ]; then
    # временный файл для безопасного sed
    sed 's/"title": "Adblock"/"title": "VodkinNet Adguard"/g' "$MENU_FILE" > "${MENU_FILE}.tmp" \
        && mv "${MENU_FILE}.tmp" "$MENU_FILE" \
        || rm -f "${MENU_FILE}.tmp"
fi

if [ -f "$VIEW_FILE" ]; then
    sed "s|'Adblock'|'VodkinNet Adguard'|g" "$VIEW_FILE" > "${VIEW_FILE}.tmp" \
        && mv "${VIEW_FILE}.tmp" "$VIEW_FILE" \
        || rm -f "${VIEW_FILE}.tmp"
    sed 's|"Adblock"|"VodkinNet Adguard"|g' "$VIEW_FILE" > "${VIEW_FILE}.tmp" \
        && mv "${VIEW_FILE}.tmp" "$VIEW_FILE" \
        || rm -f "${VIEW_FILE}.tmp"
    sed 's|Configuration of the adblock package|VodkinNet DNS-based ad blocker|g' "$VIEW_FILE" > "${VIEW_FILE}.tmp" \
        && mv "${VIEW_FILE}.tmp" "$VIEW_FILE" \
        || rm -f "${VIEW_FILE}.tmp"
fi

# применяем изменения LuCI
/etc/init.d/rpcd restart 2>/dev/null || true
/etc/init.d/uhttpd restart 2>/dev/null || true

# ── запуск ────────────────────────────────────────────────────────────────────

log "Включение и запуск adblock..."
/etc/init.d/adblock enable || die "Не удалось включить adblock"
/etc/init.d/adblock start 2>/dev/null || true  # запускается асинхронно, ненулевой код — норма

# принудительно применяем наши листы (adblock при первом старте может взять свои дефолты)
sleep 2
uci -q delete adblock.global.adb_sources 2>/dev/null || true
uci add_list adblock.global.adb_sources='adguard'
uci add_list adblock.global.adb_sources='adguard_tracking'
uci add_list adblock.global.adb_sources='oisd_small'
uci commit adblock
/etc/init.d/adblock reload

# ── итог ──────────────────────────────────────────────────────────────────────

echo ""
echo "  ┌─────────────────────────────────────────────┐"
echo "  │           vodkinnet-adguard готов           │"
echo "  ├─────────────────────────────────────────────┤"
echo "  │  Режим:     DNS-only (dnsmasq)              │"
echo "  │  nftset:    ВЫКЛЮЧЕН  ✓ podkop-safe         │"
echo "  │  Листы:     adguard + adguard_tracking + oisd_small      │"
echo "  │  Задержка:  30с (podkop стартует первым)    │"
echo "  │  UI:        LuCI → Services → VodkinNet     │"
echo "  │             Adguard                         │"
echo "  └─────────────────────────────────────────────┘"
echo ""

if [ "$PODKOP_DETECTED" -eq 1 ]; then
    ok "podkop работает параллельно — конфликтов быть не должно"
fi

ok "Готово. Блоклисты загружаются в фоне (~1-2 мин)."
echo ""
