#!/bin/sh
# 飞Young 校园网守护进程: 登录 -> 在线巡检保活 -> 掉线自动重登
# 由 /etc/init.d/feiyoung 通过 procd 拉起, 也可以手动前台运行:
#   sh /usr/lib/feiyoung/daemon.sh
#
# 设计要点:
#   * 断网时不要盲目反复 POST /login —— 那可能触发运营商的风控/黑名单,
#     所以先判断「认证网段是否可达」, 不可达就只退避等待, 不提交登录。
#   * 失败退避: 60s -> 120s -> 240s -> 最长 600s, 恢复后自动重置。

PROG=/usr/bin/feiyoung.sh

# 读取 init 脚本生成的运行期配置(凭据/网口/超时), 便于手动前台运行时也能拿到
for _c in /var/run/feiyoung.conf /etc/feiyoung.conf; do
    [ -f "$_c" ] && . "$_c" && break
done

BASE_RETRY=${FEIYOUNG_RETRY:-60}
MAX_RETRY=600
KEEP=${FEIYOUNG_KEEPALIVE:-120}
INDEX_TIMEOUT=${FEIYOUNG_INDEX_TIMEOUT:-5}
WAN_IF=${FEIYOUNG_WAN:-wan}

log_msg() {
    echo "[daemon] $*"
    logger -t feiyoung "[daemon] $*"
}

# 取 WAN 口的网关地址
get_gateway() {
    ubus call network.interface.$WAN_IF status 2>/dev/null \
        | sed -n 's/.*"nexthop"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# 整个链路沦为不可用(连网关都 ping 不到, ARP 表项 INCOMPLETE)时,
# 单纯等待是没用的 —— BRAS 踢掉会话后路由器的 DHCP 租约可能是脏的,
# 必须重新拉起 WAN 口拿新租约。
wan_recover() {
    _gw=`get_gateway`
    log_msg "尝试恢复 WAN: ifdown $WAN_IF; ifup $WAN_IF (网关=${_gw:-未知})"
    ifdown "$WAN_IF" 2>/dev/null
    sleep 3
    ifup "$WAN_IF" 2>/dev/null
    sleep 12
    if [ -n "$_gw" ] && ping -c 2 -W 2 "$_gw" >/dev/null 2>&1; then
        log_msg "WAN 恢复成功, 网关可以 ping 通了"
        return 0
    fi
    log_msg "WAN 仍未恢复"
    return 1
}

# 判断当前是否具备认证条件:
#   能在 INDEX_TIMEOUT 秒内拿到 HTTP 层任何响应(302 被劫持到 portal / 200 已放行)
#   拿不到任何东西 = 链路或认证网段不可达
# 返回 0 = 可以尝试登录, 1 = 认证网络不可达
portal_reachable() {
    _code=`curl -s -m "$INDEX_TIMEOUT" -o /dev/null -w '%{http_code}' http://captive.apple.com 2>/dev/null`
    case "$_code" in
        200|301|302|303|307|308) return 0 ;;
    esac
    # 换成国内站点再确认一次(有些网络对 captive.apple.com 有特殊处理)
    _code=`curl -s -m "$INDEX_TIMEOUT" -o /dev/null -w '%{http_code}' http://www.baidu.com 2>/dev/null`
    case "$_code" in
        200|301|302|303|307|308) return 0 ;;
    esac
    return 1
}

[ -x "$PROG" ] || { log_msg "ERROR: $PROG 不存在或没有执行权限"; exit 1; }

log_msg "启动: base_retry=${BASE_RETRY}s keepalive=${KEEP}s max_retry=${MAX_RETRY}s"

delay=$BASE_RETRY

while true; do
    # 先看认证网络通不通
    if ! portal_reachable; then
        # 分两种情况: 网关都 ping 不到 = 链路/会话死了, 需要重拉 WAN;
        #             网关通但 portal 不通 = 认证网段暂时异常, 等着就行
        _gw=`get_gateway`
        if [ -z "$_gw" ] || ! ping -c 2 -W 2 "$_gw" >/dev/null 2>&1; then
            log_msg "网关不可达(ARP 可能是 INCOMPLETE), 重新拉起 WAN"
            wan_recover
        else
            log_msg "认证网段不可达(网关可 ping 通), 等 ${delay}s 后重新探测"
        fi
        sleep "$delay"
        delay=$(( delay * 2 ))
        [ "$delay" -gt "$MAX_RETRY" ] && delay=$MAX_RETRY
        continue
    fi

    "$PROG" login
    rc=$?

    case "$rc" in
        0)
            log_msg "已在线, 开始保活巡检 (每 ${KEEP}s)"
            delay=$BASE_RETRY
            while true; do
                sleep "$KEEP"
                if "$PROG" status 2>/dev/null | grep -q ONLINE; then
                    : # 仍然在线
                else
                    log_msg "检测到掉线, 重新登录"
                    break
                fi
            done
            ;;
        3)
            log_msg "账号需要短信验证, 暂停 10 分钟(请先在浏览器手动登录一次)"
            sleep 600
            ;;
        *)
            log_msg "登录失败 (rc=$rc), ${delay}s 后重试"
            sleep "$delay"
            delay=$(( delay * 2 ))
            [ "$delay" -gt "$MAX_RETRY" ] && delay=$MAX_RETRY
            ;;
    esac
done
