#!/bin/sh
# bs-remnanode installer for OpenWrt (aarch64 / Cudy WBR3000AX)
# Usage: sh install.sh

REPO="beverlypillzz-collab/Vodkinnet-RT"
SUBDIR="bs-remnanode-openwrt"
ARCH="aarch64"
BIN_NAME="bs-remnanode_${ARCH}"
INSTALL_BIN="/usr/bin/bs-remnanode"
CONFIG_DIR="/etc/bs-remnanode"
XRAY_BIN="/usr/bin/xray"
XRAY_VERSION="v25.3.6"

echo "============================================="
echo "  !VODKIN GREETS YOU!"
echo "  BS RemnaNode Installer for OpenWrt v1.0"
echo "============================================="
echo ""

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

# --- Install xray-core ---
echo "[3/5] Installing xray-core..."
# Try OpenWrt package first (no GitHub needed, fast)
if apk add xray-core 2>/dev/null; then
    echo "       installed via apk"
else
    echo "       apk package not found, trying mirrors..."
    TMP_DIR=$(mktemp -d)
    DOWNLOADED=0

    for URL in \
        "https://ghfast.top/https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-arm64-v8a.zip" \
        "https://kkgithub.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-arm64-v8a.zip" \
        "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-arm64-v8a.zip"
    do
        echo "       trying $URL ..."
        if curl -fsSL --max-time 90 "$URL" -o "$TMP_DIR/xray.zip" 2>/dev/null; then
            DOWNLOADED=1
            break
        elif wget -q --timeout=90 "$URL" -O "$TMP_DIR/xray.zip" 2>/dev/null; then
            DOWNLOADED=1
            break
        fi
    done

    if [ "$DOWNLOADED" = "1" ]; then
        apk add unzip 2>/dev/null || true
        unzip -o "$TMP_DIR/xray.zip" xray -d "$TMP_DIR/"
        mv "$TMP_DIR/xray" "$XRAY_BIN"
        chmod +x "$XRAY_BIN"
        echo "       installed to $XRAY_BIN"
    else
        echo "[!] Could not download xray-core automatically."
        echo "    Install manually after: apk add xray"
        echo "    Or copy xray binary to /usr/bin/xray"
    fi
    rm -rf "$TMP_DIR"
fi

# --- Create config dir ---
echo "[4/5] Creating config directory..."
mkdir -p "$CONFIG_DIR"

# Copy default UCI config if not exists
if [ ! -f /etc/config/bs-remnanode ]; then
    cat > /etc/config/bs-remnanode << 'EOF'
config bs-remnanode 'main'
    option node_port '2222'
    option secret_key ''
    option xtls_api_port '61000'
    option xray_bin '/usr/bin/xray'
EOF
fi

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
fi

echo ""
echo "============================================="
echo "  Installation complete!"
echo "============================================="
echo ""
echo "Next steps:"
echo "  1. Set SECRET_KEY from Remnawave panel:"
echo "       uci set bs-remnanode.main.secret_key='YOUR_KEY'"
echo "       uci commit bs-remnanode"
echo ""
echo "  2. Start the service:"
echo "       /etc/init.d/bs-remnanode start"
echo ""
echo "  3. Open firewall port (LuCI):"
echo "       Network -> Firewall -> Traffic Rules"
echo "       Allow WAN -> port 2222"
echo ""
echo "  4. Add node in Remnawave panel:"
echo "       Nodes -> Management -> + -> WAN IP of this router"
