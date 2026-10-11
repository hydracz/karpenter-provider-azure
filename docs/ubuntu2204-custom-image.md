# Ubuntu 22.04 AKS Image and Node Public IP

## Choose a Build Method

Choose **one** method, then follow the common publication and deployment steps:

| Method | When to Choose It | Source OS Booted? |
| --- | --- | --- |
| A: CIG to unattached disk | A private, fixed AKS baseline without additional packages | No |
| B: disposable VM | Install packages, agents, files or configuration | Yes, then cleaned and generalized |

A does not add software or remove state already present in the official image.
It avoids generating **new** per-machine boot state during preparation. B supports
normal package installation but requires cleanup; cleanup is not proof that every
third-party agent has removed its identity. Do not use a live AKS node as either
source. The runtime AKS worker must eventually boot to join Kubernetes; its
normal boot writes do not modify the immutable Gallery source image.

Public IP is node networking configuration, not something to bake into an image.
Both methods use `imageFamily: Ubuntu2204` and `nodePublicIP.enabled: true` below.

## 1. Select Cluster and Source

Use Bash with Azure CLI and jq. Log in directly in your terminal and select the
subscription. These commands create billable resources; use an isolated environment.
The prepared/tested example uses the existing validation cluster:

```bash
export AZURE_SUBSCRIPTION_ID="$(az account show --query id --output tsv)"
export CLUSTER_RG=rg-karpenter-validation-20261011
export CLUSTER_NAME=aks-karpenter-validation
export IMAGE_RG="$CLUSTER_RG"
export GALLERY=karpenterValidation
export DEFINITION=aksUbuntu2204Gen2
export VERSION=1.0.0
export CONTROLLER_IDENTITY=id-karpenter-controller
AKS=$(az aks show --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$CLUSTER_RG" --name "$CLUSTER_NAME" --output json)
export LOCATION="$(jq -er '.location' <<< "$AKS")"
export CIG_GALLERY=AKSUbuntu-38d80f77-467a-481f-a8d4-09b6d4220bd2
export CIG_DEFINITION=2204gen2containerd
az sig image-version list-community --subscription "$AZURE_SUBSCRIPTION_ID" \
  --location "$LOCATION" --public-gallery-name "$CIG_GALLERY" \
  --gallery-image-definition "$CIG_DEFINITION" \
  --query '[].{version:name,published:publishedDate}' --output table
export CIG_VERSION=202610.08.0
export BASE_IMAGE_ID="/CommunityGalleries/$CIG_GALLERY/images/$CIG_DEFINITION/versions/$CIG_VERSION"
az sig image-definition show-community --subscription "$AZURE_SUBSCRIPTION_ID" \
  --location "$LOCATION" --public-gallery-name "$CIG_GALLERY" \
  --gallery-image-definition "$CIG_DEFINITION" --output json
```

The dated version was verified in eastus2 on 2026-10-11. For future builds,
deliberately select an available fixed version matching your AKS bootstrap contract;
do not assume this example is forever latest or use a plain Marketplace Ubuntu.
The verified source is Linux/Generalized/x64/V2 and supports SCSI and NVMe.

## 2A. Prepare Without Booting a VM

This REST request is necessary because CIG is **not** a private Gallery ARM ID.
Use `galleryImageReference.communityGalleryImageId`, not its `id` member.
No VM, NIC, bootstrap token or disk export URL is created.

```bash
export SOURCE_DISK=aks-ubuntu2204-unbooted
export DISK_ID="/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$IMAGE_RG/providers/Microsoft.Compute/disks/$SOURCE_DISK"
az group create --subscription "$AZURE_SUBSCRIPTION_ID" \
  --name "$IMAGE_RG" --location "$LOCATION" --output none
mkdir -p dist/ubuntu2204
jq -n --arg location "$LOCATION" --arg image "$BASE_IMAGE_ID" '
 {location:$location,sku:{name:"Standard_LRS"},properties:{
   osType:"Linux",hyperVGeneration:"V2",networkAccessPolicy:"DenyAll",
   publicNetworkAccess:"Disabled",creationData:{createOption:"FromImage",
   galleryImageReference:{communityGalleryImageId:$image}}}}
' > dist/ubuntu2204/disk.json
az rest --subscription "$AZURE_SUBSCRIPTION_ID" --method put \
  --url "https://management.azure.com$DISK_ID?api-version=2025-01-02" \
  --body @dist/ubuntu2204/disk.json --output none
az disk wait --subscription "$AZURE_SUBSCRIPTION_ID" --resource-group "$IMAGE_RG" \
  --name "$SOURCE_DISK" --created --interval 15 --timeout 900 --output none
az disk show --subscription "$AZURE_SUBSCRIPTION_ID" --resource-group "$IMAGE_RG" \
  --name "$SOURCE_DISK" --output json \
  | jq -e '.provisioningState=="Succeeded" and .diskState=="Unattached" and .managedBy==null and .hyperVGeneration=="V2"'
```

