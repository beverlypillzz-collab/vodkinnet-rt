#!/bin/sh
# netcraze-remote — установка агента на Keenetic/KNDMS (через Entware).
# Запуск на самом роутере (SSH после установки Entware):
#   curl -fsSL "https://raw.githubusercontent.com/beverlypillzz-collab/vodkinnet-rt/main/vodkinnet-keenetic/netcraze-remote/install.sh?v=$(date +%s)" | sh

set -eu

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/beverlypillzz-collab/vodkinnet-rt/main/vodkinnet-keenetic/netcraze-remote}"

C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_NC='\033[0m'
ok()   { printf '%b[+]%b %s\n' "$C_GREEN" "$C_NC" "$*"; }
info() { printf '%b[i]%b %s\n' "$C_YELLOW" "$C_NC" "$*"; }
die()  { printf '%b[!!] ОШИБКА:%b %s\n' "$C_RED" "$C_NC" "$*" >&2; exit 1; }

# --- 1. проверка Entware (ФУНКЦИОНАЛЬНАЯ, не просто "opkg есть в PATH") ---
# VodkinNET: на KNDMS документирован баг, когда Entware "числится" включённым
# на диске, но по факту не развёрнут — простого "command -v opkg" для этого
# недостаточно (см. netcraze_vpn_setup_summary.md, "disk is unchanged").
command -v opkg >/dev/null 2>&1 || die "opkg не найден. Сначала поставь Entware (System Tool -> Components -> OPKG) и зайди по SSH заново."
[ -x /opt/bin/opkg ] || die "/opt/bin/opkg не исполняемый — Entware не развёрнут по-настоящему."
[ -f /opt/etc/opkg.conf ] || die "/opt/etc/opkg.conf не найден — похоже на неполную установку Entware (см. System Log на 5 шагов установки)."
opkg --version >/dev/null 2>&1 || die "opkg есть, но не отвечает (opkg --version упал) — Entware не работает по-настоящему."
if command -v stat >/dev/null 2>&1; then
	root_dev="$(stat -c %d / 2>/dev/null || true)"
	opt_dev="$(stat -c %d /opt 2>/dev/null || true)"
	if [ -n "$root_dev" ] && [ -n "$opt_dev" ] && [ "$root_dev" = "$opt_dev" ]; then
		die "/opt смонтирован на том же устройстве, что и /, — это НЕ отдельная Entware-флешка (проверь, что флешка физически подключена и примонтирована)."
	fi
fi

info "Entware работает по-настоящему: $(opkg --version 2>/dev/null | head -n1 || echo ok)"

# --- 2. xray-core (переиспользуем существующий бинарь, если он уже стоит для XKeen) ---
XRAY_FOUND=""
for candidate in /opt/sbin/xray /opt/bin/xray /opt/usr/bin/xray-core /opt/sbin/xray-core; do
	if [ -x "$candidate" ]; then
		XRAY_FOUND="$candidate"
		break
	fi
done

if [ -n "$XRAY_FOUND" ]; then
	ok "xray-core уже установлен: $XRAY_FOUND (переиспользую, отдельный процесс netcraze-remote его не трогает)"
else
	info "xray-core не найден, ставлю через opkg..."
	opkg update
	opkg install xray-core || die "не удалось поставить xray-core"
	ok "xray-core установлен"
fi

# --- 3. curl/wget для heartbeat ---
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
	info "ставлю curl (нужен для heartbeat)..."
	opkg install curl || opkg install wget-ssl || die "нужен curl или wget"
fi

# --- 4. директории ---
mkdir -p /opt/etc/netcraze-remote
mkdir -p /opt/etc/init.d
mkdir -p /opt/sbin
mkdir -p /opt/var/run/netcraze-remote
mkdir -p /opt/var/log

# --- 5. файлы ---
fetch() {
	# fetch URL DEST
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL "$1" -o "$2"
	else
		wget -q -O "$2" "$1"
	fi
}

