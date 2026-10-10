#!/usr/bin/env bash
set -euo pipefail

kubectl apply -f official-nodeclass.yaml -f nodepool.yaml
if ! kubectl wait --for=condition=Ready aksnodeclass/val-official --timeout=180s; then
  kubectl get aksnodeclass val-official -o yaml
  kubectl -n kube-system logs deployment/karpenter -c controller --tail=80
  exit 1
fi
kubectl apply -f probe-pod.yaml
if ! kubectl -n validation wait --for=condition=Ready pod/probe --timeout=600s; then
  kubectl -n validation describe pod probe
  kubectl get nodeclaims -l karpenter.sh/nodepool=validation -o yaml
  kubectl -n kube-system logs deployment/karpenter -c controller --tail=100
  exit 1
fi
node_name=$(kubectl -n validation get pod probe -o jsonpath='{.spec.nodeName}')
kubectl get node "$node_name" -o wide
kubectl get nodeclaims -l karpenter.sh/nodepool=validation -o json | jq '{claims: [.items[] | {name:.metadata.name,providerID:.status.providerID,imageID:.status.imageID,conditions:.status.conditions}]}'
egress_ip=$(kubectl -n validation exec probe -- curl --fail --silent --show-error --connect-timeout 10 --max-time 30 https://api.ipify.org)
printf 'EGRESS_IP=%s\n' "$egress_ip"
printf 'PASS official CIG node and workload ready\n'