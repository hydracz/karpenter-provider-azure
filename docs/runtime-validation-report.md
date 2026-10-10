# Custom Image and Public IP Validation

## Scope

This report covers removal of the fork-specific GPU skip behavior, fixed custom
Compute Gallery images, opt-in node public IPv4, and regression of the retained
Spot/NVMe behavior. The previous 42-suite baseline is recorded separately in
[the port assessment](upstream-porting.md).

## Local Evidence

| Check | Result | Exit code |
| --- | --- | --- |
| Upstream GPU driver test and original tag implementation comparison | PASS | 0 |
| Custom Gallery metadata/cache/mode restriction tests | PASS | 0 |
| Custom image bootstrap in both VM modes | PASS | 0 |
| Custom image status changes and read-failure readiness clearing | PASS | 0 |
| imageID admission/persistence and legacy hash tests | PASS | 0 |
| Custom image VM payload and version drift, both VM modes | PASS | 0 |
| Owned public IP SDK lifecycle and external-resource protection | PASS | 0 |
| Public IP default/false hash compatibility | PASS | 0 |
| Orphaned public IP garbage collection and live/foreign/attached protection | PASS | 0 |
| Public IP configuration in four modes, retry, delete, failed VM cleanup | PASS: 14 cases | 0 |
| Whole-repository custom golangci-lint and controller build | PASS, 0 lint issues | 0 |
| Final `CI=true` verify with native macOS tools | PASS: generated CRDs/clients stable, 0 lint issues, actionlint passed | 0 |
| New guide shell syntax and local links | PASS | 0 |
| Canonical `make test` for this extension | PASS: 41 suites in 18m28s; composite coverage 71.5% | 0 |
| Final Gallery-region validation refinement | PASS: whole imagefamily package and scoped lint after the full run | 0 |
| Live-discovered LB/public-IP fix `f03cdd78` | PASS: complete loadbalancer, instance, garbagecollection, cloudprovider packages and scoped lint | 0 |

Local tests use envtest Kubernetes 1.37 and fake Azure clients. The SDK lifecycle
unit test uses a local HTTP policy, not Azure resources. These tests do not prove
that a real custom image boots or that packets leave via the intended public IP.
The suite count decreased from the initial port because the dedicated
fork-specific GPU tag test package was removed. The custom-image feature was also
compiled from an isolated staged snapshot before its commit, without the later
public-IP code, to verify the feature commit is independently buildable.

## Live Environment

- Docker daemon: available, verified with `docker info`.
- Node.js: available, v26.8.2; no browser tier is needed for this controller.
- Azure MCP read-only inventory identified an enabled default learning subscription.
- An existing Terraform-owned AKS cluster was identified and was not modified.
- Isolated resource group: `rg-karpenter-validation-20261011`, eastus2.
- Private AKS: `aks-karpenter-validation`, Kubernetes 1.35.8; node resource group
  `rg-karpenter-nodes-20261011`. ARM deployment completed successfully.
- Controller deployed and Ready (Run Command `1025e58616c745628529aed6170da676`,
  exit code 0). Image:
  `acrkarpx56h2kjx4nz54.azurecr.io/karpenter/controller@sha256:7b64cd306cf06a4de3bddb74e025fc1dc6fb80cbb548f12b7764363bed74cc12`.
- Live testing found and fixed the LB outbound-pool/public-IP incompatibility in
  `f03cdd78`. The corrected controller digest is
  `sha256:1c292b7aeb6392118d164b617cdff6ae681c39387e33e765727477a4200330b6`.
  Its local Docker execution, targeted tests, four complete affected Go packages,
  and scoped lint all passed.
- Final validation image is a static Linux amd64 build from `f03cdd78`; upstream
  CGO-enabled release settings are unchanged. Local Docker execution passed.
- Workload Identity uses a dedicated controller identity, the exact
  `system:serviceaccount:kube-system:karpenter-sa` federation subject, node-RG
  VM/Network/Managed Identity roles, and Reader on the custom Gallery definition.
- The system node was Ready with public IP `20.109.0.143`. The managed subnet has
  implicit outbound disabled. A Standard LB with an outbound rule exists; no NAT
  Gateway exists in the node resource group. Worker egress verification passed.
- The system pool was temporarily expanded to two `Standard_D2s_v5` nodes for
  Run Command capacity and was restored to one node, state `Succeeded`, after testing.
- Official CIG base `2404gen2containerd/202610.08.0` metadata was verified as
  generalized Linux x64, Hyper-V V2, with SCSI/NVMe support. A dedicated builder
  was customized without a kubelet kubeconfig, deallocated/generalized, and custom
  Gallery version `karpenterValidation/aksUbuntu2404Gen2/1.0.0` was published
  successfully. The builder VM, NIC, disk, and its public IP were deleted.

