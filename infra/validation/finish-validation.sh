#!/usr/bin/env bash
set -euo pipefail

egress_ip=$(kubectl -n validation exec probe -- curl --fail --silent --show-error --connect-timeout 10 --max-time 30 https://api.ipify.org)
marker=$(kubectl -n validation exec probe -- cat /host-image/build-marker)
test "$marker" = custom-image-validation-20261011
printf 'SPOT_EGRESS_IP=%s\nBUILD_MARKER=%s\n' "$egress_ip" "$marker"
bash test-cleanup.sh
patch=$(kubectl get nodepool validation -o json | jq '{spec:{template:{metadata:{annotations:{"karpenter.azure.com/spot-max-price":"-1"}},spec:{requirements:(.spec.template.spec.requirements | map(if .key=="karpenter.sh/capacity-type" then .values=["on-demand"] else . end))}}}}')
kubectl patch nodepool validation --type merge -p "$patch"
kubectl -n kube-system get deployment karpenter
kubectl get nodepool validation
printf 'PASS workload cleanup and on-demand configuration restored\n'