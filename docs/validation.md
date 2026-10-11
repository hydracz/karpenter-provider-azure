# Feature Series Validation

Validated on 2026-10-11 against Azure upstream main
`4d56249a17e2a99f63bf97fc77229e4e2bef12d0`.

The series contains four linear feature commits: Spot price ceilings, NVMe OS
disk controllers, fixed Compute Gallery images, and VM node public IPv4. Each
includes its own regression tests and usage documentation. Upstream GPU policy,
Machine public-IP implementation, OS disk sizing/placement, v1alpha2 and dependency
versions are retained. Deployment scripts and cloud-test infrastructure are not
part of this series.

## Checks

| Check | Result |
| --- | --- |
| Spot-only VM/Machine creation and billing regressions | PASS |
| Spot batch grouping package | PASS |
| NVMe-only capability and VM payload regressions | PASS |
| Custom-image admission, resolution, status, creation and drift | PASS |
| Public-IP hash, four-mode payload, retry and deletion regressions | PASS |
| Public-IP garbage collection and load-balancer tests | PASS |
| Strict native `CI=true` Makefile verify | PASS: 0 lint issues, no generated drift |
| Usage-document shell/YAML syntax and local links | PASS |

Each feature was checked before adding the next one. Generated CRDs belong to
the feature that changes the API; no hand-edited generated files were used.
On macOS the verify run skips only the Linux tool installer, using the required
native tools for all generation, CRD validation, lint and actionlint recipes.

The final `pkg`, `charts`, `go.mod` and `go.sum` trees were compared byte-for-byte
with the previously validated implementation and are identical. That implementation's
complete `make test` run passed 41 suites in 19m33.809s with 72.5% composite coverage.
The complete run was not repeated solely for history/documentation restructuring;
the feature-scoped checks and strict verify above were rerun for this series.

Historical cloud tests verified CPU Ubuntu2204/Ubuntu2404 image boot, custom-image
selection, controlled image replacement, NVMe, node public-IP egress, Spot create
price ceilings, permission rejection and resource cleanup. These are supporting
evidence for the unchanged implementation, not a new deployment of this series.
GPU runtime, Machine API cloud provisioning, advanced security modes and real
Spot eviction remain outside those live tests. No cluster or image was changed
while restructuring commits.