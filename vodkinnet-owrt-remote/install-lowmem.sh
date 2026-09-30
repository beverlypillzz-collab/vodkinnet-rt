#!/bin/sh
# VodkinNET: install-lowmem.sh — надстройка для роутеров с ОБРАТНЫМ
# профилем нехватки ресурсов: flash в достатке, а RAM впритык (основной
# install.sh рассчитан на противоположный, куда более частый случай —
# экономит flash, держа Xray-бинарник в /tmp/tmpfs, то есть в RAM).
#
# ПОЛНОСТЬЮ ОТДЕЛЬНЫЙ файл. НЕ меняет ни files/usr/sbin/owrt-remote, ни
# install.sh, ни что-либо ещё в основном агенте — просто вызывает обычный
# install.sh как есть, а затем двумя дополнительными шагами (поверх уже
# установленного агента, через штатный uci) переносит Xray-бинарник на
# flash и ставит опциональный периодический рестарт сервиса. Если что-то
# в этих двух шагах пойдёт не так — базовый агент от install.sh уже
# установлен и работает, это не совмещённый атомарный процесс.
#
# Используется ВМЕСТО install.sh (не вместе с ним) на роутерах, где
# `free`/карточка в панели показывает мало доступной RAM при достаточном
# свободном flash. Для всех остальных роутеров флота — обычный install.sh,
# этот файл на них вообще не скачивается и никак их не касается.
#
# Использование:
#   wget -O - "https://raw.githubusercontent.com/beverlypillzz-collab/Vodkinnet-RT/main/vodkinnet-owrt-remote/install-lowmem.sh?v=$(date +%s)" | sh

set -eu

export PATH="/bin:/sbin:/usr/bin:/usr/sbin:${PATH:-}"

RAW_URL="${RAW_URL:-https://raw.githubusercontent.com/beverlypillzz-collab/Vodkinnet-RT/main/vodkinnet-owrt-remote}"
SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" 2>/dev/null && pwd)" || SCRIPT_DIR=""

info() { printf '[*] %s\n' "$*"; }
ok() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[!!] ОШИБКА: %s\n' "$*" >&2; exit 1; }

fetch_to() {
	# VodkinNET: та же логика повторной попытки через известный пул Fastly
	# edge-IP, что в install.sh/owrt-remote — не дублируем здесь целиком,
	# достаточно простого fetch с одной попыткой curl/wget: этот скрипт
	# запускается руками при физическом визите, а не автоматически без
	# присмотра, так что при сбое сети проще просто перезапустить вручную.
	url="$1"
	dst="$2"
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --connect-timeout 15 "$url" -o "$dst"
	elif command -v wget >/dev/null 2>&1; then
		wget -T 15 -q -O "$dst" "$url"
	else
		die "нужен curl или wget"
	fi
}

# --- Шаг 1: обычная, ничем не отличающаяся установка основного агента ---
info "Шаг 1/3: обычная установка агента (install.sh, без изменений)."
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/install.sh" ]; then
	sh "$SCRIPT_DIR/install.sh"
else
	tmp_install="/tmp/.owrt-remote-install.$$"
	fetch_to "$RAW_URL/install.sh" "$tmp_install" || die "не смог скачать install.sh"
	sh "$tmp_install"
	rm -f "$tmp_install"
fi

command -v uci >/dev/null 2>&1 || die "uci не найден — это точно OpenWrt?"

# --- Шаг 2: перенос Xray-бинарника из /tmp (RAM) на flash ---
info "Шаг 2/3: переношу Xray-бинарник с RAM (/tmp) на flash."

XRAY_FLASH_DIR="/usr/lib/owrt-remote-xray"
current_bin="$(uci -q get owrtremote.main.xray_bin 2>/dev/null || true)"

if [ -z "$current_bin" ] || [ ! -x "$current_bin" ]; then
	die "не нашёл установленный Xray (owrtremote.main.xray_bin) — install.sh на шаге 1 должен был его поставить"
