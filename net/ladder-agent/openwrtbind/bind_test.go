package openwrtbind

import (
	"encoding/json"
	"strings"
	"testing"
)

func pppoeDump() []Logical {
	logical, err := ParseDump([]byte(`{
		"interface": [
			{
				"interface": "lan",
				"up": true,
				"device": "br-lan",
				"l3_device": "br-lan",
				"ipv4-address": [{"address": "192.168.1.1", "mask": 24}]
			},
			{
				"interface": "wan",
				"up": true,
				"proto": "pppoe",
				"device": "wan",
				"l3_device": "pppoe-wan",
				"ipv4-address": [{"address": "1.2.3.4", "mask": 32}],
				"ipv6-address": [{"address": "fe80::1", "mask": 64}]
			},
			{
				"interface": "wan6",
				"up": true,
				"device": "wan",
				"l3_device": "pppoe-wan",
				"ipv6-address": [{"address": "2001:db8::1", "mask": 64}]
			},
			{"interface": "loopback", "up": true, "l3_device": "lo", "device": "lo"}
		]
	}`))
	if err != nil {
		panic(err)
	}
	return logical
}

func TestResolvePPPoEAndDHCP(t *testing.T) {
	logical := pppoeDump()
	cases := []struct{ name, want string }{
		{"wan", "pppoe-wan"},
		{"wan6", "pppoe-wan"},
		{"pppoe-wan", "pppoe-wan"},
		{"lan", "br-lan"},
		{"br-lan", "br-lan"},
		{"eth0", "eth0"},
		{"  wan  ", "pppoe-wan"},
		{"", ""},
	}
	for _, tc := range cases {
		if got := Resolve(tc.name, logical); got != tc.want {
			t.Errorf("Resolve(%q) = %q, want %q", tc.name, got, tc.want)
		}
	}

	dhcp := []Logical{{Name: "wan", Device: "wan", L3Device: "wan", Up: true, Addrs: []string{"203.0.113.5/24"}}}
	if got := Resolve("wan", dhcp); got != "wan" {
		t.Fatalf("dhcp Resolve(wan) = %q", got)
	}
	swconfig := []Logical{{Name: "wan", Device: "eth0.2", L3Device: "eth0.2", Up: true}}
	if got := Resolve("eth0.2", swconfig); got != "eth0.2" {
		t.Fatalf("swconfig Resolve = %q", got)
	}
	// Stored lower device from before the WAN proto changed to PPPoE.
	if got := Resolve("eth0.2", []Logical{{Name: "wan", Device: "eth0.2", L3Device: "pppoe-wan", Up: true}}); got != "pppoe-wan" {
		t.Fatalf("lower device Resolve = %q", got)
	}
}

func TestResolveAmbiguousLowerDevice(t *testing.T) {
	logical := []Logical{
		{Name: "a", Device: "eth0", L3Device: "pppoe-a", Up: true},
		{Name: "b", Device: "eth0", L3Device: "pppoe-b", Up: true},
	}
	if got := Resolve("eth0", logical); got != "eth0" {
		t.Fatalf("ambiguous Resolve = %q", got)
	}
}

func TestListHidesLowerDeviceAndKeepsL3(t *testing.T) {
	kernel := []Kernel{
		{Name: "lo", Up: true, Loopback: true, Addresses: []string{"127.0.0.1/8"}},
		{Name: "wan", Up: true, MTU: 1500, Addresses: []string{"fe80::2/64"}},
		{Name: "pppoe-wan", Up: true, MTU: 1492, Addresses: []string{"1.2.3.4/32"}},
		{Name: "br-lan", Up: true, MTU: 1500, HardwareAddr: "aa:bb:cc:dd:ee:ff", Addresses: []string{"192.168.1.1/24"}},
		{Name: "lan1", Up: true, Addresses: []string{"169.254.1.1/16"}},
		{Name: "wg0", Up: true, Addresses: []string{"10.8.0.1/32"}},
	}
	listed := List(pppoeDump(), kernel)
	got := map[string]Listed{}
	var names []string
	for _, item := range listed {
		got[item.Name] = item
		names = append(names, item.Name)
	}
	for _, hidden := range []string{"lo", "lan1"} {
		if _, ok := got[hidden]; ok {
			t.Fatalf("listed %s, full=%v", hidden, names)
		}
	}
	// One wan row: the UCI interface, not a second raw DSA port.
	wanCount := 0
	for _, name := range names {
		if name == "wan" {
			wanCount++
		}
	}
	if wanCount != 1 {
		t.Fatalf("wan entries = %d, names=%v", wanCount, names)
	}
	// The UCI name is what the user picks; it carries the PPP address.
	wan := got["wan"]
	if len(wan.Addresses) != 1 || wan.Addresses[0] != "1.2.3.4/32" {
		t.Fatalf("wan addrs = %v", wan.Addresses)
	}
	if wan.MTU != 1492 {
		t.Fatalf("wan mtu = %d", wan.MTU)
	}
	if _, ok := got["pppoe-wan"]; !ok {
		t.Fatalf("missing pppoe-wan, got %v", names)
	}
	if got["lan"].HardwareAddr != "aa:bb:cc:dd:ee:ff" {
		t.Fatalf("lan hw = %q", got["lan"].HardwareAddr)
	}
	if _, ok := got["br-lan"]; !ok {
		t.Fatalf("missing br-lan, got %v", names)
	}
	if _, ok := got["wg0"]; !ok {
		t.Fatalf("missing wg0, got %v", names)
	}
	if _, ok := got["wan6"]; !ok {
		t.Fatalf("missing wan6, got %v", names)
	}
}

