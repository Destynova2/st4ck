package cloudprovider

import (
	"context"
	"testing"

	"github.com/st4ck/karpenter-provider-scaleway/pkg/reservation"
	"k8s.io/apimachinery/pkg/types"
)

func TestVMDeleteRejectsMismatchedReservationOwnerBeforeCloudAction(t *testing.T) {
	for _, providerIDWritten := range []bool{false, true} {
		t.Run(map[bool]string{false: "partial-launch", true: "launched"}[providerIDWritten], func(t *testing.T) {
			c, backend, claim := vmFixture(t)
			ctx := context.Background()
			created, err := c.Create(ctx, claim)
			if err != nil {
				t.Fatal(err)
			}
			if providerIDWritten {
				claim.Status = created.Status
			}
			lease, err := c.Store.Get(ctx, vmKey(claim.UID))
			if err != nil {
				t.Fatal(err)
			}
			// A mismatched restored/edited record is not authority for the old
			// caller to delete hardware now tagged for a different NodeClaim.
			owner := "another-claim"
			lease.Spec.HolderIdentity = &owner
			if err := c.Client.Update(ctx, lease); err != nil {
				t.Fatal(err)
			}
			backend.servers[0].Tags = []string{c.clusterTag(), claimTag(types.UID(owner))}
			phase := lease.Annotations[reservation.Prefix+"phase"]
			if err := c.Delete(ctx, claim); err == nil || backend.deletes != 0 {
				t.Fatalf("old caller reached cloud delete: calls=%d, error=%v", backend.deletes, err)
			}
			current, err := c.Store.Get(ctx, vmKey(claim.UID))
			if err != nil || current.Annotations[reservation.Prefix+"phase"] != phase {
				t.Fatal("foreign reservation modified", err)
			}
		})
	}
}
