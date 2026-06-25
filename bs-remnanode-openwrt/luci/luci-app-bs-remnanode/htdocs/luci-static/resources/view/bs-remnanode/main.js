'use strict';
'require view';
'require form';

return view.extend({
    render: function() {
        var m, s, o;

        m = new form.Map('bs-remnanode', _('BS RemnaNode'),
            _('Native Remnawave node for OpenWrt. No Docker required.'));

        s = m.section(form.NamedSection, 'main', 'bs-remnanode', _('Settings'));
        s.anonymous = false;

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
    }
});