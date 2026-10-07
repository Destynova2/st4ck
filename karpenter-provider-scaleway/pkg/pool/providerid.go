package pool

import (
	"fmt"
	"strings"
)

// ProviderIDPrefix is the URI scheme of provider IDs handed to kubelet:
// scaleway-em://<zone>/<server-id>. The format is stable and derivable on
// both sides (provider from Create(), Talos machineconfig at pre-imaging).
const ProviderIDPrefix = "scaleway-em://"

// FormatProviderID builds the canonical provider ID for a pool server.
func FormatProviderID(zone, serverID string) string {
	return fmt.Sprintf("%s%s/%s", ProviderIDPrefix, zone, serverID)
}

// ParseProviderID splits a canonical provider ID into zone and server ID.
// Strict: exactly one separating slash — extra path segments are rejected
// instead of being folded into the server ID (Codex Minor).
func ParseProviderID(providerID string) (zone, serverID string, err error) {
	rest, ok := strings.CutPrefix(providerID, ProviderIDPrefix)
	if !ok {
		return "", "", fmt.Errorf("provider ID %q does not start with %q", providerID, ProviderIDPrefix)
	}
	zone, serverID, ok = strings.Cut(rest, "/")
	if !ok || zone == "" || serverID == "" || strings.Contains(serverID, "/") {
		return "", "", fmt.Errorf("provider ID %q is not of the form %s<zone>/<server-id>", providerID, ProviderIDPrefix)
	}
	return zone, serverID, nil
}
