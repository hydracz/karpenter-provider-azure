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

package fake

import (
	"context"

	"github.com/Azure/azure-sdk-for-go/sdk/resourcemanager/compute/armcompute/v7"
	"github.com/Azure/karpenter-provider-azure/pkg/providers/imagefamily/types"
	"github.com/samber/lo"
)

type ComputeGalleryImagesAPI struct {
	Image   *armcompute.GalleryImage
	Version *armcompute.GalleryImageVersion
	Error   error
	Calls   AtomicPtrSlice[string]
}

var _ types.ComputeGalleryImagesAPI = (*ComputeGalleryImagesAPI)(nil)

func NewComputeGalleryImagesAPI() *ComputeGalleryImagesAPI {
	return &ComputeGalleryImagesAPI{
		Image: &armcompute.GalleryImage{Properties: &armcompute.GalleryImageProperties{
			OSState:          lo.ToPtr(armcompute.OperatingSystemStateTypesGeneralized),
			OSType:           lo.ToPtr(armcompute.OperatingSystemTypesLinux),
			Architecture:     lo.ToPtr(armcompute.ArchitectureX64),
			HyperVGeneration: lo.ToPtr(armcompute.HyperVGenerationV2),
		}},
		Version: &armcompute.GalleryImageVersion{
			Location: lo.ToPtr(Region),
			Properties: &armcompute.GalleryImageVersionProperties{
				ProvisioningState: lo.ToPtr(armcompute.GalleryProvisioningStateSucceeded),
			},
		},
	}
}

func (api *ComputeGalleryImagesAPI) Get(_ context.Context, imageVersionID string) (*armcompute.GalleryImage, *armcompute.GalleryImageVersion, error) {
	api.Calls.Append(&imageVersionID)
	return api.Image, api.Version, api.Error
}

func (api *ComputeGalleryImagesAPI) Reset() {
	defaults := NewComputeGalleryImagesAPI()
	api.Image = defaults.Image
	api.Version = defaults.Version
	api.Error = nil
	api.Calls.Reset()
}