### Deployment Findings

- Server-side what-if rejected AKS-managed image cache with a BYO node VNet.
- Server-side what-if also rejected Workload Identity with outbound type `none`.
  The compatible test deployment retains Workload Identity and Standard LB
  configuration, with node public IPs. Direct node egress was demonstrated;
  this environment does not prove elimination of all LB resource costs.
- AKS Run Command's CLI wait returned an invalid-status error. The validation
  helper uses the same authorized ARM runCommand/result API and records only
  command IDs in logs. Complete server-provided asynchronous URLs are kept only
  in user-private temporary files. Some long cleanup-command result lookups were
  unavailable; actual resources were checked before idempotent replay.
- Run Command Pods do not tolerate the custom CriticalAddonsOnly system taint;
  the new test system pool has that taint removed. Workload probes explicitly
  select the validation NodePool and cannot run on system nodes.
- Test worker templates now use a dedicated `validation-only` taint, tolerated
  by the probe. This keeps management Pods without a matching toleration off
  workers being cleaned up; system Pods with broad tolerations can still use them.
- Azure rejected NIC public-IP attachment while the NIC referenced an outbound
  rule's backend pool. The provider now excludes those pools, preserves eligible
  inbound pools and applies the same rule during retries. This was reproduced
  live as `NicWithPublicIpCannotReferencePoolWithOutboundRule`, then corrected
  and verified by the successful official-image run below.

### Official Image and Direct Egress

Run Command `a6c87033796846758672becb296ee8c7` completed with exit code 0.
Node `aks-validation-px82s` joined as Ready on Kubernetes 1.35.8 and its test Pod
became Ready. The exact official image was CIG `2404gen2containerd/202610.08.0`.
Azure reported `Standard_D4ds_v6`, `diskControllerType=NVMe`, and ephemeral OS
placement `NvmeDisk`.

The Pod observed `20.161.72.15` from the external IP echo endpoint, matching the
node's dedicated Standard IPv4. The NIC had the managed AKS NSG and only the
`kubernetes` inbound backend pool, not `aksOutboundBackendPool`. No NAT Gateway
was present. The managed LB resource still exists; this proves direct node egress,
not zero total LB resource cost.

After the NodeClaim deletion completed, `check-azure-node.sh deleted
aks-validation-px82s` returned exit code 0 and confirmed that the VM, NIC, disk,
and owned public IP no longer existed.

### Custom Image and Spot

Run Command `9ee3e0e7d0b64b548e4d5192bc649d62` completed with exit code 0.
Node `aks-validation-6lq8d` and its probe were Ready. The node's read-only host
mount contained `custom-image-validation-20261011`, the marker written on the
independent CIG-based builder. Azure confirmed Gallery image
`karpenterValidation/aksUbuntu2404Gen2/1.0.0`, NVMe, and `NvmeDisk` ephemeral OS.
The Pod's observed source IP `68.220.176.86` matched the node public IP.
The Azure checker returned exit code 0; all of this node's resources were later
confirmed deleted.

Run Command `038cafff422d4ce1adfe0b4f66c42c0b` completed with exit code 0 for
Spot node `aks-validation-6g8j6`. Azure independently confirmed:

- `priority: Spot` and `billingProfile.maxPrice: 0.1`.
- The same custom Gallery version, `diskControllerType: NVMe`, and `NvmeDisk` OS.
- A Standard public IP, `20.96.176.108`, and no outbound-rule pool membership.

The Azure assertion script passed with expected max price 0.10. NodeClaim cleanup
completed, and the VM/NIC/disk/public-IP absence check also returned exit code 0.
This verifies the create-request price ceiling, not actual billing totals or
price-driven Spot eviction.

### Permission Rejection and Final State

Run Command `a13cfbd2932f45579753cf61b640000f` completed with exit code 0.
The intentionally inaccessible image reference returned Azure 403
`AuthorizationFailed`; NodeClass `ImagesReady` became false with reason
`CustomImageError`, `status.images` was empty, and no NodeClaim was created.
There was no fallback to an official image. The test NodeClass was deleted.

Independent final-state command `f8d29a9cfbb245efbefbd12c87f69325` returned exit
code 0: controller Available, no validation NodeClaims, and the four-CPU NodePool
restored to on-demand with the dedicated test taint. Scaling the system pool back
to one subsequently triggered another worker carrying a Cilium operator Pod; the pool was
therefore paused at zero CPU for final retention and that worker was cleaned up.
The builder VM, its public IP and all test worker
VM/NIC/disk/public-IP resources were removed. The cluster, controller, ACR, custom
Gallery version, and paused test NodePool remain for inspection. Restore its CPU
limit to four only when deliberately running another test.

