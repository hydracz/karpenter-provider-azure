#!/usr/bin/env bash
set -euo pipefail

mode=${1:-default}
[[ "$mode" == default || "$mode" == legacy ]]
test "$(kubectl get nodeclaims -l karpenter.sh/nodepool=validation -o json | jq '.items | length')" -eq 0
kubectl get aksnodeclass val-official -o json | jq --arg mode "$mode" '
 {apiVersion,kind,metadata:{name:"val-default"},spec:(.spec|del(.nodePublicIP,.enableNodePublicIP,.osDiskSizeGB))}
 | if $mode == "legacy" then .spec.enableNodePublicIP = true else . end
' | kubectl apply -f -
kubectl wait --for=condition=Ready aksnodeclass/val-default --timeout=180s
patch=$(kubectl get nodepool validation -o json | jq '{spec:{limits:{cpu:"4"},template:{metadata:{annotations:{"karpenter.azure.com/spot-max-price":"-1"}},spec:{nodeClassRef:{group:"karpenter.azure.com",kind:"AKSNodeClass",name:"val-default"},requirements:(.spec.template.spec.requirements|map(if .key=="karpenter.sh/capacity-type" then .values=["on-demand"] else . end))}}}}')
kubectl patch nodepool validation --type merge -p "$patch"
kubectl apply -f probe-pod.yaml
kubectl -n validation wait --for=condition=Ready pod/probe --timeout=600s
node_name=$(kubectl -n validation get pod probe -o jsonpath='{.spec.nodeName}')
node=$(kubectl get node "$node_name" -o json)
if [[ "$mode" == default ]]; then
  jq -e 'all(.status.addresses[]; .type != "ExternalIP")' <<< "$node" >/dev/null
else
  jq -e 'any(.status.addresses[]; .type == "ExternalIP")' <<< "$node" >/dev/null
fi
kubectl get node "$node_name" -o wide
egress_ip=$(kubectl -n validation exec probe -- curl --fail --silent --show-error --connect-timeout 10 --max-time 30 https://api.ipify.org)
printf 'NODE_NAME=%s\nEGRESS_IP=%s\nPASS %s public-IP policy and auto-sized OS disk node ready\n' "$node_name" "$egress_ip" "$mode"