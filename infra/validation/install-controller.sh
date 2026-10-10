#!/usr/bin/env bash
set -euo pipefail

token_secret=$(kubectl -n kube-system get secrets --field-selector=type=bootstrap.kubernetes.io/token -o json | jq -er '.items[0].metadata.name')
token_id=$(kubectl -n kube-system get secret "$token_secret" -o jsonpath='{.data.token-id}' | base64 -d)
token_value=$(kubectl -n kube-system get secret "$token_secret" -o jsonpath='{.data.token-secret}' | base64 -d)
test -n "$token_id"
test -n "$token_value"
kubectl -n kube-system create secret generic karpenter-bootstrap \
  --from-literal="token=${token_id}.${token_value}" --from-file=sshPublicKey=id_rsa.pub \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
unset token_id token_value

kubectl apply -f crds.yaml
kubectl wait --for=condition=Established crd/aksnodeclasses.karpenter.azure.com --timeout=90s
kubectl apply -f controller.yaml
if ! kubectl -n kube-system rollout status deployment/karpenter --timeout=240s; then
  kubectl -n kube-system get pods -l app.kubernetes.io/name=karpenter -o wide
  kubectl -n kube-system logs deployment/karpenter -c controller --tail=80
  exit 1
fi
kubectl -n kube-system get deployment karpenter
printf 'PASS controller ready\n'