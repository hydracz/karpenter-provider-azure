/*
Portions Copyright (c) Microsoft Corporation.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package launchtemplate

import (
	"testing"

	. "github.com/onsi/gomega"
	"github.com/samber/lo"
	karpv1 "sigs.k8s.io/karpenter/pkg/apis/v1"

	"github.com/Azure/karpenter-provider-azure/pkg/apis/v1beta1"
	"github.com/Azure/karpenter-provider-azure/pkg/consts"
	"github.com/Azure/karpenter-provider-azure/pkg/operator/options"
)

func TestTagsGPUDriverInstallation(test *testing.T) {
	test.Parallel()

	for _, provisionMode := range []string{
		consts.ProvisionModeAKSScriptless,
		consts.ProvisionModeBootstrappingClient,
		consts.ProvisionModeAKSMachineAPI,
		consts.ProvisionModeAKSMachineAPIHeaderBatch,
	} {
		for _, testCase := range []struct {
			name string
			gpu  *v1beta1.GPU
			skip bool
		}{
			{name: "default"},
			{name: "empty GPU profile", gpu: &v1beta1.GPU{}},
			{name: "driver mode", gpu: &v1beta1.GPU{Mode: lo.ToPtr(v1beta1.GPUModeDriver)}},
			{name: "none mode", gpu: &v1beta1.GPU{Mode: lo.ToPtr(v1beta1.GPUModeNone)}, skip: true},
		} {
			test.Run(provisionMode+"/"+testCase.name, func(test *testing.T) {
				test.Parallel()
				expect := NewWithT(test)
				settings := &options.Options{ClusterName: "test-cluster", ProvisionMode: provisionMode}
				nodeClass := &v1beta1.AKSNodeClass{Spec: v1beta1.AKSNodeClassSpec{GPU: testCase.gpu}}
				shouldSkip := provisionMode == consts.ProvisionModeAKSScriptless && testCase.skip
				if shouldSkip {
					settings.AdditionalTags = map[string]string{SkipGPUDriverInstallTagKey: "false"}
					nodeClass.Spec.Tags = map[string]string{SkipGPUDriverInstallTagKey: "false"}
				}
				tags := Tags(settings, nodeClass, &karpv1.NodeClaim{})
				if shouldSkip {
					expect.Expect(tags).To(HaveKeyWithValue(SkipGPUDriverInstallTagKey, lo.ToPtr("true")))
				} else {
					expect.Expect(tags).NotTo(HaveKey(SkipGPUDriverInstallTagKey))
				}
				expect.Expect(tags).To(HaveKeyWithValue(KarpenterManagedTagKey, lo.ToPtr("test-cluster")))
				expect.Expect(tags).To(HaveKeyWithValue(BillingTagKey, lo.ToPtr(BillingTagValueLinux)))
			})
		}
	}
}
