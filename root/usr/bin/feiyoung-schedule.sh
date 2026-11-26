#!/bin/sh
# 飞Young 定时任务: 到点自动下线 / 到点自动恢复
#
# 由 LuCI 的「定时任务」页写入 crontab, 一般不需要手工调用:
#   feiyoung-schedule.sh off     # 下线并暂停守护进程(不占在线名额)
#   feiyoung-schedule.sh on      # 恢复守护进程(重新登录)
#   feiyoung-schedule.sh status  # 查看当前是否处于计划停机窗口
#
# 设计要点:
#   * off = 真正 stop 服务(而不只是调 portal 下线), 否则守护进程会在
#     keepalive_interval 秒内把连接抢回来, 定时下线就失效了。
#   * off 会写 /var/run/feiyoung.schedule-off 标记, on 时据此判断,
#     避免把用户手动停掉的服务又擅自拉起来。

. /lib/functions.sh

STATE=/var/run/feiyoung.schedule-off
LOG=/var/log/feiyoung.log
INIT=/etc/init.d/feiyoung

CONF=feiyoung

log_msg() {
	_line="[`date '+%Y-%m-%d %H:%M:%S'`] [schedule] $*"
	echo "$_line"
	echo "$_line" >> $LOG 2>/dev/null
	logger -t feiyoung "[schedule] $*"
}

read_conf() {
	sched_enabled=`uci -q get $CONF.schedule.enabled`
	[ -z "$sched_enabled" ] && sched_enabled=0
	case "$sched_enabled" in
		1|yes|true|on|enabled) sched_enabled=1 ;;
		*) sched_enabled=0 ;;
	esac

	off_time=`uci -q get $CONF.schedule.off_time`
	on_time=`uci -q get $CONF.schedule.on_time`
	[ -z "$off_time" ] && off_time=23:30
	[ -z "$on_time" ]  && on_time=07:00
}

# 今天这个星期几是否生效
today_enabled() {
	_w=`date +%u`          # 1=周一 ... 7=周日
	case "$_w" in
		1) _k=mon ;; 2) _k=tue ;; 3) _k=wed ;; 4) _k=thu ;;
		5) _k=fri ;; 6) _k=sat ;; 7) _k=sun ;;
		*) return 1 ;;
	esac
	_v=`uci -q get $CONF.schedule.$_k`
	[ -z "$_v" ] && _v=1
	case "$_v" in
		1|yes|true|on|enabled) return 0 ;;
		*) return 1 ;;
	esac
}

do_off() {
	read_conf
	if [ "$sched_enabled" != "1" ]; then
		log_msg "定时任务未启用, 忽略 off"
		return 0
	fi
	if ! today_enabled; then
		log_msg "今天是设定的跳过日, 忽略 off"
		return 0
	fi
	if [ -f "$STATE" ]; then
		log_msg "已经处于计划停机状态, 忽略重复 off"
		return 0
	fi

	log_msg "到达下线时间($off_time), 停止服务以释放在线名额"

	# 先让 portal 侧下线(尽力而为, 失败不影响后续)
	/usr/bin/feiyoung.sh offline >/dev/null 2>&1 || true

	# 再停守护进程, 否则会被 keepalive 抢回来
	$INIT stop >/dev/null 2>&1 || true

	touch "$STATE"
	log_msg "已停止。将在 ${on_time} 自动恢复"
}

do_on() {
	read_conf
	if [ ! -f "$STATE" ]; then
		log_msg "不在计划停机状态(可能是手动停的), 不擅自启动服务"
		return 0
	fi
	if [ "$sched_enabled" != "1" ]; then
		log_msg "定时任务已关闭, 清理标记"
		rm -f "$STATE"
		return 0
	fi

	log_msg "到达上线时间($on_time), 恢复服务"
	rm -f "$STATE"
	$INIT start >/dev/null 2>&1 || true
	log_msg "已恢复, 守护进程会自行完成认证"
}

do_status() {
	if [ -f "$STATE" ]; then
		echo "schedule: OFF (处于计划停机窗口)"
	else
		echo "schedule: ON"
	fi
	read_conf
	echo "  off_time = $off_time"
	echo "  on_time  = $on_time"
	echo "  enabled  = $sched_enabled"
	echo "  今天生效 = `today_enabled && echo yes || echo no`"
}

case "$1" in
	off)    do_off ;;
	on)     do_on ;;
	status) do_status ;;
	*)      echo "用法: $0 {off|on|status}"; exit 1 ;;
esac
exit $?
