#!/bin/sh
# ============================================================
# 河北电信飞Young (hbfeiyoung) Web Portal 自动登录脚本
# 适配 OpenWrt / BusyBox ash, 不需要 bash, 不需要装任何包
#
# 原理:
#   1. curl -I 探测公网, 从 302 Location 里抠出 Portal 入口
#   2. GET <portal>/index  并从返回的 HTML 里抠出 userip / publicIP / wlanAcIp
#      (这三个值每次会话都不同, 必须动态取, 不能写死)
#   3. POST <portal>/login 带上 username/password/userip/publicIP/wlanAcIp/deviceType
#   4. 解析 JSON 里的 isLogin 判断成败
#
# 用法:
#   feiyoung.sh login      登录
#   feiyoung.sh status     查看当前状态(会真发一次登录请求做探测)
#   feiyoung.sh offline    下线
#   feiyoung.sh raw        只打印抓到的参数, 不登录(排错用)
#
# 配置: 账号密码写在 /etc/config/feiyoung, 或者用环境变量覆盖
#   FEIYOUNG_USER / FEIYOUNG_PASS
# ============================================================

CONF=/etc/config/feiyoung
LOG=/var/log/feiyoung.log
TMO=${FEIYOUNG_TMO:-10}
DEVICE_TYPE=${DEVICE_TYPE:-mobile}
UA="Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 Chrome/90 Mobile Safari/537.36"

# ---------- 多学校适配用的默认值 ----------
# portal_url     留空 = 自动从被劫持的 302 重定向里发现(本方案默认, 换学校通常也能用)
# portal_probe   用来触发重定向的探测地址(留空用内置的几个)
# user_agent     有些学校的 portal 按 UA 返回不同页面, 必要时可覆盖
# username_prefix 少数学校要求账号加前缀(例如 '!^Adcm0'), 默认不加
# device_type    向 portal 声明的设备类型, mobile/pc
FY_PORTAL=""
FY_PROBE=""
FY_UA=""
FY_PREFIX=""

# ---------- 读配置 ----------
# 注意: /etc/config/feiyoung 是 UCI 格式 (config/option 语法), 不能直接 source!
# 优先级: 环境变量 > /var/run/feiyoung.conf > /etc/feiyoung.conf > UCI
FY_USER=""
FY_PASS=""

if command -v uci >/dev/null 2>&1; then
    # 逐个选项用 uci -q get 读, 不依赖 uci export 的输出格式和 grep 语法
    _u=`uci -q get feiyoung.main.username`
    _p=`uci -q get feiyoung.main.password`
    _d=`uci -q get feiyoung.main.device_type`
    _t=`uci -q get feiyoung.main.timeout`
    _g=`uci -q get feiyoung.main.portal_url`
    _b=`uci -q get feiyoung.main.portal_probe`
    _a=`uci -q get feiyoung.main.user_agent`
    _x=`uci -q get feiyoung.main.username_prefix`
    if [ -n "$_u" ]; then FY_USER="$_u"; fi
    if [ -n "$_p" ]; then FY_PASS="$_p"; fi
    if [ -n "$_d" ]; then DEVICE_TYPE="$_d"; fi
    if [ -n "$_t" ]; then TMO="$_t"; fi
    if [ -n "$_g" ]; then FY_PORTAL="$_g"; fi
    if [ -n "$_b" ]; then FY_PROBE="$_b"; fi
    if [ -n "$_a" ]; then FY_UA="$_a"; fi
    if [ -n "$_x" ]; then FY_PREFIX="$_x"; fi
    # 读不到时打一行诊断, 避免静默失败
    if [ -z "$FY_USER" ]; then
        echo "[feiyoung] 警告: uci -q get feiyoung.main.username 无输出" >&2
        echo "[feiyoung]   uci export feiyoung 的原始输出如下:" >&2
        uci export feiyoung 2>&1 | head -12 >&2
    fi
fi

# 兼容手写的纯 shell 变量文件 (由 init 脚本从 UCI 自动生成, 或手动创建)
# 注意: 不要再指向 /etc/config/feiyoung, 那是 UCI 文件, source 会报 config: not found
for SHELLCONF in /var/run/feiyoung.conf /etc/feiyoung.conf; do
    [ -f "$SHELLCONF" ] || continue
    # shellcheck disable=SC1090
    . "$SHELLCONF"
    if [ -n "$FY_USER" ]; then :; else if [ -n "$FEIYOUNG_USER" ]; then FY_USER="$FEIYOUNG_USER"; fi; fi
    if [ -n "$FY_PASS" ]; then :; else if [ -n "$FEIYOUNG_PASS" ]; then FY_PASS="$FEIYOUNG_PASS"; fi; fi
    break
