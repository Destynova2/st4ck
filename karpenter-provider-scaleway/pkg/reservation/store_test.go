package reservation

import (
	"context"
	"testing"

	coordinationv1 "k8s.io/api/coordination/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"
)

func TestReservationCannotBeAcquiredOrReleasedByAnotherUID(t *testing.T) {
	ctx := context.Background()
	s := Store{Client: fake.NewClientBuilder().WithScheme(scheme.Scheme).Build(), Namespace: "autoscaling"}
	l, owned, err := s.Acquire(ctx, "scaleway-em://zone/server", "first", nil)
	if err != nil || !owned {
		t.Fatal("initial acquire", owned, err)
	}
	if len(l.OwnerReferences) != 0 || l.Spec.LeaseDurationSeconds != nil {
		t.Fatal("hardware reservation must not expire or be garbage collected")
	}
	foreign, owned, err := s.Acquire(ctx, "scaleway-em://zone/server", "second", nil)
	if err != nil || owned || Owner(foreign) != "first" {
		t.Fatal("reservation stolen", owned, err)
	}
	if err := s.Release(ctx, foreign, "second"); err == nil {
		t.Fatal("foreign UID released reservation")
	}
	if _, err := s.Get(ctx, "scaleway-em://zone/server"); err != nil {
		t.Fatal("reservation lost", err)
	}
}

func TestReleaseUsesUIDAndResourceVersionPreconditions(t *testing.T) {
	ctx := context.Background()
	kube := fake.NewClientBuilder().WithScheme(scheme.Scheme).Build()
	s := Store{Client: kube, Namespace: "autoscaling"}
	l, _, err := s.Acquire(ctx, "vm-claim/first", "first", nil)
	if err != nil {
		t.Fatal(err)
	}
	// Model an API conflict after another controller updated the reservation.
	s.Client = interceptor.NewClient(kube, interceptor.Funcs{
		Delete: func(_ context.Context, _ client.WithWatch, obj client.Object, opts ...client.DeleteOption) error {
			options := &client.DeleteOptions{}
			for _, opt := range opts {
				opt.ApplyToDelete(options)
			}
			p := options.Preconditions
			if p == nil || p.UID == nil || p.ResourceVersion == nil || *p.UID != obj.GetUID() || *p.ResourceVersion != obj.GetResourceVersion() {
				t.Fatal("release can delete a newer reservation")
			}
			return apierrors.NewConflict(schema.GroupResource{Group: coordinationv1.GroupName, Resource: "leases"}, obj.GetName(), nil)
		},
	})
	if err := s.Release(ctx, l, "first"); !apierrors.IsConflict(err) {
		t.Fatalf("release hid conflict: %v", err)
	}
	if _, err := s.Get(ctx, "vm-claim/first"); err != nil {
		t.Fatal("conflicted reservation lost", err)
	}
}
