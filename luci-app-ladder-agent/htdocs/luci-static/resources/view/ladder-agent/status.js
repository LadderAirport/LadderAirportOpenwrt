'use strict';
'require view';
'require ui';
'require fs';
'require poll';
'require dom';

/* Layout follows the Panel node detail page:
 *   web/src/components/NodeDetailDrawer.tsx        header badges + summary
 *   web/src/components/node-detail/NodeOverviewTab.tsx
 *   web/src/components/node-detail/NodeSystemTab.tsx
 *   web/src/components/node-detail/NodeOpsTab.tsx  traffic cards + lifecycle
 *   web/src/lib/nodeDisplay.ts                     labels and byte format
 */

function formatBytes(n) {
	if (n == null || !isFinite(n) || n < 0)
		return n == null ? '—' : '0 B';
	if (n === 0)
		return '0 B';
	var units = ['B', 'KB', 'MB', 'GB', 'TB'];
	var v = Number(n);
	var i = 0;
	while (v >= 1024 && i < units.length - 1) {
		v /= 1024;
		i++;
	}
	var text = (v < 10 && i > 0) ? v.toFixed(1) : (i === 0 ? String(Math.round(v)) : v.toFixed(1));
	return text + ' ' + units[i];
}

function formatTime(unix) {
	if (!unix)
		return '—';
	return new Date(unix * 1000).toLocaleString();
}

function formatUptime(sec) {
	sec = Math.floor(Number(sec) || 0);
	if (sec <= 0)
		return '—';
	var d = Math.floor(sec / 86400);
	var h = Math.floor((sec % 86400) / 3600);
	var m = Math.floor((sec % 3600) / 60);
	if (d > 0)
		return d + '天 ' + h + '小时';
	if (h > 0)
		return h + '小时 ' + m + '分钟';
	return m + '分钟';
}

function percent(used, total) {
	used = Number(used) || 0;
	total = Number(total) || 0;
	if (total <= 0)
		return 0;
	return Math.min(100, Math.max(0, (used / total) * 100));
}

function dash(v) {
	return (v == null || v === '') ? '—' : String(v);
}

function badge(text, kind) {
	return E('span', { 'class': 'ladder-badge ladder-badge-' + (kind || 'muted') }, [
		E('span', { 'class': 'ladder-badge-dot' }, []),
		text
	]);
}

function metric(label, value, extra) {
	var kids = [
		E('span', { 'class': 'ladder-metric-label' }, [label]),
		E('span', { 'class': 'ladder-metric-value' }, [value])
	];
	if (extra)
		kids.push(extra);
	return E('div', { 'class': 'ladder-metric' }, kids);
}

function bar(pct) {
	return E('div', { 'class': 'ladder-bar' }, [
		E('div', { 'class': 'ladder-bar-fill', 'style': 'width:' + pct.toFixed(0) + '%' })
	]);
}

function kv(label, value) {
	return E('div', { 'class': 'ladder-kv' }, [
		E('span', { 'class': 'ladder-kv-label' }, [label]),
		E('span', { 'class': 'ladder-kv-value' }, [value])
	]);
}

function section(title, descr, body) {
	var head = [E('h3', { 'class': 'ladder-section-title' }, [title])];
	if (descr)
		head.push(E('p', { 'class': 'ladder-section-descr' }, [descr]));
	return E('section', { 'class': 'ladder-section' }, [
		E('div', { 'class': 'ladder-section-head' }, head),
		body
	]);
}

