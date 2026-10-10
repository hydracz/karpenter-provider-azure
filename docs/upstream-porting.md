# Upstream-First Fork Port

## Baseline

Assessment date: 2026-10-10.

- Upstream: `Azure/karpenter-provider-azure`, `main` at
  `8389c7e91b7dbb42efa175fd1fbcf3a398ca396c`, fetched from GitHub for this port.
- Source fork: `hydracz/karpenter-provider-azure`, `main` at
  `3f8b8bd9156e5e44c3803d8ca972b1d54e88c4f8` (`v20260323-dev`).
- Common ancestor: `9a1c4bf24693a38e9b251b05c308f44cb05e32ff`.
- The 11 fork-only commits were assessed by feature rather than replayed blindly.
  The original fork working tree and branch were left unchanged. New commits are
  on the upstream checkout's existing `main`; nothing was pushed to either remote.

## Feature Decisions

| Feature | Decision | Evidence and resulting behavior |
| --- | --- | --- |
| RTX PRO 6000 BSE v6 GPU recognition and driver selection | Use upstream | [#1706](https://github.com/Azure/karpenter-provider-azure/pull/1706), [#1772](https://github.com/Azure/karpenter-provider-azure/pull/1772), current GPU registry and GRID v20 mapping. Do not restore preview-only SKU names or old converged-driver mappings. |
| Forked skewer dependency | Drop the fork replacement | Upstream already uses `github.com/Azure/skewer v0.0.31`. Keep its dependencies and SKU discovery unchanged. |
| GPU Operator / BYO driver toggle | Use upstream `spec.gpu.mode` | [#1539](https://github.com/Azure/karpenter-provider-azure/pull/1539) supplies `Driver`/`None` and mode-aware filtering/bootstrap. Keep upstream APIs, CRDs, defaults, and hash logic. |
| Managed NVIDIA components | Use upstream | [#1752](https://github.com/Azure/karpenter-provider-azure/pull/1752) exposes NVIDIA management mode. It is distinct from disabling driver installation. |
| CIG eligibility for NVMe-only SKUs | Use upstream | [#1642](https://github.com/Azure/karpenter-provider-azure/pull/1642) removes the old CIG block. Do not reinstate the fork's obsolete compatibility predicate. |
| Ephemeral OS disk eligibility, capacity, placement | Use upstream | [#1870](https://github.com/Azure/karpenter-provider-azure/pull/1870) is retained without behavioral changes. NVMe temporary-disk placement is not the same as the VM OS disk controller. |
| Explicit NVMe controller in VM create requests | Retain and adapt | Current upstream VM requests do not set the controller. Carry `DiskControllerType=NVMe` from SKU capabilities through the existing storage lookup and launch template, only for NVMe-only SKUs. Exact token matching avoids treating `NVMeV2` as `NVMe`. |
| Scriptless AgentBaker skip-driver tag | Retain and adapt | Emit `SkipGpuDriverInstall=true` for `aksscriptless` with upstream `gpu.mode: None`. Other modes retain their upstream GPU profiles. Explicit disablement takes precedence over additional tags. |
| Spot maximum price annotation | Retain and adapt | Keep `karpenter.azure.com/spot-max-price` on NodeClaims. Current Machine SDK supports `Billing.SpotMaxPrice`, so replace the fork's obsolete Machine API rejection with native support in both Machine modes. Preserve defaults and on-demand behavior. |
| Existing-cluster Workload Identity helper | Retain and harden | Keep the standalone existing-cluster workflow. Pin subscription/context, reject conflicting federated credentials, propagate read failures, and scope roles to the node resource group. |
| Build/deployment guide and local build ignores | Retain and update | Use current values-generator arguments, existing ServiceAccount ownership, and immutable image digests. Ignore root `bin/`, `dist/`, and `controller` artifacts. |
| Historical GPU/image analysis documents | Supersede | Their preview SKU names, old GPU API, driver versions, and unsupported-mode statements are no longer reliable operational guidance. This assessment and the updated deployment guide replace them; originals remain in the source fork. |

## New Feature Commits

The retained work is split by feature, in this order. Identify commits by subject
with `git log --oneline 8389c7e9..HEAD`:

1. `feat(spot): port max-price annotations across provisioning modes`
2. `fix(gpu): honor upstream GPU mode in scriptless skip tags`
3. `fix(storage): select NVMe controllers for NVMe-only VM sizes`
4. `feat(deploy): port existing-cluster workload identity workflow`

The assessment itself is a separate documentation commit. Generated CRDs and
dependency versions are not intentionally changed by the port.

## Source Commit Accounting

| Fork commit | Disposition |
| --- | --- |
| `b9bffd0` GPU support and driver switch | GPU/SKU implementations replaced by upstream; migrate the old API as described below. |
| `2a81529` GPU and Ubuntu guides | Build/deploy workflow updated; old GPU analyses superseded. |
| `6226f00` Spot annotation | Ported, with native current Machine API support and expanded tests. |
| `0ada9be` Machine builder refactor | Intent retained in a small billing helper; obsolete unsupported-mode check and old API default markers not replayed. |
| `d2983a0` local ignores | Root build-output ignores retained in the deployment feature. |
| `c32bf9a` Workload Identity helper | Ported with read-error, subscription, context, and credential checks. |
| `d7ff99e` preview SKUs / skewer changes | Replaced by upstream GA SKU registry and upstream skewer. |
| `a305eff` fork skewer replacement | Not replayed; upstream dependency retained. |
| `3823b3e` CIG NVMe eligibility | Already covered by upstream #1642. |
| `f07ba1a` explicit NVMe controller | Ported with one SKU lookup and precise capability parsing. |
| `3f8b8bd` GPU skip tag | Ported using upstream `gpu.mode`, limited to scriptless. |

## Upgrade Existing Configurations

### GPU Driver Policy

The old fork-only field is not restored. Translate existing manifests:

| Old configuration | Current upstream configuration |
| --- | --- |
| `spec.installGPUDrivers: false` | `spec.gpu.mode: None` |
| `spec.installGPUDrivers: true` or omitted | `spec.gpu.mode: Driver` or omitted |

For a GPU Operator-managed node class:

```yaml
spec:
  gpu:
    mode: None
```

This is a fragment to merge into an existing AKSNodeClass. GPU Operator and device
plugin deployment remain the operator's responsibility. `gpu.mode: None` uses the
upstream no-driver filtering/resource behavior, which is not byte-for-byte the old
boolean implementation; verify scheduling/resource discovery for those nodes.

Pause provisioning during the old-CRD-to-new-CRD transition. Export the old manifests
first, upgrade CRDs using the installation's normal ownership mechanism, replace
the obsolete field with `gpu.mode`, then resume with the new controller. Otherwise
schema pruning can remove the old false value and expose the upstream default of
installing drivers. The port does not add a silent compatibility alias.

`gpu.nvidia.managementMode: Managed` is a separate upstream feature for AKS-managed
GPU components and is not a replacement for `gpu.mode: None`. Observe upstream
mode/image restrictions; do not enable it for unsupported VM provisioning paths.

### GPU SKU Names and Images

The fork used preview sizes with 128/256/320 CPU names. The current upstream
registry lists GA sizes such as `Standard_NC24lds_xl_RTXPRO6000BSE_v6`, the 36/72/
144/288 `ds` and `lds` variants, and their GRID v20 driver mapping. Review both
exact instance-type and SKU-family constraints in existing NodePools against the
actual regional SKU inventory. Do not mechanically rename preview sizes: GPU
count, memory, CPU count, quota families, and availability can differ.

The current RTX registry advertises Ubuntu driver support. Do not carry forward
the fork's older Windows support assumptions. See the authoritative
[GPU registry](../pkg/utils/supported-gpus.yaml),
[driver mappings](../pkg/utils/gpu.go), and
[known SKU inventory](../pkg/providers/instancetype/known_skus.yaml).

### Storage, Spot, and Identity

- NVMe controller selection is automatic; no new AKSNodeClass field is required.
  Both VM modes, CIG/SIG, and managed/ephemeral OS disks are covered. Machine API
  disk-controller selection remains owned by AKS; this port does not add a
  nonexistent Machine disk-controller field.
- Spot annotations retain the original key and NodePool template location. See
  [Spot max price](spot-node-boot-and-pricing.md) for units, defaults, float32
  limits, and batch isolation. This is a create-request ceiling, not a scheduling
  price filter or an in-place update of existing nodes.
- See [build and deployment](ubuntu-2204-build-deploy.md) for the existing-cluster
  helper, required permissions, context checks, ServiceAccount ownership, and
  values generation. Additional Machine API or external-resource permissions
  remain subject to upstream setup requirements.
- Keep upstream API hash normalization and schema migrations. Review NodeClaim
  drift and disruption budgets before resuming provisioning; crossing months of
  upstream changes is not guaranteed to preserve all existing node hashes.

## Validation

Focused checks completed during implementation:

- Spot parsing and VM payload unit tests, including NaN/infinity and invalid negatives.
- Machine billing tests, including float32 overflow/underflow.
- Spot create-path tests in all four provisioning modes, with zero VM/NIC/Machine
  creates for invalid Spot annotations.
- Batch grouping and shared payload retention for different Spot prices.
- GPU skip-tag tests across all four modes; upstream GPU tests also pass.
- NVMe exact capability matching and CIG/SIG VM payload tests.
- NVMe full template/create-path tests in both VM modes, alongside upstream
  ephemeral disk capacity and placement tests.
- ShellCheck, shell syntax, real Azure CLI local-help parameter checks, and six
  offline Workload Identity scenarios.

Final whole-repository results:

| Check | Result |
| --- | --- |
| `make test` | Passed: 42 suites in 18m02s, composite statement coverage 71.3%. |
| Upstream `verify` recipes | Passed: dependency tidy/download, bootstrap client generation, CRD generation/copy/validation, custom golangci-lint (`0 issues`), and actionlint. |
| `go build -o /dev/null ./cmd/controller` | Passed on macOS arm64. |
| Workload Identity helper | ShellCheck and all six offline mock scenarios passed. |
| Deployment guide | Shell fragments passed syntax checks; local Helm rendering confirmed image digest, Workload Identity pod label, and existing ServiceAccount settings. |
| Documentation links | All 15 local links resolved. |
| Upstream-owned artifacts | Dependencies, CRDs, and generated bootstrap clients remain identical to `8389c7e9`. |

The verification host is macOS. The Linux-only tool installer was replaced by
native installations of the same pinned Go tools and custom linter, plus modern
Bash and GNU sed. Only that installer line was removed from the Makefile input
stream; the repository Makefile and all verification recipes were left unchanged:

```bash
set -o pipefail
export PATH="/opt/homebrew/opt/gnu-sed/libexec/gnubin:/opt/homebrew/bin:$(go env GOPATH)/bin:$PATH"
export KUBEBUILDER_ASSETS="$(setup-envtest use -i -p path '1.37.x')"
sed '/^[[:space:]]*SKIP_INSTALLED=true make toolchain$/d' Makefile \
  | make -f /dev/stdin verify
make test
```

These commands assume the native tools and envtest binaries have already been
installed. Restore the usual network proxy settings when starting a new shell if
required for dependency downloads. Use ordinary `make presubmit` on a configured
Linux host.

No live Azure resources, Helm releases, node pools, images, or role assignments
were changed. Live Spot billing/eviction, GPU boot/driver installation, and Azure
image/controller compatibility still require a controlled test-cluster rollout
before production use. CI's complete Kubernetes-version matrix was not reproduced
locally; the local acceptance run used envtest Kubernetes 1.37.