#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
directory=$(mktemp -d)
trap 'rm -rf "$directory"' EXIT
export MOCK_LOG="$directory/operations"
MOCK_IMAGE="quay.io/hydracz/karpenter-controller:v20261011-dev@sha256:$(printf '%064d' 0)"
export MOCK_IMAGE
kubectl() {
  while [[ "$1" == -n || "$1" == --namespace || "$1" == --kubeconfig ]]; do shift 2; done
  case "$1 $2" in
    "config view")
      local server=https://test.aks.example
      if [[ "$MOCK_SCENARIO" == wrong-context ]]; then server=https://other.aks.example; fi
      if [[ "$MOCK_SCENARIO" == in-cluster || "$MOCK_SCENARIO" == wrong-ca ]]; then
        printf '%s\n' '{"clusters":[]}'
      else
        printf '{"current-context":"test","clusters":[{"cluster":{"server":"%s"}}]}\n' "$server"
      fi
      ;;
    "get configmap")
      local certificate=test-ca
      if [[ "$MOCK_SCENARIO" == wrong-ca ]]; then certificate=other-ca; fi
      jq -n --arg ca "$certificate" '{data:{"ca.crt":$ca}}'
      ;;
    "get nodes") printf '%s\n' '{"items":[{"metadata":{"labels":{"kubernetes.io/os":"linux"}},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}' ;;
    "get secrets")
      jq -n '{items:[{metadata:{creationTimestamp:"2026-01-01T00:00:00Z"},data:{"usage-bootstrap-authentication":("true"|@base64),"token-id":("abcdef"|@base64),"token-secret":("0123456789abcdef"|@base64)}}]}'
      ;;
    "get secret") printf '%s\n' '123' ;;
    "get Deployment"|"get CustomResourceDefinition"|"get deployment")
      if [[ " $* " == *" -o name "* ]]; then printf '%s\n' "$2/test"; return; fi
      local owner=karpenter
      if [[ "$2" == CustomResourceDefinition ]]; then owner=karpenter-crd; fi
      local annotation='{}'
      if [[ "$MOCK_SCENARIO" == foreign ]]; then annotation='{"meta.helm.sh/release-name":"another","meta.helm.sh/release-namespace":"kube-system"}'; fi
      if [[ "$MOCK_SCENARIO" == existing ]]; then annotation=$(jq -n --arg owner "$owner" '{"meta.helm.sh/release-name":$owner,"meta.helm.sh/release-namespace":"kube-system"}'); fi
      jq -n --arg owner "$owner" --argjson annotations "$annotation" --arg image "$MOCK_IMAGE" '{metadata:{labels:{"app.kubernetes.io/instance":$owner},annotations:$annotations},spec:{template:{spec:{containers:[{name:"controller",image:$image}]}}}}'
      ;;
    "create namespace") printf '%s\n' '{}' ;;
    "apply -f")
      local payload
      payload=$(cat)
      if jq -e '.kind == "Secret"' <<< "$payload" >/dev/null; then
        jq -e '.stringData.token == "abcdef.0123456789abcdef" and .metadata.namespace == "kube-system"' <<< "$payload" >/dev/null
      fi
      printf 'apply\n' >> "$MOCK_LOG"
      ;;
    "annotate Deployment"|"annotate CustomResourceDefinition"|"label Deployment"|"label CustomResourceDefinition") printf 'ownership\n' >> "$MOCK_LOG" ;;
    "wait --for=condition=Established"|"rollout status"|"get pods") ;;
    *) echo "Unexpected kubectl invocation: $*" >&2; return 90 ;;
  esac
}
helm() {
  case "$1 $2" in
    "upgrade --help") printf '%s\n' '--atomic' ;;
    "upgrade karpenter-crd"|"upgrade karpenter")
      [[ " $* " == *" --atomic "* && " $* " == *" --wait "* ]]
      if [[ "$2" == karpenter ]]; then
        jq -e '.podAnnotations["karpenter.azure.com/bootstrap-secret-version"] == "123"' effective-values.json >/dev/null
      fi
      printf '%s\n' "$2" >> "$MOCK_LOG"
      ;;
    "status karpenter") printf '%s\n' '{"name":"karpenter","version":1,"info":{"status":"deployed"}}' ;;
    *) echo "Unexpected helm invocation: $*" >&2; return 91 ;;
  esac
}
export -f kubectl helm
printf '%s\n' '[{"kind":"Deployment","metadata":{"name":"karpenter","namespace":"kube-system"}}]' > "$directory/controller-resources.json"
printf '%s\n' '[{"kind":"CustomResourceDefinition","metadata":{"name":"aksnodeclasses.karpenter.azure.com"}}]' > "$directory/crd-resources.json"
cd "$directory"
for scenario in adopt existing in-cluster wrong-context wrong-ca no-adopt foreign; do
  export MOCK_SCENARIO=$scenario
  : > "$MOCK_LOG"
  adopt=true
  if [[ "$scenario" == no-adopt ]]; then adopt=false; fi
  jq -n --argjson adopt "$adopt" --arg image "$MOCK_IMAGE" '{namespace:"kube-system",release:"karpenter",crdRelease:"karpenter-crd",endpoint:"https://test.aks.example",caCertificate:"test-ca",sshPublicKey:"ssh-rsa test",adopt:$adopt,values:{controller:{image:{repository:($image|split(":")[0]),tag:"v20261011-dev",digest:("sha256:" + ("0"*64))}}}}' > deployment.json
  printf '%s\n' '{}' > values.json
  exit_code=0
  output=$("$BASH" "$SCRIPT_DIR/helm-install.sh" 2>&1) || exit_code=$?
  if [[ "$scenario" == adopt || "$scenario" == existing || "$scenario" == in-cluster ]]; then
    [[ "$exit_code" == 0 && "$output" == *"PASS Helm controller deployment"* && "$output" != *"0123456789abcdef"* ]] || { printf '%s\n' "$output"; exit 1; }
    [[ $(tail -n 2 "$MOCK_LOG") == $'karpenter-crd\nkarpenter' ]]
  else
    [[ "$exit_code" != 0 && ! -s "$MOCK_LOG" ]] || { printf '%s\n' "$output"; exit 1; }
  fi
  printf 'PASS %s\n' "$scenario"
done