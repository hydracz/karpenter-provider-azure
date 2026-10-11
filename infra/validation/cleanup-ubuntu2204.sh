#!/usr/bin/env bash
set -euo pipefail

kubectl patch nodepool ubuntu2204-public --type merge -p '{"spec":{"limits":{"cpu":"0"}}}'
kubectl -n validation2204 delete pod probe --ignore-not-found --wait=true --timeout=60s
kubectl delete nodeclaims -l karpenter.sh/nodepool=ubuntu2204-public --wait=true --timeout=300s
test "$(kubectl get nodeclaims -l karpenter.sh/nodepool=ubuntu2204-public -o json | jq '.items|length')" -eq 0
kubectl wait --for=condition=Ready aksnodeclass/custom-ubuntu2204-public --timeout=120s
kubectl -n kube-system rollout status deployment/karpenter --timeout=120s
echo 'PASS Ubuntu2204 pool paused, no test claims, image configuration retained'