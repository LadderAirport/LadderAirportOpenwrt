package openwrtversion

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLuciControlPath(t *testing.T) {
	const want = "/usr/lib/opkg/info/luci-app-ladder-agent.control"
	if LuciControlPath != want {
		t.Fatalf("LuciControlPath = %q, want %q", LuciControlPath, want)
	}
}

func TestReadControlVersion(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "luci-app-ladder-agent.control")
	body := "Package: luci-app-ladder-agent\n" +
		"Version: 26.288.0734~760600c-1\n" +
		"Depends: libc, luci-base, ladder-agent\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := ReadControlVersion(path); got != "26.288.0734~760600c-1" {
		t.Fatalf("got %q", got)
	}
}

func TestReadControlVersionAbsentOrBlank(t *testing.T) {
	if got := ReadControlVersion(filepath.Join(t.TempDir(), "missing.control")); got != "" {
		t.Fatalf("missing file = %q", got)
	}

	dir := t.TempDir()
	blank := filepath.Join(dir, "blank.control")
	if err := os.WriteFile(blank, []byte("Package: luci-app-ladder-agent\nVersion:\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := ReadControlVersion(blank); got != "" {
		t.Fatalf("blank Version = %q", got)
	}

	noField := filepath.Join(dir, "nofield.control")
	if err := os.WriteFile(noField, []byte("Package: luci-app-ladder-agent\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := ReadControlVersion(noField); got != "" {
		t.Fatalf("no Version field = %q", got)
	}
}

func TestReadControlVersionIgnoresDescription(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "luci-app-ladder-agent.control")
	body := "Package: luci-app-ladder-agent\r\n" +
		"Description: Version: not-this\r\n" +
		"Version: 0.15.12-r2\r\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := ReadControlVersion(path); got != "0.15.12-r2" {
		t.Fatalf("got %q", got)
	}
}
