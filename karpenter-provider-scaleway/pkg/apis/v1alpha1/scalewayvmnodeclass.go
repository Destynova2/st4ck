package v1alpha1

import (
	"github.com/awslabs/operatorpkg/status"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

// ScalewayVMNodeClassSpec deliberately allows only image IDs and an explicit
// instance-type allowlist. GPUs, spot capacity and remote disks are not supported.
type ScalewayVMNodeClassSpec struct {
	Zone             string   `json:"zone"`
	ProjectID        string   `json:"projectID"`
	ImageID          string   `json:"imageID"`
	PrivateNetworkID string   `json:"privateNetworkID"`
	SecurityGroupID  string   `json:"securityGroupID"`
	BootstrapSecret  string   `json:"bootstrapSecret"`
	InstanceTypes    []string `json:"instanceTypes"`
	Architecture     string   `json:"architecture"`
	// EphemeralDiskGiB is a local SSD for Talos EPHEMERAL, separate from the image disk.
	EphemeralDiskGiB int64 `json:"ephemeralDiskGiB"`
}

type ScalewayVMNodeClass struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec              ScalewayVMNodeClassSpec   `json:"spec"`
	Status            ScalewayEMNodeClassStatus `json:"status,omitempty"`
}

type ScalewayVMNodeClassList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []ScalewayVMNodeClass `json:"items"`
}

func (in *ScalewayVMNodeClass) StatusConditions(opts ...status.ForOption) status.ConditionSet {
	return status.NewReadyConditions("ConfigurationReady").For(in, opts...)
}
func (in *ScalewayVMNodeClass) GetConditions() []status.Condition  { return in.Status.Conditions }
func (in *ScalewayVMNodeClass) SetConditions(c []status.Condition) { in.Status.Conditions = c }
func (in *ScalewayVMNodeClass) DeepCopy() *ScalewayVMNodeClass {
	if in == nil {
		return nil
	}
	out := new(ScalewayVMNodeClass)
	*out = *in
	out.ObjectMeta = *in.ObjectMeta.DeepCopy()
	out.Spec.InstanceTypes = append([]string(nil), in.Spec.InstanceTypes...)
	out.Status.Conditions = append([]status.Condition(nil), in.Status.Conditions...)
	return out
}
func (in *ScalewayVMNodeClass) DeepCopyObject() runtime.Object {
	if in == nil {
		return nil
	}
	return in.DeepCopy()
}
func (in *ScalewayVMNodeClassList) DeepCopyObject() runtime.Object {
	if in == nil {
		return nil
	}
	out := new(ScalewayVMNodeClassList)
	*out = *in
	out.ListMeta = *in.ListMeta.DeepCopy()
	out.Items = make([]ScalewayVMNodeClass, len(in.Items))
	for i := range in.Items {
		out.Items[i] = *in.Items[i].DeepCopy()
	}
	return out
}