var PAGE_CSS = [
	'.ladder-node-page{display:flex;flex-direction:column;gap:16px;max-width:960px;}',
	'.ladder-header,.ladder-section{border:1px solid var(--border-color,#d0d0d0);border-radius:8px;',
	'background:var(--background-color-high,var(--background-color,transparent));padding:16px 18px;}',
	'.ladder-title{margin:0;font-size:1.25rem;font-weight:700;letter-spacing:-.01em;}',
	'.ladder-badges{display:flex;flex-wrap:wrap;gap:6px;margin-top:8px;}',
	'.ladder-badge{display:inline-flex;align-items:center;gap:6px;padding:2px 8px;border-radius:999px;',
	'font-size:12px;line-height:1.6;border:1px solid var(--border-color,#ccc);}',
	'.ladder-badge-dot{width:6px;height:6px;border-radius:50%;background:currentColor;flex:0 0 auto;}',
	'.ladder-badge-ok{color:#1f8a4c;border-color:rgba(31,138,76,.45);background:rgba(31,138,76,.12);}',
	'.ladder-badge-bad{color:#c0392b;border-color:rgba(192,57,43,.4);background:rgba(192,57,43,.1);}',
	'.ladder-badge-warn{color:#9a6b00;border-color:rgba(154,107,0,.45);background:rgba(184,134,11,.14);}',
	'.ladder-badge-muted,.ladder-badge-outline{color:inherit;}',
	'.ladder-meta{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px;margin-top:14px;font-size:12px;}',
	'.ladder-meta-label{display:block;opacity:.7;margin-bottom:2px;}',
	'.ladder-meta-value{font-family:monospace;word-break:break-all;}',
	'.ladder-metrics{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;}',
	'.ladder-metric{border:1px solid var(--border-color,#d0d0d0);border-radius:8px;padding:12px;',
	'background:var(--background-color,transparent);}',
	'.ladder-metric-label{display:block;font-size:10px;letter-spacing:.06em;text-transform:uppercase;opacity:.7;}',
	'.ladder-metric-value{display:block;margin-top:4px;font-size:1.15rem;font-weight:700;}',
	'.ladder-metric-hint{display:block;margin-top:2px;font-size:12px;font-weight:400;opacity:.7;}',
	'.ladder-bar{height:6px;border-radius:999px;background:rgba(127,127,127,.25);overflow:hidden;margin-top:8px;}',
	'.ladder-bar-fill{height:100%;border-radius:999px;background:var(--primary,#2e7dff);}',
	'.ladder-section-title{margin:0;font-size:14px;font-weight:600;}',
	'.ladder-section-descr{margin:4px 0 0;font-size:12px;opacity:.7;}',
	'.ladder-section-head{margin-bottom:12px;}',
	'.ladder-kv-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:10px 16px;}',
	'.ladder-kv-label{display:block;font-size:12px;opacity:.7;}',
	'.ladder-kv-value{display:block;margin-top:2px;word-break:break-all;}',
	'.ladder-type-list{display:flex;flex-wrap:wrap;gap:6px;margin-top:8px;}',
	'.ladder-actions{display:flex;flex-wrap:wrap;gap:8px;}',
	'.ladder-actions .cbi-button{margin:0;}'
].join('');

function loadStatus() {
	return fs.exec_direct('/usr/libexec/ladder-agent/luci-status.sh', []).then(function (text) {
		text = (text || '').trim();
		if (!text)
			throw new Error(_('Empty status output'));
		return JSON.parse(text);
	});
}

function serviceAction(action) {
	return fs.exec('/etc/init.d/ladder-agent', [action]).then(function (res) {
		if (res.code)
			ui.addNotification(null, E('p', _('%s failed (exit %s): %s').format(
				action, res.code, (res.stderr || res.stdout || '').trim() || _('unknown'))), 'error');
		else
			ui.addNotification(null, E('p', _('Service action “%s” completed.').format(action)), 'info');
	}).catch(function (err) {
		ui.addNotification(null, E('p', _('Service action failed: %s').format(err)), 'error');
	});
}

function controlModeLabel(st) {
	if (st.uplink)
		return st.uplink_serve_grpc ? _('uplink + gRPC') : _('uplink（Agent WebSocket 长连接）');
	return _('push（Panel 拨号 gRPC）');
}

function controlModeDescr(st) {
	if (st.uplink)
		return _('节点主动建立 WebSocket 长连接，断线时回退到 HTTP 上报和拉配置。');
	return _('Panel 拨号用。NAT 时填映射后的公网/VPN 地址与外部 gRPC 端口。');
}

