#!/usr/bin/env bash
set -euo pipefail

kubectl get nodeclaims -l karpenter.sh/nodepool=validation -o json | jq '{deleting: [.items[] | {name:.metadata.name,providerID:.status.providerID}]}'
kubectl -n validation delete pod probe --ignore-not-found --wait=true --timeout=120s
kubectl delete nodeclaims -l karpenter.sh/nodepool=validation --wait=true --timeout=600s
test "$(kubectl get nodeclaims -l karpenter.sh/nodepool=validation -o json | jq '.items | length')" -eq 0
printf 'PASS NodeClaim deletion completed; verify Azure VM/NIC/IP absence separately\n'