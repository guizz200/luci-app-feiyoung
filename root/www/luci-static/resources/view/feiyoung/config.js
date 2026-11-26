'use strict';
'require view';
'require form';
'require uci';
'require ui';

/*
 * 飞Young 校园网 —— 配置
 * 全部走 uci 的 feiyoung 命名空间, 保存后自动重启服务。
 */

return view.extend({
	load: function() {
		return uci.load('feiyoung');
	},

	render: function() {
		var m, s, o;

		m = new form.Map('feiyoung', '飞Young 校园网',
			'配置保存在 /etc/config/feiyoung，保存后服务会自动重启以生效。');

		s = m.section(form.NamedSection, 'main', 'feiyoung', '基本设置');
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', '启用服务',
			'启用后开机自动登录，并由守护进程负责保活和掉线重登。');
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Value, 'username', '校园网账号',
			'一般是手机号，或 ip 开头的账号（如 ip1234567890123）。');
		o.rmempty = false;
		o.placeholder = 'ip1234567890123';

		o = s.option(form.Value, 'password', '密码',
			'由学校分配的密码。如果用手机号登录，通常是账号后六位。');
		o.password = true;
		o.rmempty = false;

		o = s.option(form.ListValue, 'device_type', '模拟设备类型',
			'向 portal 声明自己是手机端。共享热点效果最好，一般不要改。');
		o.value('mobile', '手机 (mobile) —— 推荐');
		o.value('pc', '电脑 (pc)');
		o.default = 'mobile';

		o = s.option(form.Value, 'username_prefix', '账号前缀（可选）',
			'极少数学校要求账号带前缀，例如 !^Adcm0。留空表示不加前缀。');
		o.placeholder = '留空即可';
		o.rmempty = true;

		o = s.option(form.Value, 'wan_if', 'WAN 逻辑接口名',
			'守护进程发现网关不可达时，会对这个接口执行 ifdown / ifup 以重拿租约。');
		o.default = 'wan';
		o.rmempty = false;
		o.validate = function(section_id, value) {
			if (!/^[A-Za-z0-9_]+$/.test(value))
				return '只能包含字母、数字和下划线';
			return true;
		};

		/* ---------- 换学校时主要改这一组 ---------- */
		s = m.section(form.NamedSection, 'main', 'feiyoung', '学校 / Portal 适配');
		s.anonymous = true;

		o = s.option(form.Value, 'portal_url', 'Portal 地址（可选）',
			'留空 = 自动从被劫持的 302 重定向里发现，换学校通常不用改这里。' +
			'如果自动发现失效（学校不再返回 302），就填写学校 portal 的地址。');
		o.placeholder = '例如 http://124.236.57.170:8080';
		o.rmempty = true;

		o = s.option(form.Value, 'portal_probe', '探测地址（可选）',
			'用来触发重定向的网址。留空使用内置的 captive.apple.com 与 www.baidu.com。');
		o.placeholder = '例如 http://connect.rom.miui.com';
		o.rmempty = true;

		o = s.option(form.Value, 'user_agent', '自定义 User-Agent（可选）',
			'个别学校按 UA 返回不同页面。留空使用内置的 Android Chrome UA。');
		o.placeholder = '留空即可';
		o.rmempty = true;

		s = m.section(form.NamedSection, 'main', 'feiyoung', '守护与超时');
		s.anonymous = true;

		o = s.option(form.Value, 'retry_interval', '登录失败重试间隔（秒）',
			'登录失败后的基础等待时间，实际会指数退避到 600 秒封顶。');
		o.datatype = 'uinteger';
		o.default = '60';
		o.rmempty = false;

		o = s.option(form.Value, 'keepalive_interval', '在线巡检间隔（秒）',
			'已在线时每隔多久巡检一次。既用于保活，也用于发现掉线。' +
			'如果学校频繁踢线，把它调大（例如 300）反而更稳。');
		o.datatype = 'uinteger';
		o.default = '120';
		o.rmempty = false;

		o = s.option(form.Value, 'timeout', '网络请求超时（秒）',
			'访问 portal 和提交认证的超时。portal 较慢时可以调大到 30。');
		o.datatype = 'uinteger';
		o.default = '10';
		o.rmempty = false;

		return m.render();
	}
});