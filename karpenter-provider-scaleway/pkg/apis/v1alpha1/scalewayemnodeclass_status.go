package v1alpha1

import (
	"github.com/awslabs/operatorpkg/status"
)

const (
	// ConditionTypePoolReady reports whether the Scaleway API is reachable
	// with the configured credentials, the pool has at least one member and
	// the offer shape is resolvable. The root Ready condition is derived
	// from it by operatorpkg.
	ConditionTypePoolReady = "PoolReady"
)

// ScalewayEMNodeClassStatus contains the observed pool inventory.
type ScalewayEMNodeClassStatus struct {
	// Conditions contains signals for health and readiness.
	Conditions []status.Condition `json:"conditions,omitempty"`
	// PoolSize is the number of servers carrying the pool tag.
	PoolSize int32 `json:"poolSize,omitempty"`
	// Available is the number of stopped servers, i.e. capacity that a
	// Create() call can immediately power on.
	Available int32 `json:"available,omitempty"`
}

func (in *ScalewayEMNodeClass) StatusConditions(opts ...status.ForOption) status.ConditionSet {
	return status.NewReadyConditions(ConditionTypePoolReady).For(in, opts...)
}

func (in *ScalewayEMNodeClass) GetConditions() []status.Condition {
	return in.Status.Conditions
}

func (in *ScalewayEMNodeClass) SetConditions(conditions []status.Condition) {
	in.Status.Conditions = conditions
}
