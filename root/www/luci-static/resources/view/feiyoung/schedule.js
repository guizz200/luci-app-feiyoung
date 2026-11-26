'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require rpc';

/*
 * 飞Young 校园网 —— 定时任务
 *
 * 用途: 到点自动下线(释放账号的在线名额)、到点自动恢复。
 * 典型场景:
 *   - 夜间不用网时下线, 避免长时间在线被学校判定为共享
 *   - 白天上课时段自动下线, 把名额让给手机
 *
 * 保存后由后端 rpcd 生成两条 crontab:
 *   到 off_time -> feiyoung-schedule.sh off   (内部会再判断是否启用/是否跳过日)
 *   到 on_time  -> feiyoung-schedule.sh on    (只在计划停机窗口内才恢复)
 *
 * 为什么 off 是「停服务」而不是只调 portal 下线:
 *   守护进程每 keepalive_interval 秒会巡检一次, 只调 portal 下线的话
 *   几十秒后就被自动抢回来了, 定时下线会失效。
 */

var callApplySchedule = rpc.declare({
	object: 'luci.feiyoung',
	method: 'apply_schedule',
	params: [ 'enabled', 'off_hour', 'off_min', 'on_hour', 'on_min' ],
	expect: {}
});

var DAYS = [ 'mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun' ];
var DAY_LABEL = {
	mon: '星期一', tue: '星期二', wed: '星期三', thu: '星期四',
	fri: '星期五', sat: '星期六', sun: '星期日'
};

function hourOptions(sel) {
	var r = [];
	for (var i = 0; i < 24; i++) {
		var v = (i < 10 ? '0' : '') + i;
		r.push(E('option', { 'value': v, 'selected': (v === sel) ? 'selected' : null }, v + ' 时'));
	}
	return r;
}

function minOptions(sel) {
	var r = [];
	for (var i = 0; i < 60; i++) {
		var v = (i < 10 ? '0' : '') + i;
		r.push(E('option', { 'value': v, 'selected': (v === sel) ? 'selected' : null }, v + ' 分'));
	}
	return r;
}

return view.extend({
	load: function() {
		return uci.load('feiyoung');
	},

	render: function() {
		var off = (uci.get('feiyoung', 'schedule', 'off_time') || '23:30').split(':');
		var on = (uci.get('feiyoung', 'schedule', 'on_time') || '07:00').split(':');
		var en = uci.get('feiyoung', 'schedule', 'enabled') || '0';

		var self = this;

		return E('div', {}, [
			E('h2', {}, '定时任务'),
			E('div', { 'class': 'cbi-map-descr' },
				'到点自动下线、到点自动恢复。下线时会真正停止守护进程，' +
				'否则它会在巡检周期内把连接抢回来。'),

			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, '启用定时任务'),
					E('div', { 'class': 'cbi-value-field' },
						E('input', { 'type': 'checkbox', 'id': 'fy-sched-en',
							'checked': (en === '1') ? 'checked' : null }))
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, '自动下线时间'),
					E('div', { 'class': 'cbi-value-field' }, [
						E('select', { 'class': 'cbi-input-select', 'id': 'fy-off-h' }, hourOptions(off[0])),
						' ',
						E('select', { 'class': 'cbi-input-select', 'id': 'fy-off-m' }, minOptions(off[1]))
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, '自动恢复时间'),
					E('div', { 'class': 'cbi-value-field' }, [
						E('select', { 'class': 'cbi-input-select', 'id': 'fy-on-h' }, hourOptions(on[0])),
						' ',
						E('select', { 'class': 'cbi-input-select', 'id': 'fy-on-m' }, minOptions(on[1]))
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, '生效的星期'),
					E('div', { 'class': 'cbi-value-field' },
						DAYS.map(function(d) {
							var v = uci.get('feiyoung', 'schedule', d);
							if (v === undefined || v === null || v === '') v = '1';
							return E('label', { 'style': 'margin-right:1em;white-space:nowrap;' }, [
								E('input', { 'type': 'checkbox', 'class': 'fy-day', 'data-day': d,
									'checked': (v === '1') ? 'checked' : null }),
								' ' + DAY_LABEL[d]
							]);
						})
					)
				])
			]),

			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', {
					'class': 'cbi-button cbi-button-save',
					'click': ui.createHandlerFn(this, 'handleSave')
				}, '保存并应用'),
				' ',
				E('button', {
					'class': 'cbi-button',
					'click': ui.createHandlerFn(this, 'handleShowCron')
				}, '查看当前的 crontab')
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '说明'),
				E('ul', { 'class': 'cbi-section-descr' }, [
					E('li', {}, '「自动下线」会调用 portal 下线并停止守护进程，账号的在线名额被释放。'),
					E('li', {}, '「自动恢复」只在确实处于计划停机窗口时才启动服务，' +
						'不会把你手动停掉的服务擅自拉起来。'),
					E('li', {}, '两条时间相同也可以（等价于关闭中间的空档，不推荐）。'),
					E('li', {}, '时间可以相同或跨越零点，例如 23:30 下线、07:00 上线。'),
					E('li', {}, '未勾选任何星期时，定时任务不会写入 crontab。')
				])
			])
		]);
	},

	handleSave: function() {
		var en = document.getElementById('fy-sched-en').checked ? '1' : '0';
		var oh = document.getElementById('fy-off-h').value;
		var om = document.getElementById('fy-off-m').value;
		var nh = document.getElementById('fy-on-h').value;
		var nm = document.getElementById('fy-on-m').value;

		/* 先写星期勾选到 uci, 再由后端生成 cron */
		var days = document.querySelectorAll('.fy-day');
		var self = this;
		var tasks = [];

		for (var i = 0; i < days.length; i++) {
			var d = days[i].getAttribute('data-day');
			uci.set('feiyoung', 'schedule', d, days[i].checked ? '1' : '0');
		}
		uci.set('feiyoung', 'schedule', 'enabled', en);

		return uci.save().then(function() {
			return uci.apply();
		}).then(function() {
			ui.showModal('应用中', [ E('p', { 'class': 'spinning' }, '正在写入 crontab…') ]);
			return callApplySchedule(en, oh, om, nh, nm);
		}).then(function(res) {
			ui.hideModal();
			var ok = !!(res && (res.ok === '1' || res.ok === 1));
			ui.addNotification(null,
				E('p', {}, (res && res.message) || (ok ? '已保存' : '保存失败')),
				ok ? 'info' : 'danger');
		}).catch(function(e) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, '保存出错：' + e.message), 'danger');
		});
	},

	handleShowCron: function() {
		/* 直接读 /etc/crontabs/root 需要额外 ACL, 这里用提示代替 */
		ui.showModal('查看 crontab', [
			E('p', {}, '请到「系统 → 计划任务」(Scheduled Tasks) 查看写入的条目，或在 SSH 里执行：'),
			E('pre', {}, 'crontab -l'),
			E('div', { 'class': 'cbi-page-actions' },
				E('button', { 'class': 'btn cbi-button', 'click': ui.hideModal }, '关闭'))
		]);
	}
});
