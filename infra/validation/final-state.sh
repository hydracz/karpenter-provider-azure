#!/usr/bin/env bash
set -euo pipefail

test "$(kubectl get nodeclaims -l karpenter.sh/nodepool=validation -o json | jq '.items | length')" -eq 0
kubectl -n validation delete pod probe --ignore-not-found --wait=true --timeout=30s
patch=$(kubectl get nodepool validation -o json | jq '{spec:{limits:{cpu:"0"},disruption:{budgets:[{nodes:"10%"}]},template:{metadata:{annotations:{"karpenter.azure.com/spot-max-price":"-1"}},spec:{nodeClassRef:{group:"karpenter.azure.com",kind:"AKSNodeClass",name:"val-custom"},taints:[{key:"validation-only",value:"true",effect:"NoSchedule"}],requirements:(.spec.template.spec.requirements | map(if .key=="karpenter.sh/capacity-type" then .values=["on-demand"] else . end))}}}}')
kubectl patch nodepool validation --type merge -p "$patch"
image=$(kubectl get aksnodeclass val-custom -o jsonpath='{.spec.imageID}')
kubectl patch aksnodeclass val-custom --type merge -p "$(jq -n --arg image "${image%/versions/*}/versions/1.0.0" '{spec:{imageID:$image}}')"
kubectl wait --for=condition=Ready aksnodeclass/val-custom --timeout=180s
kubectl delete aksnodeclass val-default --ignore-not-found --wait=true --timeout=60s
kubectl -n kube-system rollout status deployment/karpenter --timeout=180s
kubectl -n kube-system get deployment karpenter
kubectl get nodes -o wide
kubectl get nodepool validation -o json | jq '{name:.metadata.name,limits:.spec.limits,nodeClass:.spec.template.spec.nodeClassRef,taints:.spec.template.spec.taints,requirements:.spec.template.spec.requirements}'
printf 'PASS final cluster state: no validation NodeClaims, controller available, on-demand pool paused at zero CPU\n'