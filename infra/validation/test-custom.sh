#!/usr/bin/env bash
set -euo pipefail

test "$(kubectl get nodeclaims -l karpenter.sh/nodepool=validation -o json | jq '.items | length')" -eq 0
kubectl apply -f custom-nodeclass.yaml
kubectl wait --for=condition=Ready aksnodeclass/val-custom --timeout=180s
kubectl patch nodepool validation --type merge -p '{"spec":{"template":{"spec":{"nodeClassRef":{"group":"karpenter.azure.com","kind":"AKSNodeClass","name":"val-custom"}}}}}'
kubectl apply -f probe-pod.yaml
if ! kubectl -n validation wait --for=condition=Ready pod/probe --timeout=600s; then
  kubectl -n validation describe pod probe
  kubectl get nodeclaims -l karpenter.sh/nodepool=validation -o yaml
  kubectl -n kube-system logs deployment/karpenter -c controller --tail=100
  exit 1
fi
marker=$(kubectl -n validation exec probe -- cat /host-image/build-marker)
test "$marker" = custom-image-validation-20261011
node_name=$(kubectl -n validation get pod probe -o jsonpath='{.spec.nodeName}')
kubectl get node "$node_name" -o wide
kubectl get nodeclaims -l karpenter.sh/nodepool=validation -o json | jq '{claims: [.items[] | {name:.metadata.name,providerID:.status.providerID,imageID:.status.imageID,conditions:.status.conditions}]}'
egress_ip=$(kubectl -n validation exec probe -- curl --fail --silent --show-error --connect-timeout 10 --max-time 30 https://api.ipify.org)
printf 'BUILD_MARKER=%s\nEGRESS_IP=%s\n' "$marker" "$egress_ip"
printf 'PASS custom image node and workload ready\n'