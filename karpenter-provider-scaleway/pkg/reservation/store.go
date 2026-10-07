// Package reservation persists provider ownership independently of controller restarts.
package reservation

import (
	"context"
	"crypto/sha256"
	"fmt"

	coordinationv1 "k8s.io/api/coordination/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const Prefix = "karpenter.scaleway.st4ck.io/"
const Finalizer = Prefix + "termination"

// Store must use an uncached client. Reservations never expire and have no
// ownerReferences: garbage collection must not free hardware that is still on.
type Store struct {
	Client    client.Client
	Namespace string
}

func Name(key string) string { return fmt.Sprintf("scw-%x", sha256.Sum256([]byte(key)))[:60] }

func (s Store) Get(ctx context.Context, key string) (*coordinationv1.Lease, error) {
	l := &coordinationv1.Lease{}
	err := s.Client.Get(ctx, types.NamespacedName{Namespace: s.Namespace, Name: Name(key)}, l)
	return l, err
}

func Owner(l *coordinationv1.Lease) string {
	if l.Spec.HolderIdentity == nil {
		return ""
	}
	return *l.Spec.HolderIdentity
}

// Acquire returns false when another UID owns the resource. An API failure is
// never translated into free capacity. The name includes the provider and zone.
func (s Store) Acquire(ctx context.Context, key string, uid types.UID, metadata map[string]string) (*coordinationv1.Lease, bool, error) {
	if uid == "" {
		return nil, false, fmt.Errorf("reservation requires a NodeClaim UID")
	}
	owner := string(uid)
	a := map[string]string{Prefix + "resource": key}
	for k, v := range metadata {
		a[Prefix+k] = v
	}
	l := &coordinationv1.Lease{ObjectMeta: metav1.ObjectMeta{
		Name: Name(key), Namespace: s.Namespace, Labels: map[string]string{Prefix + "reservation": "true"}, Annotations: a,
	}, Spec: coordinationv1.LeaseSpec{HolderIdentity: &owner}}
	err := s.Client.Create(ctx, l)
	if err == nil {
		return l, true, nil
	}
	if !apierrors.IsAlreadyExists(err) {
		return nil, false, err
	}
	l, err = s.Get(ctx, key)
	if err != nil {
		return nil, false, err
	}
	if l.Annotations[Prefix+"resource"] != key {
		return nil, false, fmt.Errorf("reservation key mismatch")
	}
	return l, Owner(l) == owner, nil
}

func (s Store) Set(ctx context.Context, l *coordinationv1.Lease, key, value string) error {
	l.Annotations[Prefix+key] = value
	return s.Client.Update(ctx, l)
}

func (s Store) Release(ctx context.Context, l *coordinationv1.Lease, uid types.UID) error {
	if Owner(l) != string(uid) {
		return fmt.Errorf("refusing to release another NodeClaim's reservation")
	}
	err := s.Client.Delete(ctx, l, client.Preconditions{UID: &l.UID, ResourceVersion: &l.ResourceVersion})
	if apierrors.IsNotFound(err) {
		return nil
	}
	return err
}

func (s Store) All(ctx context.Context) ([]coordinationv1.Lease, error) {
	var list coordinationv1.LeaseList
	if err := s.Client.List(ctx, &list, client.InNamespace(s.Namespace), client.MatchingLabels{Prefix + "reservation": "true"}); err != nil {
		return nil, err
	}
	return list.Items, nil
}
