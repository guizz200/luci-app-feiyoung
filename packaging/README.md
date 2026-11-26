# 打包说明

根目录的 `Makefile` 是 OpenWrt 包定义，可直接丢进 OpenWrt SDK 或固件源码树里编译。

## 用 SDK 编译 ipk

```sh
# 1. 下载对应平台的 OpenWrt SDK
#    https://downloads.openwrt.org/releases/

# 2. 解压后进入 SDK 目录
./scripts/feeds update -a
./scripts/feeds install -a

# 3. 把本仓库放进 package/
cp -r luci-app-feiyoung package/

# 4. 编译
make package/luci-app-feiyoung/compile V=s

# 5. 产物位置
find bin/ -name 'luci-app-feiyoung*.ipk'
```

## 安装 ipk

```sh
opkg install luci-app-feiyoung_*.ipk
# 如果固件用 apk（OpenWrt 24.10+）：
# apk add --allow-untrusted luci-app-feiyoung_*.ipk
```

## 注意

- `PKGARCH:=all`，因为是纯脚本插件，不涉及架构相关二进制
- 依赖 `curl`、`luci-base`、`luci-compat`（Lua 兼容层，因为本插件用的是 Lua controller + rpcd）
- 如果你的固件没有 `luci-compat`，需要把 `usr/libexec/rpcd/luci.feiyoung` 改用 ucode 重写