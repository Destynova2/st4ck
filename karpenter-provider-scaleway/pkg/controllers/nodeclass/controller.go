// Package nodeclass reconciles the ScalewayEMNodeClass status: pool
// inventory (poolSize, available) and the Ready condition consumed by
// CloudProvider.Create() (LLD-002 §6).
package nodeclass

import (
	"context"
	stderrors "errors"
	"fmt"
	"time"

	"github.com/awslabs/operatorpkg/reasonable"
	"k8s.io/apimachinery/pkg/api/equality"
	"k8s.io/apimachinery/pkg/api/errors"
	controllerruntime "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	"github.com/st4ck/karpenter-provider-scaleway/pkg/apis/v1alpha1"
	"github.com/st4ck/karpenter-provider-scaleway/pkg/pool"
)

// pollInterval bounds how stale status.available may get without any watch
// event; pool state also changes out of band (console power-off).
const pollInterval = time.Minute

// Controller reconciles a ScalewayEMNodeClass object to update its status.
type Controller struct {
	kubeClient client.Client
	backend    pool.Backend
}

func NewController(kubeClient client.Client, backend pool.Backend) *Controller {
	return &Controller{kubeClient: kubeClient, backend: backend}
}

func (c *Controller) Name() string {
	return "nodeclass.status"
}

func (c *Controller) Reconcile(ctx context.Context, nodeClass *v1alpha1.ScalewayEMNodeClass) (reconcile.Result, error) {
	stored := nodeClass.DeepCopy()

	c.reconcilePool(ctx, nodeClass)

	if !equality.Semantic.DeepEqual(stored, nodeClass) {
		// MergeFromWithOptimisticLock: the status condition list is replaced
		// wholesale by a JSON merge patch, guard against racing writers.
		if err := c.kubeClient.Status().Patch(ctx, nodeClass, client.MergeFromWithOptions(stored, client.MergeFromWithOptimisticLock{})); err != nil {
			if errors.IsConflict(err) {
				// Requeue (bool) is deprecated in controller-runtime v0.23
				// (audit F3): re-reconcile shortly after the racing writer.
				return reconcile.Result{RequeueAfter: time.Second}, nil
			}
			return reconcile.Result{}, client.IgnoreNotFound(err)
		}
	}
	return reconcile.Result{RequeueAfter: pollInterval}, nil
}

// reconcilePool observes the pool and sets PoolReady (the root Ready
// condition is derived from it): auth OK + zone reachable + pool non-empty
// + offer resolvable.
func (c *Controller) reconcilePool(ctx context.Context, nodeClass *v1alpha1.ScalewayEMNodeClass) {
	servers, err := c.backend.ListServers(ctx, nodeClass.Spec.Zone, nodeClass.Spec.PoolTag)
	if err != nil {
		nodeClass.StatusConditions().SetFalse(v1alpha1.ConditionTypePoolReady, "APIError",
			fmt.Sprintf("listing pool servers: %s", err))
		return
	}
	nodeClass.Status.PoolSize = int32(len(servers))
	nodeClass.Status.Available = int32(pool.CountByStatus(servers, pool.StatusStopped))

	if len(servers) == 0 {
		nodeClass.StatusConditions().SetFalse(v1alpha1.ConditionTypePoolReady, "PoolEmpty",
			fmt.Sprintf("no server carries tag %q in zone %s", nodeClass.Spec.PoolTag, nodeClass.Spec.Zone))
		return
	}
	if _, err := c.backend.GetOfferByName(ctx, nodeClass.Spec.Zone, nodeClass.Spec.OfferName); err != nil {
		reason := "APIError"
		if stderrors.Is(err, pool.ErrOfferNotFound) {
			reason = "OfferNotFound"
		}
		nodeClass.StatusConditions().SetFalse(v1alpha1.ConditionTypePoolReady, reason,
			fmt.Sprintf("resolving offer %q: %s", nodeClass.Spec.OfferName, err))
		return
	}
	nodeClass.StatusConditions().SetTrue(v1alpha1.ConditionTypePoolReady)
}

func (c *Controller) Register(_ context.Context, m manager.Manager) error {
	return controllerruntime.NewControllerManagedBy(m).
		Named(c.Name()).
		For(&v1alpha1.ScalewayEMNodeClass{}).
		WithOptions(controller.Options{
			RateLimiter:             reasonable.RateLimiter(),
			MaxConcurrentReconciles: 1,
		}).
		Complete(reconcile.AsReconciler(m.GetClient(), c))
}
