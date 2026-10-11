# Helm Deployment to an Existing AKS Cluster

## One Command

Use a checkout containing the controller-matched chart and generated CRDs. With
Azure CLI already logged in and the intended subscription selected, provide only
the resource group and cluster name after selecting the controller image once:

```bash
export IMAGE_REPOSITORY=quay.io/hydracz/karpenter-controller
export IMAGE_TAG=v20261011-dev
export IMAGE_DIGEST=sha256:8f60eba2ddbec07f25455ced69a5858eabb029f3e5ed064fab0926a544a95c1f
bash hack/deploy/helm-existing-aks.sh rg-demo aks-demo
```

All three image values are required; no repository, tag or digest is built into
the installer. They can be exported by a reviewed deployment environment file.
When changing registries or versions, select the matching digest explicitly.

For the existing manually applied installation in the validation cluster, the
first deployment explicitly adopts its reviewed resources:

```bash
bash hack/deploy/helm-existing-aks.sh \
  rg-karpenter-validation-20261011 aks-karpenter-validation --adopt-existing
```

Subsequent upgrades omit `--adopt-existing`. The script refuses resources owned
by another Helm release, unrelated controller resources, and unreviewed manual
installations. It does not enable AKS NAP or replace an AKS-managed controller.
Only `aksscriptless` self-hosted provisioning is configured by this helper.

## Prerequisites

- Local tools: Bash 4+, Azure CLI, Helm, kubectl, Node.js, `jq`, `yq` v4, and `zip`.
- A running Linux system pool with capacity for the controller and management Pods.
- AKS manual node provisioning, Kubernetes RBAC, OIDC issuer, and Workload Identity.
- Permission to read AKS/network/identity metadata and retrieve cluster-user credentials.
- Permission to create/reuse the controller identity and its federated credential,
  and assign the required roles in the node resource group.
- For the default private-cluster path: permission to execute/read AKS Run Command;
  its execution Pod needs Helm, kubectl, jq, and sufficient system capacity.
- A readable controller image in the configured registry, or separately configured image-pull access.

The helper refuses missing OIDC/Workload Identity rather than changing cluster
settings implicitly. An administrator can enable them separately after review:

```bash
az aks update --resource-group rg-demo --name aks-demo \
  --enable-oidc-issuer --enable-workload-identity --output none
```

Review the login/subscription before any command. Set `AZURE_SUBSCRIPTION_ID` to
pin a subscription without changing the CLI default.

## What Is Discovered

The helper reads the cluster endpoint and CA, location, node resource group,
network plugin/mode/policy/dataplane, DNS IP, kubelet identity, node subnet, VNet
GUID, SSH public key, and an available Linux system pool. It creates or reuses
`id-karpenter-controller` in the cluster resource group. Workload Identity is bound
to `system:serviceaccount:kube-system:karpenter-sa`; VM Contributor, Network
Contributor and Managed Identity Operator roles are scoped to the node resource
group, not the subscription. Custom Gallery Reader access is separate and must
be scoped to the chosen image definition.

For ambiguous multi-subnet clusters, set `NODE_SUBNET_ID`; the script does not
guess among multiple managed AKS subnets. Optional overrides are:

| Variable | Default / Purpose |
| --- | --- |
| `AZURE_SUBSCRIPTION_ID` | Current CLI subscription |
| `KARPENTER_NAMESPACE` | `kube-system` |
| `KARPENTER_IDENTITY_NAME` | `id-karpenter-controller` |
| `SYSTEM_POOL` | First successful Linux system pool with nonzero count |
| `NODE_SUBNET_ID` | Uniquely discovered pool/managed AKS subnet |
| `CONTROLLER_REPLICAS` | `1` for bounded development use |
| `DEPLOY_TRANSPORT` | `run-command`; use `direct` with API network access |
| `IMAGE_REPOSITORY` / `IMAGE_TAG` / `IMAGE_DIGEST` | Required image selection, no implicit defaults |

For availability outside a small test environment, use two controller replicas
and sufficient system nodes to satisfy the chart's required pod anti-affinity.
The helper does not scale, create, delete, or repair system pools automatically.

## Installation and Secrets

The helper packages both local charts and waits for the actual Run Command
result. ARM HTTP success alone is not considered installation success. Direct
mode downloads credentials into an ignored deployment directory and uses that
explicit kubeconfig, leaving the user's normal current context unchanged.
Cluster matching checks the kubeconfig endpoint, or the Azure-provided CA against
the in-cluster CA for Run Command authentication.

The bootstrap token is read only inside the cluster from a currently usable AKS
bootstrap Secret, with at least one hour remaining if it has an expiration.
It is copied to `karpenter-bootstrap` with the cluster SSH public key. Helm uses
`secretKeyRef`; generated values and Run Command attachments contain no bootstrap
token or registry credentials. The Secret's resource version triggers a controller
rollout when bootstrap credentials change. Disable shell tracing; never print
Secret data. Self-hosted operators must rerun the deployment before token expiry
or provide their own secure rotation mechanism; this helper is not a rotation daemon.

The release-matched `karpenter-crd` chart is installed/upgraded first, then the
`karpenter` release. Existing ServiceAccount ownership remains with the same release.
This helper applies its generated development values rather than reusing every
custom value from an existing release. Review resource limits, replicas, labels,
and custom monitoring/pull-secret settings before adopting a customized deployment.
Helm waits for readiness and uses rollback-on-failure/atomic upgrade depending on
the installed Helm version. CRD schema changes are not automatically rolled back.
An initial adoption has no previous Helm revision; review and back up the old
installation before adopting it. Automatic upgrade rollback is not a substitute
for that backup.

## Upgrade and Verify

To select another published image, supply its repository, tag and digest. This prevents
accidentally retaining the old digest when only a tag changes:

```bash
IMAGE_REPOSITORY=<registry/repository> IMAGE_TAG=v20261011-dev2 IMAGE_DIGEST=sha256:<published-digest> \
  bash hack/deploy/helm-existing-aks.sh rg-demo aks-demo
```

From a cluster-authorized shell:

```bash
helm status karpenter --namespace kube-system
helm status karpenter-crd --namespace kube-system
kubectl --namespace kube-system rollout status deployment/karpenter
kubectl --namespace kube-system get deployment karpenter \
  --output jsonpath='{.spec.template.spec.containers[0].image}'
kubectl get aksnodeclasses,nodepools,nodeclaims --output wide
```

The chart's own version and appVersion are not proof of the deployed binary.
Verify the container digest and the embedded/logged controller version. NodePool
and AKSNodeClass resources are intentionally not installed by the helper; users
retain control over allowed sizes, image families, public addressing and budgets.

Use [the port configuration examples](upstream-porting.md),
[custom image permissions/build steps](custom-images.md), and
[public IP security and routing guidance](node-public-ip.md). Run the bounded
flows in [the validation directory](../infra/validation/README.md) before broader
rollout. GPU runtime, Machine API, FIPS/Trusted Launch/Kata and real Spot evictions
require their own suitable cluster/resources and are not implied by CPU tests.

For a previous Helm-managed revision:

```bash
helm history karpenter --namespace kube-system
helm rollback karpenter <revision> --namespace kube-system --wait
```

Pause test pools at `spec.limits.cpu: "0"` and verify VM/NIC/disk/public-IP
deletion after tests. Removing only the Helm release does not mean worker cloud
resources have been safely cleaned up. The retained AKS system nodes, images,
registry, load balancer, and traffic continue to incur charges.