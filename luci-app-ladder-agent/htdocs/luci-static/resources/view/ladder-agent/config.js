'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require fs';

return view.extend({
	load: function () {
		return Promise.all([
			uci.load('ladder-agent'),
			uci.load('network')
		]);
	},

	render: function () {
		let m, s, o;

		m = new form.Map('ladder-agent', _('LadderAirport Agent'),
			_('Configure the local LadderAirport node agent. Default mode is uplink (NAT-friendly). Save, then restart the service from the Status page.'));

		s = m.section(form.NamedSection, 'main', 'ladder-agent', _('Main'));
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('Enable'),
			_('Start ladder-agent on boot when the init script is enabled.'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Value, 'panel_url', _('Panel URL'),
			_('HTTPS base URL of the Panel, e.g. https://panel.example.com'));
		o.datatype = 'string';
		o.placeholder = 'https://panel.example.com';
		o.rmempty = false;

		o = s.option(form.Value, 'node_id', _('Node ID'),
			_('Node ID from the Panel nodes page.'));
		o.rmempty = false;

		o = s.option(form.Value, 'token', _('Control token'),
			_('Long-lived LADDER_TOKEN. Leave empty and set enroll token once to exchange automatically.'));
		o.password = true;
		o.rmempty = true;

		o = s.option(form.Value, 'enroll_token', _('Enroll token'),
			_('One-time enrollment token. Cleared after a successful enroll.'));
		o.password = true;
		o.rmempty = true;

		o = s.option(form.Flag, 'uplink', _('Uplink mode'),
			_('Agent dials Panel over HTTP/WebSocket (recommended on routers behind NAT).'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Flag, 'uplink_ws', _('Uplink WebSocket'),
			_('Realtime channel; disable to use HTTP report/config polling only.'));
		o.default = '1';
		o.depends('uplink', '1');

		o = s.option(form.Flag, 'uplink_serve_grpc', _('Also serve gRPC'),
			_('Keep mTLS gRPC listen in uplink mode (requires management TLS materials).'));
		o.default = '0';
		o.depends('uplink', '1');

		o = s.option(form.Value, 'listen', _('gRPC listen'),
			_('Used when push mode or uplink_serve_grpc is enabled.'));
		o.default = '0.0.0.0:50051';
		o.placeholder = '0.0.0.0:50051';

		o = s.option(form.Value, 'data_dir', _('Data directory'));
		o.default = '/var/lib/ladder-agent';

		o = s.option(form.Value, 'report_address', _('Report address'),
			_('Optional address reported to Panel; leave empty for auto.'));
		o.rmempty = true;

		o = s.option(form.Value, 'tls_sans', _('TLS extra SANs'),
			_('Comma-separated DNS:/IP: SANs for certificate renewals.'));
		o.rmempty = true;

		o = s.option(form.ListValue, 'egress_interface', _('Egress interface'),
			_('Logical network (wan, wwan, lan, …) used as the proxy egress on this router. The agent binds sing-box to that network\'s current L3 device (for example pppoe-wan), including when the Panel stored the lower device name. Empty follows the Panel.'));
		o.value('', _('Follow Panel'));
		o.rmempty = true;
		o.default = '';
		(uci.sections('network', 'interface') || []).forEach(function (sec) {
			var name = sec['.name'];
			if (!name || name === 'loopback')
				return;
			o.value(name, name + (sec.proto ? ' (' + sec.proto + ')' : ''));
		});

		o = s.option(form.Flag, 'log_stderr', _('Log to stderr (procd)'));
		o.default = '1';

		return m.render();
	},

	handleSaveApply: function (ev, mode) {
		return this.handleSave(ev).then(function () {
			return ui.changes.apply(mode == '0');
		}).then(function () {
			return fs.exec('/etc/init.d/ladder-agent', ['restart']).then(function (res) {
				if (res.code)
					ui.addNotification(null, E('p', _('Restart failed (exit %s): %s').format(
						res.code, (res.stderr || res.stdout || '').trim() || _('unknown'))), 'warning');
				else
					ui.addNotification(null, E('p', _('Configuration saved; ladder-agent restarted.')), 'info');
			}).catch(function (err) {
				ui.addNotification(null, E('p', _('Saved, but restart failed: %s').format(err)), 'warning');
			});
		});
	}
});
