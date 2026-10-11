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

package azclient

import (
	"context"
	"fmt"
	"regexp"
	"strings"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/arm"
	"github.com/Azure/azure-sdk-for-go/sdk/resourcemanager/compute/armcompute/v7"
	imagefamilytypes "github.com/Azure/karpenter-provider-azure/pkg/providers/imagefamily/types"
)

var galleryImageVersionPattern = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`)

type computeGalleryImagesClient struct {
	credential azcore.TokenCredential
	options    *arm.ClientOptions
}

var _ imagefamilytypes.ComputeGalleryImagesAPI = (*computeGalleryImagesClient)(nil)

func (client *computeGalleryImagesClient) Get(ctx context.Context, imageVersionID string) (*armcompute.GalleryImage, *armcompute.GalleryImageVersion, error) {
	resourceID, err := arm.ParseResourceID(imageVersionID)
	if err != nil {
		return nil, nil, fmt.Errorf("parsing Compute Gallery image version ID: %w", err)
	}
	if !strings.EqualFold(resourceID.ResourceType.String(), "Microsoft.Compute/galleries/images/versions") || !galleryImageVersionPattern.MatchString(resourceID.Name) {
		return nil, nil, fmt.Errorf("imageID must identify a fixed Compute Gallery image version, not an image definition or latest")
	}
	versionsClient, err := armcompute.NewGalleryImageVersionsClient(resourceID.SubscriptionID, client.credential, client.options)
	if err != nil {
		return nil, nil, fmt.Errorf("creating Compute Gallery image versions client: %w", err)
	}
	version, err := versionsClient.Get(ctx, resourceID.ResourceGroupName, resourceID.Parent.Parent.Name, resourceID.Parent.Name, resourceID.Name, nil)
	if err != nil {
		return nil, nil, fmt.Errorf("getting Compute Gallery image version %q: %w", imageVersionID, err)
	}
	imagesClient, err := armcompute.NewGalleryImagesClient(resourceID.SubscriptionID, client.credential, client.options)
	if err != nil {
		return nil, nil, fmt.Errorf("creating Compute Gallery images client: %w", err)
	}
	image, err := imagesClient.Get(ctx, resourceID.ResourceGroupName, resourceID.Parent.Parent.Name, resourceID.Parent.Name, nil)
	if err != nil {
		return nil, nil, fmt.Errorf("getting Compute Gallery image definition %q: %w", resourceID.Parent.String(), err)
	}
	return &image.GalleryImage, &version.GalleryImageVersion, nil
}