Skip 2B and continue to 3. Preserve the generalized source: do not boot this disk,
run a node bootstrap, or invoke generalization cleanup against another system.

## 2B. Install Software on a Disposable VM

Skip this section when using A. Create a dedicated builder network that does not
overlap your existing VNet. The example requires reviewed, non-overlapping CIDRs.
No inbound SSH rule is opened; the public IP is for outbound package downloads.

```bash
export BUILDER=ubuntu2204-builder
SSH_PUBLIC_KEY=$(jq -er '.linuxProfile.ssh.publicKeys[0].keyData' <<< "$AKS")
az network vnet create --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" --name ubuntu2204-build-vnet --location "$LOCATION" \
  --address-prefixes 10.243.0.0/16 --subnet-name builder \
  --subnet-prefixes 10.243.1.0/24 --output none
az network nsg create --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" --name ubuntu2204-build-nsg --location "$LOCATION" --output none
az vm create --subscription "$AZURE_SUBSCRIPTION_ID" --resource-group "$IMAGE_RG" \
  --name "$BUILDER" --location "$LOCATION" --image "$BASE_IMAGE_ID" \
  --size Standard_D4ds_v6 --security-type Standard --admin-username imagebuilder \
  --ssh-key-values "$SSH_PUBLIC_KEY" --vnet-name ubuntu2204-build-vnet --subnet builder \
  --nsg ubuntu2204-build-nsg --nsg-rule NONE --public-ip-address ubuntu2204-build-ip \
  --public-ip-sku Standard --os-disk-size-gb 128 --os-disk-delete-option Delete \
  --nic-delete-option Delete --output none
az vm run-command invoke --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" --name "$BUILDER" --command-id RunShellScript \
  --scripts 'set -eu' 'install -d -m 0755 /opt/karpenter-custom-image' \
  'printf "%s\n" ubuntu2204-custom-v1 > /opt/karpenter-custom-image/build-marker' --output none
```

Replace/extend the last command with your audited software installation. Do not
include credentials, kubeconfigs, cluster tokens or node identities. Do not start
kubelet to join a cluster. Preserve AKS bootstrap scripts, cloud-init, waagent,
containerd and disk drivers. Inspect Run Command success, not just HTTP success.

After checking the installed software, destroy only this builder's per-machine
state. Agent-specific caches/IDs and package logs require their own cleanup.

```bash
az vm run-command invoke --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" --name "$BUILDER" --command-id RunShellScript \
  --scripts 'set -eu' 'cloud-init clean --logs --seed --machine-id' \
  'waagent -deprovision+user -force' --output none
az vm deallocate --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" --name "$BUILDER" --output none
az vm generalize --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" --name "$BUILDER" --output none
export BUILDER_ID="$(az vm show --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" --name "$BUILDER" --query id --output tsv)"
```

Creating a Gallery definition with `osState: Generalized` alone never cleans an
already-booted disk. Do not relabel an arbitrary specialized disk as generalized.

## 3. Publish an Immutable Gallery Version

For a new Gallery, create it first. The prepared validation Gallery already exists.
Do not overwrite published versions; use the next version for changed contents.
Create a separate definition for each OS/architecture/generation combination.

```bash
az sig create --subscription "$AZURE_SUBSCRIPTION_ID" --resource-group "$IMAGE_RG" \
  --gallery-name "$GALLERY" --location "$LOCATION" --output none
```

Skip creation/publication steps when using the already prepared definition/version.

