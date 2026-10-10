# Custom AKS Compute Gallery Images

`AKSNodeClass.spec.imageID` selects a fixed version in an Azure Compute Gallery
you control. It is supported in `aksscriptless` and `bootstrappingclient` mode.
The two Machine API modes reject it explicitly. Without `imageID`, upstream image
selection is unchanged.

Use an AKS CIG image as the base, not a plain Canonical Marketplace image. A
general-purpose Ubuntu image does not include the same AKS bootstrap contract.
Custom image maintenance, security updates, licensing, and AKS compatibility are
the image owner's responsibility; this fork feature is not a claim of Microsoft
support for arbitrary AKS OS modifications.

## Requirements

- A generalized Linux image, never a captured node from an existing cluster.
- Explicit `imageFamily`: `Ubuntu2204`, `Ubuntu2404`, or `AzureLinux`, matching the
  source distribution. Match the source image to the node Kubernetes version.
- A fixed `/subscriptions/.../galleries/.../images/.../versions/1.0.0` resource ID.
  `latest`, image definitions, managed-image IDs, and VHD URLs are not accepted.
- Architecture and Hyper-V generation are read from the Gallery image definition
  and restrict eligible instance types. The version must be provisioned and
  published in the node region; the OS disk must be large enough.
- FIPS, Trusted Launch, Kata, and marketplace purchase plans are not supported in
  this initial custom-image path. `versions.nodeImageVersion` is mutually exclusive
  with `imageID`.
- Grant the controller identity read access to the Gallery image definition and
  version. The VM creation identity must also have permission to use that image.
  Cross-subscription access requires the appropriate authorization in the same
  tenant. Do not enable the upstream private AKS SIG token-server mode just to use
  your own Gallery; normal self-hosted `UseSIG=false` is supported.

## Select an Official CIG Base

The current upstream Ubuntu 24.04 Gen2 x64 definition is:

```text
/CommunityGalleries/AKSUbuntu-38d80f77-467a-481f-a8d4-09b6d4220bd2/images/2404gen2containerd/versions/<version>
```

Ubuntu 24.04 is appropriate for supported Kubernetes versions such as 1.35. For
other image families or architectures, use the definitions in the upstream
[image family implementation](../pkg/providers/imagefamily/ubuntu_2404.go).

Run these commands after authenticating in your own terminal. All examples below
create or modify real resources; choose an isolated resource group and a budget.

```bash
export AZURE_SUBSCRIPTION_ID="<subscription-id>"
export LOCATION="eastus2"
export IMAGE_RG="<new-image-build-resource-group>"
export GALLERY="karpenterCustom"
export IMAGE_DEFINITION="aksUbuntu2404Gen2"
export IMAGE_VERSION="1.0.0"
export BUILDER_VM="image-builder"
export CIG_GALLERY="AKSUbuntu-38d80f77-467a-481f-a8d4-09b6d4220bd2"
export CIG_DEFINITION="2404gen2containerd"

CIG_VERSIONS=$(az sig image-version list-community \
  --subscription "$AZURE_SUBSCRIPTION_ID" --location "$LOCATION" \
  --public-gallery-name "$CIG_GALLERY" \
  --gallery-image-definition "$CIG_DEFINITION" --output json)
CIG_VERSION=$(jq -er '
  map(select(.name | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")))
  | sort_by(.publishedDate // .properties.publishedDate // (.name | split(".") | map(tonumber)))
  | last.name // empty
' <<< "$CIG_VERSIONS")
export BASE_IMAGE_ID="/CommunityGalleries/${CIG_GALLERY}/images/${CIG_DEFINITION}/versions/${CIG_VERSION}"
printf '%s\n' "$BASE_IMAGE_ID"
```

Record the returned immutable ID and the target Kubernetes version in your build
record. In the eastus2 validation on 2026-10-11, the selected published version was
`202610.08.0` (published 2026-10-09). Its x64/Gen2/generalized and SCSI/NVMe
metadata was checked before use. Query again for a future build rather than
treating this dated version as permanently latest. The derived Gallery `1.0.0`
booted successfully and its build marker was verified on a Ready AKS node; see
[the runtime report](runtime-validation-report.md).

## Build on a Fresh VM

Never customize or generalize a production node. Do not pass a cluster bootstrap
token, kubeconfig, or node identity to the builder. Do not run kubelet bootstrap
or join it to a cluster. Keep kubelet, containerd, cloud-init, waagent, and AKS
bootstrap assets compatible with the base image.

```bash
az group create --subscription "$AZURE_SUBSCRIPTION_ID" \
  --name "$IMAGE_RG" --location "$LOCATION" --output none
az network vnet create --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" --name image-build-vnet \
  --address-prefixes 10.241.0.0/16 --subnet-name builder \
  --subnet-prefixes 10.241.0.0/24 --location "$LOCATION" --output none
az network nsg create --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" --name image-build-nsg \
  --location "$LOCATION" --output none
az vm create --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" --name "$BUILDER_VM" --location "$LOCATION" \
  --image "$BASE_IMAGE_ID" --size Standard_D2s_v5 --security-type Standard \
  --admin-username imagebuilder --ssh-key-values "$HOME/.ssh/id_ed25519.pub" \
  --vnet-name image-build-vnet --subnet builder --nsg image-build-nsg --nsg-rule NONE \
  --public-ip-address image-build-ip --public-ip-sku Standard \
  --os-disk-size-gb 128 --os-disk-delete-option Delete \
  --nic-delete-option Delete --output none

az vm run-command invoke --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" --name "$BUILDER_VM" \
  --command-id RunShellScript --scripts \
  'set -eu' \
  'install -d -m 0755 /opt/karpenter-custom-image' \
  'printf "%s\n" custom-image-v1 > /opt/karpenter-custom-image/build-marker' \
  --output none
```

