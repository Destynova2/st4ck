// Package v1alpha1 contains the ScalewayEMNodeClass API types for the
// karpenter.scaleway.st4ck.io group.
//
// +k8s:deepcopy-gen=package,register
// +groupName=karpenter.scaleway.st4ck.io
package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/kubernetes/scheme"
)

const Group = "karpenter.scaleway.st4ck.io"

var SchemeGroupVersion = schema.GroupVersion{Group: Group, Version: "v1alpha1"}

func init() {
	metav1.AddToGroupVersion(scheme.Scheme, SchemeGroupVersion)
	scheme.Scheme.AddKnownTypes(SchemeGroupVersion,
		&ScalewayEMNodeClass{},
		&ScalewayEMNodeClassList{},
	)
}
