'use strict';
'require view';
'require ui';
'require poll';
'require rpc';

/*
 * 飞Young 校园网 —— 日志
 * 读取 /var/log/feiyoung.log (主脚本和守护进程都会写这里)。
 */

var callLog = rpc.declare({ object: 'luci.feiyoung', method: 'log', params: [ 'lines' ], expect: {} });
var callClearLog = rpc.declare({ object: 'luci.feiyoung', method: 'clear_log', expect: {} });

return view.extend({
	pollFn: null,

	load: function() {
		return L.resolveDefault(callLog(200), { log: '' });
	},

	render: function(res) {
		var self = this;
		var text = (res && res.log) || '';

		var out = E('textarea', {
			'id': 'fy-log',
			'readonly': 'readonly',
			'wrap': 'off',
			'rows': 28,
			'style': 'width:100%;font-family:monospace;font-size:12px;white-space:pre;'
		});
		out.value = text;

		/* 自动刷新: 只读取文件, 不产生网络请求 */
		var auto = E('input', { 'type': 'checkbox', 'id': 'fy-autorefresh', 'checked': 'checked' });
		var lines = E('select', { 'id': 'fy-lines', 'class': 'cbi-input-select' }, [
			E('option', { 'value': '100' }, '100 行'),
			E('option', { 'value': '200', 'selected': 'selected' }, '200 行'),
			E('option', { 'value': '500' }, '500 行')
		]);

		this.pollFn = function() {
			var cb = document.getElementById('fy-autorefresh');
			if (!cb || !cb.checked) return;
			var n = (document.getElementById('fy-lines') || {}).value || '200';
			return L.resolveDefault(callLog(n), {}).then(function(r) {
				var ta = document.getElementById('fy-log');
				if (ta && r && typeof r.log === 'string')
					ta.value = r.log;
			});
		};

		poll.add(this.pollFn, 5);

		return E('div', {}, [
			E('h2', {}, '飞Young 日志'),
			E('div', { 'class': 'cbi-map-descr' },
				'内容来自 /var/log/feiyoung.log，主脚本与守护进程都会写入。可在此确认登录结果、掉线重登与 WAN 自愈记录。'),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, '显示行数'),
				E('div', { 'class': 'cbi-value-field' }, [
					lines, ' ',
					E('label', { 'style': 'margin-left:1em' }, [ auto, ' 自动刷新（5 秒）' ])
				])
			]),
			E('div', { 'class': 'cbi-section' }, out),
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', {
					'class': 'cbi-button',
					'click': ui.createHandlerFn(this, function() {
						return L.resolveDefault(callLog((document.getElementById('fy-lines') || {}).value || '200'), {})
							.then(function(r) {
								var ta = document.getElementById('fy-log');
								if (ta) ta.value = (r && r.log) || '';
							});
					})
				}, '立即刷新'),
				' ',
				E('button', {
					'class': 'cbi-button cbi-button-reset',
					'click': ui.createHandlerFn(this, 'handleClear')
				}, '清空日志')
			])
		]);
	},

	handleClear: function() {
		return L.resolveDefault(callClearLog(), {}).then(function(res) {
			var ok = !!(res && (res.ok === '1' || res.ok === 1));
			ui.addNotification(null, E('p', {}, (res && res.message) || (ok ? '已清空' : '清空失败')),
				ok ? 'info' : 'danger');
			var ta = document.getElementById('fy-log');
			if (ta && ok) ta.value = '';
		});
	}
});