func TestRewriteRemapIsIdempotent(t *testing.T) {
	src := `{
		"log": {"level": "info"},
		"inbounds": [{"type": "mixed", "listen": "::", "listen_port": 443}],
		"outbounds": [
			{"type": "direct", "tag": "direct", "bind_interface": "wan"},
			{"type": "vless", "tag": "hop", "bind_interface": "eth0.2"},
			{"type": "block", "tag": "block"}
		],
		"route": {"final": "direct", "default_interface": "wan"}
	}`
	logical := []Logical{
		{Name: "wan", Device: "eth0.2", L3Device: "pppoe-wan", Up: true},
	}
	out, note, err := RewriteConfig(src, logical, "")
	if err != nil {
		t.Fatal(err)
	}
	if note == "" || !strings.Contains(note, "pppoe-wan") {
		t.Fatalf("note = %q", note)
	}
	assertBind(t, out, "direct", "pppoe-wan")
	assertBind(t, out, "hop", "pppoe-wan")
	assertBind(t, out, "block", "")
	var doc map[string]any
	if err := json.Unmarshal([]byte(out), &doc); err != nil {
		t.Fatal(err)
	}
	route := doc["route"].(map[string]any)
	if route["default_interface"] != "pppoe-wan" || route["final"] != "direct" {
		t.Fatalf("route = %#v", route)
	}
	again, note2, err := RewriteConfig(out, logical, "")
	if err != nil {
		t.Fatal(err)
	}
	if again != out || note2 != "" {
		t.Fatalf("not idempotent\nnote=%q\nfirst=%s\nsecond=%s", note2, out, again)
	}
	// No OpenWrt data: leave the document bytes alone.
	same, note3, err := RewriteConfig(src, nil, "")
	if err != nil || same != src || note3 != "" {
		t.Fatalf("fallback changed config note=%q", note3)
	}
}

func TestRewriteOverrideForcesDialOutbounds(t *testing.T) {
	src := `{"outbounds":[{"type":"direct","tag":"direct","bind_interface":"eth0"},{"type":"block","tag":"block"},{"type":"vless","tag":"hop"}],"route":{"final":"direct"}}`
	logical := []Logical{{Name: "wwan", Device: "wwan0", L3Device: "wwan0", Up: true}}
	out, _, err := RewriteConfig(src, logical, "wwan")
	if err != nil {
		t.Fatal(err)
	}
	assertBind(t, out, "direct", "wwan0")
	assertBind(t, out, "hop", "wwan0")
	assertBind(t, out, "block", "")
	var doc map[string]any
	if err := json.Unmarshal([]byte(out), &doc); err != nil {
		t.Fatal(err)
	}
	if doc["route"].(map[string]any)["default_interface"] != "wwan0" {
		t.Fatalf("route = %#v", doc["route"])
	}
	again, note, err := RewriteConfig(out, logical, "wwan")
	if err != nil || again != out || note != "" {
		t.Fatalf("override not idempotent note=%q", note)
	}
}

func TestRewriteOverrideWithoutUbus(t *testing.T) {
	src := `{"outbounds":[{"type":"direct","tag":"direct"}]}`
	out, _, err := RewriteConfig(src, nil, "wan")
	if err != nil {
		t.Fatal(err)
	}
	assertBind(t, out, "direct", "wan")
}

func assertBind(t *testing.T, config, tag, want string) {
	t.Helper()
	var doc struct {
		Outbounds []map[string]any `json:"outbounds"`
	}
	if err := json.Unmarshal([]byte(config), &doc); err != nil {
		t.Fatal(err)
	}
	for _, ob := range doc.Outbounds {
		if ob["tag"] != tag {
			continue
		}
		got, _ := ob["bind_interface"].(string)
		if got != want {
			t.Fatalf("outbound %s bind_interface = %q, want %q", tag, got, want)
		}
		return
	}
	t.Fatalf("outbound %s not found", tag)
}
