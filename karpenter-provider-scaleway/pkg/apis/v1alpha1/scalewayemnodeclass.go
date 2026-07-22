package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// ScalewayEMNodeClassSpec describes a static pool of pre-imaged Scaleway
// Elastic Metal servers that Karpenter powers on (provision) and off
// (deprovision). Servers are never created or destroyed by the provider.
type ScalewayEMNodeClassSpec struct {
	// Zone is the Scaleway zone hosting the pool servers (e.g. fr-par-2).
	// +kubebuilder:validation:MinLength=1
	Zone string `json:"zone"`

	// PoolTag is the exact server tag selecting pool members, e.g.
	// "st4ck.io/karpenter-pool=metal". Membership is resolved with
	// ListServers filtered by this tag.
	// +kubebuilder:validation:MinLength=1
	PoolTag string `json:"poolTag"`

	// OfferName is the Elastic Metal commercial offer of the pool servers
	// (e.g. EM-A116X-SSD). It names the single instance type exposed to the
	// scheduler; the CPU/memory shape is resolved from the offer.
	// +kubebuilder:validation:MinLength=1
	OfferName string `json:"offerName"`
}

// ScalewayEMNodeClass is the Schema for the ScalewayEMNodeClass API.
// +kubebuilder:object:root=true
// +kubebuilder:resource:path=scalewayemnodeclasses,scope=Cluster,categories=karpenter,shortName={scwemnc,scwemncs}
// +kubebuilder:subresource:status
type ScalewayEMNodeClass struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   ScalewayEMNodeClassSpec   `json:"spec,omitempty"`
	Status ScalewayEMNodeClassStatus `json:"status,omitempty"`
}

// ScalewayEMNodeClassList contains a list of ScalewayEMNodeClass.
// +kubebuilder:object:root=true
type ScalewayEMNodeClassList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []ScalewayEMNodeClass `json:"items"`
}
