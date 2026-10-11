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

package imagefamily

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/resourcemanager/compute/armcompute/v7"
	"github.com/Azure/karpenter-provider-azure/pkg/apis/v1beta1"
	"github.com/Azure/karpenter-provider-azure/pkg/consts"
	"github.com/Azure/karpenter-provider-azure/pkg/operator/options"
	"github.com/samber/lo"
	corev1 "k8s.io/api/core/v1"
	karpv1 "sigs.k8s.io/karpenter/pkg/apis/v1"
	"sigs.k8s.io/karpenter/pkg/scheduling"
)

func (p *provider) listCustomImage(ctx context.Context, nodeClass *v1beta1.AKSNodeClass) ([]NodeImage, error) {
	if err := validateCustomImageConfiguration(nodeClass, options.FromContext(ctx).ProvisionMode); err != nil {
		return nil, err
	}
	if p.galleryImages == nil {
		return nil, fmt.Errorf("compute gallery image client is not configured")
	}
	kubernetesVersion, err := nodeClass.GetKubernetesVersion()
	if err != nil {
		return nil, err
	}
	key := fmt.Sprintf("custom/%s/%s", nodeClass.Hash(), kubernetesVersion)
	if images, ok := p.nodeImagesCache.Get(key); ok {
		return images.([]NodeImage), nil
	}
	image, version, err := p.galleryImages.Get(ctx, *nodeClass.Spec.ImageID)
	if err != nil {
		return nil, err
	}
	if err := validateCustomImage(image, version, p.location, nodeClass.Spec.OSDiskSizeGB); err != nil {
		return nil, err
	}
	requirements, err := customImageRequirements(image)
	if err != nil {
		return nil, err
	}
	supportedImages := getSupportedImages(nodeClass.Spec.ImageFamily, nodeClass.Spec.FIPSMode, kubernetesVersion, true, false, false)
	for _, candidate := range supportedImages {
		if requirements.Compatible(candidate.Requirements, v1beta1.AllowUndefinedWellKnownAndRestrictedLabels) == nil {
			images := []NodeImage{{ID: *nodeClass.Spec.ImageID, Requirements: candidate.Requirements}}
			p.nodeImagesCache.Set(key, images, time.Hour)
			return images, nil
		}
	}
	return nil, fmt.Errorf("compute gallery image architecture or Hyper-V generation is incompatible with imageFamily %q", lo.FromPtr(nodeClass.Spec.ImageFamily))
}

func validateCustomImageConfiguration(nodeClass *v1beta1.AKSNodeClass, mode string) error {
	switch mode {
	case consts.ProvisionModeAKSScriptless, consts.ProvisionModeBootstrappingClient:
	default:
		return fmt.Errorf("imageID is not supported in provision mode %q", mode)
	}
	switch lo.FromPtr(nodeClass.Spec.ImageFamily) {
	case v1beta1.Ubuntu2204ImageFamily, v1beta1.Ubuntu2404ImageFamily, v1beta1.AzureLinuxImageFamily:
	default:
		return fmt.Errorf("imageID requires an explicit Ubuntu2204, Ubuntu2404, or AzureLinux imageFamily")
	}
	if nodeClass.Spec.Versions != nil && nodeClass.Spec.Versions.NodeImageVersion != nil {
		return fmt.Errorf("imageID cannot be combined with versions.nodeImageVersion")
	}
	if nodeClass.IsFIPSEnabled() || nodeClass.IsTrustedLaunchEnabled() || nodeClass.IsKataEnabled() {
		return fmt.Errorf("imageID does not support FIPS, Trusted Launch, or Kata images")
	}
	return nil
}

func validateCustomImageMetadata(image *armcompute.GalleryImage, version *armcompute.GalleryImageVersion) error {
	if image == nil || image.Properties == nil || version == nil || version.Properties == nil {
		return fmt.Errorf("compute gallery image metadata is incomplete")
	}
	if lo.FromPtr(image.Properties.OSState) != armcompute.OperatingSystemStateTypesGeneralized || lo.FromPtr(image.Properties.OSType) != armcompute.OperatingSystemTypesLinux {
		return fmt.Errorf("imageID must reference a generalized Linux image, never a captured cluster node")
	}
	if image.Properties.PurchasePlan != nil {
		return fmt.Errorf("imageID does not support images requiring a marketplace purchase plan")
	}
	if lo.FromPtr(version.Properties.ProvisioningState) != armcompute.GalleryProvisioningStateSucceeded {
		return fmt.Errorf("compute gallery image version is not successfully provisioned")
	}
	return nil
}

func validateCustomImage(image *armcompute.GalleryImage, version *armcompute.GalleryImageVersion, location string, osDiskSizeGB *int32) error {
	if err := validateCustomImageMetadata(image, version); err != nil {
		return err
	}
	if !customImageIsPublished(version, location) {
		return fmt.Errorf("compute gallery image version is not published in region %q", location)
	}
	if storage := version.Properties.StorageProfile; storage != nil && storage.OSDiskImage != nil && osDiskSizeGB != nil && lo.FromPtr(storage.OSDiskImage.SizeInGB) > *osDiskSizeGB {
		return fmt.Errorf("osDiskSizeGB is smaller than the Compute Gallery image OS disk")
	}
	return nil
}

func customImageIsPublished(version *armcompute.GalleryImageVersion, location string) bool {
	normalizedLocation := strings.ReplaceAll(location, " ", "")
	if version.Properties.PublishingProfile == nil {
		return strings.EqualFold(strings.ReplaceAll(lo.FromPtr(version.Location), " ", ""), normalizedLocation)
	}
	for _, region := range version.Properties.PublishingProfile.TargetRegions {
		if region != nil && strings.EqualFold(strings.ReplaceAll(lo.FromPtr(region.Name), " ", ""), normalizedLocation) {
			return true
		}
	}
	return false
}

func customImageRequirements(image *armcompute.GalleryImage) (scheduling.Requirements, error) {
	architecture := map[armcompute.Architecture]string{
		armcompute.ArchitectureX64:   karpv1.ArchitectureAmd64,
		armcompute.ArchitectureArm64: karpv1.ArchitectureArm64,
	}[lo.FromPtr(image.Properties.Architecture)]
	generation := map[armcompute.HyperVGeneration]string{
		armcompute.HyperVGenerationV1: v1beta1.HyperVGenerationV1,
		armcompute.HyperVGenerationV2: v1beta1.HyperVGenerationV2,
	}[lo.FromPtr(image.Properties.HyperVGeneration)]
	if architecture == "" || generation == "" {
		return nil, fmt.Errorf("compute gallery image has an unsupported architecture or Hyper-V generation")
	}
	return scheduling.NewRequirements(
		scheduling.NewRequirement(corev1.LabelArchStable, corev1.NodeSelectorOpIn, architecture),
		scheduling.NewRequirement(v1beta1.LabelSKUHyperVGeneration, corev1.NodeSelectorOpIn, generation),
		scheduling.NewRequirement(corev1.LabelOSStable, corev1.NodeSelectorOpIn, string(corev1.Linux)),
	), nil
}
