# Build and Deploy a Self-Hosted Controller

This guide preserves the fork's Ubuntu 22.04 build and existing-cluster deployment
workflow using the current upstream APIs. Ubuntu 22.04 here is the build host;
the node image family is configured independently in AKSNodeClass.

Commands that publish images, configure identity, or install charts change real
resources. Run them only against a reviewed development subscription and cluster.
The porting validation does not execute those deployment commands.

## Quay AMD64 Development Images

Publish self-hosted Linux x64 images to `quay.io/hydracz/karpenter-controller`
with `bash hack/release/publish-quay.sh`. Install `ko`, Docker, `curl`, and `jq`,
and authenticate with `docker login quay.io` directly in your terminal first.
Never put registry credentials in scripts or committed files.

Development tags follow the existing `vYYYYMMDD-dev` convention using the UTC
release date. Subsequent releases on the same date use `dev2`, `dev3`, and so on;
existing tags are never overwritten. Each image also receives the full Git commit
SHA tag and OCI revision/version labels. No `latest` tag is published. The embedded
controller version matches the development tag; use the published digest for Helm.

```bash
IMAGE_TAG=v20261011-dev bash hack/release/publish-quay.sh
# A later release on the same date:
IMAGE_TAG=v20261011-dev2 bash hack/release/publish-quay.sh
```

The script requires committed sources, builds a local tarball, verifies
`linux/amd64`, and runs the controller's `--help` before pushing both tags.
Set `BUILD_ONLY=true` to stop after the local checks. Tarballs are ignored under
`dist/quay/`. This independent build uses the pinned Azure Linux base and
`CGO_ENABLED=0` for portable compilation on macOS or Linux. It is a non-FIPS
development image, not a certification of the upstream CGO-enabled release build;
the upstream multi-architecture release settings remain unchanged.

## Build and Test

Use the Go version required by [go.mod](../go.mod), with `GOTOOLCHAIN=auto` if
automatic toolchain downloads are permitted. Do not restore the old fork's
skewer `replace` directive. Add the Go binary directory to `PATH`:

```bash
export PATH="$(go env GOPATH)/bin:$PATH"
make toolchain
make presubmit
bash hack/deploy/configure-workload-identity_test.sh
```

`make toolchain` is Linux-specific and installs system packages. Review
[the toolchain script](../hack/toolchain.sh) before running it. On macOS, install
the required tools natively and configure user-owned envtest binaries instead of
running its `sudo apt-get` steps. Never cross-compile a `go test` command and then
try to execute its Linux test binary on macOS.

Build a standalone self-hosted binary:

```bash
mkdir -p bin
VERSION=$(git rev-parse --short HEAD)
go build -ldflags="-X=sigs.k8s.io/karpenter/pkg/operator.Version=${VERSION}" \
  -o bin/karpenter-controller ./cmd/controller
```

Local `bin/`, `dist/`, and root `controller` outputs are ignored. The AKS-managed
`ccp` build is a different release variant, not required for this self-hosted flow.

## Select the Existing Cluster

Install Azure CLI, jq, kubectl, Helm, ko, crane, and yq as needed. Authenticate
interactively in your own terminal. Do not put credentials in source files.

```bash
export AZURE_SUBSCRIPTION_ID="<subscription-id>"
export CLUSTER_NAME="<aks-cluster-name>"
export RG="<aks-resource-group>"
export KARPENTER_NAMESPACE="kube-system"
export KUBECTL_CONTEXT="<existing-kubectl-context>"

az account set --subscription "$AZURE_SUBSCRIPTION_ID" --output none
kubectl config use-context "$KUBECTL_CONTEXT"
```

The upstream values generator uses the active Azure account and kubectl context;
select both explicitly. The identity helper additionally checks the context API
address against the AKS public or private FQDN. Custom API aliases or tunnels need
a context using an address advertised by that cluster.

## Configure Workload Identity

The operator running this step needs permission to manage the identity, federated
credentials, node-resource-group role assignments, and the Kubernetes service
account. The controller itself uses Workload Identity, not a client secret.

```bash
bash hack/deploy/configure-workload-identity.sh \
  "$CLUSTER_NAME" "$RG" "$KARPENTER_NAMESPACE" \
  karpenter-sa karpentermsi KARPENTER_FID
```

The helper checks OIDC and Workload Identity before writes. If they are disabled,
it prints an explicit `az aks update` instruction and exits; it does not modify
cluster settings automatically. It reuses matching identities and federated
credentials. A conflicting named credential causes an error without overwriting
that credential.

Roles are scoped to the node resource group: Virtual Machine Contributor, Network
Contributor, and Managed Identity Operator. Additional permissions for external
subnets, identities, disk encryption, or Machine API provisioning must follow the
existing upstream setup for those resources. This helper does not grant broad
subscription-level access or ACR push/pull rights.

