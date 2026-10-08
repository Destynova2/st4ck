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

// defaultPodsPerNode is pinned in VM and opt-in pre-imaged EM bootstrap.
const defaultPodsPerNode = 110

// buildInstanceType derives the single static instance type of a pool from
// its offer. computeAvailability selects whether Offering.Available is
// derived from the servers snapshot (scheduling paths) or defaults to true
// (Create() path, where the stopped-server pick happens right after against
// fresh data, and hydration paths where availability is irrelevant). An
// explicit flag rather than a nil-slice sentinel: the real backend returns
// an empty non-nil slice on an empty pool, and both cases must yield
// Available=false (audit F1).
func (c *CloudProvider) buildInstanceType(ctx context.Context, nodeClass *v1alpha1.ScalewayEMNodeClass, servers []pool.Server, computeAvailability bool) (*cloudprovider.InstanceType, error) {
	offer, err := c.backend.GetOfferByName(ctx, nodeClass.Spec.Zone, nodeClass.Spec.OfferName)
	if err != nil {
		return nil, fmt.Errorf("resolving offer %q in %s, %w", nodeClass.Spec.OfferName, nodeClass.Spec.Zone, err)
	}
	if offer.Architecture != "amd64" || offer.CPUThreads <= 0 || offer.MemoryBytes <= 0 || offer.PricePerHour <= 0 {
		return nil, fmt.Errorf("EM requires verified x86 CPUs and nonzero capacity/price")
	}
	available := true
	if computeAvailability {
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
			scheduling.NewRequirement(corev1.LabelArchStable, corev1.NodeSelectorOpIn, offer.Architecture),
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
		Overhead: &cloudprovider.InstanceTypeOverhead{
			KubeReserved: corev1.ResourceList{
				corev1.ResourceCPU: resource.MustParse("500m"), corev1.ResourceMemory: resource.MustParse("1Gi"),
			},
			EvictionThreshold: corev1.ResourceList{corev1.ResourceMemory: resource.MustParse(evictionMemory)},
		},
	}
}
