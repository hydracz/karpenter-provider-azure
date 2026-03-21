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

package instance

import (
	"testing"

	"github.com/Azure/azure-sdk-for-go/sdk/resourcemanager/compute/armcompute/v7"
	. "github.com/onsi/gomega"
	"github.com/samber/lo"

	"github.com/Azure/karpenter-provider-azure/pkg/apis/v1beta1"
	"github.com/Azure/karpenter-provider-azure/pkg/auth"
	"github.com/Azure/karpenter-provider-azure/pkg/consts"
)

func TestGetManagedExtensionNames(t *testing.T) {
	publicCloudEnv := lo.Must(auth.EnvironmentFromName("AzurePublicCloud"))
	chinaCloudEnv := lo.Must(auth.EnvironmentFromName("AzureChinaCloud"))
	usGovCloudEnv := lo.Must(auth.EnvironmentFromName("AzureUSGovernmentCloud"))
	baseEnv := lo.Must(auth.EnvironmentFromName("AzurePublicCloud"))
	copiedInnerEnv := *baseEnv.Environment
	copiedInnerEnv.Name = "AzureStackCloud"
	noBillingExtensionEnv := &auth.Environment{
		Environment: &copiedInnerEnv,
		Cloud:       baseEnv.Cloud,
	}

	tests := []struct {
		name          string
		provisionMode string
		env           *auth.Environment
		expected      []string
	}{
		{
			name:          "PublicCloud with BootstrappingClient mode returns billing extension and CSE",
			provisionMode: consts.ProvisionModeBootstrappingClient,
			env:           publicCloudEnv,
			expected:      []string{"computeAksLinuxBilling", "cse-agent-karpenter"},
		},
		{
			name:          "PublicCloud with AKSScriptless mode returns only billing extension",
			provisionMode: consts.ProvisionModeAKSScriptless,
			env:           publicCloudEnv,
			expected:      []string{"computeAksLinuxBilling"},
		},
		{
			name:          "ChinaCloud with BootstrappingClient mode returns billing extension and CSE",
			provisionMode: consts.ProvisionModeBootstrappingClient,
			env:           chinaCloudEnv,
			expected:      []string{"computeAksLinuxBilling", "cse-agent-karpenter"},
		},
		{
			name:          "ChinaCloud with AKSScriptless mode returns only billing extension",
			provisionMode: consts.ProvisionModeAKSScriptless,
			env:           chinaCloudEnv,
			expected:      []string{"computeAksLinuxBilling"},
		},
		{
			name:          "USGovernmentCloud with BootstrappingClient mode returns billing extension and CSE",
			provisionMode: consts.ProvisionModeBootstrappingClient,
			env:           usGovCloudEnv,
			expected:      []string{"computeAksLinuxBilling", "cse-agent-karpenter"},
		},
		{
			name:          "USGovernmentCloud with AKSScriptless mode returns only billing extension",
			provisionMode: consts.ProvisionModeAKSScriptless,
			env:           usGovCloudEnv,
			expected:      []string{"computeAksLinuxBilling"},
		},
		{
			name:          "Nonstandard cloud with BootstrappingClient mode returns only CSE",
			provisionMode: consts.ProvisionModeBootstrappingClient,
			env:           noBillingExtensionEnv,
			expected:      []string{"cse-agent-karpenter"},
		},
		{
			name:          "Nonstandard cloud with AKSScriptless mode returns empty",
			provisionMode: consts.ProvisionModeAKSScriptless,
			env:           noBillingExtensionEnv,
			expected:      nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			g := NewWithT(t)

			result := GetManagedExtensionNames(tt.provisionMode, tt.env)

			g.Expect(result).To(Equal(tt.expected))
		})
	}
}

func TestParseSpotMaxPriceAnnotation(t *testing.T) {
	tests := []struct {
		name        string
		annotations map[string]string
		expected    *float64
		err         bool
	}{
		{
			name:        "missing annotation",
			annotations: map[string]string{},
			expected:    nil,
			err:         false,
		},
		{
			name: "valid default -1",
			annotations: map[string]string{
				v1beta1.AnnotationSpotMaxPrice: "-1",
			},
			expected: lo.ToPtr(float64(-1)),
			err:      false,
		},
		{
			name: "valid custom",
			annotations: map[string]string{
				v1beta1.AnnotationSpotMaxPrice: "0.0321",
			},
			expected: lo.ToPtr(float64(0.0321)),
			err:      false,
		},
		{
			name: "empty value",
			annotations: map[string]string{
				v1beta1.AnnotationSpotMaxPrice: "   ",
			},
			err: true,
		},
		{
			name: "invalid negative value",
			annotations: map[string]string{
				v1beta1.AnnotationSpotMaxPrice: "-0.1",
			},
			err: true,
		},
		{
			name: "invalid non float",
			annotations: map[string]string{
				v1beta1.AnnotationSpotMaxPrice: "abc",
			},
			err: true,
		},
		{
			name: "invalid NaN",
			annotations: map[string]string{
				v1beta1.AnnotationSpotMaxPrice: "NaN",
			},
			err: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			g := NewWithT(t)
			value, err := parseSpotMaxPriceAnnotation(tt.annotations)
			if tt.err {
				g.Expect(err).To(HaveOccurred())
				return
			}
			g.Expect(err).ToNot(HaveOccurred())
			g.Expect(value).To(Equal(tt.expected))
		})
	}
}

func TestSetVMPropertiesBillingProfile(t *testing.T) {
	t.Run("spot defaults to -1", func(t *testing.T) {
		g := NewWithT(t)
		props := &armcompute.VirtualMachineProperties{}

		setVMPropertiesBillingProfile(props, "spot", nil)

		g.Expect(props.EvictionPolicy).ToNot(BeNil())
		g.Expect(*props.EvictionPolicy).To(Equal(armcompute.VirtualMachineEvictionPolicyTypesDelete))
		g.Expect(props.BillingProfile).ToNot(BeNil())
		g.Expect(props.BillingProfile.MaxPrice).ToNot(BeNil())
		g.Expect(*props.BillingProfile.MaxPrice).To(Equal(float64(-1)))
	})

	t.Run("spot uses annotation value", func(t *testing.T) {
		g := NewWithT(t)
		props := &armcompute.VirtualMachineProperties{}
		maxPrice := 0.015

		setVMPropertiesBillingProfile(props, "spot", &maxPrice)

		g.Expect(props.BillingProfile).ToNot(BeNil())
		g.Expect(props.BillingProfile.MaxPrice).ToNot(BeNil())
		g.Expect(*props.BillingProfile.MaxPrice).To(Equal(maxPrice))
	})

	t.Run("on-demand keeps billing profile unset", func(t *testing.T) {
		g := NewWithT(t)
		props := &armcompute.VirtualMachineProperties{}
		maxPrice := 0.1

		setVMPropertiesBillingProfile(props, "on-demand", &maxPrice)

		g.Expect(props.BillingProfile).To(BeNil())
		g.Expect(props.EvictionPolicy).To(BeNil())
	})
}
