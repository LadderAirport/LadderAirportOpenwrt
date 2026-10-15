include $(TOPDIR)/rules.mk

PKG_NAME:=ladder-agent
PKG_RELEASE:=2

# Main monorepo is a git submodule at <feed>/LadderAirport (see .gitmodules).
LADDER_SRC ?= $(shell \
	if [ -f "$(CURDIR)/../../LadderAirport/agent/go.mod" ]; then echo "$(CURDIR)/../../LadderAirport"; \
	elif [ -f "$(TOPDIR)/LadderAirport/agent/go.mod" ]; then echo "$(TOPDIR)/LadderAirport"; \
	else echo ""; fi)

ifeq ($(origin PKG_VERSION),undefined)
  PKG_VERSION:=$(shell \
	if [ -n "$(LADDER_SRC)" ] && command -v git >/dev/null; then \
		git -C "$(LADDER_SRC)" describe --tags --always 2>/dev/null | sed 's/^v//' | tr '_' '-'; \
	else echo 0.0.0; fi)
endif

PKG_LICENSE:=MIT
PKG_MAINTAINER:=LadderAirport <https://github.com/LadderAirport/LadderAirportOpenwrt>

PKG_BUILD_PARALLEL:=1
PKG_BUILD_DEPENDS:=golang/host
PKG_USE_MIPS16:=0

GO_PKG:=github.com/ladderairport/agent
GO_PKG_BUILD_PKG:=github.com/ladderairport/agent/cmd/ladder-agent

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

define Package/ladder-agent
  SECTION:=net
  CATEGORY:=Network
  TITLE:=LadderAirport node agent (sing-box + FRPS)
  URL:=https://github.com/LadderAirport/LadderAirport
  DEPENDS:=$(GO_ARCH_DEPENDS) +ca-bundle +curl +jsonfilter
endef

define Package/ladder-agent/description
  LadderAirport node agent for OpenWrt: in-process sing-box and optional FRPS,
  managed by Panel over uplink (HTTP/WebSocket) by default.
  Egress names from the Panel or LuCI are resolved to the live L3 device
  (UCI wan to pppoe-wan) before sing-box starts.
endef

define Package/ladder-agent/conffiles
/etc/config/ladder-agent
endef

AGENT_TAGS:=with_quic,with_utls

define Build/Prepare
	@if [ -z "$(LADDER_SRC)" ] || [ ! -f "$(LADDER_SRC)/agent/go.mod" ]; then \
		echo "ERROR: LADDER_SRC must point at LadderAirport submodule (got '$(LADDER_SRC)')"; \
		echo "Run: git submodule update --init LadderAirport && git -C LadderAirport submodule update --init agent/frp agent/sing-box"; \
		exit 1; \
	fi
	rm -rf $(PKG_BUILD_DIR)
	mkdir -p $(PKG_BUILD_DIR)
	# Keep monorepo layout so agent/go.mod replace paths stay valid.
	$(CP) $(LADDER_SRC)/agent $(PKG_BUILD_DIR)/
	$(CP) $(LADDER_SRC)/pkg $(PKG_BUILD_DIR)/
	$(CP) $(LADDER_SRC)/proto $(PKG_BUILD_DIR)/
	# OpenWrt logical interface -> live L3 device. Kept outside the submodule
	# so an upstream bump does not drop it. The patch fails the build if the
	# two call sites in the agent sources have moved.
	mkdir -p $(PKG_BUILD_DIR)/agent/internal/openwrtbind
	$(CP) ./openwrtbind/bind.go $(PKG_BUILD_DIR)/agent/internal/openwrtbind/bind.go
	$(CP) ./files/control/openwrt_bind.go $(PKG_BUILD_DIR)/agent/internal/control/openwrt_bind.go
	patch -N --batch -d $(PKG_BUILD_DIR)/agent -p1 -i $(CURDIR)/patches/openwrt-bind.patch
endef

define Build/Compile
	# GO_PKG_VARS (OpenWrt golang-package.mk) sets GOTOOLCHAIN=local and
	# CGO_ENABLED=1. Same-command assignments are last-wins, so the package
	# overrides must follow GO_PKG_VARS. auto lets the SDK Go 1.23 fetch the
	# toolchain required by agent/go.mod (go 1.26.4).
	#
	# Four dollar signs. This define is expanded once while the stamp
	# recipe is generated, then again when Make runs the recipe. Two
	# signs leave a single dollar, which CI's V=s (OpenWrt verbosity)
	# reads as variable V, so VERSION_LDFLAGS becomes sERSION_LDFLAGS
	# and the git command substitution is dropped.
	( \
		SINGBOX_VER=$$$$(git -C "$(PKG_BUILD_DIR)/agent/sing-box" describe --tags 2>/dev/null | sed 's/^v//' || echo unknown); \
		VERSION_LDFLAGS="-X 'github.com/ladderairport/agent/internal/version.Version=$(PKG_VERSION)'"; \
		VERSION_LDFLAGS="$$$$VERSION_LDFLAGS -X 'github.com/sagernet/sing-box/constant.Version=$$$$SINGBOX_VER'"; \
		cd $(PKG_BUILD_DIR)/agent && \
		$(GO_PKG_VARS) \
		CGO_ENABLED=0 GOTOOLCHAIN=auto \
		go build -trimpath \
			-tags "$(AGENT_TAGS)" \
			-ldflags "-s -w $$$$VERSION_LDFLAGS" \
			-o $(PKG_BUILD_DIR)/ladder-agent \
			./cmd/ladder-agent \
	)
endef

define Package/ladder-agent/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/ladder-agent $(1)/usr/bin/ladder-agent

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/ladder-agent.init $(1)/etc/init.d/ladder-agent

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/ladder-agent.config $(1)/etc/config/ladder-agent

	$(INSTALL_DIR) $(1)/usr/libexec/ladder-agent
	$(INSTALL_BIN) ./files/enroll.sh $(1)/usr/libexec/ladder-agent/enroll.sh

	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/ladder-agent.keep $(1)/lib/upgrade/keep.d/ladder-agent

	$(INSTALL_DIR) $(1)/etc/ladder-agent
	$(INSTALL_DIR) $(1)/var/lib/ladder-agent
endef

$(eval $(call BuildPackage,ladder-agent))
