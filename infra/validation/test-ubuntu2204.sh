#!/usr/bin/env bash
set -euo pipefail

kubectl apply -f ubuntu2204-public.yaml
kubectl wait --for=condition=Ready aksnodeclass/custom-ubuntu2204-public --timeout=180s
kubectl -n validation2204 wait --for=condition=Ready pod/probe --timeout=600s
node_name=$(kubectl -n validation2204 get pod probe -o jsonpath='{.spec.nodeName}')
kubectl get node "$node_name" -o json | jq -e '.status.nodeInfo.osImage | startswith("Ubuntu 22.04")' >/dev/null
kubectl get nodeclaims -l karpenter.sh/nodepool=ubuntu2204-public -o json | jq -e 'any(.items[]; (.status.imageID|contains("/images/aksUbuntu2204Gen2/versions/1.0.0")) and any(.status.conditions[]; .type=="Ready" and .status=="True"))' >/dev/null
egress=$(kubectl -n validation2204 exec probe -- curl --fail --silent --show-error --connect-timeout 10 --max-time 30 https://api.ipify.org)
kubectl get node "$node_name" -o json | jq -e --arg ip "$egress" 'any(.status.addresses[]; .type=="ExternalIP" and .address==$ip)' >/dev/null
kubectl get node "$node_name" -o wide
printf 'NODE_NAME=%s\nEGRESS_IP=%s\nPASS Ubuntu2204 Gallery node and direct public IP egress\n' "$node_name" "$egress"