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

# VodkinNET: живой баг, найденный вживую на канарейках (VodkinR15/node-8/
# node-10, 2026-09-05 и 2026-09-07/08) — свежие сборки OpenWrt (WR3000U,
# WBR3000UAX) держат uhttpd.main.redirect_https='1'. Hub ходит к веб-морде
# роутера по чистому HTTP (шифрование уже есть на уровне VLESS-туннеля +
# TLS самого Hub) — с этой настройкой ЛЮБОЙ такой запрос получает 307 на
# https://<тот же хост>/<тот же путь>, что после переписывания указывает
# ровно на исходный URL — бесконечный цикл в браузере.
#
# Глобально гасить redirect_https на uhttpd.main НЕЛЬЗЯ — это тот же
# инстанс, что защищает LAN-доступ HTTPS'ом локально, и эта защита реально
# нужна и востребована (в отличие от более раннего предположения в этом
# же файле, что LAN-HTTPS не имеет значения — имеет).
#
# Решение: отдельный, ВТОРОЙ инстанс uhttpd, слушающий ТОЛЬКО 127.0.0.1
# на своём порту, без redirect_https, специально для туннеля. Основной
# инстанс (LAN) не трогаем вообще — ни порты, ни redirect_https.
#
# КРИТИЧНО: admin_host и admin_port меняются ТОЛЬКО вместе, никогда по
# отдельности. Живой инцидент 2026-09-07/08 — предыдущая версия этой
# функции меняла только admin_port, admin_host оставался прежним LAN IP.
# Реверс-туннель пытался достучаться на "<LAN IP>:<новый порт>", где
# физически никто не слушает (новый инстанс слушает 127.0.0.1, не LAN
# IP) — несколько часов диагностики на живом флоте, прежде чем нашли.
port_is_free() {
	local port="$1" hex busy
	hex="$(printf '%04X' "$port")"
	busy="$(awk -v hex="$hex" '
		$4 == "0A" {
			split($2, a, ":")
			if (a[2] == hex && (a[1] == "00000000" || a[1] == "0100007F")) { print "busy"; exit }
		}
	' /proc/net/tcp 2>/dev/null)"
	[ -z "$busy" ]
}

find_free_loopback_port() {
	local port=8080
	while [ "$port" -lt 8180 ]; do
		if port_is_free "$port"; then
			printf '%s' "$port"
			return 0
		fi
		port=$((port + 10))
	done
	return 1
}

setup_tunnel_admin_uhttpd() {
	local uhttpd_bin section existing_port lua_prefixes lp
	uhttpd_bin="$(target_path etc/init.d/uhttpd)"
	[ -x "$uhttpd_bin" ] || return 0
	command -v uci >/dev/null 2>&1 || return 0

	section="owrt_remote_admin"

	# Уже настроено раньше (повторный запуск install.sh) — переиспользуем
	# существующий порт, не плодим второй инстанс поверх первого.
	existing_port="$(uci -q get "uhttpd.${section}.listen_http" 2>/dev/null | sed -n 's/^127\.0\.0\.1:\([0-9]*\)$/\1/p')"
	if [ -n "$existing_port" ]; then
		TUNNEL_ADMIN_PORT="$existing_port"
		return 0
	fi

	TUNNEL_ADMIN_PORT="$(find_free_loopback_port)" || {
		info "не нашёл свободный loopback-порт для отдельного uhttpd-инстанса, редирект-цикл придётся чинить вручную"
		return 1
	}

	uci -q delete "uhttpd.${section}" 2>/dev/null || true
	uci set "uhttpd.${section}=uhttpd"
	uci set "uhttpd.${section}.listen_http=127.0.0.1:${TUNNEL_ADMIN_PORT}"
	uci set "uhttpd.${section}.redirect_https=0"
	uci set "uhttpd.${section}.home=$(uci -q get uhttpd.main.home || echo /www)"
	uci set "uhttpd.${section}.cgi_prefix=$(uci -q get uhttpd.main.cgi_prefix || echo /cgi-bin)"
	uci set "uhttpd.${section}.ubus_prefix=$(uci -q get uhttpd.main.ubus_prefix || echo /ubus)"
	uci set "uhttpd.${section}.script_timeout=$(uci -q get uhttpd.main.script_timeout || echo 60)"
	uci set "uhttpd.${section}.network_timeout=$(uci -q get uhttpd.main.network_timeout || echo 30)"
	uci set "uhttpd.${section}.max_requests=$(uci -q get uhttpd.main.max_requests || echo 3)"
	uci set "uhttpd.${section}.max_connections=$(uci -q get uhttpd.main.max_connections || echo 100)"
	uci -q delete "uhttpd.${section}.lua_prefix" 2>/dev/null || true
	lua_prefixes="$(uci -q get uhttpd.main.lua_prefix 2>/dev/null || true)"
	for lp in $lua_prefixes; do
		uci add_list "uhttpd.${section}.lua_prefix=$lp"
	done
	uci commit uhttpd
	info "второй uhttpd-инстанс на 127.0.0.1:${TUNNEL_ADMIN_PORT} (только туннель, без redirect_https) — LAN-инстанс (0.0.0.0:80/443, redirect_https) не тронут."
	"$uhttpd_bin" restart >/dev/null 2>&1 || true
}