function renderStatus(st) {
	var running = !!st.running;
	var badges = [
		badge(running ? _('运行中') : _('已停止'), running ? 'ok' : 'muted'),
		badge(st.enabled ? _('已启用') : _('未启用'), st.enabled ? 'ok' : 'muted'),
		badge(st.init_enabled ? _('开机启动') : _('未设开机启动'), st.init_enabled ? 'ok' : 'outline')
	];
	if (st.uplink && st.uplink_ws)
		badges.push(badge(_('WS 实时通道'), 'outline'));
	else if (st.uplink)
		badges.push(badge(_('WebSocket 已关闭'), 'muted'));
	else
		badges.push(badge(_('push（Panel 拨号 gRPC）'), 'outline'));

	if (st.congestion === 'bbr')
		badges.push(badge(_('BBR 已启用'), 'ok'));

	var title = st.hostname || st.node_id || 'LadderAirport';
	var header = E('header', { 'class': 'ladder-header' }, [
		E('h3', { 'class': 'ladder-title' }, [title]),
		E('div', { 'class': 'ladder-badges' }, badges),
		E('div', { 'class': 'ladder-meta' }, [
			E('div', {}, [
				E('span', { 'class': 'ladder-meta-label' }, [_('控制面')]),
				E('code', { 'class': 'ladder-meta-value' }, [dash(st.panel_url)])
			]),
			E('div', {}, [
				E('span', { 'class': 'ladder-meta-label' }, [_('节点 ID')]),
				E('code', { 'class': 'ladder-meta-value' }, [dash(st.node_id)])
			]),
			E('div', {}, [
				E('span', { 'class': 'ladder-meta-label' }, [_('版本')]),
				E('span', { 'class': 'ladder-meta-value' }, [
					'Agent ',
					E('code', {}, [dash(st.version)])
				])
			])
		])
	]);

	var memPct = percent(st.mem_used_bytes, st.mem_total_bytes);
	var diskPct = percent(st.disk_used_bytes, st.disk_total_bytes);
	var types = String(st.inbound_types || '').split(',').filter(Boolean);

	var metrics = E('div', { 'class': 'ladder-metrics' }, [
		metric(_('上行流量'), formatBytes(Number(st.uplink_bytes) || 0)),
		metric(_('下行流量'), formatBytes(Number(st.downlink_bytes) || 0)),
		metric(_('入站'), String(st.inbound_count || 0),
			E('span', { 'class': 'ladder-metric-hint' }, [
				st.has_config ? _('已下发') : _('等待 Panel')
			])),
		metric(_('已下发配置'), st.has_config
			? formatBytes(Number(st.config_bytes) || 0)
			: _('等待 Panel'))
	]);

	var tokenText = st.token_set
		? _('已设置 (%s)').format(st.token_masked || '***')
		: _('未设置');

	var control = section(_('控制模式'), controlModeDescr(st), E('div', { 'class': 'ladder-kv-grid' }, [
		kv(_('控制模式'), controlModeLabel(st)),
		kv(_('Panel URL'), dash(st.panel_url)),
		kv(_('节点 ID'), dash(st.node_id)),
		kv(_('gRPC 监听'), dash(st.listen)),
		kv(_('上报地址'), dash(st.report_address)),
		kv(_('WebSocket'), st.uplink ? (st.uplink_ws ? _('已开启') : _('已关闭')) : '—'),
		kv(_('Agent Token'), tokenText),
		kv(_('注册令牌'), st.enroll_token_set ? _('待注册') : _('无'))
	]));

	var inboundBodyKids = [
		E('div', { 'class': 'ladder-kv-grid' }, [
			kv(_('已下发配置'), st.has_config
				? _('是 (%s)').format(formatBytes(Number(st.config_bytes) || 0))
				: _('否（等待 Panel）')),
			kv(_('入站数量'), String(st.inbound_count || 0))
		])
	];
	if (types.length)
		inboundBodyKids.push(E('div', { 'class': 'ladder-type-list' }, types.map(function (t) {
			return badge(t, 'outline');
		})));
	var inbounds = section(
		_('入站') + (st.inbound_count ? ' (' + st.inbound_count + ')' : ''),
		_('本地已应用的代理入站。各入站的公网地址仍在 Panel 里配置。'),
		E('div', {}, inboundBodyKids)
	);

	var frps = section(_('内嵌 FRP Server'), _('FRPS 由 Agent 进程托管，配置持久化后会随 Agent 自动恢复。'), E('div', { 'class': 'ladder-badges' }, [
		badge(st.has_frps ? _('已下发') : _('未下发'), st.has_frps ? 'ok' : 'muted')
	]));

	var system = section(
		_('系统状态'),
		_('每 10 秒自动刷新') + (st.collected_at_unix ? _(' · 采集于 %s').format(formatTime(st.collected_at_unix)) : ''),
		E('div', { 'class': 'ladder-metrics' }, [
			metric(_('内存'), formatBytes(Number(st.mem_used_bytes) || 0),
				E('span', {}, [
					E('span', { 'class': 'ladder-metric-hint' }, [
						'/ ' + formatBytes(Number(st.mem_total_bytes) || 0) + ' (' + memPct.toFixed(0) + '%)'
					]),
					bar(memPct)
				])),
			metric(_('磁盘'), formatBytes(Number(st.disk_used_bytes) || 0),
				E('span', {}, [
					E('span', { 'class': 'ladder-metric-hint' }, [
						'/ ' + formatBytes(Number(st.disk_total_bytes) || 0) + ' (' + diskPct.toFixed(0) + '%)'
					]),
					bar(diskPct)
				])),
			metric(_('负载'), dash(st.load1)),
			metric(_('拥塞算法'), dash(st.congestion),
				E('span', { 'class': 'ladder-metric-hint' }, [
					st.congestion === 'bbr' ? _('已启用') : _('未启用 BBR')
				]))
		])
	);

	var info = section(_('节点信息'), null, E('div', { 'class': 'ladder-kv-grid' }, [
		kv(_('主机名'), dash(st.hostname)),
		kv(_('PID'), dash(st.pid)),
		kv(_('数据目录'), dash(st.data_dir)),
		kv(_('主机已运行'), formatUptime(st.uptime_seconds)),
		kv(_('UCI 启用'), st.enabled ? _('已启用') : _('未启用')),
		kv(_('开机启动'), st.init_enabled ? _('已启用') : _('未启用'))
	]));

	return E('div', { 'class': 'ladder-node-stack' }, [
		header,
		metrics,
		control,
		inbounds,
		frps,
		system,
		info
	]);
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function () {
		return loadStatus().catch(function (err) {
			return { _error: String(err) };
		});
	},

	render: function (data) {
		var view = this;
		var banner = E('div', { 'id': 'ladder-agent-status-error' });
		var body = E('div', { 'id': 'ladder-agent-status-body' });

		function fill(st) {
			dom.content(banner, []);
			dom.content(body, []);
			if (!st || st._error) {
				banner.appendChild(E('div', { 'class': 'alert-message warning' }, [
					_('Failed to read status: %s').format(st && st._error ? st._error : _('unknown'))
				]));
				return;
			}
			body.appendChild(renderStatus(st));
		}

		function reload() {
			return loadStatus().then(fill).catch(function (err) {
				fill({ _error: String(err) });
			});
		}

		function act(action) {
			return serviceAction(action).then(reload);
		}

		fill(data);

		var actions = section(
			_('生命周期与管控'),
			_('启停本机 ladder-agent。Enable / Disable 只改开机自启。'),
			E('div', { 'class': 'ladder-actions' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': ui.createHandlerFn(view, reload)
				}, [_('Refresh')]),
				E('button', {
					'class': 'btn cbi-button cbi-button-apply',
					'click': ui.createHandlerFn(view, function () { return act('start'); })
				}, [_('Start')]),
				E('button', {
					'class': 'btn cbi-button cbi-button-negative',
					'click': ui.createHandlerFn(view, function () { return act('stop'); })
				}, [_('Stop')]),
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': ui.createHandlerFn(view, function () { return act('restart'); })
				}, [_('Restart')]),
				E('button', {
					'class': 'btn cbi-button cbi-button-save',
					'click': ui.createHandlerFn(view, function () { return act('enable'); })
				}, [_('Enable on boot')]),
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(view, function () { return act('disable'); })
				}, [_('Disable on boot')])
			])
		);

		poll.add(reload, 10);

		return E('div', { 'class': 'ladder-node-page' }, [
			E('style', { 'type': 'text/css' }, [PAGE_CSS]),
			E('h2', {}, [_('LadderAirport')]),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('本机节点状态。实时 Panel 指标仍走 agent uplink/push；这里展示进程、UCI、已下发配置和本地累计流量。')
			]),
			banner,
			body,
			actions
		]);
	}
});
