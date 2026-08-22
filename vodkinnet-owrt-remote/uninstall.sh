#!/bin/sh

set -eu

ROOT="${ROOT:-/}"
PURGE="${PURGE:-0}"

target_path() {
	printf '%s/%s' "${ROOT%/}" "$1"
}

rmf() {
	rm -f "$(target_path "$1")"
}

# VodkinNET: строка watchdog'а в cron — не "конфиг" и не идентификационные
# данные, просто расписание вызова бинарника, который мы вот-вот удалим.
# Оставленная строка молча логировала бы ошибку каждую минуту (cron всё
# ещё будет пытаться запускать несуществующий /usr/sbin/owrt-remote-watchdog).
remove_watchdog_cron() {
	local cron_file
	cron_file="$(target_path etc/crontabs/root)"
	[ -f "$cron_file" ] || return 0
	if grep -q "owrt-remote-watchdog" "$cron_file" 2>/dev/null; then
		sed -i '/owrt-remote-watchdog/d' "$cron_file"
		if [ -x "$(target_path etc/init.d/cron)" ]; then
			"$(target_path etc/init.d/cron)" restart >/dev/null 2>&1 || true
		fi
	fi
}

if [ -x "$(target_path etc/init.d/owrt-remote)" ]; then
	"$(target_path etc/init.d/owrt-remote)" stop >/dev/null 2>&1 || true
	"$(target_path etc/init.d/owrt-remote)" disable >/dev/null 2>&1 || true
fi

remove_watchdog_cron

rmf usr/sbin/owrt-remote
rmf usr/sbin/owrt-remote.bak
rmf usr/sbin/owrt-remote-watchdog
rmf etc/init.d/owrt-remote
rmf etc/init.d/owrt-remote.bak
rmf etc/owrt-remote-update-pending
rmf etc/owrt-remote-rollback.log
rmf www/cgi-bin/owrt-remote
rmf usr/lib/lua/luci/controller/owrt_remote.lua
rmf usr/share/luci/menu.d/luci-app-owrt-remote.json
rmf usr/share/rpcd/acl.d/luci-app-owrt-remote.json
rmf www/luci-static/resources/view/owrt_remote.js

if [ "$PURGE" = "1" ]; then
	rmf etc/config/owrtremote
	rmf etc/owrt-remote/web.key
	rm -f "$(target_path etc/xray/owrt-remote-client.json)" 2>/dev/null || true
	rmdir "$(target_path etc/owrt-remote)" 2>/dev/null || true
fi

rm -rf "$(target_path tmp/luci-indexcache)" "$(target_path tmp/luci-modulecache)" "$(target_path tmp/luci-indexcache.)"* "$(target_path tmp/luci-modulecache.)"* 2>/dev/null || true

if [ -x "$(target_path etc/init.d/rpcd)" ]; then
	"$(target_path etc/init.d/rpcd)" restart >/dev/null 2>&1 || true
fi

if [ -x "$(target_path etc/init.d/uhttpd)" ]; then
	"$(target_path etc/init.d/uhttpd)" reload >/dev/null 2>&1 || "$(target_path etc/init.d/uhttpd)" restart >/dev/null 2>&1 || true
fi

printf '%s\n' "OpenWrt Remote удален."
if [ "$PURGE" != "1" ]; then
	printf '%s\n' "Конфиг и web key оставлены. Для полного удаления запусти с PURGE=1."
fi

