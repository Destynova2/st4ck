package cloudprovider

import (
	"context"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"

	karpv1 "sigs.k8s.io/karpenter/pkg/apis/v1"
	"sigs.k8s.io/karpenter/pkg/cloudprovider"
	"sigs.k8s.io/karpenter/pkg/scheduling"

	"github.com/st4ck/karpenter-provider-scaleway/pkg/apis/v1alpha1"
	"github.com/st4ck/karpenter-provider-scaleway/pkg/pool"
)

// defaultPodsPerNode mirrors the kubelet default maxPods; the pre-imaged
// Talos machineconfig does not override it in M0.
const defaultPodsPerNode = 110

// buildInstanceType derives the single static instance type of a pool from
// its offer. When servers is nil the offering availability is not computed
// from the pool state and defaults to available (Create() path, where the
// stopped-server pick happens right after against fresh data).
func (c *CloudProvider) buildInstanceType(ctx context.Context, nodeClass *v1alpha1.ScalewayEMNodeClass, servers []pool.Server) (*cloudprovider.InstanceType, error) {
	offer, err := c.backend.GetOfferByName(ctx, nodeClass.Spec.Zone, nodeClass.Spec.OfferName)
	if err != nil {
		return nil, fmt.Errorf("resolving offer %q in %s, %w", nodeClass.Spec.OfferName, nodeClass.Spec.Zone, err)
	}
	available := true
	if servers != nil {
		available = pool.CountByStatus(servers, pool.StatusStopped) > 0
	}
	return newInstanceType(offer, nodeClass.Spec.Zone, available), nil
}

func newInstanceType(offer pool.Offer, zone string, available bool) *cloudprovider.InstanceType {
	capacity := corev1.ResourceList{
		corev1.ResourceCPU:    *resource.NewQuantity(offer.CPUThreads, resource.DecimalSI),
		corev1.ResourceMemory: *resource.NewQuantity(offer.MemoryBytes, resource.BinarySI),
		corev1.ResourcePods:   *resource.NewQuantity(defaultPodsPerNode, resource.DecimalSI),
	}
	return &cloudprovider.InstanceType{
		Name: offer.Name,
		Requirements: scheduling.NewRequirements(
			scheduling.NewRequirement(corev1.LabelInstanceTypeStable, corev1.NodeSelectorOpIn, offer.Name),
			scheduling.NewRequirement(corev1.LabelArchStable, corev1.NodeSelectorOpIn, karpv1.ArchitectureAmd64),
			scheduling.NewRequirement(corev1.LabelOSStable, corev1.NodeSelectorOpIn, string(corev1.Linux)),
			scheduling.NewRequirement(corev1.LabelTopologyZone, corev1.NodeSelectorOpIn, zone),
			scheduling.NewRequirement(karpv1.CapacityTypeLabelKey, corev1.NodeSelectorOpIn, karpv1.CapacityTypeOnDemand),
		),
		Offerings: cloudprovider.Offerings{
			&cloudprovider.Offering{
				Requirements: scheduling.NewRequirements(
					scheduling.NewRequirement(corev1.LabelTopologyZone, corev1.NodeSelectorOpIn, zone),
					scheduling.NewRequirement(karpv1.CapacityTypeLabelKey, corev1.NodeSelectorOpIn, karpv1.CapacityTypeOnDemand),
				),
				// Flat price on identical servers: consolidation-replacement
				// (strictly cheaper required) is neutralized for free.
				Price:     offer.PricePerHour,
				Available: available,
			},
		},
		Capacity: capacity,
		Overhead: &cloudprovider.InstanceTypeOverhead{},
	}
}
