package cloudprovider

import (
	"context"
	"fmt"
	"strings"

	"github.com/awslabs/operatorpkg/status"
	"github.com/st4ck/karpenter-provider-scaleway/pkg/apis/v1alpha1"
	karpv1 "sigs.k8s.io/karpenter/pkg/apis/v1"
	core "sigs.k8s.io/karpenter/pkg/cloudprovider"
)

// Hybrid exposes both backends to ONE Karpenter scheduler and disruption loop.
type Hybrid struct{ Metal, VM core.CloudProvider }

func (c *Hybrid) provider(ref *karpv1.NodeClassReference) (core.CloudProvider, error) {
	if ref != nil && ref.Group == v1alpha1.Group {
		switch ref.Kind {
		case "ScalewayEMNodeClass":
			return c.Metal, nil
		case "ScalewayVMNodeClass":
			return c.VM, nil
		}
	}
	return nil, fmt.Errorf("unsupported Scaleway node class reference")
}
func (c *Hybrid) byID(id string) (core.CloudProvider, error) {
	if strings.HasPrefix(id, "scaleway-em://") {
		return c.Metal, nil
	}
	if strings.HasPrefix(id, "scaleway://") {
		return c.VM, nil
	}
	return nil, fmt.Errorf("unsupported Scaleway provider ID")
}
func (c *Hybrid) Create(ctx context.Context, n *karpv1.NodeClaim) (*karpv1.NodeClaim, error) {
	p, e := c.provider(n.Spec.NodeClassRef)
	if e != nil {
		return nil, e
	}
	return p.Create(ctx, n)
}
func (c *Hybrid) Delete(ctx context.Context, n *karpv1.NodeClaim) error {
	p, e := c.provider(n.Spec.NodeClassRef)
	if e != nil {
		return e
	}
	if n.Status.ProviderID != "" {
		other, err := c.byID(n.Status.ProviderID)
		if err != nil {
			return err
		}
		if other != p {
			return fmt.Errorf("provider ID and node class disagree")
		}
	}
	return p.Delete(ctx, n)
}
func (c *Hybrid) Get(ctx context.Context, id string) (*karpv1.NodeClaim, error) {
	p, e := c.byID(id)
	if e != nil {
		return nil, e
	}
	return p.Get(ctx, id)
}
func (c *Hybrid) List(ctx context.Context) ([]*karpv1.NodeClaim, error) {
	a, e := c.Metal.List(ctx)
	if e != nil {
		return nil, e
	}
	b, e := c.VM.List(ctx)
	if e != nil {
		return nil, e
	}
	return append(a, b...), nil
}
func (c *Hybrid) GetInstanceTypes(ctx context.Context, n *karpv1.NodePool) ([]*core.InstanceType, error) {
	p, e := c.provider(n.Spec.Template.Spec.NodeClassRef)
	if e != nil {
		return nil, e
	}
	return p.GetInstanceTypes(ctx, n)
}
func (c *Hybrid) IsDrifted(ctx context.Context, n *karpv1.NodeClaim) (core.DriftReason, error) {
	p, e := c.provider(n.Spec.NodeClassRef)
	if e != nil {
		return "", e
	}
	return p.IsDrifted(ctx, n)
}
func (c *Hybrid) Name() string                        { return "scaleway" }
func (c *Hybrid) RepairPolicies() []core.RepairPolicy { return nil }
func (c *Hybrid) GetSupportedNodeClasses() []status.Object {
	return append(c.Metal.GetSupportedNodeClasses(), c.VM.GetSupportedNodeClasses()...)
}
