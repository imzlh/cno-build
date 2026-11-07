include $(TOPDIR)/rules.mk

PKG_NAME:=cno
PKG_VERSION:=$(CNO_VERSION)
PKG_RELEASE:=$(CNO_PACKAGE_RELEASE)

PKG_SOURCE:=cno-linux-musl-$(CNO_RELEASE_TARGET).tar.gz
PKG_SOURCE_URL:=https://github.com/imzlh/cno-cli/releases/download/v$(PKG_VERSION)/
PKG_HASH:=$(CNO_SOURCE_SHA256)
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

PKG_LICENSE:=MIT
PKG_MAINTAINER:=cno maintainers <imzlh@users.noreply.github.com>

include $(INCLUDE_DIR)/package.mk

# cno release archives are intentionally flat (cno, ext/, lib/) rather than
# wrapped in a versioned directory, so bypass package.mk's usual source layout.
define Build/Prepare
	rm -rf $(PKG_BUILD_DIR)
	mkdir -p $(PKG_BUILD_DIR)
	tar -xzf $(DL_DIR)/$(PKG_SOURCE) -C $(PKG_BUILD_DIR)
endef

define Package/cno
  SECTION:=lang
  CATEGORY:=Languages
  TITLE:=Deno-compatible TypeScript and JavaScript runtime
  URL:=https://github.com/imzlh/cno-cli
  DEPENDS:=+ca-bundle
endef

define Package/cno/description
 cno is a native TypeScript and JavaScript runtime with Deno-style commands,
 Web APIs, and practical Node.js compatibility.
endef

define Build/Compile
endef

define Package/cno/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/cno $(1)/usr/bin/cno
endef

$(eval $(call BuildPackage,cno))

