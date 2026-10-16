// Package openwrtversion reads OpenWrt package metadata that is not known
// when ladder-agent is compiled. LuCI is a separate PKGARCH=all package, so
// its version cannot be an ldflag on the agent binary.
package openwrtversion

import (
	"bufio"
	"os"
	"strings"
)

// LuciControlPath is the opkg control file for luci-app-ladder-agent.
// OpenWrt 19.07 and 24.10 both record installed packages here. The file is
// absent when the LuCI app is not installed; callers then leave the version
// empty so it is omitted from the report.
const LuciControlPath = "/usr/lib/opkg/info/luci-app-ladder-agent.control"

// ReadControlVersion returns the Version field of an opkg control file.
// A missing file, an unreadable file, or a blank Version yields "".
func ReadControlVersion(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, val, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		if !strings.EqualFold(strings.TrimSpace(key), "Version") {
			continue
		}
		return strings.TrimSpace(val)
	}
	return ""
}
