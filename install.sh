#!/bin/sh
# luci-app-feiyoung 安装脚本（在路由器上执行）
# 用法: sh install.sh

set -e

SRC=$(cd "$(dirname "$0")" && pwd)/root
[ -d "$SRC" ] || { echo "找不到 root/ 目录"; exit 1; }

echo "[1/4] 复制文件..."
cp -a "$SRC"/. /

echo "[2/4] 设置权限..."
chmod +x /usr/bin/feiyoung.sh /usr/bin/feiyoung-schedule.sh 2>/dev/null || true
chmod +x /usr/lib/feiyoung/daemon.sh /usr/libexec/rpcd/luci.feiyoung 2>/dev/null || true
chmod +x /etc/init.d/feiyoung

echo "[3/4] 启用服务..."
/etc/init.d/feiyoung enable

echo "[4/4] 刷新 LuCI 缓存..."
rm -f /tmp/luci-indexcache*
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart

echo ""
echo "安装完成。"
echo "请到 LuCI「服务 → 飞Young 校园网 → 配置」填写账号密码后保存。"