#!/usr/bin/env bash
set -euo pipefail

for tool in kubectl helm jq; do command -v "$tool" >/dev/null; done
namespace=$(jq -er '.namespace' deployment.json)
release=$(jq -er '.release' deployment.json)
crd_release=$(jq -er '.crdRelease' deployment.json)
endpoint=$(jq -er '.endpoint' deployment.json)
context=$(kubectl config view -o json | jq -r '.["current-context"] // empty')
if [[ -n "$context" ]]; then
  server=$(kubectl config view --minify -o json | jq -er '.clusters[0].cluster.server')
  [[ "${server,,}" == "${endpoint,,}" || "${server,,}" == "${endpoint,,}:443" ]] || {
    echo "Kubernetes context does not match the selected AKS cluster." >&2
    exit 1
  }
else
  expected_ca=$(jq -er '.caCertificate' deployment.json)
  actual_ca=$(kubectl -n kube-system get configmap kube-root-ca.crt -o json | jq -er '.data["ca.crt"] | rtrimstr("\n")')
  [[ "$actual_ca" == "$expected_ca" ]] || {
    echo "In-cluster certificate authority does not match the selected AKS cluster." >&2
    exit 1
  }
fi
kubectl get nodes -o json | jq -e 'any(.items[]; .metadata.labels["kubernetes.io/os"] == "linux" and any(.status.conditions[]; .type == "Ready" and .status == "True"))' >/dev/null
check_resources() {
  local inventory=$1 owner=$2 object existing name kind object_namespace current_release current_namespace
  while IFS= read -r object; do
    name=$(jq -r '.metadata.name' <<< "$object")
    kind=$(jq -r '.kind' <<< "$object")
    object_namespace=$(jq -r '.metadata.namespace // empty' <<< "$object")
    local args=()
    if [[ -n "$object_namespace" ]]; then args+=(--namespace "$object_namespace"); fi
    existing=$(kubectl "${args[@]}" get "$kind" "$name" --ignore-not-found -o json)
    if [[ -z "$existing" ]]; then continue; fi
    current_release=$(jq -r '.metadata.annotations["meta.helm.sh/release-name"] // empty' <<< "$existing")
    current_namespace=$(jq -r '.metadata.annotations["meta.helm.sh/release-namespace"] // empty' <<< "$existing")
    if [[ -n "$current_release" && ( "$current_release" != "$owner" || "$current_namespace" != "$namespace" ) ]]; then
      echo "Refusing to take $kind/$name from another Helm release." >&2
      return 1
    fi
    if [[ -z "$current_release" ]]; then
      [[ $(jq -r '.adopt' deployment.json) == true ]] || {
        echo "$kind/$name already exists without Helm ownership; review and use --adopt-existing." >&2
        return 1
      }
      if [[ "$kind" != CustomResourceDefinition ]]; then
        jq -e --arg owner "$owner" '.metadata.labels["app.kubernetes.io/instance"] == $owner' <<< "$existing" >/dev/null || {
          echo "Refusing unrelated resource $kind/$name." >&2
          return 1
        }
      fi
    fi
  done < <(jq -c '.[]' "$inventory")
}
check_resources controller-resources.json "$release"
check_resources crd-resources.json "$crd_release"
adopt_resources() {
  local inventory=$1 owner=$2 object name kind object_namespace
  while IFS= read -r object; do
    name=$(jq -r '.metadata.name' <<< "$object")
    kind=$(jq -r '.kind' <<< "$object")
    object_namespace=$(jq -r '.metadata.namespace // empty' <<< "$object")
    local args=()
    if [[ -n "$object_namespace" ]]; then args+=(--namespace "$object_namespace"); fi
    if [[ -n $(kubectl "${args[@]}" get "$kind" "$name" --ignore-not-found -o name) ]]; then
      kubectl "${args[@]}" annotate "$kind" "$name" meta.helm.sh/release-name="$owner" meta.helm.sh/release-namespace="$namespace" --overwrite >/dev/null
      kubectl "${args[@]}" label "$kind" "$name" app.kubernetes.io/managed-by=Helm --overwrite >/dev/null
    fi
  done < <(jq -c '.[]' "$inventory")
}
adopt_resources controller-resources.json "$release"
adopt_resources crd-resources.json "$crd_release"
kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
token=$(kubectl -n kube-system get secrets --field-selector=type=bootstrap.kubernetes.io/token -o json | jq -er '
  [.items[] | select(.data["usage-bootstrap-authentication"] == ("true"|@base64))
   | select((.data.expiration // "" | @base64d) as $expiration | $expiration == "" or ($expiration|fromdateiso8601) > now + 3600)]
  | sort_by(.metadata.creationTimestamp) | last | (.data["token-id"]|@base64d) + "." + (.data["token-secret"]|@base64d)')
[[ "$token" =~ ^[a-z0-9]{6}\.[a-z0-9]{16}$ ]]
ssh_key=$(jq -er '.sshPublicKey' deployment.json)
jq -n --arg namespace "$namespace" --arg token "$token" --arg key "$ssh_key" '{apiVersion:"v1",kind:"Secret",metadata:{name:"karpenter-bootstrap",namespace:$namespace},type:"Opaque",stringData:{token:$token,sshPublicKey:$key}}' | kubectl apply -f - >/dev/null
unset token ssh_key
bootstrap_revision=$(kubectl -n "$namespace" get secret karpenter-bootstrap -o jsonpath='{.metadata.resourceVersion}')
jq --arg revision "$bootstrap_revision" '.podAnnotations["karpenter.azure.com/bootstrap-secret-version"] = $revision' values.json > effective-values.json
upgrade_args=(--install --namespace "$namespace" --timeout 8m --wait)
if helm upgrade --help | grep -q -- --rollback-on-failure; then
  upgrade_args+=(--rollback-on-failure)
else
  upgrade_args+=(--atomic)
fi
helm upgrade "$crd_release" crds.tgz "${upgrade_args[@]}"
kubectl wait --for=condition=Established crd/aksnodeclasses.karpenter.azure.com --timeout=90s
helm upgrade "$release" controller.tgz "${upgrade_args[@]}" -f effective-values.json
kubectl -n "$namespace" rollout status deployment/karpenter --timeout=300s
expected=$(jq -r '.values.controller.image | .repository + ":" + .tag + "@" + .digest' deployment.json)
kubectl -n "$namespace" get deployment karpenter -o json | jq -e --arg expected "$expected" '.spec.template.spec.containers[] | select(.name == "controller") | .image == $expected' >/dev/null
helm status "$release" --namespace "$namespace" -o json | jq '{name,version,status:.info.status}'
kubectl -n "$namespace" get pods -l app.kubernetes.io/instance=karpenter -o wide
echo "PASS Helm controller deployment and pinned image"