#!/bin/sh

set -eu

export PATH="/bin:/sbin:/usr/bin:/usr/sbin:${PATH:-}"

RAW_URL="${RAW_URL:-https://raw.githubusercontent.com/beverlypillzz-collab/Vodkinnet-RT/main/vodkinnet-owrt-remote}"
ROOT="${ROOT:-/}"
SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd)"

# VodkinNET: fleet-standard colors/symbols, matching the palette used across
# the other install scripts in this monorepo. Colors are skipped when stdout
# isn't a real terminal (e.g. piped into a log file) so output stays clean.
if [ -t 1 ]; then
	C_RED='\033[0;31m'
	C_GREEN='\033[0;32m'
	C_YELLOW='\033[1;33m'
	C_CYAN='\033[0;36m'
	C_NC='\033[0m'
else
	C_RED=''
	C_GREEN=''
	C_YELLOW=''
	C_CYAN=''
	C_NC=''
fi

vodkin_banner() {
	printf '\n'
	printf '%b\n' "${C_CYAN}  ██╗   ██╗ ██████╗ ██████╗ ██╗  ██╗██╗███╗   ██╗${C_NC}"
	printf '%b\n' "${C_CYAN}  ██║   ██║██╔═══██╗██╔══██╗██║ ██╔╝██║████╗  ██║${C_NC}"
	printf '%b\n' "${C_CYAN}  ██║   ██║██║   ██║██║  ██║█████╔╝ ██║██╔██╗ ██║${C_NC}"
	printf '%b\n' "${C_CYAN}  ╚██╗ ██╔╝██║   ██║██║  ██║██╔═██╗ ██║██║╚██╗██║${C_NC}"
	printf '%b\n' "${C_CYAN}   ╚████╔╝ ╚██████╔╝██████╔╝██║  ██╗██║██║ ╚████║${C_NC}"
	printf '%b\n' "${C_CYAN}    ╚═══╝   ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝${C_NC}"
	printf '  %s\n' "${1:-OpenWrt Remote agent installer}"
	printf '  beverlypillzz-collab/Vodkinnet-RT\n\n'
}

info() {
	printf '%b[*]%b %s\n' "$C_CYAN" "$C_NC" "$*"
}

ok() {
	printf '%b[+]%b %s\n' "$C_GREEN" "$C_NC" "$*"
}

warn() {
	printf '%b[!]%b %s\n' "$C_YELLOW" "$C_NC" "$*" >&2
}

die() {
	printf '%b[!!] ERROR:%b %s\n' "$C_RED" "$C_NC" "$*" >&2
	exit 1
}

target_path() {
	printf '%s/%s' "${ROOT%/}" "$1"
}

vodkin_banner "OpenWrt Remote agent installer"
# VodkinNET: GitHub content is served from a small pool of Fastly edge IPs.
# Individual addresses in this pool are sometimes unreachable from a given
# network (observed live: 185.199.110.133 timed out for 5+ minutes while
# .108.133 worked instantly), and neither wget nor curl retry across DNS
# answers on their own - they just hang on whichever address the resolver
# handed them. Downloads that start at github.com (e.g. Xray release assets)
# get redirected internally by curl/wget through release-assets.
# githubusercontent.com - a different host than the one originally
# requested - so pinning only "the exact host that was asked for" misses the
# actual blocked hop. Pin the WHOLE known pool at once instead; they're
# served by the same Fastly infrastructure, so one working IP covers all of
# them, and every subsequent fetch in this run benefits automatically too.
_fastly_pool_hosts="raw.githubusercontent.com release-assets.githubusercontent.com objects.githubusercontent.com github-cloud.githubusercontent.com"

_host_of() {
	printf '%s' "$1" | sed -n 's#^https\?://\([^/]*\)/.*#\1#p'
}

