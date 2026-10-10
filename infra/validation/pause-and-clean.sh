#!/usr/bin/env bash
set -euo pipefail

kubectl patch nodepool validation --type merge -p '{"spec":{"limits":{"cpu":"0"}}}'
nodes=$(kubectl get nodes -l karpenter.sh/nodepool=validation -o json | jq -r '.items[].metadata.name')
for node_name in $nodes; do
  kubectl get pods -A --field-selector="spec.nodeName=$node_name" -o json | jq '{pods:[.items[] | {name:.metadata.name,namespace:.metadata.namespace,owner:.metadata.ownerReferences[0].kind,node:.spec.nodeName}]}'
done
kubectl -n validation delete pod probe --ignore-not-found --wait=false
kubectl delete nodeclaims -l karpenter.sh/nodepool=validation --wait=false
printf 'PASS validation pool paused and worker deletion requested\n'