done

# 环境变量最高优先级, 覆盖一切
if [ -n "$FEIYOUNG_USER" ]; then FY_USER="$FEIYOUNG_USER"; fi
if [ -n "$FEIYOUNG_PASS" ]; then FY_PASS="$FEIYOUNG_PASS"; fi
if [ -n "$FEIYOUNG_PORTAL" ]; then FY_PORTAL="$FEIYOUNG_PORTAL"; fi
if [ -n "$FEIYOUNG_PROBE" ]; then FY_PROBE="$FEIYOUNG_PROBE"; fi
if [ -n "$FEIYOUNG_UA" ]; then FY_UA="$FEIYOUNG_UA"; fi
if [ -n "$FEIYOUNG_PREFIX" ]; then FY_PREFIX="$FEIYOUNG_PREFIX"; fi

# 用户代理: 配置优先, 否则用内置默认(Android Chrome)
if [ -n "$FY_UA" ]; then UA="$FY_UA"; fi

log() {
    echo "[`date '+%Y-%m-%d %H:%M:%S'`] $*"
    echo "[`date '+%Y-%m-%d %H:%M:%S'`] $*" >> $LOG 2>/dev/null
}

die() { log "ERROR: $*"; exit 1; }

# ---------- 工具函数 ----------
# 从 x-www-form-urlencoded 正文里取字段 (自己实现, 因为 curl 没有 --data-urlencode)
urlenc() {
    _v="$1"
    _a=`printf '%s' "$_v" | sed -e 's/%/%25/g' -e 's/ /%20/g' -e 's/+/%2B/g'`
    printf '%s' "$_a" | awk 'BEGIN{FS=""}{for(i=1;i<=NF;i++){c=$i;
        if(c=="&")printf "%s","%26";
        else if(c=="=")printf "%s","%3D";
        else if(c=="/")printf "%s","%2F";
        else if(c=="?")printf "%s","%3F";
        else if(c=="#")printf "%s","%23";
        else if(c=="@")printf "%s","%40";
        else if(c==":")printf "%s","%3A";
        else printf "%s",c}}'
}

