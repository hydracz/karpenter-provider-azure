#!/usr/bin/env bash
set -euo pipefail

test "$(kubectl get nodeclaims -l karpenter.sh/nodepool=validation -o json | jq '.items | length')" -eq 0
patch=$(kubectl get nodepool validation -o json | jq '{spec:{template:{metadata:{annotations:{"karpenter.azure.com/spot-max-price":"0.10"}},spec:{requirements:(.spec.template.spec.requirements | map(if .key=="karpenter.sh/capacity-type" then .values=["spot"] else . end))}}}}')
kubectl patch nodepool validation --type merge -p "$patch"
kubectl apply -f probe-pod.yaml
if ! kubectl -n validation wait --for=condition=Ready pod/probe --timeout=600s; then
  kubectl -n validation describe pod probe
  kubectl get nodeclaims -l karpenter.sh/nodepool=validation -o yaml
  kubectl -n kube-system logs deployment/karpenter -c controller --tail=100
  exit 1
fi
node_name=$(kubectl -n validation get pod probe -o jsonpath='{.spec.nodeName}')
test "$(kubectl get node "$node_name" -o jsonpath='{.metadata.labels.karpenter\.sh/capacity-type}')" = spot
kubectl get nodeclaims -l karpenter.sh/nodepool=validation -o json | jq '{claims: [.items[] | {name:.metadata.name,providerID:.status.providerID,imageID:.status.imageID,capacityType:.metadata.labels["karpenter.sh/capacity-type"]}]}'
marker=$(kubectl -n validation exec probe -- cat /host-image/build-marker)
test "$marker" = custom-image-validation-20261011
egress_ip=$(kubectl -n validation exec probe -- curl --fail --silent --show-error --connect-timeout 10 --max-time 30 https://api.ipify.org)
printf 'BUILD_MARKER=%s\nEGRESS_IP=%s\n' "$marker" "$egress_ip"
printf 'PASS Spot node ready; verify Azure billingProfile.maxPrice=0.10 separately\n'