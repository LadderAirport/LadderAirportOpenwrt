package control

import (
	"log"

	"github.com/ladderairport/agent/internal/openwrtbind"
	agentv1 "github.com/ladderairport/proto/gen/go/agent/v1"
)

// listOpenWrtInterfaces returns logical OpenWrt networks when netifd is
// available. ok is false on ordinary Linux so listHostInterfaces is unchanged.
func listOpenWrtInterfaces() ([]*agentv1.NetworkInterface, bool) {
	listed, ok := openwrtbind.ListRuntime()
	if !ok {
		return nil, false
	}
	out := make([]*agentv1.NetworkInterface, 0, len(listed))
	for _, item := range listed {
		out = append(out, &agentv1.NetworkInterface{
			Name:         item.Name,
			Addresses:    item.Addresses,
			Up:           item.Up,
			Loopback:     item.Loopback,
			Mtu:          item.MTU,
			HardwareAddr: item.HardwareAddr,
		})
	}
	return out, true
}

// rewriteOpenWrtBindInterfaces maps stored interface names onto the live L3
// device before sing-box starts. A non-empty UCI egress_interface wins over
// the name the Panel stored.
func rewriteOpenWrtBindInterfaces(configJSON string) (string, error) {
	updated, note, err := openwrtbind.RewriteRuntime(configJSON)
	if note != "" {
		log.Printf("%s", note)
	}
	return updated, err
}
