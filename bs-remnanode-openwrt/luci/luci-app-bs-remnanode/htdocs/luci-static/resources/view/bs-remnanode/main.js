'use strict';
'require view';
'require form';
'require uci';
'require ui';

return view.extend({
    render: function() {
        var m, s, o;

        m = new form.Map('bs-remnanode', _('BS RemnaNode'),
            _('Native Remnawave node for OpenWrt routers. No Docker required.'));

        s = m.section(form.TypedSection, 'main', _('Settings'));
        s.anonymous = true;

        o = s.option(form.Value, 'secret_key', _('Secret Key'),
            _('SECRET_KEY from Remnawave panel (Nodes → Management → Copy docker-compose.yml)'));
        o.password = true;
        o.rmempty = false;

        o = s.option(form.Value, 'node_port', _('Node Port'),
            _('Port for Remnawave panel to connect to this node (default: 2222)'));
        o.datatype = 'port';
        o.default = '2222';

        o = s.option(form.Value, 'xtls_api_port', _('XTLS API Port'),
            _('Internal xray gRPC API port (default: 61000, do not expose to WAN)'));
        o.datatype = 'port';
        o.default = '61000';

        o = s.option(form.Value, 'xray_bin', _('Xray Binary Path'),
            _('Path to xray-core binary'));
        o.default = '/usr/bin/xray';

        // Service status section
        s = m.section(form.TypedSection, 'main', _('Service Status'));
        s.anonymous = true;

        o = s.option(form.DummyValue, '_status', _('Status'));
        o.cfgvalue = function() {
            return E('div', { 'id': 'bs-remnanode-status' }, [
                E('em', {}, _('Loading...'))
            ]);
        };

        o.load = function() {
            fetch('/cgi-bin/luci/admin/services/bs-remnanode/status')
                .then(r => r.json())
                .then(data => {
                    var el = document.getElementById('bs-remnanode-status');
                    if (el) {
                        var running = data.xray === true;
                        el.innerHTML = '';
                        el.appendChild(E('span', {
                            'style': running ? 'color:green;font-weight:bold' : 'color:red'
                        }, running ? '● Running' : '● Stopped'));
                    }
                })
                .catch(function() {
                    var el = document.getElementById('bs-remnanode-status');
                    if (el) el.innerHTML = '<span style="color:orange">⚠ Could not connect</span>';
                });
        };

        return m.render();
    },

    handleSaveApply: function(ev) {
        return this.handleSave(ev).then(function() {
            return ui.changes.apply();
        }).then(function() {
            return fs.exec('/etc/init.d/bs-remnanode', ['restart']);
        });
    }
});