# VodkinNET: install.sh как одновременно и install-, и update-скрипт (тот
# же приём, что и в vodkinnet-owrt-remote, см. его changelog за
# 2026-08-23). Раньше install.sh просто перезаписывал агент и init-скрипт
# "начисто" — без бэкапа, без sh -n, без атомарности. Один плохой коммит —
# и переустановка флота этим же install.sh рисковала тем же, что уже было
# поймано вживую на канарейке owrt-remote (тоннель не поднялся, откатывать
# нечем).
#
# Даёт те же гарантии: sh -n новых файлов ДО установки; если это ОБНОВЛЕНИЕ
# существующей установки (агент уже стоял) — бэкап обоих файлов в .bak;
# установка — атомарный mv; выставляется тот же UPDATE_MARKER, который
# читают self_heal_check() внутри агента и независимый
# netcraze-remote-watchdog. На ПЕРВОЙ установке маркер не ставится —
# откатывать не на что.
install_agent_core() {
	local agent_dst initd_dst agent_bak initd_bak marker agent_existed
	local tmp_agent tmp_initd bust

	agent_dst="/opt/sbin/netcraze-remote"
	initd_dst="/opt/etc/init.d/S99netcraze-remote"
	agent_bak="${agent_dst}.bak"
	initd_bak="${initd_dst}.bak"
	marker="/opt/etc/netcraze-remote/update-pending"

	agent_existed=0
	[ -f "$agent_dst" ] && agent_existed=1

	tmp_agent="${agent_dst}.new.$$"
	tmp_initd="${initd_dst}.new.$$"
	bust="$(date +%s 2>/dev/null || echo $$)"

	fetch "${REPO_RAW}/files/opt/sbin/netcraze-remote?v=${bust}" "$tmp_agent"
	fetch "${REPO_RAW}/files/opt/etc/init.d/S99netcraze-remote?v=${bust}" "$tmp_initd"

	if ! sh -n "$tmp_agent"; then
		rm -f "$tmp_agent" "$tmp_initd"
		die "новый netcraze-remote не проходит проверку синтаксиса (sh -n) — установка остановлена, текущие файлы не тронуты"
	fi
	if ! sh -n "$tmp_initd"; then
		rm -f "$tmp_agent" "$tmp_initd"
		die "новый init-скрипт не проходит проверку синтаксиса (sh -n) — установка остановлена, текущие файлы не тронуты"
	fi

	chmod +x "$tmp_agent" "$tmp_initd"

	if [ "$agent_existed" = "1" ]; then
		cp "$agent_dst" "$agent_bak" 2>/dev/null || true
		[ -f "$initd_dst" ] && cp "$initd_dst" "$initd_bak" 2>/dev/null || true
	fi

	mv "$tmp_agent" "$agent_dst"
	mv "$tmp_initd" "$initd_dst"

	if [ "$agent_existed" = "1" ]; then
		date +%s >"$marker" 2>/dev/null || echo 0 >"$marker"
		info "Обнаружена предыдущая установка агента — бэкап сохранён (netcraze-remote.bak / init.d.bak)."
		info "После рестарта self-heal (heartbeat-loop) и netcraze-remote-watchdog сами проверят туннель и откатят, если тот не поднимется."
	fi
}

info "устанавливаю агент и init-скрипт..."
install_agent_core

# VodkinNET: watchdog — тоже через sh -n перед установкой, тем же
# принципом, что и выше (файл исполняется потом без нашего присмотра,
# по cron).
info "устанавливаю netcraze-remote-watchdog..."
tmp_watchdog="/opt/sbin/netcraze-remote-watchdog.new.$$"
fetch "${REPO_RAW}/files/opt/sbin/netcraze-remote-watchdog?v=$(date +%s)" "$tmp_watchdog"
if ! sh -n "$tmp_watchdog"; then
	rm -f "$tmp_watchdog"
	die "netcraze-remote-watchdog не проходит проверку синтаксиса (sh -n) — установка остановлена"
fi
chmod +x "$tmp_watchdog"
mv "$tmp_watchdog" /opt/sbin/netcraze-remote-watchdog

# VodkinNET: cron на Entware — отдельный opkg-пакет, не всегда стоит по
# умолчанию. Не хардкодим конкретный номер init-скрипта (может отличаться
# между версиями пакета) — находим реальный файл через glob.
info "проверяю cron (нужен для netcraze-remote-watchdog)..."
if ! command -v crond >/dev/null 2>&1; then
	info "cron не найден, ставлю через opkg..."
	opkg update
	opkg install cron || die "не удалось поставить cron — netcraze-remote-watchdog не будет запускаться"
fi