# 从 JSON 里取字段值, 字符串和布尔都要能取
#   "message":"sms"        -> sms
#   "isLogin":true         -> true     (注意 isLogin 是布尔, 不加引号!)
#   "isLogout":false       -> false
#   "loginName":"138..."   -> 138...
# 字符串分支先跑: 只有真的带引号才会替换, 此时用 t 跳过分支, 避免匹配到尾部重复输出
json_str() {
    printf '%s' "$1" | sed -n '
        s/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^",}]*\)".*/\1/p
        t
        s/.*"'"$2"'"[[:space:]]*:[[:space:]]*\([^",}]*\).*/\1/p
    ' | head -1
}

# ---------- 取本机 WAN 地址 ----------
get_wan_ip() {
    _ip=`ubus call network.interface.wan status 2>/dev/null \
        | sed -n 's/.*"address"[[:space:]]*:[[:space:]]*"\([0-9.]*\)".*/\1/p' | head -1`
    [ -z "$_ip" ] && _ip=`ip -4 addr show 2>/dev/null \
        | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | grep -v '^127\.' | head -1`
    printf '%s' "$_ip"
}

# ---------- 探测 Portal ----------
# 输出:
#   PORTAL       形如 http://ip:8080            (用来 POST /login /logout)
#   PORTAL_QUERY 完整登录页 URL                   (含本次会话的 query)
#   PORTAL_PAGE  GET /index 的完整 URL            (必须带 query, 否则 400!)
# 返回 0 = 需要认证, 1 = 已经能上网, 2 = 探测失败
#
# 多学校适配:
#   1) 配置了 portal_url  -> 直接用它(手工指定, 适合自动发现失效的学校)
#   2) 否则用 302 重定向自动发现(默认, 换学校通常无需改动)
#   3) 都拿不到 -> 用本机地址 + portal_url 拼一个
detect_portal() {
    PORTAL=""
    PORTAL_QUERY=""
    PORTAL_PAGE=""

    # --- 方式 1: 手工指定了 portal 地址 ---
    if [ -n "$FY_PORTAL" ]; then
        PORTAL=`printf '%s' "$FY_PORTAL" | sed 's#/*$##'`
        _myip=`get_wan_ip`
        _q="wlanuserip=$_myip&wlanacname=&wlanacip="
        PORTAL_QUERY="$PORTAL/index?$_q"
        PORTAL_PAGE="$PORTAL_QUERY"
        log "使用配置的 portal_url: $PORTAL"
        return 0
    fi

    # --- 方式 2: 从 302 重定向自动发现 ---
    _probe="$FY_PROBE"
    [ -z "$_probe" ] && _probe="http://captive.apple.com"
    _hdr=`curl -I -s -m $TMO -A "$UA" "$_probe" | tr -d '\r'`
    if [ -z "$_hdr" ]; then
        _probe="http://www.baidu.com"
        _hdr=`curl -I -s -m $TMO -A "$UA" "$_probe" | tr -d '\r'`
    fi

    _loc=`printf '%s\n' "$_hdr" | grep -i '^location:' | head -1 | sed 's/^[Ll]ocation:[[:space:]]*//'`

    if [ -n "$_loc" ]; then
        # 完整 URL 就是登录页入口, 必须连 query 一起用
        PORTAL_QUERY="$_loc"
        PORTAL=`printf '%s' "$_loc" | sed 's/?.*$//' | sed 's#\(https\?://[^/]*\).*#\1#'`
        [ -z "$PORTAL" ] && return 2
        PORTAL_PAGE="$_loc"
        log "从 $_probe 的 302 重定向发现 portal: $PORTAL"
        return 0
    fi

    # --- 没有重定向: 可能已在线, 也可能探测失败 ---
    _code=`curl -s -m $TMO -o /dev/null -w '%{http_code}' "http://www.baidu.com"`
    if [ "$_code" = "200" ]; then
        return 1
    fi

    # --- 方式 3: 配置里连 portal_url 都没有 -> 明确报错, 不再瞎猜 ---
    log "!! 没有抓到 302 重定向, 且未配置 portal_url"
    log "!! 请在 LuCI 的「配置」页填写学校的 Portal 地址, 或确认 WAN 口在认证网段"
    return 2
}

# ---------- 抓 index 并抠出三个动态参数 ----------
# 成功后设置 USERIP / PUBLICIP / WLANACIP
fetch_params() {
    # 手动兜底: 如果三个值都用环境变量/配置给定了, 就不再抓页面
    if [ -n "$FEIYOUNG_USERIP" ] && [ -n "$FEIYOUNG_PUBLICIP" ] && [ -n "$FEIYOUNG_WLANACIP" ]; then
        USERIP="$FEIYOUNG_USERIP"
        PUBLICIP="$FEIYOUNG_PUBLICIP"
        WLANACIP="$FEIYOUNG_WLANACIP"
        log "使用手动指定的参数 (跳过 /index)"
        return 0
    fi

    # 必须用带 query 的完整 URL, 裸 /index 会返回 400
    [ -z "$PORTAL_PAGE" ] && PORTAL_PAGE="$PORTAL/index"
    curl -s -m $TMO -A "$UA" "$PORTAL_PAGE" -o /tmp/feiyoung_index.html 2>/dev/null
    _size=`wc -c < /tmp/feiyoung_index.html 2>/dev/null`
    log "GET $PORTAL/index -> ${_size:-0} 字节"
    [ -z "$_size" ] && return 1
    [ "$_size" -lt 100 ] && {
        log "!! 页面太小, 内容如下:"
        head -5 /tmp/feiyoung_index.html
        return 1
    }

    # 用文件而不是变量, 避免超长字符串在管道里的问题
    # 注意: 这里刻意使用单引号包住 sed 脚本、双引号匹配值 —— 避免 ['\"] 这种
    #       「单引号里嵌转义双引号」的写法, 那在 BusyBox 的 sed/sh 上行为不可靠
    USERIP=`sed -n 's/.*var[[:space:]]*userip[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' /tmp/feiyoung_index.html | head -1`
    PUBLICIP=`sed -n 's/.*var[[:space:]]*publicIP[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' /tmp/feiyoung_index.html | head -1`
    WLANACIP=`sed -n 's/.*var[[:space:]]*wlanAcIp[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' /tmp/feiyoung_index.html | head -1`
    log "抠参数(双引号): userip=[$USERIP] publicIP=[$PUBLICIP] wlanAcIp=[$WLANACIP]"

    # 页面上实际用的是单引号, 所以再试一遍单引号写法 (同样不嵌转义)
    if [ -z "$USERIP" ]; then
        USERIP=`sed -n "s/.*var[[:space:]]*userip[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" /tmp/feiyoung_index.html | head -1`
    fi
    if [ -z "$PUBLICIP" ]; then
        PUBLICIP=`sed -n "s/.*var[[:space:]]*publicIP[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" /tmp/feiyoung_index.html | head -1`
    fi
    if [ -z "$WLANACIP" ]; then
        WLANACIP=`sed -n "s/.*var[[:space:]]*wlanAcIp[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" /tmp/feiyoung_index.html | head -1`
    fi
    log "抠参数(单引号): userip=[$USERIP] publicIP=[$PUBLICIP] wlanAcIp=[$WLANACIP]"

    # 兜底1: 宽松写法, 不要求 var 前缀, 两种引号都试
    if [ -z "$USERIP" ]; then
        USERIP=`sed -n "s/.*userip[^'\"]*['\"]\([^'\"]*\)['\"].*/\1/p" /tmp/feiyoung_index.html | head -1`
    fi
    if [ -z "$PUBLICIP" ]; then
        PUBLICIP=`sed -n "s/.*publicIP[^'\"]*['\"]\([^'\"]*\)['\"].*/\1/p" /tmp/feiyoung_index.html | head -1`
    fi
    if [ -z "$WLANACIP" ]; then
        WLANACIP=`sed -n "s/.*wlanAcIp[^'\"]*['\"]\([^'\"]*\)['\"].*/\1/p" /tmp/feiyoung_index.html | head -1`
    fi
    log "抠参数(宽松): userip=[$USERIP] publicIP=[$PUBLICIP] wlanAcIp=[$WLANACIP]"

    # 兜底2: 从重定向 URL 的 query 里取 (wlanuserip / wlanacip 本来就带在 URL 上)
    if [ -z "$USERIP" ] && [ -n "$PORTAL_QUERY" ]; then
        USERIP=`printf '%s' "$PORTAL_QUERY" | sed -n 's/.*wlanuserip=\([^&]*\).*/\1/p'`
        WLANACIP=`printf '%s' "$PORTAL_QUERY" | sed -n 's/.*wlanacip=\([^&]*\).*/\1/p'`
        log "抠参数(URL兜底): userip=[$USERIP] wlanacip=[$WLANACIP]"
    fi

    if [ -z "$USERIP" ]; then
        log "!! 三种方法都没抠出 userip"
        log "!! HTML 已保存到 /tmp/feiyoung_index.html, 相关行如下:"
        grep -in "userip\|publicIP\|wlanAcIp" /tmp/feiyoung_index.html 2>/dev/null | head -10
        return 2
    fi
    return 0
}

# ---------- 下线 ----------
do_offline() {
    detect_portal
    _rc=$?
    if [ $_rc -eq 1 ]; then
        log "当前可直接上网, 无需处理"
        return 0
    elif [ $_rc -ne 0 ]; then
        die "探测不到 Portal: 请确认 WAN 口已插在校园网并拿到地址, 或在「配置」页填写学校的 Portal 地址"
    fi

    fetch_params || die "无法从 $PORTAL/index 抓到 userip/publicIP/wlanAcIp"
    log "下线中 userip=$USERIP publicIP=$PUBLICIP wlanAcIp=$WLANACIP"

    _body="userip=`urlenc "$USERIP"`&publicIP=`urlenc "$PUBLICIP"`&wlanAcIp=`urlenc "$WLANACIP"`&deviceType=$DEVICE_TYPE"
    _resp=`curl -s -m $TMO -A "$UA" -X POST "$PORTAL/logout" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -H "X-Requested-With: XMLHttpRequest" \
        --data "$_body"`

    _islogoff=`json_str "$_resp" isLogout`
    _msg=`json_str "$_resp" message`
    if [ "$_islogoff" = "true" ]; then
        log "下线成功: $_msg"
        return 0
    fi
    log "下线失败: isLogout=$_islogoff message=$_msg"
    log "原始响应: $_resp"
    return 1
}

# ---------- 登录 ----------
do_login() {
    if [ -z "$FY_USER" ] || [ -z "$FY_PASS" ]; then
        log "ERROR: 未读到账号密码, 三个来源都为空:"
        log "  1) /etc/config/feiyoung 的 uci 配置 (uci show feiyoung)"
        log "  2) /var/run/feiyoung.conf 或 /etc/feiyoung.conf 变量文件"
        log "  3) 环境变量 FEIYOUNG_USER / FEIYOUNG_PASS"
        log "  自检: uci -q get feiyoung.main.username 应当有输出"
        log "  临时可用: FEIYOUNG_USER=xx FEIYOUNG_PASS=yy $0 login"
        exit 1
    fi

    detect_portal
    _rc=$?
    if [ $_rc -eq 1 ]; then
        log "已经在线, 跳过登录"
        return 0
    elif [ $_rc -ne 0 ]; then
        die "探测不到 Portal: 请确认 WAN 口已插在校园网并拿到地址, 或在「配置」页填写学校的 Portal 地址"
    fi
    log "Portal = $PORTAL"
    # 少数学校要求账号带前缀(例如 '!^Adcm0'), 由 username_prefix 配置
    _fulluser="$FY_PREFIX$FY_USER"
    log "凭据: 账号=$FY_USER 密码长度=${#FY_PASS} 前缀=[$FY_PREFIX]"
    if [ -n "$FY_PREFIX" ]; then
        log "实际提交的 UserName = $_fulluser"
    fi

    fetch_params || die "无法从 $PORTAL/index 抓到 userip/publicIP/wlanAcIp"
    log "参数 userip=$USERIP publicIP=$PUBLICIP wlanAcIp=$WLANACIP deviceType=$DEVICE_TYPE"

    _body="username=`urlenc "$_fulluser"`&password=`urlenc "$FY_PASS"`&userip=`urlenc "$USERIP"`&publicIP=`urlenc "$PUBLICIP"`&wlanAcIp=`urlenc "$WLANACIP"`&deviceType=$DEVICE_TYPE"

    log "提交登录..."
    _resp=`curl -s -m $TMO -A "$UA" -X POST "$PORTAL/login" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -H "X-Requested-With: XMLHttpRequest" \
        --data "$_body"`

    _islogin=`json_str "$_resp" isLogin`
    _msg=`json_str "$_resp" message`

    if [ "$_islogin" = "true" ]; then
        log ">>> 登录成功 <<<"
        return 0
    fi

    if [ "$_msg" = "sms" ]; then
        _ln=`json_str "$_resp" loginName`
        _phone=`json_str "$_resp" phone`
        log "!! 该账号被要求短信验证 (验证码已发到 $phone)"
        log "!! 需要人工做一次验证, 60 秒内执行:"
        log "!!   curl -s \"$PORTAL/sms/get?ln=$_ln\""
        log "!!   curl -s -X POST \"$PORTAL/sms/verify\" -H 'Content-Type: application/x-www-form-urlencoded' \\"
        log "!!        --data 'loginNameParam=$_ln&smsCodeParam=<收到的6位码>&deviceType=$DEVICE_TYPE'"
        log "!! 最好在浏览器里开着 $PORTAL/index 手动登录一次, 完成短信验证"
        return 3
    fi

    log "登录失败: isLogin=$_islogin message=$_msg"
    log "原始响应: $_resp"
    # 常见失败信息含义:
    #  找不到对应的BAS.        -> publicIP/wlanAcIp 取错了, 或 WAN 口不在认证网段
    #  用户名或密码错误          -> 账号密码不对
    #  该账号已在线              -> 别处已登录(手机端), 需要先下线
    #  达到最大在线数            -> 同名账号名额占满
    return 1
}

# ---------- 只看参数 ----------
do_raw() {
    detect_portal
    _rc=$?
    if [ $_rc -eq 1 ]; then log "已经在线"; return 0; fi
    if [ $_rc -ne 0 ]; then die "探测不到 Portal"; fi
    log "Portal = $PORTAL"
    log "Portal 完整重定向: $PORTAL_QUERY"
    log "登录页 URL: $PORTAL_PAGE"
    fetch_params && log "userip=$USERIP publicIP=$PUBLICIP wlanAcIp=$WLANACIP" \
                 || die "抠参数失败, 请手动 curl '$PORTAL_PAGE' 看 HTML"
}

# ---------- 完整诊断: 抓页面 + 试所有抠法 + 打印相关行 ----------
do_dump() {
    log "===== DUMP 开始 ====="
    detect_portal
    _rc=$?
    log "detect_portal 返回 = $_rc  (0=需认证 1=已在线 2=探测失败)"
    log "PORTAL       = [$PORTAL]"
    log "PORTAL_QUERY = [$PORTAL_QUERY]"
    log "PORTAL_PAGE  = [$PORTAL_PAGE]"
    [ $_rc -ne 0 ] && log "!! Portal 没探测到, 后面的抓取仅供参考"

    # 关键: 必须用带 query 的 PORTAL_PAGE, 裸 /index 会 400
    curl -s -m $TMO -A "$UA" "$PORTAL_PAGE" -o /tmp/feiyoung_index.html 2>/dev/null
    log "GET $PORTAL_PAGE"
    log "HTML 大小 = `wc -c < /tmp/feiyoung_index.html 2>/dev/null` 字节"
    log "--- 页面里含 userip/publicIP/wlanAcIp 的行 ---"
    grep -in "userip\|publicIP\|wlanAcIp" /tmp/feiyoung_index.html 2>/dev/null | head -10
    log "--- 页面头 3 行 ---"
    head -3 /tmp/feiyoung_index.html
    log "--- 双引号 sed 抠法 ---"
    for k in userip publicIP wlanAcIp; do
        _v=`sed -n "s/.*var[[:space:]]*$k[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" /tmp/feiyoung_index.html | head -1`
        log "  var $k = [$_v]"
    done
    log "--- 单引号 sed 抠法 ---"
    for k in userip publicIP wlanAcIp; do
        _v=`sed -n "s/.*var[[:space:]]*$k[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" /tmp/feiyoung_index.html | head -1`
        log "  var $k = [$_v]"
    done
    log "--- 从重定向 URL 抠 ---"
    _uip=`printf '%s' "$PORTAL_QUERY" | sed -n 's/.*wlanuserip=\([^&]*\).*/\1/p'`
    _aip=`printf '%s' "$PORTAL_QUERY" | sed -n 's/.*wlanacip=\([^&]*\).*/\1/p'`
    log "  wlanuserip -> [$_uip]"
    log "  wlanacip   -> [$_aip]"
    log "===== DUMP 结束, HTML 留在 /tmp/feiyoung_index.html ====="
}

# ---------- 把当前凭据(环境变量)写进 UCI 配置 ----------
# 用法: FEIYOUNG_USER='x' FEIYOUNG_PASS='y' ./feiyoung.sh save
do_save() {
    if [ -z "$FEIYOUNG_USER" ] || [ -z "$FEIYOUNG_PASS" ]; then
        die "用法: FEIYOUNG_USER='账号' FEIYOUNG_PASS='密码' $0 save"
    fi
    command -v uci >/dev/null 2>&1 || die "没有 uci 命令"
    uci set feiyoung.main.username="$FEIYOUNG_USER" || die "uci set username 失败"
    uci set feiyoung.main.password="$FEIYOUNG_PASS" || die "uci set password 失败"
    uci set feiyoung.main.enabled='1'
    uci commit feiyoung || die "uci commit 失败"
    chmod 600 /etc/config/feiyoung 2>/dev/null
    log "已保存到 /etc/config/feiyoung:"
    log "  账号 = $FEIYOUNG_USER"
    log "  密码长度 = ${#FEIYOUNG_PASS}"
    log "  enabled = `uci -q get feiyoung.main.enabled`"
    log "下一步: /etc/init.d/feiyoung enable && /etc/init.d/feiyoung start"
    log "正在重启服务..."
    /etc/init.d/feiyoung restart 2>/dev/null || true
}

# ---------- 入口 ----------
case "$1" in
    login|"")  do_login ;;
    offline)   do_offline ;;
    status)
        detect_portal
        _rc=$?
        if [ $_rc -eq 1 ]; then echo "status: ONLINE"; else echo "status: OFFLINE (portal=${PORTAL:-unknown})"; fi
        ;;
    raw)       do_raw ;;
    dump)      do_dump ;;
    save)      do_save ;;
    *)  echo "用法: $0 {login|offline|status|raw|dump|save}"; exit 1 ;;
esac
exit $?
