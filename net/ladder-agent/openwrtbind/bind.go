// Package openwrtbind maps OpenWrt logical networks onto the L3 device
// sing-box can bind. Panel and LuCI both store a name; on OpenWrt that name
// is often the UCI interface (wan) or the lower device (eth0.2, a DSA port),
// while the address and default route live on l3_device (pppoe-wan, br-lan).
package openwrtbind

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os/exec"
	"sort"
	"strings"
	"time"
)

// Logical is one netifd interface from `ubus call network.interface dump`.
type Logical struct {
	Name     string
	Device   string
	L3Device string
	Up       bool
	Addrs    []string
}

// Kernel is a subset of net.Interface used by List.
type Kernel struct {
	Name         string
	Up           bool
	Loopback     bool
	MTU          int
	HardwareAddr string
	Addresses    []string
}

// Listed is one row for the egress dropdown. Name is what the Panel stores.
type Listed struct {
	Name         string
	Addresses    []string
	Up           bool
	Loopback     bool
	MTU          int32
	HardwareAddr string
}

// noBindType are sing-box outbound types that reject bind_interface.
var noBindType = map[string]bool{
	"block":    true,
	"dns":      true,
	"selector": true,
	"urltest":  true,
}

// ParseDump parses `ubus call network.interface dump`.
func ParseDump(data []byte) ([]Logical, error) {
	var dump struct {
		Interface []struct {
			Interface string `json:"interface"`
			Up        bool   `json:"up"`
			Device    string `json:"device"`
			L3Device  string `json:"l3_device"`
			IPv4      []struct {
				Address string `json:"address"`
				Mask    int    `json:"mask"`
			} `json:"ipv4-address"`
			IPv6 []struct {
				Address string `json:"address"`
				Mask    int    `json:"mask"`
			} `json:"ipv6-address"`
		} `json:"interface"`
	}
	if err := json.Unmarshal(data, &dump); err != nil {
		return nil, fmt.Errorf("解析 network.interface dump：%w", err)
	}
	out := make([]Logical, 0, len(dump.Interface))
	for _, item := range dump.Interface {
		name := strings.TrimSpace(item.Interface)
		if name == "" || name == "loopback" {
			continue
		}
		l3 := strings.TrimSpace(item.L3Device)
		dev := strings.TrimSpace(item.Device)
		if l3 == "" {
			l3 = dev
		}
		var addrs []string
		for _, a := range item.IPv4 {
			if cidr := formatAddr(a.Address, a.Mask); cidr != "" {
				addrs = append(addrs, cidr)
			}
		}
		for _, a := range item.IPv6 {
			if cidr := formatAddr(a.Address, a.Mask); cidr != "" {
				addrs = append(addrs, cidr)
			}
		}
		out = append(out, Logical{
			Name:     name,
			Device:   dev,
			L3Device: l3,
			Up:       item.Up,
			Addrs:    addrs,
		})
	}
	return out, nil
}

func formatAddr(address string, mask int) string {
	address = strings.TrimSpace(address)
	if address == "" || mask <= 0 {
		return ""
	}
	return fmt.Sprintf("%s/%d", address, mask)
}

// Resolve returns the device sing-box should bind for a stored name.
// A UCI name (wan) and the lower device (eth0.2, DSA wan) follow the live
// l3_device. A name that is already the L3 device is unchanged.
func Resolve(name string, logical []Logical) string {
	name = strings.TrimSpace(name)
	if name == "" {
		return ""
	}
	for _, ifc := range logical {
		if ifc.Name == name && ifc.L3Device != "" {
			return ifc.L3Device
		}
	}
	for _, ifc := range logical {
		if ifc.L3Device == name {
			return name
		}
	}
	candidate := ""
	ambiguous := false
	for _, ifc := range logical {
		if !ifc.Up || ifc.Device != name || ifc.L3Device == "" || ifc.L3Device == name {
			continue
		}
		if candidate == "" {
			candidate = ifc.L3Device
			continue
		}
		if candidate != ifc.L3Device {
			ambiguous = true
			break
		}
	}
	if candidate != "" && !ambiguous {
		return candidate
	}
	return name
}

