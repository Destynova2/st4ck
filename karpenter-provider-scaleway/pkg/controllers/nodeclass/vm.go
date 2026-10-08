package nodeclass

import (
	"context"
	"time"

	"github.com/st4ck/karpenter-provider-scaleway/pkg/apis/v1alpha1"
	provider "github.com/st4ck/karpenter-provider-scaleway/pkg/cloudprovider"
	"k8s.io/apimachinery/pkg/api/equality"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
	karpv1 "sigs.k8s.io/karpenter/pkg/apis/v1"
)

type VMController struct {
	Client   client.Client
	Provider *provider.VM
}

func (c *VMController) Name() string { return "vmnodeclass.status" }
func (c *VMController) Register(_ context.Context, m manager.Manager) error {
	return ctrl.NewControllerManagedBy(m).Named(c.Name()).For(&v1alpha1.ScalewayVMNodeClass{}).Complete(reconcile.AsReconciler(m.GetClient(), c))
}
func (c *VMController) Reconcile(ctx context.Context, nc *v1alpha1.ScalewayVMNodeClass) (reconcile.Result, error) {
	before := nc.DeepCopy()
	np := &karpv1.NodePool{}
	np.Spec.Template.Spec.NodeClassRef = &karpv1.NodeClassReference{Group: v1alpha1.Group, Kind: "ScalewayVMNodeClass", Name: nc.Name}
	types, err := c.Provider.GetInstanceTypes(ctx, np)
	if err != nil {
		nc.StatusConditions().SetFalse("ConfigurationReady", "ConfigurationError", err.Error())
	} else if len(types) == 0 {
		nc.StatusConditions().SetFalse("ConfigurationReady", "NoAllowedType", "No allowed instance type matches the image architecture")
	} else {
		nc.StatusConditions().SetTrue("ConfigurationReady")
	}
	if !equality.Semantic.DeepEqual(before, nc) {
		if e := c.Client.Status().Patch(ctx, nc, client.MergeFromWithOptions(before, client.MergeFromWithOptimisticLock{})); e != nil {
			return reconcile.Result{}, client.IgnoreNotFound(e)
		}
	}
	return reconcile.Result{RequeueAfter: time.Minute}, nil
}