_pin_fastly_pool() {
	local ip hosts_file tmp host ok
	hosts_file="$(target_path etc/hosts)"
	ok=""
	for ip in 185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133; do
		info "Пробую release-assets.githubusercontent.com через $ip..."
		if command -v curl >/dev/null 2>&1; then
			curl -fsS --connect-timeout 6 --resolve "release-assets.githubusercontent.com:443:$ip" \
				-o /dev/null "https://release-assets.githubusercontent.com/" 2>/dev/null && { ok="$ip"; break; }
		elif command -v wget >/dev/null 2>&1; then
			tmp="$(target_path tmp/.owrt-probe.$$)"
			printf '%s release-assets.githubusercontent.com\n' "$ip" >>"$hosts_file"
			wget -T 6 -q -O /dev/null "https://release-assets.githubusercontent.com/" 2>/dev/null && { ok="$ip"; break; }
			sed -i '/ release-assets\.githubusercontent\.com$/d' "$hosts_file" 2>/dev/null || true
		fi
	done
	[ -n "$ok" ] || return 1
	for host in $_fastly_pool_hosts; do
		tmp="$(target_path tmp/.owrt-hosts.$$)"
		if [ -f "$hosts_file" ]; then
			grep -v " $host\$" "$hosts_file" >"$tmp" 2>/dev/null || true
		else
			: >"$tmp"
		fi
		printf '%s %s\n' "$ok" "$host" >>"$tmp"
		cp "$tmp" "$hosts_file"
		rm -f "$tmp"
	done
	info "Зафиксировал весь пул GitHub-content хостов -> $ok"
	return 0
}

fetch() {
	local src dst host
	src="$1"
	dst="$2"
	if _fetch_once "$src" "$dst"; then
		return 0
	fi
	host="$(_host_of "$src")"
	info "Не удалось скачать с первой попытки ($host), проверяю известные IP CDN..."
	if _pin_fastly_pool; then
		_fetch_once "$src" "$dst" && return 0
	fi
	die "не удалось скачать $src (ни обычным DNS, ни через известные IP)"
}

_fetch_once() {
	local src dst
	src="$1"
	dst="$2"
	if command -v wget >/dev/null 2>&1; then
		wget -T 15 -O "$dst" "$src"
	elif command -v curl >/dev/null 2>&1; then
		curl -fsSL --connect-timeout 15 "$src" -o "$dst"
	else
		die "для удаленной установки нужен wget или curl"
	fi
}

install_file() {
	local rel mode src dst bust
	rel="$1"
	mode="$2"
	src="$SCRIPT_DIR/files/$rel"
	dst="$(target_path "$rel")"
	mkdir -p "$(dirname "$dst")"
	if [ -f "$src" ]; then
		cp "$src" "$dst"
	else
		bust="$(date +%s 2>/dev/null || echo $$)"
		fetch "$RAW_URL/files/$rel?v=$bust" "$dst"
	fi
	chmod "$mode" "$dst"
}

# VodkinNET: для shell-скриптов, которые исполняются позже без нашего
# присмотра (watchdog — раз в минуту через cron), проверяем sh -n ДО
# установки той же схемой tmp+mv, что и в install_owrt_remote_core() —
# битый файл не должен вообще попасть на диск по целевому пути.
install_file_checked() {
	local rel mode dst tmp bust
	rel="$1"
	mode="$2"
	dst="$(target_path "$rel")"
	tmp="${dst}.new.$$"
	mkdir -p "$(dirname "$dst")"

	if [ -f "$SCRIPT_DIR/files/$rel" ]; then
		cp "$SCRIPT_DIR/files/$rel" "$tmp"
	else
		bust="$(date +%s 2>/dev/null || echo $$)"
		fetch "$RAW_URL/files/$rel?v=$bust" "$tmp"
	fi

	if ! sh -n "$tmp"; then
		rm -f "$tmp"
		die "$rel не проходит проверку синтаксиса (sh -n) — установка остановлена"
	fi

	chmod "$mode" "$tmp"
	mv "$tmp" "$dst"
}

