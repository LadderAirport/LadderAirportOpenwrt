package version

import "github.com/ladderairport/agent/internal/openwrtversion"

// init reads the LuCI app version once, at process start.
//
// luci-app-ladder-agent is a separate PKGARCH=all package, so its version
// cannot be linked into this binary. The opkg control file is present only
// after that package is installed. An empty LuciVersion means "omit this
// field"; the main-repo report path is what drops the empty string.
//
// version.Report copies ClientType, ClientVersion, and LuciVersion into
// PingResponse and the HTTP/WebSocket report. An empty LuciVersion is omitted
// by that path.
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