mkdir -p /opt/etc/crontabs
[ -f /opt/etc/crontabs/root ] || : > /opt/etc/crontabs/root
if ! grep -q "netcraze-remote-watchdog" /opt/etc/crontabs/root 2>/dev/null; then
	echo "* * * * * /opt/sbin/netcraze-remote-watchdog" >> /opt/etc/crontabs/root
	ok "netcraze-remote-watchdog добавлен в cron (проверка раз в минуту)."
fi

CRON_INITD="$(find /opt/etc/init.d -maxdepth 1 -name 'S*cron*' 2>/dev/null | head -n1 || true)"
if [ -n "$CRON_INITD" ] && [ -x "$CRON_INITD" ]; then
	"$CRON_INITD" restart >/dev/null 2>&1 || "$CRON_INITD" start >/dev/null 2>&1 || true
else
	info "не нашёл init-скрипт cron автоматически — проверь вручную: ls /opt/etc/init.d/ | grep -i cron, затем запусти restart"
fi

if [ ! -f /opt/etc/netcraze-remote/netcraze-remote.conf ]; then
	fetch "${REPO_RAW}/files/opt/etc/netcraze-remote/netcraze-remote.conf.example?v=$(date +%s)" \
		/opt/etc/netcraze-remote/netcraze-remote.conf.example
	cp /opt/etc/netcraze-remote/netcraze-remote.conf.example /opt/etc/netcraze-remote/netcraze-remote.conf
	ok "создан конфиг-шаблон: /opt/etc/netcraze-remote/netcraze-remote.conf"
else
	info "конфиг уже существует, не трогаю: /opt/etc/netcraze-remote/netcraze-remote.conf"
fi

chmod 600 /opt/etc/netcraze-remote/netcraze-remote.conf

# --- 6. НЕ гадаем какой SSH где — реально смотрим, что слушает --------
# VodkinNET: на KNDMS SSH-поверхностей может быть ДВЕ РАЗНЫЕ вещи — SSH
# самой NDMS и отдельный sshd/dropbear, поставленный через opkg внутри
# Entware. Вместо совета "угадай порт", реально сканируем локальные
# слушающие порты, чтобы решение о том, что добавлять как сервис в Hub,
# принималось по факту, а не наугад.
info "ищу реально слушающие SSH-подобные порты (informational, ничего не меняю)..."
detect_listen() {
	if command -v netstat >/dev/null 2>&1; then
		netstat -tln 2>/dev/null | awk '/LISTEN/{print $4}' | sed 's/.*://' | sort -un
	elif command -v ss >/dev/null 2>&1; then
		ss -tln 2>/dev/null | awk 'NR>1{print $4}' | sed 's/.*://' | sort -un
	fi
}
LISTEN_PORTS="$(detect_listen || true)"
if [ -n "$LISTEN_PORTS" ]; then
	for p in 22 222 2222; do
		if printf '%s\n' "$LISTEN_PORTS" | grep -qx "$p"; then
			ok "порт $p слушается локально — вероятный кандидат на SSH-сервис"
		fi
	done
	info "полный список локально слушающих портов (для справки): $(printf '%s' "$LISTEN_PORTS" | tr '\n' ' ')"
else
	info "не смог просканировать локальные порты (нет netstat/ss) — проверь вручную при добавлении сервиса в Hub"
fi

echo
ok "Установка завершена."
cat <<'EOF'

Дальше:
  1. Добавь роутер в панели netcraze-remote Hub — создадутся 2 сервиса
     по умолчанию: "NDMS веб-морда" (80) и "SSH (NDMS)" (22).
  2. Если внутри Entware отдельно стоит свой sshd/dropbear (см. порты
     выше) — это ДРУГОЙ сервис, не то же самое, что SSH самой NDMS.
     Добавь его отдельной кнопкой "+ Добавить сервис" на странице роутера
     в Hub (например: "SSH (Entware)", хост 127.0.0.1, порт из списка выше).
  3. Скопируй блок конфига со страницы роутера в Hub целиком в:
       /opt/etc/netcraze-remote/netcraze-remote.conf
     (проще всего через SMB-шару Entware, либо vi по SSH.)
  4. Запусти:
       /opt/etc/init.d/S99netcraze-remote start
       netcraze-remote doctor
       netcraze-remote status

EOF
