# luci-app-feiyoung

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](#license)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-21.02%2B-00b5e2.svg)](https://openwrt.org/)

> 河北电信飞Young（hbfeiyoung）校园网 Web Portal 自动认证插件，适用于 OpenWrt / FanchmWrt / ImmortalWrt。
> 纯 Shell 实现，不依赖 Python / Go，BusyBox ash + curl 即可运行。

## 特性

- **自动发现 Portal**：从公网请求被劫持后的 `302` 重定向里抠出认证入口，换学校通常无需改代码
- **守护进程常驻**：开机自动登录、定时保活、掉线自动重登（procd 拉起，被杀自动重启）
- **WAN 自愈**：检测到「网关都 ping 不通 / ARP 是 INCOMPLETE」时自动 `ifdown`/`ifup` 换租约
- **防风控**：断网时**不会**盲目反复 POST `/login`，而是先判断认证网段可达性再退避（60s → 120s → 240s → 上限 600s）
- **定时下线/恢复**：可设定每天某个时段自动下线（释放在线名额给手机）、到点自动恢复
- **完整 LuCI 界面**：状态与操作 / 配置 / 定时任务 / 日志 四个页面

## 目录结构

```
luci-app-feiyoung/
├── root/                                    # 部署到路由器 / 下的文件树
│   ├── etc/
│   │   ├── config/feiyoung                  # UCI 配置（账号密码在此）
│   │   └── init.d/feiyoung                  # procd 服务定义
│   ├── usr/
│   │   ├── bin/
│   │   │   ├── feiyoung.sh                  # 主脚本：portal 发现 + 登录/下线/状态
│   │   │   └── feiyoung-schedule.sh         # 定时任务执行器
│   │   ├── lib/feiyoung/
│   │   │   └── daemon.sh                    # 守护进程：保活 + 退避 + WAN 自愈
│   │   ├── libexec/rpcd/luci.feiyoung       # rpcd 后端（LuCI 调用的 ubus 接口）
│   │   └── share/
│   │       ├── rpcd/acl.d/luci-app-feiyoung.json   # 权限声明
│   │       └── luci/menu.d/luci-app-feiyoung.json  # 菜单注册
│   └── www/luci-static/resources/view/feiyoung/
│       ├── overview.js                      # 状态与操作（登录/下线/重启/自启开关）
│       ├── config.js                        # 账号密码等配置
│       ├── schedule.js                      # 定时下线/恢复
│       └── log.js                           # 日志查看
├── packaging/                               # 可选：打包为 ipk/apk
└── README.md
```

## 工作原理

### 认证流程（`feiyoung.sh`）

```
1. 探测公网  ── curl -I http://captive.apple.com
                 ↓ 被校园网关劫持，返回 302
2. 提取入口  ── 从 Location 头抠 portal 地址
                 ↓ 没拿到 302 就报错（说明 WAN 不在认证网段）
3. 拉会话参数 ── GET <portal>/index
                 ↓ 从 HTML 里抠 userip / publicIP / wlanAcIp
                   （这三个值每次会话都不同，必须动态取，不能写死）
4. 提交登录  ── POST <portal>/login
                 参数：username / password / userip / publicIP / wlanAcIp / deviceType
5. 判定结果  ── 解析返回 JSON 的 isLogin 字段
```

### 守护进程逻辑（`daemon.sh`）

```
每 keepalive_interval（默认 120s）循环一次：
  ├─ 网关可达？ ── 否 ─→ 只退避等待 + 尝试 WAN 自愈（不提交登录）
  └─ 是 ─→ 调用 feiyoung.sh status 探测在线状态
              ├─ 在线 ─→ 跳过，继续下一轮
              └─ 离线 ─→ 调用 feiyoung.sh login
                           ├─ 成功 ─→ 重置退避计数
                           └─ 失败 ─→ 退避 60s→120s→240s→…→600s
```

**为什么断网时不重试登录**：运营商 Portal 对频繁登录有风控，盲目重试可能导致账号被临时拉黑。所以先判断链路是否真的通，不通就只等待。

## 安装

### 方式一：直接拷贝（推荐，适用于已 root 的 OpenWrt）

```sh
# 在电脑上，把 root/ 下的内容推到路由器
scp -r root/* root@192.168.1.1:/

# SSH 进路由器
ssh root@192.168.1.1

# 赋可执行权限
chmod +x /usr/bin/feiyoung.sh /usr/bin/feiyoung-schedule.sh
chmod +x /usr/lib/feiyoung/daemon.sh /usr/libexec/rpcd/luci.feiyoung
chmod +x /etc/init.d/feiyoung

# 注册服务并启动
/etc/init.d/feiyoung enable
/etc/init.d/feiyoung start

# 刷新 LuCI 菜单缓存
rm -f /tmp/luci-indexcache*
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

### 方式二：打包成 ipk

见 [`packaging/`](packaging/) 目录，`make` 后得到 `luci-app-feiyoung_*.ipk`。

## 配置

### LuCI 界面

安装后进入 **服务 → 飞Young 校园网 → 配置**，填写：

| 选项 | UCI 键 | 说明 |
|---|---|---|
| 启用 | `feiyoung.main.enabled` | 总开关 |
| 校园网账号 | `feiyoung.main.username` | 手机号，或 `ip` 开头（如 `ip1234567890123`）|
| 密码 | `feiyoung.main.password` | 学校分配的密码，手机号登录通常是后六位 |
| 模拟设备类型 | `feiyoung.main.device_type` | `mobile` / `pc`，共享热点建议 `mobile` |
| 重试间隔 | `feiyoung.main.retry_interval` | 秒，默认 66 |
| 保活间隔 | `feiyoung.main.keepalive_interval` | 秒，默认 120 |
| WAN 接口 | `feiyoung.main.wan_if` | 默认 `wan` |
| Portal 地址 | `feiyoung.main.portal_url` | **留空自动发现**；自动发现失败时手工填写 |
| 探测地址 | `feiyoung.main.portal_probe` | 触发 302 用的 URL，留空用内置的 |
| 账号前缀 | `feiyoung.main.username_prefix` | 少数学校要求，如 `!^Adcm0` |

### 命令行

```sh
/usr/bin/feiyoung.sh login       # 登录
/usr/bin/feiyoung.sh status      # 查看状态（会真发一次请求探测）
/usr/bin/feiyoung.sh offline     # 下线（释放在线名额）
/usr/bin/feiyoung.sh raw         # 只打印抓到的参数，不登录（排错用）

/etc/init.d/feiyoung start|stop|restart|enable|disable
```

## 排错

### 症状：日志反复报「没有抓到 302 重定向」

**这不是插件的问题**，说明 WAN 根本没通到认证网关。依次检查：

```sh
# 1. WAN 有没有拿到 IP
ip -4 a show wan        # 注意：本固件的 WAN 口可能叫 lan1

# 2. 网关能不能通（关键！）
ip neigh show dev wan | grep -i incomplete   # 有 INCOMPLETE 说明二层不通
ping -c2 $(ip route | awk '/default/{print $3}')

# 3. HTTP 到底返回什么
curl -s -m 10 -o /dev/null -w '%{http_code}\n' http://www.baidu.com
#   000 = 连不通（链路问题）
#   302 = 正常被劫持（插件能工作）
#   200 = 已经认证在线
```

**最常见的根因**：DHCP 租约失效，网关 ARP 解析不了。执行 `ifup wan` 重新获取即可。

### 症状：`running=0`，守护进程不工作

```sh
# 检查 daemon.sh 是否存在（升级固件后最容易丢这个文件）
ls -l /usr/lib/feiyoung/daemon.sh

# 不存在就从包里补回来，然后
chmod +x /usr/lib/feiyoung/daemon.sh
/etc/init.d/feiyoung restart
```

### 症状：登录成功但很快掉线

多为运营商单账号在线名额限制（手机和路由器抢名额）。可以：
- 用定时任务在手机使用时段自动下线：**服务 → 飞Young 校园网 → 定时任务**
- 调小 `keepalive_interval` 提高检测频率（但别太小，避免风控）

## 适配其他学校

本插件的 portal 发现是**通用**的，理论上换学校无需改代码。如果自动发现失败：

1. 用 `feiyoung.sh raw` 看抓到了什么
2. 浏览器手动打开认证页，F12 看 `POST` 的 URL 和参数
3. 在 LuCI 配置里填 `portal_url`
4. 如果参数名不同（不是 `userip`/`publicIP`/`wlanAcIp`），需要改 `feiyoung.sh` 里的 `do_login()`

## 开发

### 修改后快速生效

```sh
# 改完脚本，直接重启服务
/etc/init.d/feiyoung restart
tail -f /var/log/feiyoung.log

# 改了 LuCI 前端 js，需要清缓存
rm -f /tmp/luci-indexcache*
```

### 前台调试守护进程

```sh
/etc/init.d/feiyoung stop
sh -x /usr/lib/feiyoung/daemon.sh    # -x 打印每条命令
```

## 贡献

欢迎 PR。提交前请：

1. **不要提交真实账号密码**（`/etc/config/feiyoung` 保持空值）
2. Shell 脚本过一遍 `shellcheck`
3. 在至少一台真机上验证过登录/掉线重登/定时任务

## 兼容性

| 项目 | 说明 |
|---|---|
| OpenWrt | 21.02+（含 23.05 / 24.10 / 25.12）|
| 固件 | FanchmWrt、ImmortalWrt、官方 OpenWrt |
| Shell | BusyBox ash（**不需要 bash**）|
| 依赖 | `curl`、`ubus`、`procd`（OpenWrt 标配）|

> **注意**：部分固件（如 FanchmWrt 1.0.5）升级时不会保留 `/usr/lib/feiyoung/daemon.sh`，升级后请检查该文件是否存在。

## License

MIT

---

## 致谢

本插件的 portal 探测思路参考了社区公开的飞Young 认证脚本，重写为适配 OpenWrt procd + LuCI 的完整方案。