The builder uses its own Standard public IP for outbound access; no inbound SSH
rule is opened. Run Command is executed by the guest agent. Install your audited
packages or files in this customization step. Never embed passwords, tokens,
private keys, cluster certificates, or environment-specific node state.

## Generalize and Publish

The following operations intentionally destroy the builder's per-machine state
and make it unusable as a normal running VM. Use them only on this disposable
builder, never on a cluster node:

```bash
az vm run-command invoke --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" --name "$BUILDER_VM" \
  --command-id RunShellScript --scripts \
  'set -eu' \
  'cloud-init clean --logs --seed' \
  'waagent -deprovision+user -force' --output none
az vm deallocate --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" --name "$BUILDER_VM" --output none
az vm generalize --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" --name "$BUILDER_VM" --output none

az sig create --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" --gallery-name "$GALLERY" \
  --location "$LOCATION" --output none
az sig image-definition create --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" --gallery-name "$GALLERY" \
  --gallery-image-definition "$IMAGE_DEFINITION" --location "$LOCATION" \
  --publisher custom --offer aks-ubuntu --sku 2404-gen2 \
  --os-type Linux --os-state Generalized --architecture x64 \
  --hyper-v-generation V2 --features 'DiskControllerTypes=SCSI,NVMe' --output none
BUILDER_ID=$(az vm show --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" --name "$BUILDER_VM" --query id --output tsv)
az sig image-version create --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" --gallery-name "$GALLERY" \
  --gallery-image-definition "$IMAGE_DEFINITION" --gallery-image-version "$IMAGE_VERSION" \
  --virtual-machine "$BUILDER_ID" --location "$LOCATION" \
  --target-regions "$LOCATION" --replica-count 1 --storage-account-type Standard_LRS \
  --output none
export CUSTOM_IMAGE_ID=$(az sig image-version show \
  --subscription "$AZURE_SUBSCRIPTION_ID" --resource-group "$IMAGE_RG" \
  --gallery-name "$GALLERY" --gallery-image-definition "$IMAGE_DEFINITION" \
  --gallery-image-version "$IMAGE_VERSION" --query id --output tsv)
```

The example assumes the chosen AKS Gen2 CIG supports both SCSI and NVMe, and that
the customizations did not remove NVMe support. Verify the source definition's
features and preserve them; declaring a feature does not add a driver to the
image. For another source, do not copy these feature/architecture flags blindly.
Wait for image replication to finish before use. Never overwrite a released
version: publish `1.0.1` or a new version instead.

Grant the controller identity Reader at the narrowest image/Gallery scope that
covers the definition and version. Keep VM Contributor at the node resource group;
do not grant broad subscription Contributor merely to read an image.

## Configure and Verify

```yaml
apiVersion: karpenter.azure.com/v1beta1
kind: AKSNodeClass
metadata:
  name: custom-ubuntu
spec:
  imageFamily: Ubuntu2404
  imageID: /subscriptions/<subscription-id>/resourceGroups/<image-rg>/providers/Microsoft.Compute/galleries/<gallery>/images/<definition>/versions/1.0.0
  osDiskSizeGB: 128
```

Attach this NodeClass to a bounded test NodePool and schedule one Pod. Check:

1. `status.images` contains exactly the configured ID and correct architecture/
   generation requirements; `ImagesReady` is true.
2. The Azure VM `storageProfile.imageReference.id` equals that ID, while
   `communityGalleryImageId` is unset.
3. The node joins and runs Pods. Read `/opt/karpenter-custom-image/build-marker`
   through a read-only hostPath test Pod or guest Run Command and confirm the value.
4. On an NVMe-only SKU, `storageProfile.diskControllerType` is `NVMe`.
5. Publishing a new immutable version and updating `imageID` marks the old node
   drifted; use normal disruption budgets for replacement.
6. Delete the test workload/NodeClaim and verify NIC, disk, and public IP cleanup.

If Gallery access or metadata validation fails, `ImagesReady` becomes false and
stale resolved images are cleared. A cached successful lookup may remain valid
for up to one hour; Azure still authorizes the actual VM create request.

After a successful image publication, delete the disposable builder VM, its public
IP, and remaining build-only networking. Keep the Gallery/version while any
NodeClass needs it. Do not delete the entire resource group if it contains the
published Gallery.

References: [AKS image definitions](../pkg/providers/imagefamily/ubuntu_2404.go),
[Azure Compute Gallery](https://learn.microsoft.com/azure/virtual-machines/shared-image-galleries),
[generalize a Linux VM](https://learn.microsoft.com/azure/virtual-machines/generalize),
[AKS node public IPs](https://learn.microsoft.com/azure/aks/use-node-public-ips).