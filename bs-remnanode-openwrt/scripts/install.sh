#!/bin/sh
# bs-remnanode installer for OpenWrt (aarch64 / Cudy WBR3000AX)
# Usage: sh install.sh

set -e

REPO="beverlypillzz-collab/Vodkinnet-RT"
SUBDIR="bs-remnanode-openwrt"
ARCH="aarch64"
BIN_NAME="bs-remnanode_${ARCH}"
INSTALL_BIN="/usr/bin/bs-remnanode"
CONFIG_DIR="/etc/bs-remnanode"
XRAY_BIN="/usr/bin/xray"
XRAY_VERSION="v25.3.6"

echo "=== bs-remnanode installer ==="

# --- Check architecture ---
MACHINE=$(uname -m)
if [ "$MACHINE" != "aarch64" ]; then
    echo "WARNING: this installer is for aarch64, detected: $MACHINE"
fi

# --- Install dependencies ---
echo "[1/5] Installing dependencies..."
apk update
apk add curl ca-bundle

# --- Download bs-remnanode binary ---
echo "[2/5] Downloading bs-remnanode..."
LATEST_URL="https://github.com/${REPO}/releases/latest/download/${BIN_NAME}"
curl -fsSL "$LATEST_URL" -o "$INSTALL_BIN"
chmod +x "$INSTALL_BIN"
echo "       installed to $INSTALL_BIN"

# --- Download xray-core ---
echo "[3/5] Downloading xray-core ${XRAY_VERSION}..."
XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-arm64-v8a.zip"
TMP_DIR=$(mktemp -d)
curl -fsSL "$XRAY_URL" -o "$TMP_DIR/xray.zip"
unzip -o "$TMP_DIR/xray.zip" xray -d "$TMP_DIR/"
mv "$TMP_DIR/xray" "$XRAY_BIN"
chmod +x "$XRAY_BIN"
rm -rf "$TMP_DIR"
echo "       installed to $XRAY_BIN"

# --- Create config dir ---
echo "[4/5] Creating config directory..."
mkdir -p "$CONFIG_DIR"

# --- Install init.d service ---
echo "[5/5] Installing init.d service..."
INIT_URL="https://raw.githubusercontent.com/${REPO}/main/${SUBDIR}/luci/luci-app-bs-remnanode/root/etc/init.d/bs-remnanode"
curl -fsSL "$INIT_URL" -o /etc/init.d/bs-remnanode
chmod +x /etc/init.d/bs-remnanode
/etc/init.d/bs-remnanode enable

# --- Install LuCI app if LuCI is present ---
if [ -d "/usr/lib/lua/luci" ]; then
    echo "[+] LuCI detected, installing web UI..."
    LUCI_URL="https://raw.githubusercontent.com/${REPO}/main/${SUBDIR}/luci/luci-app-bs-remnanode/htdocs/luci-static/resources/view/bs-remnanode/main.js"
    mkdir -p /www/luci-static/resources/view/bs-remnanode
    curl -fsSL "$LUCI_URL" -o /www/luci-static/resources/view/bs-remnanode/main.js

    MENU_URL="https://raw.githubusercontent.com/${REPO}/main/${SUBDIR}/luci/luci-app-bs-remnanode/root/etc/uci-defaults/bs-remnanode"
    curl -fsSL "$MENU_URL" -o /etc/uci-defaults/bs-remnanode
    sh /etc/uci-defaults/bs-remnanode
fi

echo ""
echo "=== Installation complete! ==="
echo ""
echo "Next steps:"
echo "  1. Set credentials in /etc/config/bs-remnanode:"
echo "       uci set bs-remnanode.main.node_port='2222'"
echo "       uci set bs-remnanode.main.secret_key='YOUR_SECRET_KEY_FROM_PANEL'"
echo "       uci commit bs-remnanode"
echo ""
echo "  2. Start the service:"
echo "       /etc/init.d/bs-remnanode start"
echo ""
echo "  3. Open firewall port in LuCI:"
echo "       Network -> Firewall -> Traffic Rules"
echo "       Allow WAN -> port 2222 (or your NODE_PORT)"
echo ""
echo "  4. Add node in Remnawave panel:"
echo "       Nodes -> Management -> + -> enter this router's WAN IP"
