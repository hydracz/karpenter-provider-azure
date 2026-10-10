#!/usr/bin/env bash
set -euo pipefail

image=$(cat controller-image.txt)
test -n "$image"
kubectl -n kube-system set image deployment/karpenter "controller=$image"
kubectl -n kube-system rollout status deployment/karpenter --timeout=240s
printf 'PASS updated controller ready\n'