```bash
az sig image-definition create --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" --gallery-name "$GALLERY" \
  --gallery-image-definition "$DEFINITION" --location "$LOCATION" \
  --publisher custom --offer aks-ubuntu --sku 2204-gen2 \
  --os-type Linux --os-state Generalized --architecture x64 \
  --hyper-v-generation V2 --features 'DiskControllerTypes=SCSI,NVMe' --output none
export IMAGE_DEFINITION_ID="/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$IMAGE_RG/providers/Microsoft.Compute/galleries/$GALLERY/images/$DEFINITION"
export CUSTOM_IMAGE_ID="$IMAGE_DEFINITION_ID/versions/$VERSION"
```

The feature flags preserve verified source capabilities; they do not install
missing drivers. `TrustedLaunchSupported` metadata does not enable Trusted Launch
in the NodeClass. The current custom-image path does not support FIPS/TL/Kata.

**A publication**:

```bash
jq -n --arg location "$LOCATION" --arg disk "$DISK_ID" '
 {location:$location,properties:{publishingProfile:{replicationMode:"Full",
   storageAccountType:"Standard_LRS",targetRegions:[{name:$location,regionalReplicaCount:1}]},
   storageProfile:{osDiskImage:{hostCaching:"ReadOnly",source:{id:$disk}}}}}
' > dist/ubuntu2204/version.json
az rest --subscription "$AZURE_SUBSCRIPTION_ID" --method put \
  --url "https://management.azure.com$CUSTOM_IMAGE_ID?api-version=2025-03-03" \
  --body @dist/ubuntu2204/version.json --output none
```

**B publication** (run this instead of A publication):

```bash
az sig image-version create --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" --gallery-name "$GALLERY" \
  --gallery-image-definition "$DEFINITION" --gallery-image-version "$VERSION" \
  --virtual-machine "$BUILDER_ID" --location "$LOCATION" \
  --target-regions "$LOCATION" --replica-count 1 --storage-account-type Standard_LRS --output none
```

For **both**:

```bash
az sig image-version wait --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" --gallery-name "$GALLERY" \
  --gallery-image-definition "$DEFINITION" --gallery-image-version "$VERSION" \
  --created --interval 15 --timeout 1800 --output none
az sig image-version show --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" --gallery-name "$GALLERY" \
  --gallery-image-definition "$DEFINITION" --gallery-image-version "$VERSION" \
  --expand ReplicationStatus --query '{state:provisioningState,replication:replicationStatus}' --output json
PRINCIPAL=$(az identity show --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$CLUSTER_RG" --name "$CONTROLLER_IDENTITY" --query principalId --output tsv)
az role assignment create --subscription "$AZURE_SUBSCRIPTION_ID" \
  --assignee-object-id "$PRINCIPAL" --assignee-principal-type ServicePrincipal \
  --role Reader --scope "$IMAGE_DEFINITION_ID" --output none
```

Wait for regional replication `Completed`. The preparing operator needs access
to the image and disk; the controller needs Reader here plus its normal node-RG
VM/Network/Managed Identity roles. Cross-subscription use requires appropriate
same-tenant permissions. Avoid subscription-wide Contributor for image access.

## 4. Configure and Test AKS

Install/upgrade the controller and matching CRDs using [the Helm guide](helm-existing-aks.md).
Select `IMAGE_REPOSITORY`, `IMAGE_TAG`, and `IMAGE_DIGEST` explicitly: the installer
contains no fixed registry. The retained cluster is already on the tested Quay image.

Render the supplied class, bounded pool and workload. Review the fixed example
SKU and zone against your cluster's region and available capacity before applying.

```bash
CUSTOM_IMAGE_ID="$CUSTOM_IMAGE_ID" yq '(..|select(tag=="!!str")) |= envsubst(nu)' \
  infra/validation/ubuntu2204-public.yaml > dist/ubuntu2204/ubuntu2204-public.yaml
kubectl apply -f dist/ubuntu2204/ubuntu2204-public.yaml
kubectl wait --for=condition=Ready aksnodeclass/custom-ubuntu2204-public --timeout=180s
kubectl -n validation2204 wait --for=condition=Ready pod/probe --timeout=600s
kubectl get nodes -l karpenter.sh/nodepool=ubuntu2204-public --output wide
```

Key class settings are:

