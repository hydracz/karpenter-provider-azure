# Isolated AKS Feature Validation

These artifacts are for a dedicated test cluster, not an existing production
cluster. Review resource names, region, quotas, permissions, and cost first.

## Existing Cluster Upgrade

For an existing cluster, use [the two-input Helm helper](../../docs/helm-existing-aks.md)
instead of repeating the infrastructure deployment. The Quay `v20261011-dev`
controller was installed and re-upgraded with both Helm releases at revision 2.
The current healthy system pool is `valmgmt` (`Standard_D4ds_v6`); the former
empty/failed `sys` pool was deleted after allocation was unavailable. Do not run
the old `sys` scaling commands below blindly against this retained environment.

The official/custom manifests now use `nodePublicIP.enabled`. Additional
journeys are `test-default.sh` (default no IP / legacy boolean),
`test-contracts.sh` (admission and VM prefix rejection), and `test-drift.sh`
(published version1.0.1, drift, controlled replacement). Use the corresponding
command JSON with `run-command.mjs start`, attach every referenced script/manifest,
then `run-command.mjs wait <id>` to propagate the remote result. Before drift,
publish the temporary Gallery1.0.1 from1.0.0; restore1.0.0 and delete1.0.1 after
all worker VMs are removed. Keep one worker at a time and independently run
`check-azure-node.sh deleted <name>` after each cleanup.

Full current results, limitations and retained costs are in
[the validation report](../../docs/runtime-validation-report.md). The pool is
paused at CPU0 after testing; the controller remains deployed. Old setup steps
below describe the initial environment, not an instruction to recreate it.
Azure CLI authentication must be completed in your own terminal. Never put
credentials, bootstrap tokens, or private keys in these files.

## Observed Platform Constraints

The 2026-10-11 eastus2 validation used Kubernetes 1.35.8 and `Standard_D4ds_v6`
workers. The AMD v6 candidates were subscription-restricted in this region.

ARM preflight rejected both AKS-managed artifact cache with a BYO node VNet and
Workload Identity with outbound type `none`. The deployed compatible topology is
a private AKS cluster with Workload Identity, standard LB configuration, and node
public IPs. There is no NAT Gateway. The tests prove direct public-IP egress;
they do not prove zero LB resource charges.

The system pool must have enough free CPU for AKS Run Command Pods and no custom
taint those Pods cannot tolerate. Two small system nodes were used temporarily
during concurrent tests, then reduced to one.
Workers use the `validation-only` taint and probes explicitly tolerate it. Keep
that isolation so management commands do not run on the node being deleted.

## Provision

Run from the repository root, selecting only a new, isolated resource group:

```bash
export AZURE_SUBSCRIPTION_ID="<subscription-id>"
export AZURE_RESOURCE_GROUP="rg-karpenter-validation-20261011"
export CLUSTER_NAME="aks-karpenter-validation"
az group create --subscription "$AZURE_SUBSCRIPTION_ID" \
  --name "$AZURE_RESOURCE_GROUP" --location eastus2 --output none
az deployment group what-if --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$AZURE_RESOURCE_GROUP" --name karpenter-validation \
  --template-file infra/validation/main.bicep \
  --parameters @infra/validation/main.parameters.json \
  sshPublicKey="$(cut -d' ' -f1,2 "$HOME/.ssh/id_rsa.pub")" --output json
az deployment group create --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$AZURE_RESOURCE_GROUP" --name karpenter-validation \
  --template-file infra/validation/main.bicep \
  --parameters @infra/validation/main.parameters.json \
  sshPublicKey="$(cut -d' ' -f1,2 "$HOME/.ssh/id_rsa.pub")" --output json
az aks nodepool scale --subscription "$AZURE_SUBSCRIPTION_ID" \
  --resource-group "$AZURE_RESOURCE_GROUP" --cluster-name "$CLUSTER_NAME" \
  --name sys --node-count 2 --output none
```

The Bicep creates AKS, Basic ACR, a control-plane identity, image-builder network,
and the kubelet AcrPull assignment. AKS creates its managed node resource group.
Controller Workload Identity is configured separately with the exact service
account subject and scoped node-resource-group roles. See
[the deployment guide](../../docs/ubuntu-2204-build-deploy.md).

## Build and Deploy the Controller

Use the existing release build on a configured Linux host. For this macOS-hosted
validation, `ko.yaml` produces a static Linux amd64 binary without changing the
upstream CGO-enabled release settings:

```bash
KO_CONFIG_PATH="$PWD/infra/validation/ko.yaml" KO_DOCKER_REPO=ko.local \
  ko build --base-import-paths --platform=linux/amd64 --tags=validation ./cmd/controller
docker run --rm --platform linux/amd64 ko.local/controller:validation --help
```

