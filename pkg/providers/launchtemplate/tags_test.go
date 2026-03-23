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

	"github.com/samber/lo"
	. "github.com/onsi/gomega"

	"github.com/Azure/karpenter-provider-azure/pkg/apis/v1beta1"
	"github.com/Azure/karpenter-provider-azure/pkg/operator/options"
	karpv1 "sigs.k8s.io/karpenter/pkg/apis/v1"
)

func TestTags(t *testing.T) {
	t.Run("adds skip gpu driver install tag when disabled", func(t *testing.T) {
		g := NewWithT(t)
		tags := Tags(
			&options.Options{ClusterName: "test-cluster"},
			&v1beta1.AKSNodeClass{Spec: v1beta1.AKSNodeClassSpec{InstallGPUDrivers: lo.ToPtr(false)}},
			&karpv1.NodeClaim{},
		)

		g.Expect(tags).To(HaveKeyWithValue(SkipGPUDriverInstallTagKey, lo.ToPtr("true")))
	})

	t.Run("does not add skip gpu driver install tag by default", func(t *testing.T) {
		g := NewWithT(t)
		tags := Tags(
			&options.Options{ClusterName: "test-cluster"},
			&v1beta1.AKSNodeClass{},
			&karpv1.NodeClaim{},
		)

		g.Expect(tags).ToNot(HaveKey(SkipGPUDriverInstallTagKey))
	})
}
