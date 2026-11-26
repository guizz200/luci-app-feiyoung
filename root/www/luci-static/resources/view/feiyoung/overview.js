'use strict';
'require view';
'require ui';
'require rpc';
'require uci';

/*
 * 飞Young 校园网 —— 状态与操作
 *
 * 在线检测会真实请求 portal(约 5-10 秒), 所以只在页面打开和手动点击时做真实探测,
 * 避免频繁打扰认证服务器。页面内不再自动轮询。
 */

var callStatus  = rpc.declare({ object: 'luci.feiyoung', method: 'status', expect: {} });
var callLogin   = rpc.declare({ object: 'luci.feiyoung', method: 'login', params: [ 'username', 'password' ], expect: {} });
var callLogout  = rpc.declare({ object: 'luci.feiyoung', method: 'logout', expect: {} });
var callRestart = rpc.declare({ object: 'luci.feiyoung', method: 'restart', params: [ 'wan_if' ], expect: {} });
var callInit    = rpc.declare({ object: 'luci', method: 'setInitAction', params: [ 'name', 'action' ], expect: { result: false } });

return view.extend({
	status: {},

	/* ---------- 打开页面时: 真实探测一次 ---------- */
	load: function() {
		return L.resolveDefault(callStatus(), {});
	},

	/* ---------- 渲染 ---------- */
	render: function(status) {
		this.status = status || {};

		var s = this.status;
		var self = this;

		var onlineText = (s.online == '1')
			? E('strong', { style: 'color:#2e7d32' }, '● 已联网')
			: E('strong', { style: 'color:#c62828' }, '● 未联网 / 未认证');

		var rows = [
			this.row('服务状态', E('span', {}, (s.running == '1') ? '运行中' : '已停止')),
			this.row('开机自启', E('span', { 'id': 'fy-enabled' },
				(s.enabled == '1')
					? E('strong', { style: 'color:#2e7d32' }, '已启用')
					: E('strong', { style: 'color:#6d6d72' }, '未启用'))),
			this.row('联网状态', E('span', { id: 'fy-online' }, onlineText)),
			this.row('校园网账号', E('span', {}, s.username || '（未配置）')),
			this.row('portal 探测', E('code', { style: 'word-break:break-all;' }, s.status || '（未知）')),
			this.row('最近事件', E('span', { style: 'word-break:break-all;' }, s.last || '（无记录）'))
		];

		return E('div', {}, [
			E('h2', {}, '飞Young 校园网'),
			E('div', { 'class': 'cbi-map-descr' },
				'本机已内置自动认证与保活守护：开机自动登录、掉线自动重登、网关不可达时自动重拉 WAN。'),
			E('div', { 'class': 'cbi-section' }, [
				E('table', { 'class': 'table' }, [ E('tbody', {}, rows) ])
			]),
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', {
					'class': 'cbi-button cbi-button-apply',
					'click': ui.createHandlerFn(this, 'handleLoginPrompt')
				}, '立即登录'),
				' ',
				E('button', {
					'class': 'cbi-button cbi-button-reset',
					'click': ui.createHandlerFn(this, 'handleLogout')
				}, '强制下线'),
				' ',
				E('button', {
					'class': 'cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, 'handleRestart')
				}, '重启服务'),
				' ',
				E('button', {
					'class': 'cbi-button',
					'click': ui.createHandlerFn(this, 'handleProbe')
				}, '重新检测联网'),
				' ',
				E('button', {
					'class': 'cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, 'handleToggleAutostart')
				}, (s.enabled == '1') ? '关闭开机自启' : '开启开机自启')
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '说明'),
				E('ul', { 'class': 'cbi-section-descr' }, [
					E('li', {}, '「立即登录」会占用本账号的在线名额，手机端届时无法同时登录。'),
					E('li', {}, '「强制下线」用于把名额让给手机；之后守护进程会自行尝试重新登录。'),
					E('li', {}, '「重启服务」重新读取配置并重拉守护进程，不会影响 WAN 拨号。'),
					E('li', {}, '修改账号密码请到「配置」页，保存后服务自动重启。'),
					E('li', {}, '掉线不必手动处理：守护进程检测到掉线会自动重登，网关不可达会自动重拉 WAN。')
				])
			])
		]);
	},

	row: function(label, value) {
		return E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left', 'width': '22%' }, E('strong', {}, label)),
			E('td', { 'class': 'td left' }, value)
		]);
	},

	/* ---------- 操作 ---------- */
	handleLoginPrompt: function() {
		var self = this;

		ui.showModal('校园网登录', [
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, '账号'),
				E('div', { 'class': 'cbi-value-field' },
					E('input', { 'type': 'text', 'id': 'fy-user', 'style': 'width:100%',
						'value': this.status.username || '' }))
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, '密码'),
				E('div', { 'class': 'cbi-value-field' },
					E('input', { 'type': 'password', 'id': 'fy-pass', 'style': 'width:100%' }))
			]),
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', { 'class': 'btn cbi-button', 'click': ui.hideModal }, '取消'),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-apply',
					'click': ui.createHandlerFn(this, function() {
						var u = (document.getElementById('fy-user') || {}).value || '';
						var p = (document.getElementById('fy-pass') || {}).value || '';
						if (!u || !p) {
							ui.addNotification(null, E('p', {}, '账号和密码都不能为空'), 'warning');
							return;
						}
						ui.showModal('正在登录', [
							E('p', { 'class': 'spinning' }, '正在向 portal 提交认证，请稍候…')
						]);
						return self.applyResult(callLogin(u, p), '登录');
					})
				}, '提交登录')
			])
		]);
	},

	handleLogout: function() {
		return this.applyResult(callLogout(), '下线');
	},

	handleRestart: function() {
		return this.applyResult(callInit('feiyoung', 'restart'), '重启服务');
	},

	/* 开机自启开关: 同时把 uci 的 enabled 与 /etc/rc.d 的软链接一起改掉,
	   保证界面上看到的状态和实际行为一致 */
	handleToggleAutostart: function() {
		var self = this;
		var on = (this.status.enabled != '1');
		var tasks = [
			L.resolveDefault(callInit('feiyoung', on ? 'enable' : 'disable'), {}),
			uci.load('feiyoung').then(function() {
				uci.set('feiyoung', 'main', 'enabled', on ? '1' : '0');
				return uci.save();
			}).then(function() {
				return uci.apply();
			})
		];
		/* 开启自启时顺便把服务跑起来; 关闭时只解自启, 不停当前服务 */
		if (on)
			tasks.push(L.resolveDefault(callInit('feiyoung', 'start'), {}));

		ui.showModal('处理中', [ E('p', { 'class': 'spinning' }, '正在' + (on ? '开启' : '关闭') + '开机自启…') ]);
		return Promise.all(tasks).then(function() {
			ui.hideModal();
			ui.addNotification(null,
				E('p', {}, '开机自启已' + (on ? '开启' : '关闭') +
					(on ? '，服务已启动' : '（当前服务仍在运行，如需停止请用「强制下线」或 SSH stop）')),
				'info');
			return L.resolveDefault(callStatus(), {}).then(function(s) {
				return self.renderStatus(s);
			});
		}).catch(function(e) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, '操作失败：' + e.message), 'danger');
		});
	},

	handleProbe: function() {
		var self = this;
		ui.showModal('检测中', [
			E('p', { 'class': 'spinning' }, '正在探测 portal，约需 5-10 秒…')
		]);
		return L.resolveDefault(callStatus(), {}).then(function(res) {
			ui.hideModal();
			return self.renderStatus(res);
		});
	},

	/* 统一处理 RPC 结果: 关弹窗 -> 提示 -> 重新探测状态 */
	applyResult: function(promise, label) {
		var self = this;
		return L.resolveDefault(promise, { ok: '0', message: 'RPC 调用无响应' }).then(function(res) {
			ui.hideModal();
			var ok = !!(res && (res.ok === '1' || res.ok === 1 || res.result === true));
			ui.addNotification(null,
				E('p', {}, label + (ok ? '成功' : '失败') +
					(res && res.message ? '：' + res.message : '')),
				ok ? 'info' : 'danger');
			ui.showModal('刷新状态', [ E('p', { 'class': 'spinning' }, '正在重新探测…') ]);
			return L.resolveDefault(callStatus(), {}).then(function(s) {
				ui.hideModal();
				return self.renderStatus(s);
			});
		}).catch(function(e) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, label + ' 出错：' + e.message), 'danger');
		});
	},

	/* 只更新状态表格, 不整页重绘(避免闪烁和滚动位置丢失) */
	renderStatus: function(status) {
		this.status = status || {};
		var s = this.status;

		var el = document.getElementById('fy-online');
		if (el) {
			while (el.firstChild) el.removeChild(el.firstChild);
			el.appendChild(s.online == '1'
				? E('strong', { style: 'color:#2e7d32' }, '● 已联网')
				: E('strong', { style: 'color:#c62828' }, '● 未联网 / 未认证'));
		}

		var en = document.getElementById('fy-enabled');
		if (en) {
			while (en.firstChild) en.removeChild(en.firstChild);
			en.appendChild(s.enabled == '1'
				? E('strong', { style: 'color:#2e7d32' }, '已启用')
				: E('strong', { style: 'color:#6d6d72' }, '未启用'));
		}
		return true;
	}
});
