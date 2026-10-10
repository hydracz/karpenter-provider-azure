#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export AZURE_SUBSCRIPTION_ID=test-subscription
export KUBECTL_CONTEXT=test-context

az() {
  [[ " $* " == *" --output json "* ]] || { echo "Mock: missing explicit JSON output" >&2; return 90; }
  [[ " $* " == *" --subscription test-subscription "* ]] || { echo "Mock: wrong subscription" >&2; return 91; }
  local command_key="$1 $2"
  if [[ "$command_key" == "identity federated-credential" || "$command_key" == "role assignment" ]]; then
    command_key="$command_key $3"
  fi
  case "$command_key" in
    "account show") printf '%s\n' '{"id":"test-subscription","tenantId":"test-tenant"}' ;;
    "aks show")
      if [[ "$MOCK_SCENARIO" == "disabled" ]]; then
        printf '%s\n' '{"securityProfile":{"workloadIdentity":{"enabled":false}}}'
      else
        printf '%s\n' '{"location":"eastus","nodeResourceGroup":"node-rg","fqdn":"test.aks.example","oidcIssuerProfile":{"issuerUrl":"https://issuer.example/"},"securityProfile":{"workloadIdentity":{"enabled":true}}}'
      fi
      ;;
    "group show") printf '%s\n' '{"id":"/subscriptions/test-subscription/resourceGroups/node-rg"}' ;;
    "identity list")
      if [[ "$MOCK_SCENARIO" == "read-failure" ]]; then echo "Mock: identity read denied" >&2; return 92; fi
      if [[ "$MOCK_SCENARIO" == "new" ]]; then
        printf '%s\n' '[]'
      else
        printf '%s\n' '[{"name":"karpentermsi","clientId":"test-client","principalId":"test-principal"}]'
      fi
      ;;
    "identity create")
      echo "MOCK_WRITE identity" >&2
      printf '%s\n' '{"name":"karpentermsi","clientId":"test-client","principalId":"test-principal"}'
      ;;
    "identity federated-credential list")
      if [[ "$MOCK_SCENARIO" == "new" ]]; then
        printf '%s\n' '[]'
      else
        local subject="system:serviceaccount:kube-system:karpenter-sa"
        if [[ "$MOCK_SCENARIO" == "credential-mismatch" ]]; then subject="other-subject"; fi
        printf '{"name":"KARPENTER_FID","issuer":"https://issuer.example/","subject":"%s","audiences":["api://AzureADTokenExchange"]}\n' "$subject" | jq -s '.'
      fi
      ;;
    "identity federated-credential create")
      [[ " $* " == *" --subject system:serviceaccount:kube-system:karpenter-sa "* && " $* " == *" --audiences api://AzureADTokenExchange "* ]] || return 93
      echo "MOCK_WRITE federated-credential" >&2
      printf '%s\n' '{}'
      ;;
    "role assignment list")
      if [[ "$MOCK_SCENARIO" == "new" ]]; then printf '%s\n' '[]'; else printf '%s\n' '[{"id":"existing-assignment"}]'; fi
      ;;
    "role assignment create")
      [[ " $* " == *" --scope /subscriptions/test-subscription/resourceGroups/node-rg "* ]] || return 94
      echo "MOCK_WRITE role" >&2
      printf '%s\n' '{}'
      ;;
    *) echo "Mock: unexpected az command: $*" >&2; return 95 ;;
  esac
}

kubectl() {
  [[ "$1" == "--context" && "$2" == "test-context" ]] || return 96
  shift 2
  case "$1 $2" in
    "config view")
      local server="https://test.aks.example"
      if [[ "$MOCK_SCENARIO" == "wrong-context" ]]; then server="https://other.aks.example"; fi
      printf '{"clusters":[{"cluster":{"server":"%s"}}]}\n' "$server"
      ;;
    "create namespace"|"create serviceaccount") printf '%s\n' '{}' ;;
    "apply -f") cat >/dev/null; echo "MOCK_KUBE_WRITE apply" >&2 ;;
    "annotate serviceaccount") echo "MOCK_KUBE_WRITE annotate" >&2 ;;
    *) echo "Mock: unexpected kubectl command: $*" >&2; return 97 ;;
  esac
}

export -f az kubectl

for scenario in new existing wrong-context disabled read-failure credential-mismatch; do
  exit_code=0
  output=$(MOCK_SCENARIO="$scenario" "$BASH" "$SCRIPT_DIR/configure-workload-identity.sh" test-cluster cluster-rg kube-system 2>&1) || exit_code=$?
  case "$scenario" in
    new)
      [[ "$exit_code" -eq 0 ]] || { printf '%s\n' "$output"; exit 1; }
      [[ $(grep -c '^MOCK_WRITE identity$' <<< "$output") -eq 1 ]]
      [[ $(grep -c '^MOCK_WRITE federated-credential$' <<< "$output") -eq 1 ]]
      [[ $(grep -c '^MOCK_WRITE role$' <<< "$output") -eq 3 ]]
      [[ "$output" == *"MOCK_KUBE_WRITE annotate"* ]]
      ;;
    existing)
      [[ "$exit_code" -eq 0 && "$output" != *"MOCK_WRITE "* && "$output" == *"MOCK_KUBE_WRITE annotate"* ]] || { printf '%s\n' "$output"; exit 1; }
      ;;
    *)
      [[ "$exit_code" -ne 0 && "$output" != *"MOCK_WRITE "* && "$output" != *"MOCK_KUBE_WRITE "* ]] || { printf '%s\n' "$output"; exit 1; }
      case "$scenario" in
        wrong-context) [[ "$output" == *"does not point to AKS cluster"* ]] ;;
        disabled) [[ "$output" == *"enable OIDC and Workload Identity"* ]] ;;
        read-failure) [[ "$output" == *"identity read denied"* ]] ;;
        credential-mismatch) [[ "$output" == *"different issuer, subject, or audience"* ]] ;;
      esac
      ;;
  esac
  printf 'PASS %s\n' "$scenario"
done