Final confirmation `1f73a3c5f8084961983a07c1e477d80e` returned exit code 0 after
all cleanup and system scale-down: one Ready system node, controller 1/1
Available, zero validation NodeClaims, and `validation.spec.limits.cpu: "0"`.
The separate Azure resource query returned no `aks-validation*` resources.

Retained resources still incur ongoing charges. The system VM's checked retail
rate was USD 0.096/hour, excluding disks, IP, registry, Gallery storage, LB and
data transfer. No NAT Gateway was deployed. Remove the dedicated environment
when it is no longer needed.

## Authentication History

Authentication was renewed by the user on 2026-10-11. The resumed Azure CLI
preflight successfully listed AKS versions, eastus2 compute/public-IP quotas,
and official AKS Ubuntu 24.04 Gen2 CIG versions. Version `202610.08.0` was
observed as published on 2026-10-09. Live deployment and the bounded tests completed; the
earlier MFA failure below is retained as historical evidence, not a current
blocker.

The first Azure CLI live preflight failed:

```text
az aks get-versions --location eastus2 --subscription <selected-subscription> --output json
AADSTS50078: Presented multi-factor authentication has expired due to policies
configured by your administrator; refresh multi-factor authentication.
```

The command exited nonzero before the chained vCPU/public-IP quota checks. No
resource-creation commands were attempted. Read-only inventory from another tool
is not used to bypass the CLI's authentication requirement.

The user renewed Azure CLI authentication directly in their own terminal using
the tenant and scope shown by the CLI and selected the intended subscription.
Do not send passwords, MFA codes, tokens, or device-login credentials through chat.
No logout, identity switch, or alternate credential workaround was attempted.

## Live Acceptance Results

Follow [Testing Strategy](upstream-porting.md#testing-strategy) and the independent
[custom image](custom-images.md) and [public IP](node-public-ip.md) guides.

| Journey | Current status | Required evidence |
| --- | --- | --- |
| Cluster and controller startup | PASS, exit code 0 | Private cluster, Ready system node and controller, isolated identity and context. |
| Official CIG and NVMe node | PASS, exit code 0 | Ready node/Pod, exact CIG version, NVMe controller and NvmeDisk OS placement. |
| Generalized custom Gallery image | PASS, exit code 0 | Published generalized image; Ready node/Pod; matching VM image ID and build marker. |
| Direct node public-IP egress | PASS, exit code 0 | Observed source IP equals node public IP; NSG present; no outbound pool membership or NAT. |
| Spot maximum price | PASS, exit code 0 | Ready Spot VM and actual Azure billing MaxPrice 0.1. |
| Deletion cleanup | PASS, exit code 0 | Official/custom/Spot VM/NIC/disk/public IP absent after cleanup; builder resources removed. |
| Inaccessible image | PASS, exit code 0 | Azure 403, no resolved images/fallback/NodeClaim, rejected class cleaned up. |

### Remaining Boundaries

- Live workloads used `aksscriptless`, Ubuntu 24.04 and CPU-only Intel v6 VMs.
  Other provisioning modes retain local fake-client coverage, not live certification.
- GPU nodes, advanced FIPS/Trusted Launch/Kata images, the upstream CGO/FIPS release
  configuration, the full Kubernetes-version matrix, and actual Spot eviction were
  not exercised. Custom-image advanced security restrictions remain documented.
- Immutable-image version drift has local regression coverage; this run proved
  creation from a custom version, not an automated live image upgrade rollout.
- Provider fault injection and foreign-resource protection have local coverage;
  the live run additionally exercised failed NIC attachment before its fix and
  verified no leftover worker resources. This is not an exhaustive failure matrix.
- The existence of a managed LB means this environment does not demonstrate zero
  LB resource cost, even though direct worker egress bypassed its outbound pool.

## Verdict

```text
environment:
  docker: AVAILABLE
  node: AVAILABLE
  browser-tier: SKIPPED (Kubernetes controller, no browser UI)
  infra-tier: local envtest PASS; live Azure private AKS
startup: PASS, exit_code: 0 (private AKS and controller Ready)
integration: PASS (focused tests and 41 canonical suites), exit_code: 0
e2e: PASS, exit_code: 0 (bounded official/custom/Spot/public-IP/NVMe/cleanup journeys)
overall: PASS for the documented bounded validation scope; production rollout needs its own review
```