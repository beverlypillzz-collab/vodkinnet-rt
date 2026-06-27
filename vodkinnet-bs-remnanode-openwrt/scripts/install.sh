#!/bin/sh
# bs-remnanode installer for OpenWrt
# Supports: aarch64 (Cudy WBR3000AX, MediaTek Filogic)

REPO="beverlypillzz-collab/Vodkinnet-RT"
INSTALL_BIN="/usr/bin/bs-remnanode"
CONFIG_DIR="/etc/bs-remnanode"
INIT_SCRIPT="/etc/init.d/bs-remnanode"
UCI_CONFIG="/etc/config/bs-remnanode"

echo ""
echo "  ██╗   ██╗ ██████╗ ██████╗ ██╗  ██╗██╗███╗   ██╗"
echo "  ██║   ██║██╔═══██╗██╔══██╗██║ ██╔╝██║████╗  ██║"
echo "  ██║   ██║██║   ██║██║  ██║█████╔╝ ██║██╔██╗ ██║"
echo "  ╚██╗ ██╔╝██║   ██║██║  ██║██╔═██╗ ██║██║╚██╗██║"
echo "   ╚████╔╝ ╚██████╔╝██████╔╝██║  ██╗██║██║ ╚████║"
echo "    ╚═══╝   ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝"
echo "  bs-remnanode installer v1.4"
echo "  beverlypillzz-collab/Vodkinnet-RT"
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

# --- Cleanup previous installation ---
echo "[0/7] Cleaning previous installation..."
if [ -f "$INIT_SCRIPT" ]; then
    "$INIT_SCRIPT" stop 2>/dev/null
    "$INIT_SCRIPT" disable 2>/dev/null
fi
rm -f "$INSTALL_BIN"
rm -f "$INIT_SCRIPT"
rm -f "$UCI_CONFIG"
rm -rf "$CONFIG_DIR"
rm -f /usr/bin/xray
apk del xray-core 2>/dev/null
rm -f /usr/share/luci/menu.d/luci-app-bs-remnanode.json
rm -f /www/luci-static/resources/view/bs-remnanode/main.js
rm -f /usr/share/rpcd/acl.d/luci-app-bs-remnanode.json
# Remove duplicate firewall rules
uci -q show firewall | grep "name='bs-remnanode'" | while read line; do
    idx=$(echo "$line" | sed "s/firewall\.@rule\[\([0-9]*\)\].*/\1/")
    uci -q delete "firewall.@rule[$idx]" 2>/dev/null
done
uci commit firewall 2>/dev/null
echo "      OK: cleaned"

# --- Install dependencies ---
echo "[1/7] Installing dependencies..."
apk update >/dev/null 2>&1
if ! command -v curl >/dev/null 2>&1; then
    apk add curl ca-bundle >/dev/null 2>&1
    echo "      OK: curl installed"
else
    echo "      OK: curl already present"
fi

# --- Download bs-remnanode binary ---
echo "[2/7] Downloading bs-remnanode..."
BIN_URL="https://github.com/${REPO}/releases/latest/download/bs-remnanode_${ARCH}"
if curl -fsSL --max-time 60 "$BIN_URL" -o "$INSTALL_BIN" 2>/dev/null; then
    chmod +x "$INSTALL_BIN"
    echo "      OK: $INSTALL_BIN"
else
    echo "      [!] Failed to download bs-remnanode"
fi

# --- Install xray-core ---
echo "[3/7] Installing xray-core..."
if [ -f /usr/bin/xray ]; then
    echo "      OK: xray already installed"
elif apk add xray-core 2>/dev/null; then
    echo "      OK: installed via apk"
else
    echo "      [!] Could not install xray-core, run: apk add xray-core"
fi

# --- Install luci-app-firewall ---
echo "[4/7] Installing luci-app-firewall..."
apk add luci-app-firewall >/dev/null 2>&1
echo "      OK: done"