# VodkinNET: install.sh как одновременно и install-, и update-скрипт.
# Раньше повторный запуск install.sh на уже развёрнутом роутере просто
# перезаписывал usr/sbin/owrt-remote и etc/init.d/owrt-remote "начисто" —
# без бэкапа и без подключения к self-heal/watchdog-механизму из
# `owrt-remote update`. Один плохой коммит в files/ — и переустановка
# флота этим же install.sh рисковала тем же способом, что мы уже ловили
# руками на канарейке (тунель не поднялся, откатывать нечем и некому).
#
# Эта функция даёт install.sh те же гарантии:
#   - sh -n новых файлов ДО установки (не только для owrt-remote, но и
#     для init.d — тот самый файл, что уже один раз тихо ронял heartbeat-
#     инстанс при restart);
#   - если это ОБНОВЛЕНИЕ существующей установки (bin уже был) — текущие
#     версии обоих файлов бэкапятся в .bak (agent) / .bak (init.d);
#   - установка — атомарный mv, не cp поверх места назначения;
#   - выставляется тот же UPDATE_MARKER
#     (/etc/owrt-remote-update-pending), что читают self_heal_check() в
#     heartbeat_loop() САМОГО агента и независимый owrt-remote-watchdog —
#     то есть install.sh-апдейт проверяется и откатывается той же
#     инфраструктурой, что и `owrt-remote update`, без дублирования логики.
#   - на ПЕРВОЙ установке (bin ещё не было) маркер не ставится — откатывать
#     не на что, шуметь незачем.
install_owrt_remote_core() {
	local bin_rel initd_rel bin_dst initd_dst bin_bak initd_bak
	local tmp_bin tmp_initd bin_existed marker bust

	bin_rel="usr/sbin/owrt-remote"
	initd_rel="etc/init.d/owrt-remote"
	bin_dst="$(target_path "$bin_rel")"
	initd_dst="$(target_path "$initd_rel")"
	bin_bak="${bin_dst}.bak"
	initd_bak="${initd_dst}.bak"
	marker="$(target_path etc/owrt-remote-update-pending)"

	bin_existed=0
	[ -f "$bin_dst" ] && bin_existed=1

	mkdir -p "$(dirname "$bin_dst")" "$(dirname "$initd_dst")"

	tmp_bin="${bin_dst}.new.$$"
	tmp_initd="${initd_dst}.new.$$"

	if [ -f "$SCRIPT_DIR/files/$bin_rel" ]; then
		cp "$SCRIPT_DIR/files/$bin_rel" "$tmp_bin"
	else
		bust="$(date +%s 2>/dev/null || echo $$)"
		fetch "$RAW_URL/files/$bin_rel?v=$bust" "$tmp_bin"
	fi
	if [ -f "$SCRIPT_DIR/files/$initd_rel" ]; then
		cp "$SCRIPT_DIR/files/$initd_rel" "$tmp_initd"
	else
		bust="$(date +%s 2>/dev/null || echo $$)"
		fetch "$RAW_URL/files/$initd_rel?v=$bust" "$tmp_initd"
	fi

	if ! sh -n "$tmp_bin"; then
		rm -f "$tmp_bin" "$tmp_initd"
		die "новый owrt-remote не проходит проверку синтаксиса (sh -n) — установка остановлена, текущие файлы не тронуты"
	fi
	if ! sh -n "$tmp_initd"; then
		rm -f "$tmp_bin" "$tmp_initd"
		die "новый init.d/owrt-remote не проходит проверку синтаксиса (sh -n) — установка остановлена, текущие файлы не тронуты"
	fi

	chmod 0755 "$tmp_bin" "$tmp_initd"

	if [ "$bin_existed" = "1" ]; then
		cp "$bin_dst" "$bin_bak" 2>/dev/null || true
		[ -f "$initd_dst" ] && cp "$initd_dst" "$initd_bak" 2>/dev/null || true
	fi

	mv "$tmp_bin" "$bin_dst"
	mv "$tmp_initd" "$initd_dst"

	if [ "$bin_existed" = "1" ]; then
		date +%s >"$marker" 2>/dev/null || echo 0 >"$marker"
		info "Обнаружена предыдущая установка агента — бэкап сохранён (owrt-remote.bak / init.d.bak)."
		info "После рестарта self-heal (heartbeat-loop) и owrt-remote-watchdog сами проверят туннель и откатят, если тот не поднимется."
	fi
}

install_config() {
	local rel src dst bust
	rel="etc/config/owrtremote"
	src="$SCRIPT_DIR/files/$rel"
	dst="$(target_path "$rel")"
	mkdir -p "$(dirname "$dst")"
	if [ -f "$dst" ]; then
		info "Оставляю существующий конфиг: $dst"
		return
	fi
	if [ -f "$src" ]; then
		cp "$src" "$dst"
	else
		bust="$(date +%s 2>/dev/null || echo $$)"
		fetch "$RAW_URL/files/$rel?v=$bust" "$dst"
	fi
	chmod 0644 "$dst"
}