# VodkinNET: живой инцидент 2026-09-08/10 (node-6/node-8) — раньше
# смена admin_host/admin_port + рестарт агента происходили ЗДЕСЬ, ДО
# install_owrt_remote_core (скачивание и атомарная замена бинарника
# агента). Если install.sh выполнялся через встроенный SSH-веб-терминал
# самой панели — то есть команды шли через тот же самый реверс-туннель,
# который этот рестарт и обрывал, — рестарт разрывал СВОЮ ЖЕ SSH-сессию
# раньше, чем скрипт успевал докачать остальные файлы. Два роутера
# остались в наполовину установленном состоянии, self-heal не спас,
# потому что сам агент не успел подняться корректно, чтобы его
# запустить. Поэтому смена admin_host/admin_port и рестарт агента
# ТЕПЕРЬ — это finalize_tunnel_admin_config(), вызывается САМОЙ ПОСЛЕДНЕЙ
# строкой во всём файле, когда абсолютно всё остальное (бинарник агента,
# watchdog, конфиг, финальная инструкция «Дальше») уже гарантированно
# установлено и показано пользователю. Если этот последний рестарт всё
# же оборвёт SSH-сессию — терять уже нечего, всё нужное уже на месте.
#
# Дополнительно (по итогам того же инцидента): перед тем как вообще
# трогать admin_host/admin_port, проверяем, что новый uhttpd-инстанс
# реально слушает (через port_is_free — не через HTTP-статус, который
# может путать 403/404 с реальной поломкой) и что сам агент физически
# на месте и проходит sh -n. Если что-то не так — конфиг НЕ трогаем
# вообще, рестарт отменяется, старые (рабочие) значения остаются как
# были. Если всё в порядке — взводим CONFIG_MARKER с сохранёнными
# старыми значениями, чтобы self-heal самого агента (см.
# self_heal_check_config/rollback_tunnel_admin_config в
# usr/sbin/owrt-remote) мог откатить это назад сам, без участия
# человека, если турна после рестарта так и не поднимется.
finalize_tunnel_admin_config() {
	local old_admin_host old_admin_port initd agent_bin config_marker
	[ -n "${TUNNEL_ADMIN_PORT:-}" ] || return 0
	[ -f "$(target_path etc/config/owrtremote)" ] || return 0
	uci -q get owrtremote.main >/dev/null 2>&1 || return 0

	old_admin_host="$(uci -q get owrtremote.main.admin_host 2>/dev/null)" || old_admin_host="__UNSET__"
	old_admin_port="$(uci -q get owrtremote.main.admin_port 2>/dev/null)" || old_admin_port="__UNSET__"

	# Уже в нужном состоянии — идемпотентный повторный запуск, менять и
	# рестартовать нечего.
	if [ "$old_admin_host" = "127.0.0.1" ] && [ "$old_admin_port" = "$TUNNEL_ADMIN_PORT" ]; then
		return 0
	fi

	if port_is_free "$TUNNEL_ADMIN_PORT"; then
		info "второй uhttpd-инстанс на 127.0.0.1:${TUNNEL_ADMIN_PORT} не слушает — admin_host/admin_port НЕ трогаю, рестарт отменён. Проверьте uhttpd.owrt_remote_admin вручную."
		return 1
	fi

	agent_bin="$(target_path usr/sbin/owrt-remote)"
	if [ ! -x "$agent_bin" ]; then
		info "агент ${agent_bin} отсутствует или не исполняемый — admin_host/admin_port НЕ трогаю, рестарт отменён."
		return 1
	fi
	if ! sh -n "$agent_bin" 2>/dev/null; then
		info "агент ${agent_bin} не проходит проверку синтаксиса (sh -n) — admin_host/admin_port НЕ трогаю, рестарт отменён."
		return 1
	fi

	uci set owrtremote.main.admin_host="127.0.0.1"
	uci set owrtremote.main.admin_port="$TUNNEL_ADMIN_PORT"
	uci commit owrtremote

	initd="$(target_path etc/init.d/owrt-remote)"
	if [ -x "$initd" ]; then
		config_marker="$(target_path etc/owrt-remote-config-pending)"
		{
			date +%s 2>/dev/null || echo 0
			printf '%s\n' "$old_admin_host"
			printf '%s\n' "$old_admin_port"
		} > "$config_marker" 2>/dev/null

		info "admin_host/admin_port изменились — перезапускаю owrt-remote (это последний шаг установки). Если туннель не поднимется, self-heal сам откатит это назад через rollback_grace_seconds."
		( "$initd" restart >/dev/null 2>&1 & )
	fi
}

setup_tunnel_admin_uhttpd
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

finalize_tunnel_admin_config
