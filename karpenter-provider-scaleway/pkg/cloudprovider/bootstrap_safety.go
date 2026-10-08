package cloudprovider

import (
	"fmt"
	"reflect"

	karpv1 "sigs.k8s.io/karpenter/pkg/apis/v1"
)

const evictionMemory = "100Mi"

// Disk thresholds are explicit too, but disk capacity is not advertised to
// scheduling. Memory eviction headroom is deducted from both VM and EM RAM.
func configureBootstrapSafety(extra map[string]any) error {
	hard := map[string]any{
		"memory.available": evictionMemory, "nodefs.available": "10%",
		"imagefs.available": "15%", "nodefs.inodesFree": "5%", "imagefs.inodesFree": "5%",
	}
	if configured, exists := extra["evictionHard"]; exists && !reflect.DeepEqual(configured, hard) {
		return fmt.Errorf("evictionHard must match provider bootstrap thresholds")
	}
	for _, field := range []string{"evictionSoft", "evictionSoftGracePeriod", "evictionMinimumReclaim"} {
		if configured, exists := extra[field]; exists {
			values, ok := configured.(map[string]any)
			if !ok || len(values) != 0 {
				return fmt.Errorf("%s is not modelled by provider resource accounting", field)
			}
		}
	}
	if configured, exists := extra["mergeDefaultEvictionSettings"]; exists && configured != false {
		return fmt.Errorf("mergeDefaultEvictionSettings must be false")
	}
	extra["evictionHard"] = hard
	extra["mergeDefaultEvictionSettings"] = false

	taints := []any{}
	if configured, exists := extra["registerWithTaints"]; exists {
		var ok bool
		taints, ok = configured.([]any)
		if !ok {
			return fmt.Errorf("registerWithTaints must be a list")
		}
	}
	found := false
	for _, configured := range taints {
		taint, ok := configured.(map[string]any)
		if !ok {
			return fmt.Errorf("registerWithTaints entries must be objects")
		}
		if taint["key"] == karpv1.UnregisteredNoExecuteTaint.Key {
			value, hasValue := taint["value"]
			if found || taint["effect"] != string(karpv1.UnregisteredNoExecuteTaint.Effect) || (hasValue && value != "") {
				return fmt.Errorf("conflicting initial Karpenter taint")
			}
			found = true
		}
	}
	if !found {
		taints = append(taints, map[string]any{"key": karpv1.UnregisteredNoExecuteTaint.Key, "effect": string(karpv1.UnregisteredNoExecuteTaint.Effect)})
	}
	extra["registerWithTaints"] = taints
	return nil
}