```yaml
spec:
  imageFamily: Ubuntu2204
  imageID: /subscriptions/<subscription-id>/resourceGroups/<image-rg>/providers/Microsoft.Compute/galleries/<gallery>/images/aksUbuntu2204Gen2/versions/1.0.0
  osDiskSizeGB: 128
  nodePublicIP:
    enabled: true
```

For a private cluster without API connectivity, reuse the authorized Run Command
helper instead of changing the cluster endpoint or exporting admin credentials:

```bash
export AZURE_RESOURCE_GROUP="$CLUSTER_RG"
COMMAND_ID=$(node infra/validation/run-command.mjs start infra/validation/ubuntu2204-command.json \
  infra/validation/test-ubuntu2204.sh dist/ubuntu2204/ubuntu2204-public.yaml)
node infra/validation/run-command.mjs wait "$COMMAND_ID"
```

This verifies the node reports Ubuntu22.04, its claim resolves your Gallery ID,
the Pod is Ready, and observed Internet egress equals the node ExternalIP. Also
verify exact Azure image ID, NVMe for NVMe-only SKUs, NSG attachment, dedicated
Standard/static IP and no outbound-rule pool reference. Public IP does not open
inbound rules or remove a NAT/UDR/LB; routing overrides may take precedence.

## 5. Cleanup and Prepared Result

For private-cluster tests, pause the pool and delete its test workload/claims:

```bash
COMMAND_ID=$(node infra/validation/run-command.mjs start infra/validation/ubuntu2204-cleanup-command.json \
  infra/validation/cleanup-ubuntu2204.sh)
node infra/validation/run-command.mjs wait "$COMMAND_ID"
```

Independently check VM/NIC/disk/public-IP deletion. After **full** Gallery
replication completes, remove A's unattached source disk, or B's disposable VM,
NIC/disk/public-IP and build-only network. Keep the published image while it is
referenced. Do not delete a whole resource group containing a retained Gallery.

**A cleanup**:

```bash
az disk delete --subscription "$AZURE_SUBSCRIPTION_ID" --resource-group "$IMAGE_RG" \
  --name "$SOURCE_DISK" --yes --output none
```

**B cleanup** (only the dedicated builder resources):

```bash
az vm delete --subscription "$AZURE_SUBSCRIPTION_ID" --resource-group "$IMAGE_RG" \
  --name "$BUILDER" --yes --output none
az network public-ip delete --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" --name ubuntu2204-build-ip --output none
az network vnet delete --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" --name ubuntu2204-build-vnet --output none
az network nsg delete --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$IMAGE_RG" --name ubuntu2204-build-nsg --output none
```

Verify the builder NIC and disk with Azure inventory before removing its network;
the create commands set their delete options but deletion must still be checked.

The prepared image is `karpenterValidation/aksUbuntu2204Gen2/1.0.0` in
`rg-karpenter-validation-20261011`, eastus2. It used method A from fixed CIG
`202610.08.0`; no source VM was created. The test node reported Ubuntu22.04.5,
Kubernetes1.35.8, NVMe/NvmeDisk, and allocated/observed IP `20.186.114.205`.
The test worker and source disk were deleted. The published image and
`custom-ubuntu2204-public` class remain; `ubuntu2204-public` pool is paused at CPU0.
Applying the manifest again deliberately reenables it at CPU4 and creates a probe.
Gallery replicas, system nodes, public IPs and traffic still have charges.

## Offline Customization Boundary

If you want additional files without booting the target OS, attach a copy as a
**data disk** to a separate trusted Linux helper, mount the target root partition,
make audited changes, unmount and detach, then publish it. The helper boots its
own OS; the target disk must never be its OS disk. Use a copy/snapshot for rollback.
Package installation via chroot can invoke post-install scripts, generate keys or
machine IDs, or start services; merely not booting is not sufficient hygiene.
This advanced offline package workflow was not performed or certified here.
For normal software installation choose B; for a clean fixed baseline choose A.

References: [CIG-to-disk API](https://learn.microsoft.com/rest/api/compute/disks/create-or-update?view=rest-compute-2025-01-02),
[Gallery publication API](https://learn.microsoft.com/rest/api/compute/gallery-image-versions/create-or-update),
[Linux generalization](https://learn.microsoft.com/azure/virtual-machines/generalize),
[node public IP behavior](node-public-ip.md).