# --- Create UCI config ---
echo "[5/7] Creating config..."
mkdir -p "$CONFIG_DIR"
cat > "$UCI_CONFIG" << 'EOF'
config bs-remnanode 'main'
    option node_port '2222'
    option secret_key ''
    option xtls_api_port '61000'
    option xray_bin '/usr/bin/xray'
EOF
echo "      OK: $UCI_CONFIG"

# --- Install init.d service ---
echo "[6/7] Installing init.d service..."
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
        logger -t bs-remnanode "ERROR: SECRET_KEY not set"
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

stop_service() { return 0; }
reload_service() { stop; start; }
EOF
chmod +x "$INIT_SCRIPT"
/etc/init.d/bs-remnanode enable
echo "      OK: init.d installed and enabled"

# --- Install LuCI app ---
echo "[7/7] Installing LuCI app..."

# ACL permissions
mkdir -p /usr/share/rpcd/acl.d
cat > /usr/share/rpcd/acl.d/luci-app-bs-remnanode.json << 'EOF'
{
  "luci-app-bs-remnanode": {
    "description": "BS RemnaNode LuCI access",
    "read": {
      "uci": [ "bs-remnanode" ],
      "ubus": {
        "service": [ "list" ]
      }
    },
    "write": {
      "uci": [ "bs-remnanode" ]
    }
  }
}
EOF

# Menu entry
mkdir -p /usr/share/luci/menu.d
cat > /usr/share/luci/menu.d/luci-app-bs-remnanode.json << 'EOF'
{
  "admin/services/bs-remnanode": {
    "title": "BS RemnaNode",
    "order": 43,
    "action": {
      "type": "view",
      "path": "bs-remnanode/main"
    },
    "depends": {
      "uci": { "bs-remnanode": true }
    }
  }
}
EOF

# View file
mkdir -p /www/luci-static/resources/view/bs-remnanode
cat > /www/luci-static/resources/view/bs-remnanode/main.js << 'EOF'
'use strict';
'require view';
'require form';

return view.extend({
    render: function() {
        var m, s, o;

        m = new form.Map('bs-remnanode', _('BS RemnaNode'),
            _('Native Remnawave node for OpenWrt. No Docker required.'));

        s = m.section(form.NamedSection, 'main', _('Settings'));
        s.anonymous = true;

        o = s.option(form.Value, 'secret_key', _('Secret Key'),
            _('SECRET_KEY from Remnawave panel'));
        o.password = true;
        o.rmempty = false;

        o = s.option(form.Value, 'node_port', _('Node Port'),
            _('Port for Remnawave panel (default: 2222)'));
        o.datatype = 'port';
        o.default = '2222';

        o = s.option(form.Value, 'xtls_api_port', _('XTLS API Port'));
        o.datatype = 'port';
        o.default = '61000';

        o = s.option(form.Value, 'xray_bin', _('Xray Binary Path'));
        o.default = '/usr/bin/xray';

        return m.render();
    },

    handleSaveApply: function(ev) {
        return this.handleSave(ev).then(function() {
            return L.resolveDefault(L.Request.post('/cgi-bin/luci/command', {
                cmd: '/etc/init.d/bs-remnanode restart'
            }));
        });
    }
});
EOF

/etc/init.d/rpcd restart 2>/dev/null
echo "      OK: LuCI app installed"

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
echo "NEXT STEP — set SECRET_KEY:"
echo ""
echo "  1. Open LuCI: Services -> BS RemnaNode"
echo "     Enter SECRET_KEY from Remnawave panel"
echo "     Click Save & Apply"
echo ""
echo "  OR via console:"
echo "  KEY='your_key'"
echo "  uci set bs-remnanode.main.secret_key=\"\$KEY\""
echo "  uci commit bs-remnanode"
echo "  /etc/init.d/bs-remnanode start"
echo ""
echo "  Check: netstat -tlnp | grep 2222"
