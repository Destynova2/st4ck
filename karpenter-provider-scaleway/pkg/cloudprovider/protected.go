package cloudprovider

import (
	"context"
	"fmt"
	"sync"

	"github.com/st4ck/karpenter-provider-scaleway/pkg/reservation"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	karpv1 "sigs.k8s.io/karpenter/pkg/apis/v1"
	core "sigs.k8s.io/karpenter/pkg/cloudprovider"
)

// Protected retains partially launched claims even before core has a providerID.
// The client is uncached; the same wrapper serves core and partial termination.
type Protected struct {
	core.CloudProvider
	Client client.Client
	mu     sync.Mutex
}

func (c *Protected) Create(ctx context.Context, claim *karpv1.NodeClaim) (*karpv1.NodeClaim, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	live := &karpv1.NodeClaim{}
	if err := c.Client.Get(ctx, client.ObjectKeyFromObject(claim), live); err != nil {
		return nil, err
	}
	if live.UID != claim.UID || !live.DeletionTimestamp.IsZero() {
		return nil, fmt.Errorf("refusing to launch a deleted or replaced NodeClaim")
	}
	if !controllerutil.ContainsFinalizer(live, reservation.Finalizer) {
		before := live.DeepCopy()
		controllerutil.AddFinalizer(live, reservation.Finalizer)
		if err := c.Client.Patch(ctx, live, client.MergeFromWithOptions(before, client.MergeFromWithOptimisticLock{})); err != nil {
			return nil, err
		}
	}
	return c.CloudProvider.Create(ctx, claim)
}

func (c *Protected) Delete(ctx context.Context, claim *karpv1.NodeClaim) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	err := c.CloudProvider.Delete(ctx, claim)
	if !core.IsNodeClaimNotFoundError(err) {
		return err
	}
	live := &karpv1.NodeClaim{}
	if e := c.Client.Get(ctx, client.ObjectKeyFromObject(claim), live); e != nil {
		if apierrors.IsNotFound(e) {
			return err
		}
		return e
	}
	if live.UID != claim.UID {
		return fmt.Errorf("refusing to finalize a replaced NodeClaim")
	}
	if controllerutil.ContainsFinalizer(live, reservation.Finalizer) {
		before := live.DeepCopy()
		controllerutil.RemoveFinalizer(live, reservation.Finalizer)
		if e := c.Client.Patch(ctx, live, client.MergeFromWithOptions(before, client.MergeFromWithOptimisticLock{})); e != nil {
			return e
		}
	}
	return err
}
