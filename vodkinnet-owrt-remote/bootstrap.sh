#!/bin/sh
# VodkinNET: raw.githubusercontent.com is served by a small pool of Fastly
# edge IPs, and individual addresses are sometimes unreachable from a given
# network for minutes at a time (confirmed live: .110.133 timed out
# repeatedly on one router while working fine on another at the same
# moment). install.sh itself already retries across this pool once it's
# running - but bootstrapping install.sh's OWN download can't benefit from
# that, since the code isn't on disk yet. This tiny script exists solely to
# fix that one gap: pin a working Fastly IP first, then fetch+run install.sh.
set -eu

RAW_URL="${RAW_URL:-https://raw.githubusercontent.com/beverlypillzz-collab/Vodkinnet-RT/main/vodkinnet-owrt-remote}"
HOST="raw.githubusercontent.com"
TMP_SH="/tmp/.vodkinnet-install.$$.sh"

_fetch() {
	if command -v wget >/dev/null 2>&1; then
		wget -q -T 6 -O "$1" "$2" 2>/dev/null
	elif command -v curl >/dev/null 2>&1; then
		curl -fsS --connect-timeout 6 -o "$1" "$2" 2>/dev/null
	else
		return 1
	fi
}

_try_host() {
	_fetch /dev/null "https://$HOST/"
}

run_install() {
	_fetch "$TMP_SH" "$RAW_URL/install.sh?v=$(date +%s)" || return 1
	[ -s "$TMP_SH" ] || return 1
	sh "$TMP_SH"
	status=$?
	rm -f "$TMP_SH"
	return "$status"
}

# Quick path: current DNS answer already works, don't touch /etc/hosts at all.
if _try_host; then
	run_install
	exit $?
fi

echo "[*] $HOST не отвечает по умолчанию, перебираю известные IP..."
for ip in 185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133; do
	sed -i "/ $HOST\$/d" /etc/hosts 2>/dev/null || true
	printf '%s %s\n' "$ip" "$HOST" >> /etc/hosts
	if _try_host; then
		echo "[+] $HOST -> $ip"
		run_install
		exit $?
	fi
done

echo "[!!] не удалось достучаться до $HOST ни по одному известному адресу" >&2
exit 1
