#!/bin/sh
# vodkinnet-adguard installer
# https://github.com/beverlypillzz-collab/Vodkinnet-RT
# Installs adblock (dibdot) pre-configured for podkop compatibility (DNS-only, no nftset)

set -e

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

# ── проверки ────────────────────────────────────────────────────────────────

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

# ── установка пакетов ────────────────────────────────────────────────────────

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

# ── применение конфига ───────────────────────────────────────────────────────

log "Применение podkop-safe конфигурации..."

# Сбрасываем до чистого состояния
uci -q delete adblock.global 2>/dev/null || true
uci set adblock.global=adblock

# --- базовые настройки ---
uci set adblock.global.adb_enabled='1'

# DNS backend: dnsmasq (plain mode, без nftset)
uci set adblock.global.adb_dns='dnsmasq'

# КРИТИЧНО для podkop: отключаем nftset/firewall интеграцию
# nftset конфликтует с nftables-правилами podkop
uci set adblock.global.adb_dnsvariant='dnsmasq'

# Отключаем DNS reporting — он делает дополнительные DNS-запросы
# которые могут выйти мимо FakeIP-туннеля podkop
uci set adblock.global.adb_dns_report='0'

# Отключаем nftables счётчики (не нужны, экономим ресурсы)
uci set adblock.global.adb_nftcnt='0'

# --- источники блоклистов ---
# Hagezi: отличный баланс блокировок без переблокировки
uci -q delete adblock.global.adb_sources 2>/dev/null || true
uci add_list adblock.global.adb_sources='hagezi_normal'
uci add_list adblock.global.adb_sources='oisd_small'

# --- производительность ---
# Параллельная загрузка листов
uci set adblock.global.adb_maxqueue='4'

# Загрузка при старте с задержкой (даём dnsmasq/podkop подняться первыми)
uci set adblock.global.adb_bootdelay='30'

# Автообновление: раз в сутки в 03:00
uci set adblock.global.adb_autoupdate='1'
uci set adblock.global.adb_updatecycle='24'

# --- логирование ---
uci set adblock.global.adb_loglevel='info'
uci set adblock.global.adb_logfile='/var/log/adblock.log'

uci commit adblock
ok "Конфигурация применена"

# ── запуск ───────────────────────────────────────────────────────────────────

log "Включение и запуск adblock..."
/etc/init.d/adblock enable
/etc/init.d/adblock start

# ── итог ─────────────────────────────────────────────────────────────────────

echo ""
echo "  ┌─────────────────────────────────────────────┐"
echo "  │           vodkinnet-adguard готов           │"
echo "  ├─────────────────────────────────────────────┤"
echo "  │  Режим:     DNS-only (dnsmasq)              │"
echo "  │  nftset:    ВЫКЛЮЧЕН  ✓ podkop-safe         │"
echo "  │  Листы:     hagezi_normal + oisd_small      │"
echo "  │  Задержка:  30с (podkop стартует первым)    │"
echo "  │  UI:        LuCI → Services → Adblock       │"
echo "  └─────────────────────────────────────────────┘"
echo ""

if [ "$PODKOP_DETECTED" -eq 1 ]; then
    ok "podkop работает параллельно — конфликтов быть не должно"
fi

ok "Готово. Блоклисты загружаются в фоне (~1-2 мин)."
echo ""