// List builds the dropdown. Logical networks that are up and have a usable
// address are listed under the UCI name, with that address even when it lives
// on another device. Lower devices that are not the L3 device are omitted so
// a DSA port named wan is not offered next to pppoe-wan.
func List(logical []Logical, kernel []Kernel) []Listed {
	byName := make(map[string]Kernel, len(kernel))
	for _, iface := range kernel {
		byName[iface.Name] = iface
	}
	var out []Listed
	shown := map[string]bool{}
	hiddenLower := map[string]bool{}
	for _, ifc := range logical {
		addrs := usableAddrs(ifc.Addrs)
		if len(addrs) == 0 && ifc.L3Device != "" {
			if k, ok := byName[ifc.L3Device]; ok {
				addrs = usableAddrs(k.Addresses)
			}
		}
		if !ifc.Up || ifc.L3Device == "" || len(addrs) == 0 {
			continue
		}
		if ifc.L3Device == "lo" {
			continue
		}
		item := Listed{
			Name:      ifc.Name,
			Addresses: addrs,
			Up:        true,
		}
		if k, ok := byName[ifc.L3Device]; ok {
			item.MTU = int32(k.MTU)
			item.HardwareAddr = k.HardwareAddr
			item.Loopback = k.Loopback
		}
		out = append(out, item)
		shown[ifc.Name] = true
		// Hide the lower netdev when it is not the L3 device (DSA wan,
		// eth0.2 under pppoe-wan). A lower device that shares the UCI name
		// is already suppressed by shown[name].
		if ifc.Device != "" && ifc.Device != ifc.L3Device && ifc.Device != ifc.Name {
			hiddenLower[ifc.Device] = true
		}
	}
	var extras []Listed
	for _, iface := range kernel {
		if iface.Loopback || !iface.Up {
			continue
		}
		if shown[iface.Name] || hiddenLower[iface.Name] {
			continue
		}
		addrs := usableAddrs(iface.Addresses)
		if len(addrs) == 0 {
			continue
		}
		extras = append(extras, Listed{
			Name:         iface.Name,
			Addresses:    addrs,
			Up:           true,
			Loopback:     false,
			MTU:          int32(iface.MTU),
			HardwareAddr: iface.HardwareAddr,
		})
	}
	sort.Slice(extras, func(i, j int) bool { return extras[i].Name < extras[j].Name })
	return append(out, extras...)
}

// RewriteConfig rewrites sing-box bind_interface / route.default_interface.
// override, when set, is the LuCI UCI value and replaces every dial outbound.
// An empty override only renames names the Panel already stored.
// The input string is returned unchanged when nothing was rewritten.
func RewriteConfig(configJSON string, logical []Logical, override string) (string, string, error) {
	override = strings.TrimSpace(override)
	if len(logical) == 0 && override == "" {
		return configJSON, "", nil
	}
	var doc map[string]any
	if err := json.Unmarshal([]byte(configJSON), &doc); err != nil {
		return "", "", fmt.Errorf("解析节点配置失败：%w", err)
	}
	target := ""
	if override != "" {
		target = Resolve(override, logical)
		if target == "" {
			target = override
		}
	}
	var notes []string
	if route, ok := doc["route"].(map[string]any); ok {
		if target != "" {
			if setString(route, "default_interface", target) {
				notes = append(notes, "route.default_interface="+target)
			}
		} else if cur, ok := route["default_interface"].(string); ok && strings.TrimSpace(cur) != "" {
			next := Resolve(cur, logical)
			if next != "" && next != cur {
				route["default_interface"] = next
				notes = append(notes, fmt.Sprintf("route.default_interface %s -> %s", cur, next))
			}
		}
	} else if target != "" {
		doc["route"] = map[string]any{"default_interface": target}
		notes = append(notes, "route.default_interface="+target)
	}
	if outs, ok := doc["outbounds"].([]any); ok {
		for _, item := range outs {
			ob, ok := item.(map[string]any)
			if !ok {
				continue
			}
			tag, _ := ob["tag"].(string)
			typ, _ := ob["type"].(string)
			if target != "" {
				if noBindType[typ] {
					continue
				}
				if setString(ob, "bind_interface", target) {
					notes = append(notes, fmt.Sprintf("outbound %s bind_interface=%s", tag, target))
				}
				continue
			}
			cur, ok := ob["bind_interface"].(string)
			if !ok || strings.TrimSpace(cur) == "" {
				continue
			}
			next := Resolve(cur, logical)
			if next != "" && next != cur {
				ob["bind_interface"] = next
				notes = append(notes, fmt.Sprintf("outbound %s bind_interface %s -> %s", tag, cur, next))
			}
		}
	}
	if len(notes) == 0 {
		return configJSON, "", nil
	}
	encoded, err := marshal(doc)
	if err != nil {
		return "", "", err
	}
	return encoded, "openwrt egress: " + strings.Join(notes, "; "), nil
}

