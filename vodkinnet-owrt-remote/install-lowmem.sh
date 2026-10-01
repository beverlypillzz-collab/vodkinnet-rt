#!/bin/sh
# VodkinNET: install-lowmem.sh — надстройка для роутеров с ОБРАТНЫМ
# профилем нехватки ресурсов: flash в достатке, а RAM впритык (основной
# install.sh рассчитан на противоположный, куда более частый случай —
# экономит flash, держа Xray-бинарник в /tmp/tmpfs, то есть в RAM).
#
# ПОЧТИ ПОЛНОСТЬЮ ОТДЕЛЬНЫЙ файл — вызывает обычный install.sh как есть,
# меняя единственное: куда install.sh (через owrt-remote install-xray-tmp)
# скачивает и распаковывает Xray. Это единственный зацеп с основным
# агентом — переменная окружения OWRT_REMOTE_XRAY_DIR, которую понимает
# install_xray_tmp() в files/usr/sbin/owrt-remote (по умолчанию для
# обычного install.sh она не задана и поведение не меняется).
#
# Живой инцидент 2026-10-01 (канарейка клиента, Xiaomi Redmi AC2100):
# прежняя версия этого файла качала и распаковывала Xray в /tmp (tmpfs,
# то есть RAM) НА ШАГЕ 1 через обычный install.sh, и только ПОТОМ, шагом 2,
# переносила готовый бинарник на flash — то есть "экономия RAM" наступала
# уже ПОСЛЕ того, как самый прожорливый момент (скачка 27MB zip + распаковка
# ~30MB бинарника, пиково ~60-70MB) уже случился в RAM. На этом роутере
# ровно в этот момент сработал OOM killer: процесс "Killed", SSH оборвался.
# Экономить RAM "постфактум" бессмысленно для роутера, у которого этого
# RAM не хватает уже на само скачивание.
#
# Фикс: больше не переносим бинарник после установки — сразу просим agent
# качать и распаковывать Xray прямо на flash (XRAY_FLASH_DIR ниже), минуя
# tmpfs целиком. Шаг "перенос" остался только как подстраховка на случай,
# если xray_bin почему-то всё равно указывает на /tmp (например, старая
# версия owrt-remote без поддержки OWRT_REMOTE_XRAY_DIR ещё не обновилась).
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
XRAY_FLASH_DIR="/usr/lib/owrt-remote-xray"

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

# --- Шаг 1: установка основного агента, Xray качается СРАЗУ на flash ---
info "Шаг 1/2: установка агента (install.sh), Xray качается сразу на flash, минуя RAM."
mkdir -p "$XRAY_FLASH_DIR"
export OWRT_REMOTE_XRAY_DIR="$XRAY_FLASH_DIR"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/install.sh" ]; then
	sh "$SCRIPT_DIR/install.sh"
else
	tmp_install="/tmp/.owrt-remote-install.$$"
	fetch_to "$RAW_URL/install.sh" "$tmp_install" || die "не смог скачать install.sh"
	sh "$tmp_install"
	rm -f "$tmp_install"
fi

command -v uci >/dev/null 2>&1 || die "uci не найден — это точно OpenWrt?"

# --- Подстраховка: если xray_bin всё равно указывает на /tmp (старый ---
# --- owrt-remote без поддержки OWRT_REMOTE_XRAY_DIR) - перенести вручную ---
current_bin="$(uci -q get owrtremote.main.xray_bin 2>/dev/null || true)"

if [ -z "$current_bin" ] || [ ! -x "$current_bin" ]; then
	die "не нашёл установленный Xray (owrtremote.main.xray_bin) — install.sh на шаге 1 должен был его поставить"
fi

case "$current_bin" in
	"$XRAY_FLASH_DIR"/*)
		ok "Xray уже на flash: $current_bin (качался сразу туда, RAM на распаковку не тратилась)."
		;;
	/tmp/*)
		warn "xray_bin всё ещё указывает на /tmp ($current_bin) — похоже, на роутере старая версия owrt-remote без поддержки OWRT_REMOTE_XRAY_DIR. Переношу постфактум (это тот самый RAM-тяжёлый путь, который и чинит этот скрипт — обнови агент, если видишь это предупреждение)."
		entry="${current_bin##*/}"
		cp "$current_bin" "$XRAY_FLASH_DIR/$entry"
		chmod +x "$XRAY_FLASH_DIR/$entry"
		uci set owrtremote.main.xray_bin="$XRAY_FLASH_DIR/$entry"
		uci commit owrtremote
		ok "Xray перенесён: $current_bin (RAM) -> $XRAY_FLASH_DIR/$entry (flash)."
		;;
	*)
		warn "xray_bin указывает на нестандартный путь ($current_bin) — не трогаю, разбирайтесь руками."
		;;
esac

# --- Шаг 2/2: owrt-remote-recycle — периодический профилактический рестарт ---
info "Шаг 2/2: ставлю owrt-remote-recycle (периодический рестарт, по умолчанию ВЫКЛЮЧЕН)."

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
