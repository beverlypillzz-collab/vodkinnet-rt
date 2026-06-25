#!/bin/sh
# bs-remnanode installer for OpenWrt
# Supports: aarch64 (Cudy WBR3000AX, MediaTek Filogic)

REPO="beverlypillzz-collab/Vodkinnet-RT"
SUBDIR="bs-remnanode-openwrt"
INSTALL_BIN="/usr/bin/bs-remnanode"
CONFIG_DIR="/etc/bs-remnanode"
INIT_SCRIPT="/etc/init.d/bs-remnanode"
UCI_CONFIG="/etc/config/bs-remnanode"

echo "============================================="
echo "  !VODKIN GREETS YOU!"
echo "  BS RemnaNode Installer for OpenWrt v1.1"
echo "============================================="
echo ""

# --- Detect arch ---
MACHINE=$(uname -m)
case "$MACHINE" in
    aarch64) ARCH="aarch64" ;;
    armv7*)  ARCH="armv7" ;;
    x86_64)  ARCH="x86_64" ;;
    *)       ARCH="aarch64"; echo "[!] Unknown arch $MACHINE, defaulting to aarch64" ;;
esac
echo "[i] Architecture: $ARCH"

# --- Helper: download with fallback ---
download() {
    URL="$1"
    OUT="$2"
    # Try curl first, then wget
    if curl -fsSL --max-time 30 "$URL" -o "$OUT" 2>/dev/null; then
        return 0
    elif wget -q --timeout=30 "$URL" -O "$OUT" 2>/dev/null; then
        return 0
    fi
    return 1
}

# --- Install curl if missing ---
if ! command -v curl >/dev/null 2>&1; then
    echo "[1/6] Installing curl..."
    apk update >/dev/null 2>&1
    apk add curl ca-bundle >/dev/null 2>&1
else
    echo "[1/6] curl already installed"
    apk update >/dev/null 2>&1
fi

# --- Download bs-remnanode binary ---
echo "[2/6] Downloading bs-remnanode..."
BIN_NAME="bs-remnanode_${ARCH}"
BIN_URL="https://github.com/${REPO}/releases/latest/download/${BIN_NAME}"

if download "$BIN_URL" "$INSTALL_BIN"; then
    chmod +x "$INSTALL_BIN"
    echo "      OK: $INSTALL_BIN"
else
    echo "[!] Failed to download bs-remnanode"
    echo "    Try manually: wget $BIN_URL -O $INSTALL_BIN"
fi

# --- Install xray-core via apk ---
echo "[3/6] Installing xray-core..."
if [ -f /usr/bin/xray ]; then
    echo "      OK: xray already installed"
elif apk add xray-core 2>/dev/null; then
    echo "      OK: installed via apk"
else
    echo "[!] Could not install xray-core via apk"
    echo "    Try manually: apk add xray-core"
fi

# --- Install luci-app-firewall if missing ---
echo "[4/6] Checking luci-app-firewall..."
if ! apk info luci-app-firewall >/dev/null 2>&1; then
    apk add luci-app-firewall >/dev/null 2>&1 && echo "      OK: luci-app-firewall installed" || echo "      [!] Could not install luci-app-firewall"
else
    echo "      OK: already installed"
fi

# --- Create UCI config if missing ---
echo "[5/6] Setting up config..."
mkdir -p "$CONFIG_DIR"

if [ ! -f "$UCI_CONFIG" ]; then
    cat > "$UCI_CONFIG" << 'EOF'
config bs-remnanode 'main'
    option node_port '2222'
    option secret_key ''
    option xtls_api_port '61000'
    option xray_bin '/usr/bin/xray'
EOF
    echo "      OK: created $UCI_CONFIG"
else
    echo "      OK: config exists"
fi

# --- Install init.d service (embedded, no download needed) ---
echo "[6/6] Installing init.d service..."
cat > "$INIT_SCRIPT" << 'EOF'
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1

PROG=/usr/bin/bs-remnanode

start_service() {
    local node_port secret_key xtls_api_port xray_bin

    config_load bs-remnanode
    config_get node_port     main node_port     "2222"
    config_get secret_key    main secret_key    ""
    config_get xtls_api_port main xtls_api_port "61000"
    config_get xray_bin      main xray_bin      "/usr/bin/xray"

    if [ -z "$secret_key" ]; then
        logger -t bs-remnanode "ERROR: SECRET_KEY is not set in /etc/config/bs-remnanode"
        return 1
    fi

    procd_open_instance
    procd_set_param command "$PROG"
    procd_set_param env \
        NODE_PORT="$node_port" \
        SECRET_KEY="$secret_key" \
        XTLS_API_PORT="$xtls_api_port" \
        XRAY_BIN="$xray_bin"
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    return 0
}

reload_service() {
    stop
    start
}
EOF

chmod +x "$INIT_SCRIPT"
/etc/init.d/bs-remnanode enable
echo "      OK: init.d installed and enabled"

# --- Open firewall port ---
echo "[+] Opening firewall port 2222..."
uci add firewall rule >/dev/null 2>&1
uci set firewall.@rule[-1].name='bs-remnanode'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].dest_port='2222'
uci set firewall.@rule[-1].target='ACCEPT'
uci set firewall.@rule[-1].proto='tcp'
uci commit firewall
/etc/init.d/firewall restart >/dev/null 2>&1
echo "      OK: port 2222 opened"

echo ""
echo "============================================="
echo "  Installation complete!"
echo "============================================="
echo ""
echo "NEXT STEP — set your SECRET_KEY from panel:"
echo ""
echo "  uci set bs-remnanode.main.secret_key='KEY'"
echo "  uci commit bs-remnanode"
echo "  /etc/init.d/bs-remnanode start"
echo ""
echo "Then add node in Remnawave panel:"
echo "  Nodes -> Management -> + -> WAN IP, port 2222"