make_key() {
	local key_dir key_file key
	key_dir="$(target_path etc/owrt-remote)"
	key_file="$key_dir/web.key"
	mkdir -p "$key_dir"
	if [ ! -s "$key_file" ]; then
		if command -v base64 >/dev/null 2>&1; then
			key="$(head -c 32 /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -d '\n')"
		fi
		if [ -z "${key:-}" ] && command -v hexdump >/dev/null 2>&1; then
			key="$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | hexdump -v -e '16/1 "%02x"')"
		fi
		[ -n "${key:-}" ] || key="$(date +%s)-$$"
		printf '%s\n' "$key" >"$key_file"
	fi
	chmod 0600 "$key_file"
	cat "$key_file"
}

router_ip() {
	local ip
	if command -v uci >/dev/null 2>&1; then
		ip="$(uci -q get network.lan.ipaddr 2>/dev/null || true)"
		# VodkinNET: strip a CIDR suffix if present (e.g. "10.0.0.1/27") -
		# this is what caused the panel URL printed at the end of install to
		# show up as "http://10.0.0.1/28/cgi-bin/..." with a stray path
		# segment on some routers.
		ip="${ip%%/*}"
		if [ -n "$ip" ]; then
			printf '%s\n' "$ip"
			return
		fi
	fi
	ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
	if [ -n "$ip" ]; then
		printf '%s\n' "$ip"
		return
	fi
	printf '192.168.1.1'
}

installed_ui_version() {
	local file
	file="$(target_path www/cgi-bin/owrt-remote)"
	awk -F '"' '/^OWRT_REMOTE_UI_VERSION=/ { print $2; exit }' "$file" 2>/dev/null || true
}

openwrt_version() {
	local file
	file="$(target_path etc/openwrt_release)"
	if [ -r "$file" ]; then
		(
			. "$file" 2>/dev/null
			printf '%s %s' "${DISTRIB_ID:-OpenWrt}" "${DISTRIB_RELEASE:-unknown}"
		)
		return
	fi
	printf 'OpenWrt unknown'
}

package_manager() {
	if command -v apk >/dev/null 2>&1; then
		printf 'apk'
		return
	fi
	if command -v opkg >/dev/null 2>&1; then
		printf 'opkg'
		return
	fi
	printf 'unknown'
}

install_xray_runtime() {
	local remote_bin
	[ "${ROOT%/}" = "" ] || return 0
	remote_bin="$(target_path usr/sbin/owrt-remote)"
	[ -x "$remote_bin" ] || die "missing $remote_bin after install"
	info "Installing Xray to /tmp..."
	"$remote_bin" install-xray-tmp || die "failed to install Xray to /tmp"
}

# VodkinNET: owrt-remote-watchdog — намеренно отдельный от owrt-remote файл
# (см. комментарий в самом watchdog-скрипте: не должен зависеть от
# исправности агента, который он же и откатывает). В install.sh он поэтому
# тоже ставится и включается отдельным шагом, не как часть install_file()
# основного агента. Идемпотентно: повторный запуск install.sh (переустановка
# существующего роутера при апдейте фикса) не плодит вторую строку в cron.
install_watchdog_cron() {
	local cron_file marker cron_line
	cron_file="$(target_path etc/crontabs/root)"
	marker="owrt-remote-watchdog"
	cron_line="* * * * * /usr/sbin/owrt-remote-watchdog"

	mkdir -p "$(dirname "$cron_file")"
	[ -f "$cron_file" ] || : >"$cron_file"

	if grep -q "$marker" "$cron_file" 2>/dev/null; then
		return 0
	fi

	printf '%s\n' "$cron_line" >>"$cron_file"
	info "owrt-remote-watchdog добавлен в cron (проверка раз в минуту)."

	if [ -x "$(target_path etc/init.d/cron)" ]; then
		"$(target_path etc/init.d/cron)" restart >/dev/null 2>&1 || true
	fi
}

