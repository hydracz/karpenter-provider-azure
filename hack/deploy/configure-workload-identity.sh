#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 || $# -gt 6 ]]; then
  echo "Usage: $0 <cluster-name> <resource-group> <namespace> [service-account-name] [identity-name] [federated-credential-name]" >&2
  exit 1
fi

CLUSTER_NAME=$1
RG=$2
KARPENTER_NAMESPACE=$3
KARPENTER_SERVICE_ACCOUNT_NAME=${4:-karpenter-sa}
IDENTITY_NAME=${5:-karpentermsi}
FEDERATED_CREDENTIAL_NAME=${6:-KARPENTER_FID}

for command_name in az jq kubectl; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Error: command '$command_name' is required" >&2
    exit 1
  fi
done

ACCOUNT_ARGS=(--output json)
if [[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
  ACCOUNT_ARGS+=(--subscription "$AZURE_SUBSCRIPTION_ID")
fi
ACCOUNT_JSON=$(az account show "${ACCOUNT_ARGS[@]}")
SUBSCRIPTION_ID=$(jq -er '.id | select(type == "string" and length > 0)' <<< "$ACCOUNT_JSON")
TENANT_ID=$(jq -er '.tenantId | select(type == "string" and length > 0)' <<< "$ACCOUNT_JSON")

az_in_subscription() {
  az "$@" --subscription "$SUBSCRIPTION_ID" --output json
}

AKS_JSON=$(az_in_subscription aks show --name "$CLUSTER_NAME" --resource-group "$RG")
OIDC_ISSUER=$(jq -r '.oidcIssuerProfile.issuerUrl // empty' <<< "$AKS_JSON")
if [[ -z "$OIDC_ISSUER" ]] || ! jq -e '.securityProfile.workloadIdentity.enabled == true' <<< "$AKS_JSON" >/dev/null; then
  echo "Error: enable OIDC and Workload Identity on the cluster, then rerun this script:" >&2
  printf 'az aks update --name %q --resource-group %q --subscription %q --enable-oidc-issuer --enable-workload-identity --output json\n' "$CLUSTER_NAME" "$RG" "$SUBSCRIPTION_ID" >&2
  exit 1
fi

KUBECTL_CONTEXT=${KUBECTL_CONTEXT:-$(kubectl config current-context)}
KUBE_CONFIG=$(kubectl --context "$KUBECTL_CONTEXT" config view --minify --output json)
if ! jq -e --argjson aks "$AKS_JSON" '
  (.clusters[0].cluster.server | ascii_downcase | rtrimstr("/") | sub(":443$"; "")) as $server
  | [$aks.fqdn, $aks.privateFqdn]
  | map(select(type == "string" and length > 0) | "https://" + ascii_downcase)
  | index($server) != null
' <<< "$KUBE_CONFIG" >/dev/null; then
  echo "Error: kubectl context '$KUBECTL_CONTEXT' does not point to AKS cluster '$CLUSTER_NAME'; no resources changed" >&2
  exit 1
fi

LOCATION=$(jq -er '.location | select(type == "string" and length > 0)' <<< "$AKS_JSON")
RG_MC=$(jq -er '.nodeResourceGroup | select(type == "string" and length > 0)' <<< "$AKS_JSON")
RG_MC_JSON=$(az_in_subscription group show --name "$RG_MC")
RG_MC_RES=$(jq -er '.id | select(type == "string" and length > 0)' <<< "$RG_MC_JSON")

IDENTITIES_JSON=$(az_in_subscription identity list --resource-group "$RG")
IDENTITY_JSON=$(jq -c --arg name "$IDENTITY_NAME" '[.[] | select(.name == $name)][0] // empty' <<< "$IDENTITIES_JSON")
if [[ -z "$IDENTITY_JSON" ]]; then
  echo "Creating managed identity '$IDENTITY_NAME' in '$RG' ..."
  IDENTITY_JSON=$(az_in_subscription identity create --name "$IDENTITY_NAME" --resource-group "$RG" --location "$LOCATION")
fi
CLIENT_ID=$(jq -er '.clientId | select(type == "string" and length > 0)' <<< "$IDENTITY_JSON")
PRINCIPAL_ID=$(jq -er '.principalId | select(type == "string" and length > 0)' <<< "$IDENTITY_JSON")

SUBJECT="system:serviceaccount:${KARPENTER_NAMESPACE}:${KARPENTER_SERVICE_ACCOUNT_NAME}"
FICS_JSON=$(az_in_subscription identity federated-credential list --identity-name "$IDENTITY_NAME" --resource-group "$RG")
EXISTING_FIC=$(jq -c --arg name "$FEDERATED_CREDENTIAL_NAME" '[.[] | select(.name == $name)][0] // empty' <<< "$FICS_JSON")
if [[ -n "$EXISTING_FIC" ]]; then
  if ! jq -e --arg issuer "$OIDC_ISSUER" --arg subject "$SUBJECT" '
    .issuer == $issuer and .subject == $subject and .audiences == ["api://AzureADTokenExchange"]
  ' <<< "$EXISTING_FIC" >/dev/null; then
    echo "Error: existing federated credential '$FEDERATED_CREDENTIAL_NAME' has a different issuer, subject, or audience; review it or choose another name" >&2
    exit 1
  fi
else
  az_in_subscription identity federated-credential create \
    --name "$FEDERATED_CREDENTIAL_NAME" \
    --identity-name "$IDENTITY_NAME" \
    --resource-group "$RG" \
    --issuer "$OIDC_ISSUER" \
    --subject "$SUBJECT" \
    --audiences api://AzureADTokenExchange >/dev/null
fi

for role in "Virtual Machine Contributor" "Network Contributor" "Managed Identity Operator"; do
  ASSIGNMENTS_JSON=$(az_in_subscription role assignment list \
    --assignee-object-id "$PRINCIPAL_ID" --scope "$RG_MC_RES" --role "$role")
  if [[ $(jq 'length' <<< "$ASSIGNMENTS_JSON") -eq 0 ]]; then
    az_in_subscription role assignment create \
      --assignee-object-id "$PRINCIPAL_ID" \
      --assignee-principal-type ServicePrincipal \
      --scope "$RG_MC_RES" \
      --role "$role" >/dev/null
  fi
done

kubectl --context "$KUBECTL_CONTEXT" create namespace "$KARPENTER_NAMESPACE" --dry-run=client --output yaml \
  | kubectl --context "$KUBECTL_CONTEXT" apply -f - >/dev/null
kubectl --context "$KUBECTL_CONTEXT" create serviceaccount "$KARPENTER_SERVICE_ACCOUNT_NAME" --namespace "$KARPENTER_NAMESPACE" --dry-run=client --output yaml \
  | kubectl --context "$KUBECTL_CONTEXT" apply -f - >/dev/null
kubectl --context "$KUBECTL_CONTEXT" annotate serviceaccount "$KARPENTER_SERVICE_ACCOUNT_NAME" --namespace "$KARPENTER_NAMESPACE" \
  azure.workload.identity/client-id="$CLIENT_ID" azure.workload.identity/tenant-id="$TENANT_ID" --overwrite >/dev/null

echo "Workload Identity configured for ${KARPENTER_NAMESPACE}/${KARPENTER_SERVICE_ACCOUNT_NAME}."
echo "Identity client ID: $CLIENT_ID"
echo "For a new Helm release, use serviceAccount.create=false and serviceAccount.name=$KARPENTER_SERVICE_ACCOUNT_NAME."
echo "For an existing release, preserve ServiceAccount ownership and configure its workload identity annotations in Helm values."
echo "The controller pod must have the azure.workload.identity/use=true label."