It creates or annotates the chosen ServiceAccount. For a new Helm release, use
that existing account with `serviceAccount.create=false`. For an existing release
that already owns its ServiceAccount, retain `serviceAccount.create=true` and set
the client/tenant ID annotations through `serviceAccount.annotations`; changing
ownership during an upgrade can make Helm delete the existing account.
The controller pod must carry
`azure.workload.identity/use: "true"`; this is a pod label, not a ServiceAccount
label.

## Publish the Controller Image

Use a clean, committed tree and a registry you are authorized to push to:

```bash
export AZURE_ACR_NAME="<registry-name>"
export AZURE_ACR_LOGIN_SERVER="<registry-login-server>"
export IMAGE_TAG="$(git rev-parse --short HEAD)"
az acr login --name "$AZURE_ACR_NAME" \
  --subscription "$AZURE_SUBSCRIPTION_ID" --output none
GOFLAGS="-ldflags=-X=sigs.k8s.io/karpenter/pkg/operator.Version=${IMAGE_TAG}" \
KO_DOCKER_REPO="${AZURE_ACR_LOGIN_SERVER}/karpenter" \
  ko publish -B --sbom none -t "$IMAGE_TAG" ./cmd/controller
crane digest "${AZURE_ACR_LOGIN_SERVER}/karpenter/controller:${IMAGE_TAG}"
```

Use the repository, tag, and digest from the actual published image. The chart's
default digest points to an upstream release: overriding only the repository and
tag can leave the wrong digest in place. Prefer an immutable digest. For local
tag-only experiments, explicitly set `controller.image.digest` to an empty string.

The existing [skaffold configuration](../skaffold.yaml) and `make az-build` remain
alternatives for the upstream development workflow. Do not edit chart defaults
merely to use a private image.

## Generate Values and Install

For the self-hosted scriptless/CIG path, run the current values generator with all
required arguments:

```bash
bash hack/deploy/configure-values.sh \
  "$CLUSTER_NAME" "$RG" karpenter-sa karpentermsi false aksscriptless
```

Review the generated values for your network, node identities, image source, and
provisioning mode. The generator reads cluster bootstrap credentials; keep the
generated values private and untracked. It also requires access to the configured
SSH public key and Kubernetes bootstrap-token Secret.

For a new release using the helper-created ServiceAccount, use an additional
local values file, such as `image-overrides.yaml`, with these settings filled in
from your build. Existing releases must preserve their ServiceAccount ownership
as described above:

```yaml
serviceAccount:
  create: false
  name: karpenter-sa
podLabels:
  azure.workload.identity/use: "true"
controller:
  image:
    repository: "<registry-login-server>/karpenter/controller"
    tag: "<commit-tag>"
    digest: "sha256:<published-digest>"
```

Before upgrading an old fork, follow the API and GPU migration notes in
[the porting assessment](upstream-porting.md). Pause provisioning while replacing
the obsolete `installGPUDrivers` field. Keep CRD ownership consistent with the
existing installation; do not uninstall or delete CRDs to resolve ownership errors.
Update CRDs through that installation's normal mechanism before deploying the new
controller. For a fresh installation, the separate CRD chart is
[charts/karpenter-crd](../charts/karpenter-crd).

```bash
helm upgrade --install karpenter ./charts/karpenter \
  --namespace "$KARPENTER_NAMESPACE" --create-namespace \
  --values karpenter-values.yaml --values image-overrides.yaml \
  --wait
```

## Verify and Roll Back

```bash
kubectl --context "$KUBECTL_CONTEXT" rollout status \
  deployment/karpenter --namespace "$KARPENTER_NAMESPACE"
kubectl --context "$KUBECTL_CONTEXT" get deployment karpenter \
  --namespace "$KARPENTER_NAMESPACE" \
  --output jsonpath='{.spec.template.spec.containers[0].image}'
kubectl --context "$KUBECTL_CONTEXT" get nodepools,nodeclaims,aksnodeclasses
kubectl --context "$KUBECTL_CONTEXT" get nodes --output wide
kubectl --context "$KUBECTL_CONTEXT" logs deployment/karpenter \
  --namespace "$KARPENTER_NAMESPACE" --container controller --tail=100
```

Inspect logs locally; do not publish bootstrap credentials or tokens. Validate
node creation using a bounded test workload and the appropriate
[repository examples](../examples). Check node registration, GPU resources and
driver installation policy, and the Azure VM's actual disk controller/billing
profile. Local fake-client tests do not establish live Azure provisioning success.

For rollback, retain the previous image digest, chart revision, values, and
AKSNodeClass manifests. Review API compatibility before rolling back the
controller; changing a Helm revision does not undo CRD schema changes or repair
already provisioned nodes. Do not delete NodeClaims or CRDs as a routine rollback.