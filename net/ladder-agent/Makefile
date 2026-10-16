# Directory of this Makefile, before rules.mk is appended to MAKEFILE_LIST.
LADDER_PKG_DIR:=$(patsubst %/,%,$(dir $(lastword $(MAKEFILE_LIST))))

include $(TOPDIR)/rules.mk

PKG_NAME:=ladder-agent
# Feed repack counter only. client_version is $(PKG_VERSION)-r$(PKG_RELEASE),
# for example 0.15.12-r2. It is not part of the core version.
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

# Core identity is the submodule checkout, not the feed repack.
# version.Version / agent_version / core_version: vX.Y.Z on a tag, otherwise
# vX.Y.Z-N-gSHA. Never pass --abbrev=0; that drops the commit distance.
# version.Commit is core_commit (short SHA).
# version.ClientType is the closed enum "openwrt".
# version.ClientVersion is the feed package, PKG_VERSION-rPKG_RELEASE.
# version.LuciVersion is not an ldflag; the process reads it at startup.
LADDER_CLIENT_TYPE:=openwrt
LADDER_CLIENT_VERSION:=$(PKG_VERSION)-r$(PKG_RELEASE)
LADDER_CORE_VERSION:=$(shell sh $(LADDER_PKG_DIR)/scripts/core-identity.sh version "$(LADDER_SRC)")
LADDER_CORE_COMMIT:=$(shell sh $(LADDER_PKG_DIR)/scripts/core-identity.sh commit "$(LADDER_SRC)")

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
	@if [ "$(LADDER_CORE_VERSION)" = "v0.0.0" ] || [ "$(LADDER_CORE_COMMIT)" = "unknown" ]; then \
		echo "ERROR: core identity is $(LADDER_CORE_VERSION) / $(LADDER_CORE_COMMIT)"; \
		echo "git describe --tags --always (leading v, never --abbrev=0) and rev-parse --short must succeed in $(LADDER_SRC)"; \
		exit 1; \
	fi
	# LuCI version is read at process start from the opkg control file.
	# ClientType / ClientVersion / LuciVersion are declared here only while
	# the linked version package does not declare those names yet.
	mkdir -p $(PKG_BUILD_DIR)/agent/internal/openwrtversion
	$(CP) $(LADDER_PKG_DIR)/openwrtversion/*.go $(PKG_BUILD_DIR)/agent/internal/openwrtversion/
	rm -f $(PKG_BUILD_DIR)/agent/internal/openwrtversion/*_test.go
	# zzz_ so this init runs after other files in the version package.
	$(CP) $(LADDER_PKG_DIR)/files/version/openwrt_luci.go $(PKG_BUILD_DIR)/agent/internal/version/zzz_openwrt_luci.go
	sh $(LADDER_PKG_DIR)/scripts/write-client-identity.sh $(PKG_BUILD_DIR)/agent/internal/version
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
		VERSION_LDFLAGS="-X 'github.com/ladderairport/agent/internal/version.Version=$(LADDER_CORE_VERSION)'"; \
		VERSION_LDFLAGS="$$$$VERSION_LDFLAGS -X 'github.com/ladderairport/agent/internal/version.Commit=$(LADDER_CORE_COMMIT)'"; \
		VERSION_LDFLAGS="$$$$VERSION_LDFLAGS -X 'github.com/ladderairport/agent/internal/version.ClientType=$(LADDER_CLIENT_TYPE)'"; \
		VERSION_LDFLAGS="$$$$VERSION_LDFLAGS -X 'github.com/ladderairport/agent/internal/version.ClientVersion=$(LADDER_CLIENT_VERSION)'"; \
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
