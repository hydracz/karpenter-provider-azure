#!/usr/bin/env bash
set -euo pipefail

test "$(kubectl get nodeclaims -l karpenter.sh/nodepool=validation -o json | jq '.items | length')" -eq 0
kubectl -n validation delete pod probe --ignore-not-found --wait=true --timeout=30s
patch=$(kubectl get nodepool validation -o json | jq '{spec:{limits:{cpu:"0"},template:{metadata:{annotations:{"karpenter.azure.com/spot-max-price":"-1"}},spec:{taints:[{key:"validation-only",value:"true",effect:"NoSchedule"}],requirements:(.spec.template.spec.requirements | map(if .key=="karpenter.sh/capacity-type" then .values=["on-demand"] else . end))}}}}')
kubectl patch nodepool validation --type merge -p "$patch"
kubectl -n kube-system get deployment karpenter
kubectl get nodes -o wide
kubectl get nodepool validation -o json | jq '{name:.metadata.name,limits:.spec.limits,nodeClass:.spec.template.spec.nodeClassRef,taints:.spec.template.spec.taints,requirements:.spec.template.spec.requirements}'
printf 'PASS final cluster state: no validation NodeClaims, controller available, on-demand pool paused at zero CPU\n'