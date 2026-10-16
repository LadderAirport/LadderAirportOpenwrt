package version

import "github.com/ladderairport/agent/internal/openwrtversion"

// init reads the LuCI app version once, at process start.
//
// luci-app-ladder-agent is a separate PKGARCH=all package, so its version
// cannot be linked into this binary. The opkg control file is present only
// after that package is installed. An empty LuciVersion means "omit this
// field"; the main-repo report path is what drops the empty string.
//
// Reporting client_type, client_version, core_commit, and luci_version
// requires the main repo to copy these version-package variables into
// PingResponse and the HTTP/WebSocket report. Until that lands, the values
// are in the binary and on -version only as far as upstream already prints
// Version and Commit.
func init() {
	// ldflags also set ClientType. Pin it after other version inits so a
	// main-repo default of "linux" does not stick on this binary.
	// ClientVersion stays the ldflags value (PKG_VERSION-rPKG_RELEASE).
	ClientType = "openwrt"
	v := openwrtversion.ReadControlVersion(openwrtversion.LuciControlPath)
	if v != "" {
		LuciVersion = v
	}
}