install_owrt_remote_core
install_file_checked "usr/sbin/owrt-remote-watchdog" 0755
install_config
install_file "www/cgi-bin/owrt-remote" 0755
install_file "usr/share/luci/menu.d/luci-app-owrt-remote.json" 0644
install_file "usr/share/rpcd/acl.d/luci-app-owrt-remote.json" 0644
install_file "www/luci-static/resources/view/owrt_remote.js" 0644

rm -f "$(target_path usr/lib/lua/luci/controller/owrt_remote.lua)" 2>/dev/null || true
rm -rf "$(target_path tmp/luci-indexcache)" "$(target_path tmp/luci-modulecache)" "$(target_path tmp/luci-indexcache.)"* "$(target_path tmp/luci-modulecache.)"* 2>/dev/null || true

if [ -x "$(target_path etc/init.d/rpcd)" ]; then
	"$(target_path etc/init.d/rpcd)" restart >/dev/null 2>&1 || true
fi

if [ -x "$(target_path etc/init.d/uhttpd)" ]; then
	"$(target_path etc/init.d/uhttpd)" reload >/dev/null 2>&1 || "$(target_path etc/init.d/uhttpd)" restart >/dev/null 2>&1 || true
fi

install_xray_runtime
install_watchdog_cron

# VodkinNET: fleet standard — management daemons are bound to the 'lan'
# interface only (not loopback), as part of the "manage from one admin IP
# only" hardening pattern applied across the whole router fleet. Under that
# setup uhttpd's forced HTTP->HTTPS redirect breaks the tunnel's plain-TCP
# forward to LuCI (redirect_https returns a 307 the tunnel can't follow).
# The LuCI session is still protected end-to-end by the reverse channel's own
# TLS (VPS<->router), so disabling this LOCAL redirect is safe here and is
# the expected setup for every VodkinNET router. Skip with
# OWRT_REMOTE_KEEP_HTTPS_REDIRECT=1 if you don't want this behavior.
if [ "${OWRT_REMOTE_KEEP_HTTPS_REDIRECT:-0}" != "1" ]; then
	if uci -q get uhttpd.main >/dev/null 2>&1; then
		current_redirect="$(uci -q get uhttpd.main.redirect_https 2>/dev/null || true)"
		if [ "$current_redirect" != "0" ]; then
			uci set uhttpd.main.redirect_https='0'
			uci commit uhttpd
			if [ -x "$(target_path etc/init.d/uhttpd)" ]; then
				"$(target_path etc/init.d/uhttpd)" restart >/dev/null 2>&1 || true
			fi
			info "uhttpd.main.redirect_https отключён (fleet-стандарт для reverse-туннеля)."
			info "  LuCI-сессия защищена TLS reverse-канала (VPS<->роутер), локальный редирект был лишним и ломал туннель."
			info "  Отключить это поведение установщика: OWRT_REMOTE_KEEP_HTTPS_REDIRECT=1"
		fi
	fi
fi

key="$(make_key)"
ip="$(router_ip)"
ui_version="$(installed_ui_version)"
owrt_version="$(openwrt_version)"
pkg_manager="$(package_manager)"

info "OpenWrt Remote установлен."
info "OpenWrt: $owrt_version"
info "PKG:    $pkg_manager"
if [ -n "$ui_version" ]; then
	info "UI:     $ui_version"
fi
info "LuCI:   Службы -> OpenWrt Remote"
info "Панель: http://$ip/cgi-bin/owrt-remote?key=$key"
info "CLI:    owrt-remote doctor"
info "Xray:   если пишет 'нет Xray', нажми в панели 'Поставить Xray в /tmp' или выполни: owrt-remote install-xray-tmp"

cat <<'EOF'

Дальше (регистрация в Hub на VPS для удалённого доступа):
  1. В панели Hub -> "+ Добавить роутер": id, название, роль, VPS-хост,
     ENTRY PORT (свободный порт на этом VPS — панель подскажет, если
     порт уже занят другим роутером).
  2. Нажми "Обновить Xray CFG", затем "Рестарт Xray VPS" (это НЕ
     происходит автоматически при добавлении роутера — нужно руками
     после каждого изменения списка роутеров).
  3. Открой "Конфиг" в карточке роутера -> вставь текст целиком в
     /etc/config/owrtremote на этом роутере.
  4. /etc/init.d/owrt-remote restart
  5. owrt-remote doctor

EOF
