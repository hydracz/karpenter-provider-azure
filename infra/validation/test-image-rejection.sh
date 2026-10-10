#!/usr/bin/env bash
set -euo pipefail

kubectl get aksnodeclass val-custom -o json | jq '{apiVersion,kind,metadata:{name:"val-rejected"},spec:(.spec | .imageID |= sub("/images/[^/]+/";"/images/not-authorized/"))}' | kubectl apply -f -
if ! kubectl wait --for=condition=ImagesReady=false aksnodeclass/val-rejected --timeout=120s; then
  kubectl get aksnodeclass val-rejected -o yaml
  exit 1
fi
nodeclass=$(kubectl get aksnodeclass val-rejected -o json)
jq -e '(.status.images // [] | length) == 0 and any(.status.conditions[]; .type == "ImagesReady" and .status == "False" and .reason == "CustomImageError")' <<< "$nodeclass" >/dev/null
jq '{name:.metadata.name,images:.status.images,conditions:[.status.conditions[] | select(.type=="ImagesReady")]}' <<< "$nodeclass"
test "$(kubectl get nodeclaims -o json | jq '[.items[] | select(.spec.nodeClassRef.name == "val-rejected")] | length')" -eq 0
kubectl delete aksnodeclass val-rejected --wait=true --timeout=90s
printf 'PASS inaccessible custom image rejected without fallback or NodeClaim\n'