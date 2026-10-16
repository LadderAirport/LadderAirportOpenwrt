# Local helpers for the LadderAirport OpenWrt feed.
# Formal package build uses OpenWrt SDK (see .github/workflows).

.PHONY: check-src help sync-submodule

# Main monorepo is linked as a git submodule at ./LadderAirport
LADDER_SRC ?= $(CURDIR)/LadderAirport

help:
	@echo "LadderAirport OpenWrt feed"
	@echo ""
	@echo "  make check-src          Verify ./LadderAirport submodule is checked out"
	@echo "  make sync-submodule     git submodule update --init --recursive"
	@echo "  LADDER_SRC=$(LADDER_SRC)"
	@echo ""
	@echo "Clone this repo with submodules:"
	@echo "  git clone --recurse-submodules https://github.com/LadderAirport/LadderAirportOpenwrt.git"
	@echo ""
	@echo "CI builds all router architectures with openwrt/gh-action-sdk."

sync-submodule:
	git submodule update --init --recursive

check-src:
	@test -f "$(LADDER_SRC)/agent/go.mod" || { \
		echo "missing $(LADDER_SRC)/agent/go.mod — run: make sync-submodule"; \
		exit 1; \
	}
	@test -d "$(LADDER_SRC)/agent/sing-box" || { \
		echo "missing sing-box under submodule — run: make sync-submodule"; \
		exit 1; \
	}
	@test -d "$(LADDER_SRC)/pkg" -a -d "$(LADDER_SRC)/proto" || { \
		echo "missing pkg/ or proto/ under $(LADDER_SRC)"; \
		exit 1; \
	}
	@echo "OK: LADDER_SRC=$(LADDER_SRC) (git submodule)"
	@echo "core_version=$$(sh "$(CURDIR)/net/ladder-agent/scripts/core-identity.sh" version "$(LADDER_SRC)")"
	@echo "core_commit=$$(sh "$(CURDIR)/net/ladder-agent/scripts/core-identity.sh" commit "$(LADDER_SRC)")"
