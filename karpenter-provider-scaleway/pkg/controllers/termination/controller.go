// Package termination reconciles launches that core cannot terminate without a providerID.
package termination

import (
	"context"
	"time"

	"github.com/st4ck/karpenter-provider-scaleway/pkg/reservation"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
	karpv1 "sigs.k8s.io/karpenter/pkg/apis/v1"
	core "sigs.k8s.io/karpenter/pkg/cloudprovider"
)

type Controller struct {
	Provider core.CloudProvider
}

func (c *Controller) Name() string { return "scaleway.partial-termination" }
func (c *Controller) Register(_ context.Context, m manager.Manager) error {
	return ctrl.NewControllerManagedBy(m).Named(c.Name()).For(&karpv1.NodeClaim{}).
		Complete(reconcile.AsReconciler(m.GetClient(), c))
}
func (c *Controller) Reconcile(ctx context.Context, claim *karpv1.NodeClaim) (reconcile.Result, error) {
	if claim.DeletionTimestamp.IsZero() || claim.Status.ProviderID != "" ||
		!controllerutil.ContainsFinalizer(claim, reservation.Finalizer) {
		return reconcile.Result{}, nil
	}
	err := c.Provider.Delete(ctx, claim)
	if core.IsNodeClaimNotFoundError(err) {
		return reconcile.Result{}, nil
	}
	if err != nil {
		return reconcile.Result{}, err
	}
	return reconcile.Result{RequeueAfter: 5 * time.Second}, nil
}