fi

case "$current_bin" in
	/tmp/*)
		entry="${current_bin##*/}"
		mkdir -p "$XRAY_FLASH_DIR"
		cp "$current_bin" "$XRAY_FLASH_DIR/$entry"
		chmod +x "$XRAY_FLASH_DIR/$entry"
		# VodkinNET: owrt-remote сам по себе уже поддерживает произвольный
		# xray_bin — xray_bin_path()/ensure_xray_available() в
		# files/usr/sbin/owrt-remote проверяют совпадение версии по
		# зафиксированному OWRT_REMOTE_PINNED_XRAY_VERSION, а не то, что
		# путь именно /tmp/owrt-xray/xray. Так что просто меняем uci —
		# никакой код агента трогать не нужно.
		uci set owrtremote.main.xray_bin="$XRAY_FLASH_DIR/$entry"
		uci commit owrtremote
		ok "Xray перенесён: $current_bin (RAM) -> $XRAY_FLASH_DIR/$entry (flash). Освобождено ~$(du -h "$XRAY_FLASH_DIR/$entry" 2>/dev/null | cut -f1) RAM, бинарник переживёт перезагрузку (не будет качаться заново с GitHub при каждом старте)."
		;;
	"$XRAY_FLASH_DIR"/*)
		info "Xray уже на flash ($current_bin) — этот скрипт уже запускали, шаг 2 пропущен."
		;;
	*)
		warn "xray_bin указывает на нестандартный путь ($current_bin) — переносить не стал, разбирайтесь руками."
		;;
esac

# --- Шаг 3: owrt-remote-recycle — периодический профилактический рестарт ---
info "Шаг 3/3: ставлю owrt-remote-recycle (периодический рестарт, по умолчанию ВЫКЛЮЧЕН)."

recycle_dst="/usr/sbin/owrt-remote-recycle"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/files/usr/sbin/owrt-remote-recycle" ]; then
	cp "$SCRIPT_DIR/files/usr/sbin/owrt-remote-recycle" "$recycle_dst"
else
	tmp_recycle="${recycle_dst}.new.$$"
	fetch_to "$RAW_URL/files/usr/sbin/owrt-remote-recycle" "$tmp_recycle" || die "не смог скачать owrt-remote-recycle"
	if ! sh -n "$tmp_recycle"; then
		rm -f "$tmp_recycle"
		die "owrt-remote-recycle не прошёл проверку синтаксиса (sh -n) — не устанавливаю"
	fi
	mv "$tmp_recycle" "$recycle_dst"
fi
chmod 0755 "$recycle_dst"

cron_file="/etc/crontabs/root"
mkdir -p "$(dirname "$cron_file")"
[ -f "$cron_file" ] || : >"$cron_file"
if grep -q "owrt-remote-recycle" "$cron_file" 2>/dev/null; then
	info "owrt-remote-recycle уже в cron — строку не дублирую."
else
	printf '0 * * * * /usr/sbin/owrt-remote-recycle\n' >>"$cron_file"
	if [ -x /etc/init.d/cron ]; then
		/etc/init.d/cron restart >/dev/null 2>&1 || true
	fi
	ok "owrt-remote-recycle установлен и добавлен в cron (проверка раз в час, сам по себе ничего не делает)."
fi

printf '\n'
ok "Готово. Xray теперь на flash, owrt-remote-recycle установлен, но выключен."
printf '\n'
printf 'Чтобы включить периодический профилактический рестарт сервиса (защита от\n'
printf 'постепенного роста потребления памяти за долгий аптайм) — выполните:\n\n'
printf '    uci set owrtremote.main.recycle_interval_hours='"'"'12'"'"'\n'
printf '    uci commit owrtremote\n\n'
printf 'Значение — интервал в часах между профилактическими рестартами.\n'
printf '0 (или не задано) — выключено, это значение по умолчанию.\n'
