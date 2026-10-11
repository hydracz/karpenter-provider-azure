#!/usr/bin/env bash
set -euo pipefail

source_class=$(kubectl get aksnodeclass val-custom -o json)
for scenario in mutable-version incompatible-family; do
  class=$(jq --arg scenario "$scenario" '{apiVersion,kind,metadata:{name:"val-contract"},spec}
    | if $scenario == "mutable-version" then .spec.imageID |= sub("/versions/[^/]+$";"/versions/latest") else .spec.imageFamily="Ubuntu" end' <<< "$source_class")
  if output=$(printf '%s\n' "$class" | kubectl apply --dry-run=server -f - 2>&1); then
    echo "FAIL admission accepted $scenario" >&2
    exit 1
  fi
  [[ "$output" == *"Invalid"* && "$output" == *"imageID"* ]] || { printf '%s\n' "$output"; exit 1; }
  printf 'PASS admission rejects %s\n' "$scenario"
done
for mode in Driver None; do
  jq --arg mode "$mode" '{apiVersion,kind,metadata:{name:"val-contract"},spec} | .spec.gpu={mode:$mode}' <<< "$source_class" | kubectl apply --dry-run=server -f - >/dev/null
  printf 'PASS upstream GPU %s API admission (no GPU runtime claim)\n' "$mode"
done
jq '{apiVersion,kind,metadata:{name:"val-contract"},spec}
  | .spec.nodePublicIP={enabled:true,prefixIDs:["/subscriptions/test/resourceGroups/network/providers/Microsoft.Network/publicIPPrefixes/prefix"]}' <<< "$source_class" | kubectl apply -f -
kubectl wait --for=condition=ValidationSucceeded=false aksnodeclass/val-contract --timeout=120s
kubectl get aksnodeclass val-contract -o json | jq -e 'any(.status.conditions[]; .type=="ValidationSucceeded" and .status=="False" and .reason=="NodePublicIPUnsupportedProvisionMode")' >/dev/null
test "$(kubectl get nodeclaims -o json | jq '[.items[]|select(.spec.nodeClassRef.name=="val-contract")]|length')" -eq 0
kubectl delete aksnodeclass val-contract --wait=true --timeout=90s
printf 'PASS VM prefix configuration rejected without NodeClaim\n'