Push only after the local container runs. Render `controller-values.yaml` using
the actual cluster, subnet, kubelet identity, controller identity, and image digest.
`CONTROLLER_TAG` and `CONTROLLER_DIGEST` must identify the same build. Generated
manifests belong under ignored `dist/live-validation/`.

The install script reads the AKS bootstrap token inside the private cluster and
creates a Kubernetes Secret; the token is never downloaded. Upload only the
rendered controller/CRD manifests, script, and SSH public key:

```bash
node infra/validation/run-command.mjs start infra/validation/install-command.json \
  infra/validation/install-controller.sh dist/live-validation/controller.yaml \
  dist/live-validation/crds.yaml "$HOME/.ssh/id_rsa.pub"
```

## Run Command Results

The helper works around CLI waiting incompatibilities using the authorized ARM
API. `start` prints a command ID. The complete server-provided asynchronous URL
is stored only in a user-private temporary file; it must not be logged or committed.

```bash
node infra/validation/run-command.mjs result "<command-id>"
```

Exit codes: `0` means the remote command completed successfully, `1` means failed,
and `2` means it is not complete. Inspect `exitCode`, `provisioningState`, and logs.
Do not treat an HTTP 200 or accepted command ID as test success. A lost result
requires checking actual resources before replaying an idempotent test.

## Journeys

Run one worker journey at a time; `nodepool.yaml` limits the pool to four CPUs.

1. Upload `test-official.sh`, `official-nodeclass.yaml`, `nodepool.yaml`, and
   `probe-pod.yaml` using `official-command.json`. Verify a Ready node/Pod, exact
   CIG version, NVMe controller, and matching external egress/public IP.
2. Run `test-cleanup.sh` using `cleanup-command.json`; then run
   `check-azure-node.sh deleted <old-vm-name>` from the local machine.
3. Build the generalized Gallery image using [the image guide](../../docs/custom-images.md),
   render `custom-nodeclass.yaml` with `CUSTOM_IMAGE_ID`, and upload it with
   `test-custom.sh` and `probe-pod.yaml` using `custom-command.json`. The build
   marker must match on the actual node.
4. Clean up again, then run `test-spot.sh` with `spot-command.json`. Confirm a Ready
   Spot node and use the Azure checker to assert `billingProfile.maxPrice=0.10`.
5. Run `test-image-rejection.sh` with `rejection-command.json` to verify an
   unauthorized image reference is NotReady with no resolved images or fallback.
6. Run `finish-validation.sh` plus `test-cleanup.sh` using `finish-command.json`.
   This records the last egress IP/marker, removes test nodes, and restores the
   NodePool to on-demand configuration. Verify Azure deletion separately.

The Azure checker requires `AZURE_SUBSCRIPTION_ID` and `NODE_RESOURCE_GROUP`:

```bash
bash infra/validation/check-azure-node.sh active \
  "<vm-name>" "<expected-image-id>" "<expected-public-egress-ip>" 0.10
bash infra/validation/check-azure-node.sh deleted "<vm-name>"
```

It checks actual VM metadata, NSG attachment, Standard static IPv4, absence of
outbound-rule pool membership, optional Spot price, and resource deletion. The
public IP and LB pool behavior is described in [node-public-ip.md](../../docs/node-public-ip.md).

## Final State and Cost

Remove builder VMs and their IPs after image publication. Remove all test worker
NodeClaims and Pods, and scale the system pool back to one node. Keep only the
explicitly reported cluster, registry, Gallery version, and manifests for review.
These retained resources still incur ongoing charges. To remove the environment
entirely, delete only its dedicated resource group after confirming that none of
its images or identities are needed elsewhere; AKS also removes its managed node RG.

The retained `validation` NodePool is paused with `spec.limits.cpu: "0"` after
cleanup. This prevents system or management Pod pressure from creating another
worker when the system pool is scaled down. Before another deliberate test,
restore the limit to four CPUs from an authorized session in this private cluster:

```bash
kubectl patch nodepool validation --type merge -p '{"spec":{"limits":{"cpu":"4"}}}'
```

Keep the dedicated worker taint and probe toleration. At the end, run
`pause-and-clean.sh` via `pause-command.json`, verify Azure resource deletion,
scale the system pool back to one node, and use the short `final-state.sh` check.
The live run observed a Cilium operator Pod trigger another worker after system
scale-down while the validation pool was still enabled. Do not infer cleanup success solely
from a long Run Command whose execution Pod may have been evicted.

Results and known gaps are recorded in
[the runtime report](../../docs/runtime-validation-report.md).