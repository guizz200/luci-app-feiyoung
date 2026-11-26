# 打包为 OpenWrt ipk 的 Makefile
# 用法（在 OpenWrt SDK 里）：
#   cp -r luci-app-feiyoung package/
#   make package/luci-app-feiyoung/compile V=s

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-feiyoung
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=luci-app-feiyoung contributors

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=飞Young 校园网自动认证
  DEPENDS:=+curl +luci-base +luci-compat +rpcd
  PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
  河北电信飞Young 校园网 Web Portal 自动认证插件。
  自动发现 portal、开机登录、保活、掉线重登、WAN 自愈、定时下线。
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/
	$(CP) ./root/* $(1)/
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
	[ -n "$${IPKG_INSTROOT}" ] || {
		chmod +x /usr/bin/feiyoung.sh /usr/bin/feiyoung-schedule.sh 2>/dev/null
		chmod +x /usr/lib/feiyoung/daemon.sh /usr/libexec/rpcd/luci.feiyoung 2>/dev/null
		/etc/init.d/feiyoung enable
		rm -f /tmp/luci-indexcache*
	}
endef

$(eval $(call BuildPackage,$(PKG_NAME)))