func setString(obj map[string]any, key, value string) bool {
	cur, _ := obj[key].(string)
	if cur == value {
		return false
	}
	obj[key] = value
	return true
}

func marshal(v any) (string, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return "", err
	}
	return strings.TrimRight(buf.String(), "\n"), nil
}

func usableAddrs(addrs []string) []string {
	var out []string
	seen := map[string]bool{}
	for _, addr := range addrs {
		if !usableAddr(addr) || seen[addr] {
			continue
		}
		seen[addr] = true
		out = append(out, addr)
	}
	return out
}

func usableAddr(cidr string) bool {
	host := cidr
	if i := strings.IndexByte(cidr, '/'); i >= 0 {
		host = cidr[:i]
	}
	ip := net.ParseIP(strings.TrimSpace(host))
	if ip == nil || ip.IsLoopback() || ip.IsUnspecified() || ip.IsMulticast() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() {
		return false
	}
	if v4 := ip.To4(); v4 != nil && v4[0] == 169 && v4[1] == 254 {
		return false
	}
	return true
}

// LoadLogical reads the live netifd dump. ok is false when ubus is missing
// or the dump cannot be parsed, so callers keep ordinary Linux behavior.
func LoadLogical() ([]Logical, bool) {
	path, err := exec.LookPath("ubus")
	if err != nil {
		return nil, false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, path, "call", "network.interface", "dump")
	out, err := cmd.Output()
	if err != nil || len(bytes.TrimSpace(out)) == 0 {
		return nil, false
	}
	logical, err := ParseDump(out)
	if err != nil {
		return nil, false
	}
	return logical, true
}

// LoadOverride reads the LuCI/UCI egress selection. Empty means follow Panel.
func LoadOverride() string {
	path, err := exec.LookPath("uci")
	if err != nil {
		return ""
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, path, "-q", "get", "ladder-agent.main.egress_interface")
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// ReadKernel snapshots host netdevs. A failure yields a nil slice; logical
// entries can still be listed without MTU or hardware address.
func ReadKernel() []Kernel {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	out := make([]Kernel, 0, len(ifaces))
	for _, iface := range ifaces {
		item := Kernel{
			Name:         iface.Name,
			Up:           iface.Flags&net.FlagUp != 0,
			Loopback:     iface.Flags&net.FlagLoopback != 0,
			MTU:          iface.MTU,
			HardwareAddr: iface.HardwareAddr.String(),
		}
		addrs, err := iface.Addrs()
		if err == nil {
			for _, addr := range addrs {
				if addr == nil {
					continue
				}
				if s := addr.String(); s != "" {
					item.Addresses = append(item.Addresses, s)
				}
			}
		}
		out = append(out, item)
	}
	return out
}

// ListRuntime is the OpenWrt dropdown. ok is false when this host is not
// running netifd, so the caller falls back to net.Interfaces.
func ListRuntime() ([]Listed, bool) {
	logical, ok := LoadLogical()
	if !ok || len(logical) == 0 {
		return nil, false
	}
	return List(logical, ReadKernel()), true
}

// RewriteRuntime applies LoadLogical and LoadOverride to a sing-box document.
func RewriteRuntime(configJSON string) (string, string, error) {
	logical, _ := LoadLogical()
	return RewriteConfig(configJSON, logical, LoadOverride())
}
