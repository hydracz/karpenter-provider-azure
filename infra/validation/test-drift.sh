#!/usr/bin/env bash
set -euo pipefail

old_claim=$(kubectl get nodeclaims -l karpenter.sh/nodepool=validation -o json | jq -er '.items | if length == 1 then .[0].metadata.name else error("Expected one active test claim") end')
kubectl patch nodepool validation --type merge -p '{"spec":{"disruption":{"budgets":[{"nodes":"0"}]}}}'
old_image=$(kubectl get aksnodeclass val-custom -o jsonpath='{.spec.imageID}')
new_image="${old_image%/versions/*}/versions/1.0.1"
kubectl patch aksnodeclass val-custom --type merge -p "$(jq -n --arg image "$new_image" '{spec:{imageID:$image}}')"
kubectl wait --for=condition=Ready aksnodeclass/val-custom --timeout=180s
kubectl get aksnodeclass val-custom -o json | jq -e --arg image "$new_image" 'any(.status.images[]; .id == $image)' >/dev/null
kubectl wait --for=condition=Drifted nodeclaim/"$old_claim" --timeout=300s
kubectl get nodeclaim "$old_claim" -o json | jq '{name:.metadata.name,image:.status.imageID,drift:[.status.conditions[]|select(.type=="Drifted")]}'
kubectl -n validation delete pod probe --ignore-not-found --wait=true --timeout=60s
kubectl delete nodeclaim "$old_claim" --wait=true --timeout=300s
kubectl apply -f probe-pod.yaml
kubectl -n validation wait --for=condition=Ready pod/probe --timeout=600s
kubectl get nodeclaims -l karpenter.sh/nodepool=validation -o json | jq -e --arg image "$new_image" 'length > 0 and any(.items[]; .status.imageID == $image and any(.status.conditions[]; .type=="Ready" and .status=="True"))' >/dev/null
marker=$(kubectl -n validation exec probe -- cat /host-image/build-marker)
test "$marker" = custom-image-validation-20261011
node_name=$(kubectl -n validation get pod probe -o jsonpath='{.spec.nodeName}')
egress_ip=$(kubectl -n validation exec probe -- curl --fail --silent --show-error --connect-timeout 10 --max-time 30 https://api.ipify.org)
printf 'OLD_CLAIM=%s\nNODE_NAME=%s\nIMAGE_ID=%s\nEGRESS_IP=%s\nPASS image status update, drift detection and controlled replacement\n' "$old_claim" "$node_name" "$new_image" "$egress_ip"