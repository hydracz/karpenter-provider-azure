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
- Planned isolated test region: eastus2, subject to version/SKU/quota checks.
- No new Azure resources, image builds, controller deployments, role assignments,
  or Kubernetes workloads were created in this extension attempt.

## Authentication Blocker

The first Azure CLI live preflight failed:

```text
az aks get-versions --location eastus2 --subscription <selected-subscription> --output json
AADSTS50078: Presented multi-factor authentication has expired due to policies
configured by your administrator; refresh multi-factor authentication.
```

The command exited nonzero before the chained vCPU/public-IP quota checks. No
resource-creation commands were attempted. Read-only inventory from another tool
is not used to bypass the CLI's authentication requirement.

The user must renew Azure CLI authentication directly in their own terminal using
the tenant and scope shown by the CLI, then select the intended subscription.
Do not send passwords, MFA codes, tokens, or device-login credentials through chat.
No logout, identity switch, or alternate credential workaround was attempted.

## Live Acceptance Plan

Follow [Testing Strategy](upstream-porting.md#testing-strategy) and the independent
[custom image](custom-images.md) and [public IP](node-public-ip.md) guides.

| Journey | Current status | Required evidence |
| --- | --- | --- |
| Cluster and controller startup | UNVERIFIED | Correct isolated context, healthy controller, working system-node egress. |
| Official CIG and NVMe node | UNVERIFIED | Ready node/Pod, exact CIG version, NVMe controller where required. |
| Generalized custom Gallery image | UNVERIFIED | Image publication, scoped access, matching VM image ID, build marker on a Ready node. |
| Direct node public-IP egress | UNVERIFIED | NIC binding, protected NSG, observed external source IP, NAT/LB/UDR inventory. |
| Spot maximum price | UNVERIFIED | Separate Spot VM creation and expected billing MaxPrice. |
| Failure and deletion cleanup | UNVERIFIED | Provider-owned VM, NIC, disks and public IP absent after cleanup; unrelated resources untouched. |

## Verdict

```text
environment:
  docker: AVAILABLE
  node: AVAILABLE
  browser-tier: SKIPPED (Kubernetes controller, no browser UI)
  infra-tier: local envtest PASS; live Azure blocked by MFA expiry
startup: UNVERIFIED (live controller not deployed)
integration: PASS (focused tests and 41 canonical suites), exit_code: 0
e2e: UNVERIFIED, exit_code: not-run (preflight authentication failure)
overall: NEEDS_SIGNOFF (live Azure validation requires renewed authentication)
```